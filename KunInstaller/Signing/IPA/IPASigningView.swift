import SwiftUI
import UniformTypeIdentifiers
import ZsignC

struct IPASigningView: View {
    // KI_SIGN_TO_INSTALL_CALLBACK
    // Notify the existing installer after successful signing.
    let onSignedIPAReady: (URL) -> Bool

    // KI_APP_LIBRARY_HANDOFF
    var initialIPAURL: URL? = nil
    var onInitialIPAImported: ((URL) -> Void)? = nil
    var onSigningStateChanged: ((Bool) -> Void)? = nil

    // KI_SIGNING_INSTALL_CONTROLS
    let installationStatus: String
    let installationDetail: String
    let installationProgress: Double?
    let installationInProgress: Bool
    let appleTVConnected: Bool
    let onInstall: () -> Void

    @State private var installationReady = false

    @State private var records: [SigningCertificateRecord] = []
    @State private var selectedCertificateID: UUID?
    @State private var showingIPAImporter = false
    @State private var workspace: IPAWorkspace?
    @State private var appInfo: [String: Any]?

    @State private var selectedIPAName = "No IPA selected"
    @State private var message = ""
    @State private var isError = false
    @State private var isSigning = false
    @State private var hasSignedWorkspace = false
    @State private var signingViewVisible = true
    @State private var lastHandledInitialIPAURL: URL?

    var body: some View {
        Form {
            Section("tvOS Application") {
                Button {
                    showingIPAImporter = true
                } label: {
                    Label("Select IPA", systemImage: "doc.badge.plus")
                }
                .disabled(isSigning)

                Text(selectedIPAName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let appInfo {
                Section("Application Information") {
                    LabeledContent(
                        "Name",
                        value: appInfo["name"] as? String ?? "Unknown"
                    )

                    LabeledContent(
                        "Bundle ID",
                        value: appInfo["bundleID"] as? String ?? "Unknown"
                    )

                    LabeledContent(
                        "Version",
                        value: "\(appInfo["version"] as? String ?? "?") (\(appInfo["build"] as? String ?? "?"))"
                    )

                    LabeledContent(
                        "Executable",
                        value: appInfo["executable"] as? String ?? "Unknown"
                    )
                }
            }

            Section("Signing Certificate") {
                if records.isEmpty {
                    Text("No signing certificates saved.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker(
                        "Certificate",
                        selection: $selectedCertificateID
                    ) {
                        Text("Select Certificate")
                            .tag(nil as UUID?)

                        ForEach(records) { record in
                            Text(record.nickname)
                                .tag(Optional(record.id))
                        }
                    }
                }
            }


            Section("tvOS IPA Signing") {
                Button {
                    signIPA()
                } label: {
                    if isSigning {
                        ProgressView("Signing IPA...")
                    } else {
                        Label("Sign tvOS IPA", systemImage: "signature")
                    }
                }
                .disabled(
                    workspace == nil ||
                    selectedCertificateID == nil ||
                    isSigning ||
                    installationInProgress
                )
            }

            // KI_SIGNING_INSTALL_UI
            if installationReady {
                Section("Install to Apple TV") {
                    Button {
                        onInstall()
                    } label: {
                        HStack(spacing: 10) {
                            Image("AppleTVLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: 32, height: 32)
                            Text("Install to Apple TV")
                        }
                    }
                    .disabled(
                        !appleTVConnected ||
                        installationInProgress
                    )

                    if !appleTVConnected {
                        Text("Connect to Apple TV before installing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Installation Status") {
                    HStack(spacing: 12) {
                        if installationStatus == "Complete" {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else if installationStatus == "Failed" {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        } else if installationInProgress {
                            ProgressView()
                        } else {
                            Image(systemName: "circle")
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text(installationStatus)
                                .font(.headline)

                            Text(installationDetail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if let installationProgress {
                        ProgressView(
                            value: installationProgress,
                            total: 1.0
                        )
                    }
                }
            }

            Section("Signing Status") {
                if message.isEmpty {
                    Text("Select an IPA and signing certificate.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(message)
                        .foregroundStyle(
                            isError ? .red : .secondary
                        )
                }
            }
        }
        .navigationTitle("tvOS IPA Signing")
        .fileImporter(
            isPresented: $showingIPAImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "ipa") ?? .data
            ],
            allowsMultipleSelection: false
        ) { result in
            importIPA(result)
        }
        .task {
            loadCertificates()
        }
        .onAppear {
            signingViewVisible = true
            importInitialIPAIfNeeded()
        }
        .onChange(of: initialIPAURL) { _, _ in
            importInitialIPAIfNeeded()
        }
        .onChange(of: isSigning) { _, signing in
            onSigningStateChanged?(signing)
        }
        .onDisappear {
            signingViewVisible = false

            if !isSigning {
                workspace?.cleanup()
                workspace = nil
            }
        }
    }


    private func signIPA() {
        guard !isSigning,
              let workspace,
              let selectedCertificateID,
              let record = records.first(where: {
                  $0.id == selectedCertificateID
              }) else {
            return
        }

        isSigning = true
        hasSignedWorkspace = false
        installationReady = false
        message = "Signing and packaging tvOS IPA..."
        isError = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try IPASigningCoordinator.sign(
                    workspace: workspace,
                    record: record
                )

                let extracted = workspace.directory.appendingPathComponent(
                    "Extracted",
                    isDirectory: true
                )

                let packaged = workspace.directory.appendingPathComponent(
                    "Signed.ipa"
                )

                guard KIPackageIPA(
                    extracted.path,
                    packaged.path
                ) else {
                    throw IPAWorkspaceError.invalidIPA
                }

                guard let metadata = KIInspectIPA(
                    packaged.path
                ) as? [String: Any],
                let bundleID = metadata["bundleID"] as? String,
                !bundleID.isEmpty else {
                    throw IPAWorkspaceError.invalidIPA
                }

                let fm = FileManager.default

                let directory = fm.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                )[0].appendingPathComponent(
                    "KhmerInstaller/SignedTVOS",
                    isDirectory: true
                )

                try fm.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )

                let destination = directory.appendingPathComponent(
                    UUID().uuidString + ".ipa"
                )

                try fm.moveItem(
                    at: packaged,
                    to: destination
                )

                DispatchQueue.main.async {
                    // KI_SIGNED_IPA_READY
                    // The permanent signed IPA has been saved.
                    installationReady = onSignedIPAReady(destination)
                    message = installationReady
                        ? "tvOS IPA signed and ready to install: " + bundleID
                        : "IPA signed, but installation preparation failed."

                    hasSignedWorkspace = true
                    isError = false
                    isSigning = false

                    if !signingViewVisible {
                        workspace.cleanup()
                        self.workspace = nil
                    }
                }

            } catch {
                DispatchQueue.main.async {
                    hasSignedWorkspace = false
                    installationReady = false
                    message = "tvOS signing failed: "
                        + error.localizedDescription
                    isError = true
                    isSigning = false

                    if !signingViewVisible {
                        workspace.cleanup()
                        self.workspace = nil
                    }
                }
            }
        }
    }

    private func loadCertificates() {
        do {
            records = try CertificateVault.shared.loadRecords()
        } catch {
            message = "Unable to load certificates: "
                + error.localizedDescription
            isError = true
        }
    }

    // KI_APP_LIBRARY_INITIAL_IMPORT
    private func importInitialIPAIfNeeded() {
        guard let initialIPAURL,
              lastHandledInitialIPAURL?.standardizedFileURL !=
                initialIPAURL.standardizedFileURL else {
            return
        }

        lastHandledInitialIPAURL = initialIPAURL
        importIPA(.success([initialIPAURL]))
    }

    private func importIPA(
        _ result: Result<[URL], Error>
    ) {
        do {
            let urls = try result.get()
            guard let url = urls.first else { return }

            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let prepared = try IPAWorkspace.prepare(from: url)

            guard let inspected = KIInspectIPA(
                prepared.sourceIPA.path
            ) as? [String: Any] else {
                prepared.cleanup()
                throw IPAWorkspaceError.invalidIPA
            }


            workspace?.cleanup()
            hasSignedWorkspace = false
            installationReady = false
            workspace = prepared
            appInfo = inspected

            selectedIPAName = url.lastPathComponent
            message = "IPA imported into the signing workspace."
            isError = false

            if initialIPAURL?.standardizedFileURL ==
                url.standardizedFileURL {
                onInitialIPAImported?(url)
            }
        } catch {
            message = "Unable to import IPA: "
                + error.localizedDescription
            isError = true
        }
    }
}
