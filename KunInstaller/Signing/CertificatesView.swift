import SwiftUI
import UniformTypeIdentifiers
import Zsign

struct CertificatesView: View {
    @State private var records: [SigningCertificateRecord] = []

    @State private var p12Data: Data?
    @State private var profileData: Data?

    @State private var p12Filename = "No certificate selected"
    @State private var profileFilename = "No profile selected"

    @State private var password = ""
    @State private var nickname = ""

    @State private var showingFileImporter = false
    @State private var importingP12 = false
    @State private var additionalProfileRecord: SigningCertificateRecord?
    @State private var isValidating = false

    @State private var message = ""
    @State private var isError = false
    @State private var certificateToDelete: SigningCertificateRecord?

    private let p12Type =
        UTType(filenameExtension: "p12") ?? .data

    private let profileType =
        UTType(filenameExtension: "mobileprovision") ?? .data

    var body: some View {
        List {
            Section("Import Signing Credentials") {
                Button {
                    importingP12 = true
                    showingFileImporter = true
                } label: {
                    Label(
                        "Choose .p12 Certificate",
                        systemImage: "key"
                    )
                }

                Text(p12Filename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                Button {
                    importingP12 = false
                    showingFileImporter = true
                } label: {
                    Label(
                        "Choose Provisioning Profile",
                        systemImage: "doc.badge.gearshape"
                    )
                }

                Text(profileFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                TextField("Nickname (Optional)", text: $nickname)

                SecureField("Certificate Password", text: $password)

                Button {
                    validateAndSave()
                } label: {
                    if isValidating {
                        ProgressView("Validating...")
                    } else {
                        Label(
                            "Validate and Save",
                            systemImage: "checkmark.shield"
                        )
                    }
                }
                .disabled(
                    p12Data == nil ||
                    profileData == nil ||
                    isValidating
                )
            }


            if !message.isEmpty {
                Section("Status") {
                    Text(message)
                        .foregroundStyle(
                            isError ? .red : .secondary
                        )
                        .textSelection(.enabled)
                }
            }

            Section("Saved Certificates") {
                if records.isEmpty {
                    Text("No signing certificates saved yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(records) { record in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(record.nickname)
                                .font(.headline)

                            Text(
                                "\(1 + record.additionalProfileFilenames.count) provisioning profile(s) saved"
                            )
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            if let expiry = record.expirationDate {
                                let formattedExpiry = expiry.formatted(
                                    date: .abbreviated,
                                    time: .omitted
                                )

                                Text("Expires \(formattedExpiry)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button {
                            verifySavedCredentials(record)
                        } label: {
                            Label(
                                "Verify Saved Credentials",
                                systemImage: "checkmark.shield"
                            )
                        }
                        .disabled(isValidating)

                        Button {
                            additionalProfileRecord = record
                            showingFileImporter = true
                        } label: {
                            Label(
                                "Add Provisioning Profile",
                                systemImage: "doc.badge.plus"
                            )
                        }
                        .disabled(isValidating)

                        Button(role: .destructive) {
                            certificateToDelete = record
                        } label: {
                            Label(
                                "Delete Certificate",
                                systemImage: "trash"
                            )
                        }
                        .disabled(isValidating)
                    }
                }
            }
        }
        .navigationTitle("Certificates")
        .confirmationDialog(
            "Delete Certificate?",
            isPresented: Binding(
                get: { certificateToDelete != nil },
                set: { if !$0 { certificateToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let record = certificateToDelete {
                Button(
                    "Delete \(record.nickname)",
                    role: .destructive
                ) {
                    certificateToDelete = nil
                    deleteRecord(record)
                }
            }

            Button("Cancel", role: .cancel) {
                certificateToDelete = nil
            }
        } message: {
            Text(
                "This removes the saved certificate, all associated provisioning profiles, and its Keychain password."
            )
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            if let record = additionalProfileRecord {
                additionalProfileRecord = nil
                importAdditionalProfile(result, to: record)
            } else {
                loadSelectedFile(result, isP12: importingP12)
            }
        }
        .task {
            refreshRecords()
        }
    }

    private func loadSelectedFile(
        _ result: Result<[URL], Error>,
        isP12: Bool
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

            let data = try Data(contentsOf: url)

            if isP12 {
                p12Data = data
                p12Filename = url.lastPathComponent
            } else {
                profileData = data
                profileFilename = url.lastPathComponent
            }

            message = ""
            isError = false
        } catch {
            message = "Unable to read selected file: \(error.localizedDescription)"
            isError = true
        }
    }




    private func importAdditionalProfile(
        _ result: Result<[URL], Error>,
        to record: SigningCertificateRecord
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

            let data = try Data(contentsOf: url)

            isValidating = true
            message = "Validating additional tvOS profile..."
            isError = false

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try CertificateVault.shared.addAdditionalProfile(
                        data,
                        to: record
                    )

                    DispatchQueue.main.async {
                        refreshRecords()
                        message = "Additional tvOS profile saved successfully."
                        isError = false
                        isValidating = false
                    }
                } catch {
                    DispatchQueue.main.async {
                        message = "Additional profile failed: "
                            + error.localizedDescription
                        isError = true
                        isValidating = false
                    }
                }
            }
        } catch {
            message = "Unable to import additional profile: "
                + error.localizedDescription
            isError = true
        }
    }

    private func verifySavedCredentials(
        _ record: SigningCertificateRecord
    ) {
        isValidating = true
        message = "Verifying saved signing credentials..."
        isError = false

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let vault = CertificateVault.shared

                let p12Data = try Data(
                    contentsOf: vault.fileURL(
                        for: record.p12Filename
                    )
                )

                let profileData = try Data(
                    contentsOf: vault.fileURL(
                        for: record.profileFilename
                    )
                )

                let savedPassword = try vault.password(
                    for: record
                )

                let identity = try SigningCredentialValidator.importIdentity(
                    p12Data: p12Data,
                    password: savedPassword
                )

                let certificate = try SigningCredentialValidator.certificate(
                    from: identity
                )

                _ = try SigningCredentialValidator.validateCertificateDates(
                    certificate
                )

                try SigningCredentialValidator.validateProfileSignerTrust(
                    profileData: profileData
                )

                _ = try SigningCredentialValidator.validateProfile(
                    profileData: profileData,
                    certificate: certificate
                )

                DispatchQueue.main.async {
                    message =
                        "PASS: Saved certificate, provisioning profile, and Keychain password verified."
                    isError = false
                    isValidating = false
                }
            } catch {
                DispatchQueue.main.async {
                    message =
                        "Saved credential verification failed: "
                        + error.localizedDescription
                    isError = true
                    isValidating = false
                }
            }
        }
    }

    private func validateAndSave() {
        guard let p12Data, let profileData else {
            return
        }

        isValidating = true
        message = "Validating signing credentials..."
        isError = false

        let enteredPassword = password
        let enteredNickname = nickname

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let identity = try SigningCredentialValidator.importIdentity(
                    p12Data: p12Data,
                    password: enteredPassword
                )

                let certificate = try SigningCredentialValidator.certificate(
                    from: identity
                )

                // Verify the signing certificate's validity dates.
                _ = try SigningCredentialValidator.validateCertificateDates(
                    certificate
                )

                try SigningCredentialValidator.validateProfileSignerTrust(
                    profileData: profileData
                )

                let profile = try SigningCredentialValidator.validateProfile(
                    profileData: profileData,
                    certificate: certificate
                )

                DispatchQueue.main.async {
                    do {
                        _ = try CertificateVault.shared.add(
                            p12Data: p12Data,
                            profileData: profileData,
                            password: enteredPassword,
                            nickname: enteredNickname,
                            expirationDate: profile.expirationDate
                        )

                        password = ""
                        nickname = ""
                        self.p12Data = nil
                        self.profileData = nil

                        p12Filename = "No certificate selected"
                        profileFilename = "No profile selected"

                        refreshRecords()

                        message =
                            "Certificate and profile passed local compatibility checks and were saved. Profile: "
                            + profile.name

                        isError = false
                    } catch {
                        message =
                            "Unable to save credentials: "
                            + error.localizedDescription
                        isError = true
                    }

                    isValidating = false
                }
            } catch {
                DispatchQueue.main.async {
                    message =
                        "Validation failed: "
                        + error.localizedDescription
                    isError = true
                    isValidating = false
                }
            }
        }
    }

    private func refreshRecords() {
        do {
            records = try CertificateVault.shared.loadRecords()
        } catch {
            message = "Unable to load certificates: \(error.localizedDescription)"
            isError = true
        }
    }

    private func deleteRecord(_ record: SigningCertificateRecord) {
        do {
            try CertificateVault.shared.delete(record)
            refreshRecords()
            message = "Certificate removed."
            isError = false
        } catch {
            message = "Unable to remove certificate: \(error.localizedDescription)"
            isError = true
        }
    }
}
