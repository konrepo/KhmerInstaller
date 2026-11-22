import SwiftUI
import ZsignC
import CryptoKit
import Network
import NetworkExtension
import UniformTypeIdentifiers

struct PairingDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let identifier: String
    let type: String
    let domain: String
}

struct ContentView: View {

    @State private var devices: [PairingDevice] = []

    @State private var status =
        "Searching for pairable Apple TVs..."

    @State private var pairingDeviceID: String?

    @State private var pairingStatus = ""

    @State private var pin = ""

    @State private var showingPINEntry = false

    @State private var appleTVUDID: String?

    @State private var pairingClient: RemotePairingClient?
    @State private var tunnelClient:
        RemotePairingClient?

    @State private var packetTunnelManager:
        NETunnelProviderManager?

    @State private var vpnStatus: NEVPNStatus = .invalid

    @State private var installationStatus =
        "Idle"

    @State private var installationDetail =
        "Wait for installation to be completed ."

    @State private var installationProgress:
        Double?

    @State private var installationMonitorTask:
        Task<Void, Never>?

    // KI_INSTALL_ACTIVITY_GUARD
    @State private var installationInProgress = false
    // KI_MANUAL_CANCEL_BUTTON
    @State private var showingCancelConfirmation = false
    @State private var cancellationRequestInProgress = false

    @State private var selectedIPAName =
        "No IPA selected"

    // KI_ACTIVE_INSTALLATION_ID
    // Identifies the installation attempt accepted by the tunnel.
    @State private var activeInstallationID: String?

    @State private var selectedIPAURL:
        URL?

    @State private var tunnelBrowser: NWBrowser?

    @State private var tunnelServiceBrowser: NetServiceBrowser?
    private var tunnelServices: [NetService] = []

    @State private var bonjourResolver =
        RemotePairingBonjourResolver()

    private let serviceType =
        "_remotepairing-manual-pairing._tcp"

    private let tunnelServiceType =
        "_remotepairing._tcp"

    var body: some View {

        NavigationStack {

            List {

                Section("1. Instruction: Apple TV") {

                    Text(
                        "Apple TV → Settings → Remotes and Devices → Remote App and Devices"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Section("2. Pair Apple TV") {

                    if devices.isEmpty {

                        HStack {
                            ProgressView()

                            Text(status)
                                .foregroundStyle(.secondary)
                        }

                    } else {

                        ForEach(devices) { device in

                            VStack(
                                alignment: .leading,
                                spacing: 8
                            ) {

                                Button {
                                    startPairing(device)
                                } label: {

                                    HStack {

                                        Image(
                                            systemName: "appletv"
                                        )
                                        .font(.title2)

                                        Text(device.name)
                                            .font(.headline)

                                        Spacer()

                                        Image(
                                            systemName: "chevron.right"
                                        )
                                        .foregroundStyle(
                                            .secondary
                                        )
                                    }
                                }
                                .buttonStyle(.plain)

                                if
                                    pairingDeviceID == device.id,
                                    let appleTVUDID
                                {

                                    VStack(
                                        alignment: .leading,
                                        spacing: 6
                                    ) {

                                        Text(
                                            "UDID: \(appleTVUDID)"
                                        )
                                        .font(.caption)
                                        .foregroundStyle(
                                            .secondary
                                        )
                                        .textSelection(.enabled)

                                        Button("Copy UDID") {

                                            UIPasteboard.general.string =
                                                appleTVUDID
                                        }
                                        .font(.caption)
                                    }

                                } else {

                                    Text(
                                        "UDID: Not retrieved"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(
                                        .secondary
                                    )
                                }

                                if pairingDeviceID == device.id {

                                    Text(pairingStatus)
                                        .font(.subheadline)
                                        .foregroundStyle(
                                            .secondary
                                        )

                                    if showingPINEntry {

                                        VStack(
                                            alignment: .leading,
                                            spacing: 10
                                        ) {

                                            Text(
                                                "Enter the 6-digit PIN shown on Apple TV"
                                            )
                                            .font(.subheadline)
                                            .fontWeight(
                                                .medium
                                            )

                                            HStack {

                                                TextField(
                                                    "123456",
                                                    text: $pin
                                                )
                                                .keyboardType(
                                                    .numberPad
                                                )
                                                .textFieldStyle(
                                                    .roundedBorder
                                                )
                                                .onChange(
                                                    of: pin
                                                ) { _, newValue in

                                                    let digits =
                                                        newValue.filter {
                                                            $0.isNumber
                                                        }

                                                    pin =
                                                        String(
                                                            digits.prefix(
                                                                6
                                                            )
                                                        )
                                                }

                                                Button("Pair") {
                                                    submitPIN()
                                                }
                                                .disabled(
                                                    pin.count != 6
                                                )
                                            }
                                        }
                                        .padding(.top, 4)
                                    } else {

                                        ProgressView()
                                            .scaleEffect(0.8)
                                    }

                                    if !showingPINEntry {

                                        Button("Get UDID") {

                                            Task {
                                                await fetchAppleTVUDID()
                                            }
                                        }
                                        .disabled(
                                            vpnStatus != .connected
                                        )
                                    }
                                }
                            }
                            .padding(
                                .vertical,
                                6
                            )
                        }
                    }
                }
                Section("3. Certificates") {
                    NavigationLink {
                        CertificatesView()
                    } label: {
                        Label(
                            "Certificates",
                            systemImage: "checkmark.seal"
                        )
                    }
                }

                Section("4. Sign tvOS IPA") {
                    NavigationLink {
                        IPASigningView(
                            onSignedIPAReady: { url in
                                prepareSignedIPAForInstallation(url)
                            },
                            installationStatus: installationStatus,
                            installationDetail: installationDetail,
                            installationProgress: installationProgress,
                            installationInProgress: installationInProgress,
                            appleTVConnected:
                                vpnStatus == .connected,
                            onInstall: {
                                Task {
                                    await installSelectedIPA()
                                }
                            }
                        )
                        // KI_CANCEL_BUTTON_SIGNING_ONLY
                        .safeAreaInset(edge: .bottom) {
                            if installationInProgress,
                               activeInstallationID != nil,
                               !cancellationRequestInProgress,
                               ["Starting installation", "Preparing installation",
                                "Uploading IPA", "Installing", "Verifying"].contains(installationStatus) {
                                Button(role: .destructive) {
                                    showingCancelConfirmation = true
                                } label: {
                                    Label("Cancel Installation", systemImage: "xmark.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.horizontal)
                                .padding(.vertical, 8)
                            }
                        }
                    } label: {
                        Label(
                            "Sign tvOS IPA",
                            systemImage: "signature"
                        )
                    }
                }

                Section("5. About") {
                    NavigationLink {
                        KhmerInstallerAboutView()
                    } label: {
                        Label(
                            "About & Acknowledgements",
                            systemImage: "info.circle"
                        )
                    }
                }


            }
                VStack(spacing: 4) {

                    Text("Made by TheDevilz")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Text(
                        "Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown") (Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"))"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                }
                .frame(
                    maxWidth: .infinity,
                    alignment: .center
                )
                .padding(
                    .vertical,
                    12
                )

            .navigationTitle("KhmerInstaller")
            }
            .confirmationDialog(
                "Cancel current installation?",
                isPresented: $showingCancelConfirmation,
                titleVisibility: .visible
            ) {
                Button("Cancel Installation", role: .destructive) {
                    Task { await cancelCurrentInstallation() }
                }
                Button("Keep Installing", role: .cancel) {}
            } message: {
                Text("The Apple TV installation will be stopped. Wait for cancellation before reconnecting or retrying.")
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .NEVPNStatusDidChange
                )
            ) { notification in
                guard let manager = packetTunnelManager,
                      let connection = notification.object as? NEVPNConnection,
                      connection === manager.connection else {
                    return
                }
                vpnStatus = connection.status
            }
            .task {
                startBrowsing()
            }
    }

    // MARK: - Bonjour Discovery

    private func startBrowsing() {

        let browser = NWBrowser(
            for: .bonjour(
                type: serviceType,
                domain: nil
            ),
            using: .tcp
        )

        browser.stateUpdateHandler = { state in


            DispatchQueue.main.async {

                switch state {

                case .ready:
                    status =
                        "Searching for pairable Apple TVs..."

                case .waiting(let error):
                    status =
                        "Waiting: \(error.localizedDescription)"

                case .failed(let error):
                    status =
                        "Search failed: \(error.localizedDescription)"

                case .cancelled:
                    status =
                        "Search stopped"

                default:
                    break
                }
            }
        }

        browser.browseResultsChangedHandler = {
            results,
            _
            in

            let found =
                results.compactMap {
                    result -> PairingDevice? in

                    guard case let .service(
                        name,
                        type,
                        domain,
                        _
                    ) = result.endpoint
                    else {
                        return nil
                    }

                    return PairingDevice(
                        id: name,
                        name: name,
                        identifier: name,
                        type: type,
                        domain: domain
                    )
                }

            DispatchQueue.main.async {

                devices =
                    found.sorted {
                        $0.name.localizedCaseInsensitiveCompare(
                            $1.name
                        ) == .orderedAscending
                    }

                status =
                    devices.isEmpty
                    ? "No pairable Apple TVs found"
                    : "\(devices.count) pairable Apple TV\(devices.count == 1 ? "" : "s") found"
            }
        }

        browser.start(queue: .main)
    }

    // MARK: - RemotePairing Tunnel Discovery

    private func startTunnelBrowsing() {

        let browser = NWBrowser(
            for: .bonjour(
                type: tunnelServiceType,
                domain: nil
            ),
            using: .tcp
        )

        tunnelBrowser = browser

        browser.stateUpdateHandler = { state in


            switch state {

            case .ready:
                break

            case .waiting(let error):
                break

            case .failed(let error):
                break

            case .cancelled:
                break

            default:
                break
            }
        }

        browser.start(queue: .main)

    }

    private func stopTunnelBrowsing() {
        tunnelBrowser?.cancel()
        tunnelBrowser = nil

    }





    // KI_INSTALL_STREAMING_SHA256
    // Hash large IPA files without loading them into memory.
    private static func sha256ForIPA(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024)
                ?? Data()

            if chunk.isEmpty {
                break
            }

            hasher.update(data: chunk)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    // KI_SIGNED_IPA_INSTALL_HANDOFF
    // Copy a saved signed IPA into the existing App Group
    // without modifying the permanent signed copy.
    @MainActor
    private func prepareSignedIPAForInstallation(
        _ sourceURL: URL
    ) -> Bool {
        let fm = FileManager.default

        guard !installationInProgress else {
            installationDetail =
                "Wait for the current installation to finish."
            return false
        }

        do {
            guard sourceURL.pathExtension.lowercased() == "ipa",
                  sourceURL.deletingLastPathComponent()
                    .standardizedFileURL ==
                    fm.urls(
                        for: .applicationSupportDirectory,
                        in: .userDomainMask
                    )[0].appendingPathComponent(
                        "KhmerInstaller/SignedTVOS",
                        isDirectory: true
                    ).standardizedFileURL else {
                throw NSError(
                    domain: "KhmerInstaller",
                    code: 100,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid signed IPA location."
                    ]
                )
            }

            guard let container = fm.containerURL(
                forSecurityApplicationGroupIdentifier:
                    KhmerInstallerConfig.appGroupID
            ) else {
                throw NSError(
                    domain: "KhmerInstaller",
                    code: 101,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "App Group unavailable."
                    ]
                )
            }

            let directory = container.appendingPathComponent(
                "IPA",
                isDirectory: true
            )

            try fm.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let destination = directory.appendingPathComponent(
                UUID().uuidString + ".ipa"
            )

            try fm.copyItem(
                at: sourceURL,
                to: destination
            )

            // KI_DYNAMIC_INSTALL_METADATA
            // Read the actual bundle ID from the signed IPA.
            guard let inspected = KIInspectIPA(
                destination.path
            ) as? [String: Any],
            let bundleID = inspected["bundleID"] as? String,
            !bundleID.isEmpty else {
                try? fm.removeItem(at: destination)
                throw NSError(
                    domain: "KhmerInstaller",
                    code: 102,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Unable to inspect signed IPA bundle identifier."
                    ]
                )
            }

            let selectionURL = container.appendingPathComponent(
                "selected-ipa.txt"
            )

            let metadataURL = container.appendingPathComponent(
                "selected-ipa-metadata.json"
            )

            // KI_INSTALL_IPA_SHA256
            // Bind installation metadata to the selected IPA bytes.
            let ipaSHA256 = try Self.sha256ForIPA(destination)

            let metadata: [String: String] = [
                "filename": destination.lastPathComponent,
                "bundleID": bundleID,
                "selectionID": UUID().uuidString,
                "sha256": ipaSHA256
            ]

            let metadataData = try JSONSerialization.data(
                withJSONObject: metadata
            )

            do {
                try metadataData.write(
                    to: metadataURL,
                    options: .atomic
                )

                try destination.lastPathComponent.write(
                    to: selectionURL,
                    atomically: true,
                    encoding: .utf8
                )
            } catch {
                // KI_INSTALL_METADATA_ROLLBACK
                // Invalidate both selection records on failure.
                try? fm.removeItem(at: selectionURL)
                try? fm.removeItem(at: metadataURL)
                try? fm.removeItem(at: destination)
                throw error
            }

            // KI_SUPERSEDED_IPA_CLEANUP
            // Remove only the previous App Group IPA copy.
            // Never delete a permanent SignedTVOS IPA.
            let previousIPA = selectedIPAURL

            selectedIPAURL = destination
            selectedIPAName = sourceURL.lastPathComponent

            if let previousIPA {
                let previous = previousIPA.standardizedFileURL
                let safeDirectory = directory.standardizedFileURL

                if previous.deletingLastPathComponent() ==
                    safeDirectory &&
                    previous.pathExtension.lowercased() == "ipa" &&
                    previous != destination.standardizedFileURL {
                    try? fm.removeItem(at: previous)
                }
            }

            installationStatus = "Idle"
            installationDetail =
                "Signed IPA selected. Connect to Apple TV and tap Install IPA."
            installationProgress = nil
            return true

        } catch {
            installationDetail =
                "Unable to prepare signed IPA: "
                + error.localizedDescription
            installationStatus = "Failed"
            installationProgress = nil
            return false
        }
    }

    private func cleanupTemporaryIPA() {

        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier:
                    KhmerInstallerConfig.appGroupID
            )
        else {
            return
        }

        let ipaDirectory = container.appendingPathComponent(
            "IPA",
            isDirectory: true
        )

        let selectionURL = container.appendingPathComponent(
            "selected-ipa.txt"
        )

        // Only delete the IPA copy stored inside our App Group.
        if let selectedIPAURL {
            let ipaURL = selectedIPAURL.standardizedFileURL
            let directoryURL = ipaDirectory.standardizedFileURL

            if ipaURL.deletingLastPathComponent() == directoryURL &&
                ipaURL.pathExtension.lowercased() == "ipa" {

                try? FileManager.default.removeItem(at: ipaURL)
            }
        }

        try? FileManager.default.removeItem(at: selectionURL)

        // KI_INSTALL_METADATA_CLEANUP
        let metadataURL = container.appendingPathComponent(
            "selected-ipa-metadata.json"
        )

        try? FileManager.default.removeItem(at: metadataURL)

        selectedIPAURL = nil
        selectedIPAName = "No IPA selected"
    }

    @MainActor


    // KI_JSON_INSTALL_STATUS_READER
    private struct InstallationStatusRecord: Decodable {
        let installationID: String
        let phase: String
        let progress: Double?
        let detail: String
        let terminal: Bool
    }

    @MainActor
    private func readInstallationStatus(
        from container: URL,
        expectedInstallationID: String
    ) -> Bool {
        let statusURL = container.appendingPathComponent(
            "installation-status.json"
        )

        guard let data = try? Data(contentsOf: statusURL),
              let record = try? JSONDecoder().decode(
                  InstallationStatusRecord.self,
                  from: data
              ),
              record.installationID == expectedInstallationID,
              activeInstallationID == expectedInstallationID
        else {
            return false
        }

        let phaseNames: [String: String] = [
            "preparing": "Preparing installation",
            "uploading": "Uploading IPA",
            "installing": "Installing",
            "verifying": "Verifying",
            "complete": "Complete",
            "failed": "Failed"
        ]

        guard let statusName = phaseNames[record.phase],
              record.terminal == (
                  record.phase == "complete" ||
                  record.phase == "failed"
              )
        else {
            return false
        }

        if let progress = record.progress {
            guard progress.isFinite,
                  (0.0...1.0).contains(progress)
            else {
                return false
            }
        }

        // KI_JSON_STATUS_UI_UPDATE
        installationStatus = statusName
        installationDetail = record.detail
        installationProgress = record.progress

        if record.terminal {
            if record.phase == "complete" {
                installationInProgress = false
                installationProgress = 1.0
                cleanupTemporaryIPA()
            }
            // KI_FAILURE_RECOVERY_WAIT: Failed attempts remain locked
            // until the tunnel reports that all workers have exited.
        }

        return true
    }

    @MainActor
    private func startInstallationMonitor() {

        // KI_JSON_MONITOR_ATTEMPT_CAPTURE
        guard let expectedInstallationID =
            activeInstallationID else {
            installationStatus = "Failed"
            installationInProgress = false
            installationDetail =
                "Installation attempt identifier unavailable."
            installationProgress = nil
            return
        }

        installationMonitorTask?.cancel()

        installationMonitorTask =
            Task { @MainActor in

                // KI_INSTALL_MONITOR_TIMEOUT
                let deadline = Date().addingTimeInterval(600)

                while !Task.isCancelled {

                    // KI_JSON_MONITOR_OWNERSHIP
                    // An older monitor cannot update a newer attempt.
                    guard activeInstallationID ==
                        expectedInstallationID else {
                        return
                    }

                    if Date() >= deadline {
                        // KI_LIFECYCLE_TIMEOUT_CANCEL
                        installationStatus = "Cancelling"
                        installationDetail =
                            "Installation timed out. Stopping Apple TV operations..."
                        installationProgress = nil
                        if let manager = packetTunnelManager,
                           let session = manager.connection as? NETunnelProviderSession,
                           session.status == .connected {
                            let request = Data(
                                ("KunInstaller Cancel IPA:" + expectedInstallationID).utf8
                            )
                            do {
                                let response = try await withCheckedThrowingContinuation {
                                    (continuation: CheckedContinuation<Data?, Error>) in
                                    do {
                                        try session.sendProviderMessage(request) { data in
                                            continuation.resume(returning: data)
                                        }
                                    } catch {
                                        continuation.resume(throwing: error)
                                    }
                                }
                                let reply = response.flatMap {
                                    String(data: $0, encoding: .utf8)
                                } ?? ""
                                installationDetail = reply == "CANCEL_ACCEPTED"
                                    ? "Timed out. Cancellation requested; reconnect before retrying."
                                    : "Cancellation unconfirmed. Reconnect before retrying."
                            } catch {
                                installationDetail =
                                    "Cancellation request failed. Reconnect before retrying."
                            }
                        } else {
                            installationDetail = "Tunnel disconnected. Reconnect before retrying."
                        }
                        installationStatus = "Failed"
                        // Keep retry blocked until the tunnel is reconnected.
                        return
                    }

                    guard
                        let container =
                            FileManager.default.containerURL(
                                forSecurityApplicationGroupIdentifier:
                                    KhmerInstallerConfig.appGroupID
                            )
                    else {
                        installationStatus = "Failed"
                        installationInProgress = false
                        installationDetail =
                            "App Group unavailable."
                        return
                    }

                    // KI_JSON_MONITOR_STATUS_READ
                    if readInstallationStatus(
                        from: container,
                        expectedInstallationID:
                            expectedInstallationID
                    ) {
                        if installationStatus == "Complete" { return }
                        if installationStatus == "Failed" {
                            await waitForFailedInstallationCleanup(
                                expectedInstallationID
                            )
                            return
                        }
                    }

                    try? await Task.sleep(
                        for: .milliseconds(500)
                    )
                }
            }
    }



    @MainActor
    private func installSelectedIPA() async {

        guard !installationInProgress else {
            return
        }

        guard selectedIPAURL != nil else {

            installationStatus =
                "Idle"

            installationDetail =
                "Select an IPA first."

            installationProgress = nil

            return
        }

        guard
            let manager = packetTunnelManager,
            let session =
                manager.connection
                    as? NETunnelProviderSession,
            session.status == .connected
        else {

            installationStatus =
                "Waiting for VPN"

            installationDetail =
                "Connect to the Apple TV first."

            installationProgress = nil

            return
        }

        installationInProgress = true

        installationStatus =
            "Starting installation"

        installationDetail =
            "Sending install request to Apple TV..."

        installationProgress = nil

        // KI_INSTALL_MONITOR_ORDER
        // Wait for the Packet Tunnel to reset its previous
        // installation log before starting the monitor.
        do {

            let response =
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Data?, Error>
                    ) in

                    do {

                        try session.sendProviderMessage(
                            Data(
                                "KunInstaller Install IPA".utf8
                            )
                        ) { response in

                            continuation.resume(
                                returning:
                                    response
                            )
                        }

                    } catch {

                        continuation.resume(
                            throwing:
                                error
                        )
                    }
                }

            // KI_INSTALL_LATE_RESPONSE_GUARD
            // Do not overwrite a terminal result from the monitor.
            guard installationInProgress else {
                return
            }

            let responseText =
                response.flatMap {
                    String(
                        data:
                            $0,
                        encoding:
                            .utf8
                    )
                } ?? ""

            // KI_INSTALL_ATTEMPT_ACK
            // Accept only an installation acknowledgment containing
            // a valid unique installation-attempt identifier.
            let acknowledgmentPrefix = "INSTALL_STARTED:"

            let acknowledgedInstallationID: String? = {
                guard responseText.hasPrefix(
                    acknowledgmentPrefix
                ) else {
                    return nil
                }

                let identifier = String(
                    responseText.dropFirst(
                        acknowledgmentPrefix.count
                    )
                )

                guard UUID(uuidString: identifier) != nil else {
                    return nil
                }

                return identifier
            }()

            guard let acknowledgedInstallationID else {

                installationStatus =
                    "Failed"
                installationInProgress = false

                installationDetail =
                    responseText.isEmpty
                        ? "Packet Tunnel did not accept the install request."
                        : responseText

                installationProgress = nil

                return
            }

            // KI_STORE_ACTIVE_INSTALLATION_ID
            activeInstallationID = acknowledgedInstallationID

            // KI_INSTALL_MONITOR_AFTER_ACK
            // INSTALL_STARTED is returned after startRSDProbe()
            // has begun and reset the previous debug log.
            startInstallationMonitor()

            installationStatus =
                "Preparing installation"

            installationDetail =
                "Apple TV accepted the install request."

            installationProgress = nil

        } catch {

            // Preserve terminal status already reported by monitor.
            guard installationInProgress else {
                return
            }

            installationStatus =
                "Failed"
            installationInProgress = false

            installationDetail =
                "Install request failed: \(error.localizedDescription)"

            installationProgress = nil
        }
    }

    // KI_FAILURE_RECOVERY_POLL
    // Never unlock an ordinary failure from JSON alone.
    @MainActor
    private func waitForFailedInstallationCleanup(_ id: String) async {
        for _ in 0..<60 {
            guard activeInstallationID == id, !Task.isCancelled else { return }
            guard let session = packetTunnelManager?.connection
                as? NETunnelProviderSession, session.status == .connected else {
                installationDetail = "Tunnel unavailable. Reconnect before retrying."
                return
            }
            do {
                let request = Data(("KunInstaller Cleanup Status:" + id).utf8)
                let data: Data? = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data?, Error>) in
                    do {
                        try session.sendProviderMessage(request) { response in
                            continuation.resume(returning: response)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
                guard activeInstallationID == id, !Task.isCancelled else { return }
                let reply = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if reply == "CLEANUP_COMPLETE" {
                    cleanupTemporaryIPA()
                    activeInstallationID = nil
                    installationInProgress = false
                    installationDetail = "Installation failed. Cleanup complete; another IPA can be selected."
                    installationProgress = nil
                    return
                }
                if reply != "CLEANUP_PENDING" {
                    installationDetail = "Cleanup unconfirmed. Reconnect before retrying."
                    return
                }
            } catch {
                installationDetail = "Cleanup check failed. Reconnect before retrying."
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        installationDetail = "Cleanup still pending. Reconnect before retrying."
    }

    // KI_CLEANUP_POLL_V1
    // A cancellation acknowledgment alone must never unlock installation.
    @MainActor
    private func waitForInstallationCleanup(_ id: String) async {
        for _ in 0..<60 {
            guard activeInstallationID == id else { return }
            guard let session = packetTunnelManager?.connection
                as? NETunnelProviderSession, session.status == .connected else {
                installationDetail = "Tunnel disconnected. Reconnect before retrying."
                return
            }
            do {
                let request = Data(("KunInstaller Cleanup Status:" + id).utf8)
                let data: Data? = try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data?, Error>) in
                    do {
                        try session.sendProviderMessage(request) { response in
                            continuation.resume(returning: response)
                        }
                    } catch { continuation.resume(throwing: error) }
                }
                guard activeInstallationID == id else { return }
                let response = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if response == "CLEANUP_COMPLETE" {
                    cleanupTemporaryIPA()
                    activeInstallationID = nil
                    installationInProgress = false
                    installationStatus = "Idle"
                    installationDetail = "Cancellation cleanup complete. Select and sign another IPA."
                    installationProgress = nil
                    return
                }
                if response != "CLEANUP_PENDING" {
                    installationDetail = "Cleanup cannot be confirmed. Reconnect before retrying."
                    return
                }
            } catch {
                installationDetail = "Cleanup check failed. Reconnect before retrying."
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        installationDetail = "Cleanup still pending. Reconnect before retrying."
    }

    // KI_MANUAL_CANCEL_IPC
    @MainActor
    private func cancelCurrentInstallation() async {
        guard installationInProgress,
              !cancellationRequestInProgress,
              let id = activeInstallationID else { return }

        cancellationRequestInProgress = true
        installationMonitorTask?.cancel()
        installationStatus = "Cancelling"
        installationDetail = "Requesting cancellation from Packet Tunnel..."
        installationProgress = nil
        defer { cancellationRequestInProgress = false }

        guard let session = packetTunnelManager?.connection
            as? NETunnelProviderSession,
              session.status == .connected else {
            installationStatus = "Failed"
            installationDetail = "Tunnel unavailable. Reconnect before retrying."
            // Keep installationInProgress true to block unsafe retry.
            return
        }

        do {
            let request = Data(("KunInstaller Cancel IPA:" + id).utf8)
            let data: Data? = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data?, Error>) in
                do {
                    try session.sendProviderMessage(request) { response in
                        continuation.resume(returning: response)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            guard activeInstallationID == id else { return }
            let reply = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            installationStatus = "Failed"
            installationDetail = reply == "CANCEL_ACCEPTED"
                ? "Cancellation requested. Waiting for worker cleanup..."
                : "Cancellation not confirmed. Reconnect before retrying."
            if reply == "CANCEL_ACCEPTED" {
                await waitForInstallationCleanup(id)
            }
            // Keep the lock if cleanup was not confirmed.
        } catch {
            guard activeInstallationID == id else { return }
            installationStatus = "Failed"
            installationDetail = "Cancellation request failed. Reconnect before retrying."
        }
    }

    @MainActor
    private func fetchAppleTVUDID() async {

        guard
            let manager = packetTunnelManager,
            let session =
                manager.connection as? NETunnelProviderSession,
            session.status == .connected
        else {
            pairingStatus =
                "Connect to the Apple TV first."
            return
        }

        pairingStatus =
            "Getting Apple TV UDID..."

        do {

            let response =
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Data?, Error>
                    ) in

                    do {

                        try session.sendProviderMessage(
                            Data(
                                "KunInstaller Get UDID".utf8
                            )
                        ) { response in

                            continuation.resume(
                                returning: response
                            )
                        }

                    } catch {

                        continuation.resume(
                            throwing: error
                        )
                    }
                }

            let result =
                response.flatMap {
                    String(
                        data: $0,
                        encoding: .utf8
                    )
                } ?? ""

            guard
                !result.isEmpty,
                !result.hasPrefix("ERROR:")
            else {

                pairingStatus =
                    result.isEmpty
                        ? "Unable to retrieve Apple TV UDID."
                        : result

                return
            }

            appleTVUDID = result

            pairingStatus =
                "Apple TV UDID retrieved."

        } catch {

            pairingStatus =
                "UDID request failed: \(error.localizedDescription)"
        }
    }

    private func startPacketTunnel(
        pairingHost: String,
        pairingPort: Int
    ) async throws {

        await MainActor.run {
            installationStatus =
                "Starting VPN"
            installationDetail =
                "Starting Apple TV tunnel..."
            installationProgress = nil
        }

        guard let appBundleIdentifier = Bundle.main.bundleIdentifier else {
            throw NSError(
                domain: "KhmerInstaller.Configuration",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Main application bundle identifier is missing."
                ]
            )
        }

        let providerBundleIdentifier =
            appBundleIdentifier + ".KunInstallerTunnel"

        let managers =
            try await NETunnelProviderManager
                .loadAllFromPreferences()

        let manager =
            managers.first {
                guard
                    let configuration =
                        $0.protocolConfiguration
                            as? NETunnelProviderProtocol
                else {
                    return false
                }

                return configuration.providerBundleIdentifier
                    == providerBundleIdentifier
            }
            ?? NETunnelProviderManager()

        // If the existing system tunnel belongs to a different
        // Apple TV, stop it before reconfiguring the manager.
        if
            let existingConfiguration =
                manager.protocolConfiguration
                    as? NETunnelProviderProtocol,
            existingConfiguration.serverAddress != pairingHost
        {
            let existingSession =
                manager.connection

            switch existingSession.status {

            case .connecting,
                 .connected,
                 .reasserting:


                existingSession.stopVPNTunnel()

                for _ in 0..<20 {

                    try? await Task.sleep(
                        for:
                            .milliseconds(100)
                    )

                    switch existingSession.status {

                    case .disconnecting,
                         .connected,
                         .connecting,
                         .reasserting:

                        continue

                    default:

                        break
                    }

                    break
                }

            default:
                break
            }
        }

        let configuration =
            NETunnelProviderProtocol()

        configuration.providerBundleIdentifier =
            providerBundleIdentifier

        // The Packet Tunnel extension establishes the actual
        // Cumulative Tunnel and obtains its IPv6 addresses.
        configuration.serverAddress =
            pairingHost

        manager.localizedDescription =
            "KhmerInstaller Apple TV Tunnel"

        manager.protocolConfiguration =
            configuration

        manager.isEnabled = true

        try await manager.saveToPreferences()
        try await manager.loadFromPreferences()

        guard
            let session =
                manager.connection
                    as? NETunnelProviderSession
        else {
            throw NSError(
                domain: "KunInstaller",
                code: 1001,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Unable to create Packet Tunnel session."
                ]
            )
        }

        let options:
            [String: NSObject] = [
                "pairingHost":
                    pairingHost as NSString,

                "pairingPort":
                    NSNumber(value: pairingPort)
            ]

        packetTunnelManager =
            manager

        vpnStatus = manager.connection.status





        do {

            try session.startVPNTunnel(
                options: options
            )




        } catch {


            throw error
        }
    }

    // MARK: - Pairing

    private func startTunnelForPairedClient(
        _ client: RemotePairingClient
    ) {

        bonjourResolver.onResolved = { service in

            do {
                let matched =
                    try client.matchesTunnelService(
                        identifier:
                            service.identifier,
                        authTag:
                            service.authTag
                    )


                guard matched else {
                    return
                }

                _ = try client.savedPairRecord()


                bonjourResolver.stop()

                Task {
                    do {

                        await MainActor.run {
                            pairingStatus =
                                """
                                Tunnel matched
                                Starting Packet Tunnel...
                                """
                        }

                        try await startPacketTunnel(
                            pairingHost:
                                service.host,
                            pairingPort:
                                service.port
                        )

                        await MainActor.run {
                            pairingStatus =
                                """
                                Trusted connection established
                                Packet Tunnel connected
                                """

                            showingPINEntry = false
                        }


                    } catch {


                        await MainActor.run {
                            pairingStatus =
                                """
                                Tunnel connection failed:
                                \(error.localizedDescription)
                                """

                            showingPINEntry = false
                        }
                    }
                }

            } catch {

            }
        }

        bonjourResolver.start()
    }

    private func startPairing(
        _ device: PairingDevice
    ) {
        pairingDeviceID = device.id
        appleTVUDID = nil

        pairingStatus =
            "Connecting to \(device.name)..."

        showingPINEntry = false
        pin = ""

        let client =
            RemotePairingClient()

        pairingClient = client

        Task {
            do {
                let result =
                    try await client.connect(
                        serviceName: device.name,
                        serviceType: device.type,
                        domain: device.domain
                    )

                if result.contains(
                    "Trusted connection established"
                ) {

                    startTunnelForPairedClient(
                        client
                    )

                    await MainActor.run {
                        pairingStatus =
                            """
                            Trusted connection established
                            Searching for matching tunnel...
                            """

                        showingPINEntry = false
                    }

                } else {

                    await MainActor.run {
                        pairingStatus = result
                        showingPINEntry = true
                    }
                }

            } catch {

                await MainActor.run {
                    pairingStatus =
                        "Pairing failed: \(error.localizedDescription)"

                    showingPINEntry = false
                }
            }
        }
    }

    private func submitPIN() {

        guard pin.count == 6 else {
            pairingStatus =
                "Enter the 6-digit PIN shown on Apple TV."
            return
        }

        guard let client = pairingClient else {
            pairingStatus =
                "Pairing session is no longer available."
            return
        }

        showingPINEntry = false
        pairingStatus =
            "Verifying PIN..."

        let enteredPIN = pin

        Task {

            do {

                let result =
                    try await client.submitPIN(
                        enteredPIN
                    )

                await MainActor.run {

                    pairingStatus = result
                    showingPINEntry = false
                }

                startTunnelForPairedClient(
                    client
                )

            } catch {

                await MainActor.run {

                    pairingStatus =
                        "Pairing failed: \(error.localizedDescription)"

                    showingPINEntry = true
                }
            }
        }
    }
}


// MARK: - About, Project License, and Acknowledgements
private struct KhmerInstallerAboutView: View {
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "Version \(version) (Build \(build))"
    }

    private var gplLicense: String {
        let encoded = [
        "ICAgICAgICAgICAgICAgICAgICBHTlUgR0VORVJBTCBQVUJMSUMgTElDRU5TRQogICAgICAgICAgICAgICAgICAgICAgIFZl",
        "cnNpb24gMywgMjkgSnVuZSAyMDA3CgogQ29weXJpZ2h0IChDKSAyMDA3IEZyZWUgU29mdHdhcmUgRm91bmRhdGlvbiwgSW5j",
        "LiA8aHR0cHM6Ly9mc2Yub3JnLz4KIEV2ZXJ5b25lIGlzIHBlcm1pdHRlZCB0byBjb3B5IGFuZCBkaXN0cmlidXRlIHZlcmJh",
        "dGltIGNvcGllcwogb2YgdGhpcyBsaWNlbnNlIGRvY3VtZW50LCBidXQgY2hhbmdpbmcgaXQgaXMgbm90IGFsbG93ZWQuCgog",
        "ICAgICAgICAgICAgICAgICAgICAgICAgICAgUHJlYW1ibGUKCiAgVGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGlz",
        "IGEgZnJlZSwgY29weWxlZnQgbGljZW5zZSBmb3IKc29mdHdhcmUgYW5kIG90aGVyIGtpbmRzIG9mIHdvcmtzLgoKICBUaGUg",
        "bGljZW5zZXMgZm9yIG1vc3Qgc29mdHdhcmUgYW5kIG90aGVyIHByYWN0aWNhbCB3b3JrcyBhcmUgZGVzaWduZWQKdG8gdGFr",
        "ZSBhd2F5IHlvdXIgZnJlZWRvbSB0byBzaGFyZSBhbmQgY2hhbmdlIHRoZSB3b3Jrcy4gIEJ5IGNvbnRyYXN0LAp0aGUgR05V",
        "IEdlbmVyYWwgUHVibGljIExpY2Vuc2UgaXMgaW50ZW5kZWQgdG8gZ3VhcmFudGVlIHlvdXIgZnJlZWRvbSB0bwpzaGFyZSBh",
        "bmQgY2hhbmdlIGFsbCB2ZXJzaW9ucyBvZiBhIHByb2dyYW0tLXRvIG1ha2Ugc3VyZSBpdCByZW1haW5zIGZyZWUKc29mdHdh",
        "cmUgZm9yIGFsbCBpdHMgdXNlcnMuICBXZSwgdGhlIEZyZWUgU29mdHdhcmUgRm91bmRhdGlvbiwgdXNlIHRoZQpHTlUgR2Vu",
        "ZXJhbCBQdWJsaWMgTGljZW5zZSBmb3IgbW9zdCBvZiBvdXIgc29mdHdhcmU7IGl0IGFwcGxpZXMgYWxzbyB0bwphbnkgb3Ro",
        "ZXIgd29yayByZWxlYXNlZCB0aGlzIHdheSBieSBpdHMgYXV0aG9ycy4gIFlvdSBjYW4gYXBwbHkgaXQgdG8KeW91ciBwcm9n",
        "cmFtcywgdG9vLgoKICBXaGVuIHdlIHNwZWFrIG9mIGZyZWUgc29mdHdhcmUsIHdlIGFyZSByZWZlcnJpbmcgdG8gZnJlZWRv",
        "bSwgbm90CnByaWNlLiAgT3VyIEdlbmVyYWwgUHVibGljIExpY2Vuc2VzIGFyZSBkZXNpZ25lZCB0byBtYWtlIHN1cmUgdGhh",
        "dCB5b3UKaGF2ZSB0aGUgZnJlZWRvbSB0byBkaXN0cmlidXRlIGNvcGllcyBvZiBmcmVlIHNvZnR3YXJlIChhbmQgY2hhcmdl",
        "IGZvcgp0aGVtIGlmIHlvdSB3aXNoKSwgdGhhdCB5b3UgcmVjZWl2ZSBzb3VyY2UgY29kZSBvciBjYW4gZ2V0IGl0IGlmIHlv",
        "dQp3YW50IGl0LCB0aGF0IHlvdSBjYW4gY2hhbmdlIHRoZSBzb2Z0d2FyZSBvciB1c2UgcGllY2VzIG9mIGl0IGluIG5ldwpm",
        "cmVlIHByb2dyYW1zLCBhbmQgdGhhdCB5b3Uga25vdyB5b3UgY2FuIGRvIHRoZXNlIHRoaW5ncy4KCiAgVG8gcHJvdGVjdCB5",
        "b3VyIHJpZ2h0cywgd2UgbmVlZCB0byBwcmV2ZW50IG90aGVycyBmcm9tIGRlbnlpbmcgeW91CnRoZXNlIHJpZ2h0cyBvciBh",
        "c2tpbmcgeW91IHRvIHN1cnJlbmRlciB0aGUgcmlnaHRzLiAgVGhlcmVmb3JlLCB5b3UgaGF2ZQpjZXJ0YWluIHJlc3BvbnNp",
        "YmlsaXRpZXMgaWYgeW91IGRpc3RyaWJ1dGUgY29waWVzIG9mIHRoZSBzb2Z0d2FyZSwgb3IgaWYKeW91IG1vZGlmeSBpdDog",
        "cmVzcG9uc2liaWxpdGllcyB0byByZXNwZWN0IHRoZSBmcmVlZG9tIG9mIG90aGVycy4KCiAgRm9yIGV4YW1wbGUsIGlmIHlv",
        "dSBkaXN0cmlidXRlIGNvcGllcyBvZiBzdWNoIGEgcHJvZ3JhbSwgd2hldGhlcgpncmF0aXMgb3IgZm9yIGEgZmVlLCB5b3Ug",
        "bXVzdCBwYXNzIG9uIHRvIHRoZSByZWNpcGllbnRzIHRoZSBzYW1lCmZyZWVkb21zIHRoYXQgeW91IHJlY2VpdmVkLiAgWW91",
        "IG11c3QgbWFrZSBzdXJlIHRoYXQgdGhleSwgdG9vLCByZWNlaXZlCm9yIGNhbiBnZXQgdGhlIHNvdXJjZSBjb2RlLiAgQW5k",
        "IHlvdSBtdXN0IHNob3cgdGhlbSB0aGVzZSB0ZXJtcyBzbyB0aGV5Cmtub3cgdGhlaXIgcmlnaHRzLgoKICBEZXZlbG9wZXJz",
        "IHRoYXQgdXNlIHRoZSBHTlUgR1BMIHByb3RlY3QgeW91ciByaWdodHMgd2l0aCB0d28gc3RlcHM6CigxKSBhc3NlcnQgY29w",
        "eXJpZ2h0IG9uIHRoZSBzb2Z0d2FyZSwgYW5kICgyKSBvZmZlciB5b3UgdGhpcyBMaWNlbnNlCmdpdmluZyB5b3UgbGVnYWwg",
        "cGVybWlzc2lvbiB0byBjb3B5LCBkaXN0cmlidXRlIGFuZC9vciBtb2RpZnkgaXQuCgogIEZvciB0aGUgZGV2ZWxvcGVycycg",
        "YW5kIGF1dGhvcnMnIHByb3RlY3Rpb24sIHRoZSBHUEwgY2xlYXJseSBleHBsYWlucwp0aGF0IHRoZXJlIGlzIG5vIHdhcnJh",
        "bnR5IGZvciB0aGlzIGZyZWUgc29mdHdhcmUuICBGb3IgYm90aCB1c2VycycgYW5kCmF1dGhvcnMnIHNha2UsIHRoZSBHUEwg",
        "cmVxdWlyZXMgdGhhdCBtb2RpZmllZCB2ZXJzaW9ucyBiZSBtYXJrZWQgYXMKY2hhbmdlZCwgc28gdGhhdCB0aGVpciBwcm9i",
        "bGVtcyB3aWxsIG5vdCBiZSBhdHRyaWJ1dGVkIGVycm9uZW91c2x5IHRvCmF1dGhvcnMgb2YgcHJldmlvdXMgdmVyc2lvbnMu",
        "CgogIFNvbWUgZGV2aWNlcyBhcmUgZGVzaWduZWQgdG8gZGVueSB1c2VycyBhY2Nlc3MgdG8gaW5zdGFsbCBvciBydW4KbW9k",
        "aWZpZWQgdmVyc2lvbnMgb2YgdGhlIHNvZnR3YXJlIGluc2lkZSB0aGVtLCBhbHRob3VnaCB0aGUgbWFudWZhY3R1cmVyCmNh",
        "biBkbyBzby4gIFRoaXMgaXMgZnVuZGFtZW50YWxseSBpbmNvbXBhdGlibGUgd2l0aCB0aGUgYWltIG9mCnByb3RlY3Rpbmcg",
        "dXNlcnMnIGZyZWVkb20gdG8gY2hhbmdlIHRoZSBzb2Z0d2FyZS4gIFRoZSBzeXN0ZW1hdGljCnBhdHRlcm4gb2Ygc3VjaCBh",
        "YnVzZSBvY2N1cnMgaW4gdGhlIGFyZWEgb2YgcHJvZHVjdHMgZm9yIGluZGl2aWR1YWxzIHRvCnVzZSwgd2hpY2ggaXMgcHJl",
        "Y2lzZWx5IHdoZXJlIGl0IGlzIG1vc3QgdW5hY2NlcHRhYmxlLiAgVGhlcmVmb3JlLCB3ZQpoYXZlIGRlc2lnbmVkIHRoaXMg",
        "dmVyc2lvbiBvZiB0aGUgR1BMIHRvIHByb2hpYml0IHRoZSBwcmFjdGljZSBmb3IgdGhvc2UKcHJvZHVjdHMuICBJZiBzdWNo",
        "IHByb2JsZW1zIGFyaXNlIHN1YnN0YW50aWFsbHkgaW4gb3RoZXIgZG9tYWlucywgd2UKc3RhbmQgcmVhZHkgdG8gZXh0ZW5k",
        "IHRoaXMgcHJvdmlzaW9uIHRvIHRob3NlIGRvbWFpbnMgaW4gZnV0dXJlIHZlcnNpb25zCm9mIHRoZSBHUEwsIGFzIG5lZWRl",
        "ZCB0byBwcm90ZWN0IHRoZSBmcmVlZG9tIG9mIHVzZXJzLgoKICBGaW5hbGx5LCBldmVyeSBwcm9ncmFtIGlzIHRocmVhdGVu",
        "ZWQgY29uc3RhbnRseSBieSBzb2Z0d2FyZSBwYXRlbnRzLgpTdGF0ZXMgc2hvdWxkIG5vdCBhbGxvdyBwYXRlbnRzIHRvIHJl",
        "c3RyaWN0IGRldmVsb3BtZW50IGFuZCB1c2Ugb2YKc29mdHdhcmUgb24gZ2VuZXJhbC1wdXJwb3NlIGNvbXB1dGVycywgYnV0",
        "IGluIHRob3NlIHRoYXQgZG8sIHdlIHdpc2ggdG8KYXZvaWQgdGhlIHNwZWNpYWwgZGFuZ2VyIHRoYXQgcGF0ZW50cyBhcHBs",
        "aWVkIHRvIGEgZnJlZSBwcm9ncmFtIGNvdWxkCm1ha2UgaXQgZWZmZWN0aXZlbHkgcHJvcHJpZXRhcnkuICBUbyBwcmV2ZW50",
        "IHRoaXMsIHRoZSBHUEwgYXNzdXJlcyB0aGF0CnBhdGVudHMgY2Fubm90IGJlIHVzZWQgdG8gcmVuZGVyIHRoZSBwcm9ncmFt",
        "IG5vbi1mcmVlLgoKICBUaGUgcHJlY2lzZSB0ZXJtcyBhbmQgY29uZGl0aW9ucyBmb3IgY29weWluZywgZGlzdHJpYnV0aW9u",
        "IGFuZAptb2RpZmljYXRpb24gZm9sbG93LgoKICAgICAgICAgICAgICAgICAgICAgICBURVJNUyBBTkQgQ09ORElUSU9OUwoK",
        "ICAwLiBEZWZpbml0aW9ucy4KCiAgIlRoaXMgTGljZW5zZSIgcmVmZXJzIHRvIHZlcnNpb24gMyBvZiB0aGUgR05VIEdlbmVy",
        "YWwgUHVibGljIExpY2Vuc2UuCgogICJDb3B5cmlnaHQiIGFsc28gbWVhbnMgY29weXJpZ2h0LWxpa2UgbGF3cyB0aGF0IGFw",
        "cGx5IHRvIG90aGVyIGtpbmRzIG9mCndvcmtzLCBzdWNoIGFzIHNlbWljb25kdWN0b3IgbWFza3MuCgogICJUaGUgUHJvZ3Jh",
        "bSIgcmVmZXJzIHRvIGFueSBjb3B5cmlnaHRhYmxlIHdvcmsgbGljZW5zZWQgdW5kZXIgdGhpcwpMaWNlbnNlLiAgRWFjaCBs",
        "aWNlbnNlZSBpcyBhZGRyZXNzZWQgYXMgInlvdSIuICAiTGljZW5zZWVzIiBhbmQKInJlY2lwaWVudHMiIG1heSBiZSBpbmRp",
        "dmlkdWFscyBvciBvcmdhbml6YXRpb25zLgoKICBUbyAibW9kaWZ5IiBhIHdvcmsgbWVhbnMgdG8gY29weSBmcm9tIG9yIGFk",
        "YXB0IGFsbCBvciBwYXJ0IG9mIHRoZSB3b3JrCmluIGEgZmFzaGlvbiByZXF1aXJpbmcgY29weXJpZ2h0IHBlcm1pc3Npb24s",
        "IG90aGVyIHRoYW4gdGhlIG1ha2luZyBvZiBhbgpleGFjdCBjb3B5LiAgVGhlIHJlc3VsdGluZyB3b3JrIGlzIGNhbGxlZCBh",
        "ICJtb2RpZmllZCB2ZXJzaW9uIiBvZiB0aGUKZWFybGllciB3b3JrIG9yIGEgd29yayAiYmFzZWQgb24iIHRoZSBlYXJsaWVy",
        "IHdvcmsuCgogIEEgImNvdmVyZWQgd29yayIgbWVhbnMgZWl0aGVyIHRoZSB1bm1vZGlmaWVkIFByb2dyYW0gb3IgYSB3b3Jr",
        "IGJhc2VkCm9uIHRoZSBQcm9ncmFtLgoKICBUbyAicHJvcGFnYXRlIiBhIHdvcmsgbWVhbnMgdG8gZG8gYW55dGhpbmcgd2l0",
        "aCBpdCB0aGF0LCB3aXRob3V0CnBlcm1pc3Npb24sIHdvdWxkIG1ha2UgeW91IGRpcmVjdGx5IG9yIHNlY29uZGFyaWx5IGxp",
        "YWJsZSBmb3IKaW5mcmluZ2VtZW50IHVuZGVyIGFwcGxpY2FibGUgY29weXJpZ2h0IGxhdywgZXhjZXB0IGV4ZWN1dGluZyBp",
        "dCBvbiBhCmNvbXB1dGVyIG9yIG1vZGlmeWluZyBhIHByaXZhdGUgY29weS4gIFByb3BhZ2F0aW9uIGluY2x1ZGVzIGNvcHlp",
        "bmcsCmRpc3RyaWJ1dGlvbiAod2l0aCBvciB3aXRob3V0IG1vZGlmaWNhdGlvbiksIG1ha2luZyBhdmFpbGFibGUgdG8gdGhl",
        "CnB1YmxpYywgYW5kIGluIHNvbWUgY291bnRyaWVzIG90aGVyIGFjdGl2aXRpZXMgYXMgd2VsbC4KCiAgVG8gImNvbnZleSIg",
        "YSB3b3JrIG1lYW5zIGFueSBraW5kIG9mIHByb3BhZ2F0aW9uIHRoYXQgZW5hYmxlcyBvdGhlcgpwYXJ0aWVzIHRvIG1ha2Ug",
        "b3IgcmVjZWl2ZSBjb3BpZXMuICBNZXJlIGludGVyYWN0aW9uIHdpdGggYSB1c2VyIHRocm91Z2gKYSBjb21wdXRlciBuZXR3",
        "b3JrLCB3aXRoIG5vIHRyYW5zZmVyIG9mIGEgY29weSwgaXMgbm90IGNvbnZleWluZy4KCiAgQW4gaW50ZXJhY3RpdmUgdXNl",
        "ciBpbnRlcmZhY2UgZGlzcGxheXMgIkFwcHJvcHJpYXRlIExlZ2FsIE5vdGljZXMiCnRvIHRoZSBleHRlbnQgdGhhdCBpdCBp",
        "bmNsdWRlcyBhIGNvbnZlbmllbnQgYW5kIHByb21pbmVudGx5IHZpc2libGUKZmVhdHVyZSB0aGF0ICgxKSBkaXNwbGF5cyBh",
        "biBhcHByb3ByaWF0ZSBjb3B5cmlnaHQgbm90aWNlLCBhbmQgKDIpCnRlbGxzIHRoZSB1c2VyIHRoYXQgdGhlcmUgaXMgbm8g",
        "d2FycmFudHkgZm9yIHRoZSB3b3JrIChleGNlcHQgdG8gdGhlCmV4dGVudCB0aGF0IHdhcnJhbnRpZXMgYXJlIHByb3ZpZGVk",
        "KSwgdGhhdCBsaWNlbnNlZXMgbWF5IGNvbnZleSB0aGUKd29yayB1bmRlciB0aGlzIExpY2Vuc2UsIGFuZCBob3cgdG8gdmll",
        "dyBhIGNvcHkgb2YgdGhpcyBMaWNlbnNlLiAgSWYKdGhlIGludGVyZmFjZSBwcmVzZW50cyBhIGxpc3Qgb2YgdXNlciBjb21t",
        "YW5kcyBvciBvcHRpb25zLCBzdWNoIGFzIGEKbWVudSwgYSBwcm9taW5lbnQgaXRlbSBpbiB0aGUgbGlzdCBtZWV0cyB0aGlz",
        "IGNyaXRlcmlvbi4KCiAgMS4gU291cmNlIENvZGUuCgogIFRoZSAic291cmNlIGNvZGUiIGZvciBhIHdvcmsgbWVhbnMgdGhl",
        "IHByZWZlcnJlZCBmb3JtIG9mIHRoZSB3b3JrCmZvciBtYWtpbmcgbW9kaWZpY2F0aW9ucyB0byBpdC4gICJPYmplY3QgY29k",
        "ZSIgbWVhbnMgYW55IG5vbi1zb3VyY2UKZm9ybSBvZiBhIHdvcmsuCgogIEEgIlN0YW5kYXJkIEludGVyZmFjZSIgbWVhbnMg",
        "YW4gaW50ZXJmYWNlIHRoYXQgZWl0aGVyIGlzIGFuIG9mZmljaWFsCnN0YW5kYXJkIGRlZmluZWQgYnkgYSByZWNvZ25pemVk",
        "IHN0YW5kYXJkcyBib2R5LCBvciwgaW4gdGhlIGNhc2Ugb2YKaW50ZXJmYWNlcyBzcGVjaWZpZWQgZm9yIGEgcGFydGljdWxh",
        "ciBwcm9ncmFtbWluZyBsYW5ndWFnZSwgb25lIHRoYXQKaXMgd2lkZWx5IHVzZWQgYW1vbmcgZGV2ZWxvcGVycyB3b3JraW5n",
        "IGluIHRoYXQgbGFuZ3VhZ2UuCgogIFRoZSAiU3lzdGVtIExpYnJhcmllcyIgb2YgYW4gZXhlY3V0YWJsZSB3b3JrIGluY2x1",
        "ZGUgYW55dGhpbmcsIG90aGVyCnRoYW4gdGhlIHdvcmsgYXMgYSB3aG9sZSwgdGhhdCAoYSkgaXMgaW5jbHVkZWQgaW4gdGhl",
        "IG5vcm1hbCBmb3JtIG9mCnBhY2thZ2luZyBhIE1ham9yIENvbXBvbmVudCwgYnV0IHdoaWNoIGlzIG5vdCBwYXJ0IG9mIHRo",
        "YXQgTWFqb3IKQ29tcG9uZW50LCBhbmQgKGIpIHNlcnZlcyBvbmx5IHRvIGVuYWJsZSB1c2Ugb2YgdGhlIHdvcmsgd2l0aCB0",
        "aGF0Ck1ham9yIENvbXBvbmVudCwgb3IgdG8gaW1wbGVtZW50IGEgU3RhbmRhcmQgSW50ZXJmYWNlIGZvciB3aGljaCBhbgpp",
        "bXBsZW1lbnRhdGlvbiBpcyBhdmFpbGFibGUgdG8gdGhlIHB1YmxpYyBpbiBzb3VyY2UgY29kZSBmb3JtLiAgQQoiTWFqb3Ig",
        "Q29tcG9uZW50IiwgaW4gdGhpcyBjb250ZXh0LCBtZWFucyBhIG1ham9yIGVzc2VudGlhbCBjb21wb25lbnQKKGtlcm5lbCwg",
        "d2luZG93IHN5c3RlbSwgYW5kIHNvIG9uKSBvZiB0aGUgc3BlY2lmaWMgb3BlcmF0aW5nIHN5c3RlbQooaWYgYW55KSBvbiB3",
        "aGljaCB0aGUgZXhlY3V0YWJsZSB3b3JrIHJ1bnMsIG9yIGEgY29tcGlsZXIgdXNlZCB0bwpwcm9kdWNlIHRoZSB3b3JrLCBv",
        "ciBhbiBvYmplY3QgY29kZSBpbnRlcnByZXRlciB1c2VkIHRvIHJ1biBpdC4KCiAgVGhlICJDb3JyZXNwb25kaW5nIFNvdXJj",
        "ZSIgZm9yIGEgd29yayBpbiBvYmplY3QgY29kZSBmb3JtIG1lYW5zIGFsbAp0aGUgc291cmNlIGNvZGUgbmVlZGVkIHRvIGdl",
        "bmVyYXRlLCBpbnN0YWxsLCBhbmQgKGZvciBhbiBleGVjdXRhYmxlCndvcmspIHJ1biB0aGUgb2JqZWN0IGNvZGUgYW5kIHRv",
        "IG1vZGlmeSB0aGUgd29yaywgaW5jbHVkaW5nIHNjcmlwdHMgdG8KY29udHJvbCB0aG9zZSBhY3Rpdml0aWVzLiAgSG93ZXZl",
        "ciwgaXQgZG9lcyBub3QgaW5jbHVkZSB0aGUgd29yaydzClN5c3RlbSBMaWJyYXJpZXMsIG9yIGdlbmVyYWwtcHVycG9zZSB0",
        "b29scyBvciBnZW5lcmFsbHkgYXZhaWxhYmxlIGZyZWUKcHJvZ3JhbXMgd2hpY2ggYXJlIHVzZWQgdW5tb2RpZmllZCBpbiBw",
        "ZXJmb3JtaW5nIHRob3NlIGFjdGl2aXRpZXMgYnV0CndoaWNoIGFyZSBub3QgcGFydCBvZiB0aGUgd29yay4gIEZvciBleGFt",
        "cGxlLCBDb3JyZXNwb25kaW5nIFNvdXJjZQppbmNsdWRlcyBpbnRlcmZhY2UgZGVmaW5pdGlvbiBmaWxlcyBhc3NvY2lhdGVk",
        "IHdpdGggc291cmNlIGZpbGVzIGZvcgp0aGUgd29yaywgYW5kIHRoZSBzb3VyY2UgY29kZSBmb3Igc2hhcmVkIGxpYnJhcmll",
        "cyBhbmQgZHluYW1pY2FsbHkKbGlua2VkIHN1YnByb2dyYW1zIHRoYXQgdGhlIHdvcmsgaXMgc3BlY2lmaWNhbGx5IGRlc2ln",
        "bmVkIHRvIHJlcXVpcmUsCnN1Y2ggYXMgYnkgaW50aW1hdGUgZGF0YSBjb21tdW5pY2F0aW9uIG9yIGNvbnRyb2wgZmxvdyBi",
        "ZXR3ZWVuIHRob3NlCnN1YnByb2dyYW1zIGFuZCBvdGhlciBwYXJ0cyBvZiB0aGUgd29yay4KCiAgVGhlIENvcnJlc3BvbmRp",
        "bmcgU291cmNlIG5lZWQgbm90IGluY2x1ZGUgYW55dGhpbmcgdGhhdCB1c2VycwpjYW4gcmVnZW5lcmF0ZSBhdXRvbWF0aWNh",
        "bGx5IGZyb20gb3RoZXIgcGFydHMgb2YgdGhlIENvcnJlc3BvbmRpbmcKU291cmNlLgoKICBUaGUgQ29ycmVzcG9uZGluZyBT",
        "b3VyY2UgZm9yIGEgd29yayBpbiBzb3VyY2UgY29kZSBmb3JtIGlzIHRoYXQKc2FtZSB3b3JrLgoKICAyLiBCYXNpYyBQZXJt",
        "aXNzaW9ucy4KCiAgQWxsIHJpZ2h0cyBncmFudGVkIHVuZGVyIHRoaXMgTGljZW5zZSBhcmUgZ3JhbnRlZCBmb3IgdGhlIHRl",
        "cm0gb2YKY29weXJpZ2h0IG9uIHRoZSBQcm9ncmFtLCBhbmQgYXJlIGlycmV2b2NhYmxlIHByb3ZpZGVkIHRoZSBzdGF0ZWQK",
        "Y29uZGl0aW9ucyBhcmUgbWV0LiAgVGhpcyBMaWNlbnNlIGV4cGxpY2l0bHkgYWZmaXJtcyB5b3VyIHVubGltaXRlZApwZXJt",
        "aXNzaW9uIHRvIHJ1biB0aGUgdW5tb2RpZmllZCBQcm9ncmFtLiAgVGhlIG91dHB1dCBmcm9tIHJ1bm5pbmcgYQpjb3ZlcmVk",
        "IHdvcmsgaXMgY292ZXJlZCBieSB0aGlzIExpY2Vuc2Ugb25seSBpZiB0aGUgb3V0cHV0LCBnaXZlbiBpdHMKY29udGVudCwg",
        "Y29uc3RpdHV0ZXMgYSBjb3ZlcmVkIHdvcmsuICBUaGlzIExpY2Vuc2UgYWNrbm93bGVkZ2VzIHlvdXIKcmlnaHRzIG9mIGZh",
        "aXIgdXNlIG9yIG90aGVyIGVxdWl2YWxlbnQsIGFzIHByb3ZpZGVkIGJ5IGNvcHlyaWdodCBsYXcuCgogIFlvdSBtYXkgbWFr",
        "ZSwgcnVuIGFuZCBwcm9wYWdhdGUgY292ZXJlZCB3b3JrcyB0aGF0IHlvdSBkbyBub3QKY29udmV5LCB3aXRob3V0IGNvbmRp",
        "dGlvbnMgc28gbG9uZyBhcyB5b3VyIGxpY2Vuc2Ugb3RoZXJ3aXNlIHJlbWFpbnMKaW4gZm9yY2UuICBZb3UgbWF5IGNvbnZl",
        "eSBjb3ZlcmVkIHdvcmtzIHRvIG90aGVycyBmb3IgdGhlIHNvbGUgcHVycG9zZQpvZiBoYXZpbmcgdGhlbSBtYWtlIG1vZGlm",
        "aWNhdGlvbnMgZXhjbHVzaXZlbHkgZm9yIHlvdSwgb3IgcHJvdmlkZSB5b3UKd2l0aCBmYWNpbGl0aWVzIGZvciBydW5uaW5n",
        "IHRob3NlIHdvcmtzLCBwcm92aWRlZCB0aGF0IHlvdSBjb21wbHkgd2l0aAp0aGUgdGVybXMgb2YgdGhpcyBMaWNlbnNlIGlu",
        "IGNvbnZleWluZyBhbGwgbWF0ZXJpYWwgZm9yIHdoaWNoIHlvdSBkbwpub3QgY29udHJvbCBjb3B5cmlnaHQuICBUaG9zZSB0",
        "aHVzIG1ha2luZyBvciBydW5uaW5nIHRoZSBjb3ZlcmVkIHdvcmtzCmZvciB5b3UgbXVzdCBkbyBzbyBleGNsdXNpdmVseSBv",
        "biB5b3VyIGJlaGFsZiwgdW5kZXIgeW91ciBkaXJlY3Rpb24KYW5kIGNvbnRyb2wsIG9uIHRlcm1zIHRoYXQgcHJvaGliaXQg",
        "dGhlbSBmcm9tIG1ha2luZyBhbnkgY29waWVzIG9mCnlvdXIgY29weXJpZ2h0ZWQgbWF0ZXJpYWwgb3V0c2lkZSB0aGVpciBy",
        "ZWxhdGlvbnNoaXAgd2l0aCB5b3UuCgogIENvbnZleWluZyB1bmRlciBhbnkgb3RoZXIgY2lyY3Vtc3RhbmNlcyBpcyBwZXJt",
        "aXR0ZWQgc29sZWx5IHVuZGVyCnRoZSBjb25kaXRpb25zIHN0YXRlZCBiZWxvdy4gIFN1YmxpY2Vuc2luZyBpcyBub3QgYWxs",
        "b3dlZDsgc2VjdGlvbiAxMAptYWtlcyBpdCB1bm5lY2Vzc2FyeS4KCiAgMy4gUHJvdGVjdGluZyBVc2VycycgTGVnYWwgUmln",
        "aHRzIEZyb20gQW50aS1DaXJjdW12ZW50aW9uIExhdy4KCiAgTm8gY292ZXJlZCB3b3JrIHNoYWxsIGJlIGRlZW1lZCBwYXJ0",
        "IG9mIGFuIGVmZmVjdGl2ZSB0ZWNobm9sb2dpY2FsCm1lYXN1cmUgdW5kZXIgYW55IGFwcGxpY2FibGUgbGF3IGZ1bGZpbGxp",
        "bmcgb2JsaWdhdGlvbnMgdW5kZXIgYXJ0aWNsZQoxMSBvZiB0aGUgV0lQTyBjb3B5cmlnaHQgdHJlYXR5IGFkb3B0ZWQgb24g",
        "MjAgRGVjZW1iZXIgMTk5Niwgb3IKc2ltaWxhciBsYXdzIHByb2hpYml0aW5nIG9yIHJlc3RyaWN0aW5nIGNpcmN1bXZlbnRp",
        "b24gb2Ygc3VjaAptZWFzdXJlcy4KCiAgV2hlbiB5b3UgY29udmV5IGEgY292ZXJlZCB3b3JrLCB5b3Ugd2FpdmUgYW55IGxl",
        "Z2FsIHBvd2VyIHRvIGZvcmJpZApjaXJjdW12ZW50aW9uIG9mIHRlY2hub2xvZ2ljYWwgbWVhc3VyZXMgdG8gdGhlIGV4dGVu",
        "dCBzdWNoIGNpcmN1bXZlbnRpb24KaXMgZWZmZWN0ZWQgYnkgZXhlcmNpc2luZyByaWdodHMgdW5kZXIgdGhpcyBMaWNlbnNl",
        "IHdpdGggcmVzcGVjdCB0bwp0aGUgY292ZXJlZCB3b3JrLCBhbmQgeW91IGRpc2NsYWltIGFueSBpbnRlbnRpb24gdG8gbGlt",
        "aXQgb3BlcmF0aW9uIG9yCm1vZGlmaWNhdGlvbiBvZiB0aGUgd29yayBhcyBhIG1lYW5zIG9mIGVuZm9yY2luZywgYWdhaW5z",
        "dCB0aGUgd29yaydzCnVzZXJzLCB5b3VyIG9yIHRoaXJkIHBhcnRpZXMnIGxlZ2FsIHJpZ2h0cyB0byBmb3JiaWQgY2lyY3Vt",
        "dmVudGlvbiBvZgp0ZWNobm9sb2dpY2FsIG1lYXN1cmVzLgoKICA0LiBDb252ZXlpbmcgVmVyYmF0aW0gQ29waWVzLgoKICBZ",
        "b3UgbWF5IGNvbnZleSB2ZXJiYXRpbSBjb3BpZXMgb2YgdGhlIFByb2dyYW0ncyBzb3VyY2UgY29kZSBhcyB5b3UKcmVjZWl2",
        "ZSBpdCwgaW4gYW55IG1lZGl1bSwgcHJvdmlkZWQgdGhhdCB5b3UgY29uc3BpY3VvdXNseSBhbmQKYXBwcm9wcmlhdGVseSBw",
        "dWJsaXNoIG9uIGVhY2ggY29weSBhbiBhcHByb3ByaWF0ZSBjb3B5cmlnaHQgbm90aWNlOwprZWVwIGludGFjdCBhbGwgbm90",
        "aWNlcyBzdGF0aW5nIHRoYXQgdGhpcyBMaWNlbnNlIGFuZCBhbnkKbm9uLXBlcm1pc3NpdmUgdGVybXMgYWRkZWQgaW4gYWNj",
        "b3JkIHdpdGggc2VjdGlvbiA3IGFwcGx5IHRvIHRoZSBjb2RlOwprZWVwIGludGFjdCBhbGwgbm90aWNlcyBvZiB0aGUgYWJz",
        "ZW5jZSBvZiBhbnkgd2FycmFudHk7IGFuZCBnaXZlIGFsbApyZWNpcGllbnRzIGEgY29weSBvZiB0aGlzIExpY2Vuc2UgYWxv",
        "bmcgd2l0aCB0aGUgUHJvZ3JhbS4KCiAgWW91IG1heSBjaGFyZ2UgYW55IHByaWNlIG9yIG5vIHByaWNlIGZvciBlYWNoIGNv",
        "cHkgdGhhdCB5b3UgY29udmV5LAphbmQgeW91IG1heSBvZmZlciBzdXBwb3J0IG9yIHdhcnJhbnR5IHByb3RlY3Rpb24gZm9y",
        "IGEgZmVlLgoKICA1LiBDb252ZXlpbmcgTW9kaWZpZWQgU291cmNlIFZlcnNpb25zLgoKICBZb3UgbWF5IGNvbnZleSBhIHdv",
        "cmsgYmFzZWQgb24gdGhlIFByb2dyYW0sIG9yIHRoZSBtb2RpZmljYXRpb25zIHRvCnByb2R1Y2UgaXQgZnJvbSB0aGUgUHJv",
        "Z3JhbSwgaW4gdGhlIGZvcm0gb2Ygc291cmNlIGNvZGUgdW5kZXIgdGhlCnRlcm1zIG9mIHNlY3Rpb24gNCwgcHJvdmlkZWQg",
        "dGhhdCB5b3UgYWxzbyBtZWV0IGFsbCBvZiB0aGVzZSBjb25kaXRpb25zOgoKICAgIGEpIFRoZSB3b3JrIG11c3QgY2Fycnkg",
        "cHJvbWluZW50IG5vdGljZXMgc3RhdGluZyB0aGF0IHlvdSBtb2RpZmllZAogICAgaXQsIGFuZCBnaXZpbmcgYSByZWxldmFu",
        "dCBkYXRlLgoKICAgIGIpIFRoZSB3b3JrIG11c3QgY2FycnkgcHJvbWluZW50IG5vdGljZXMgc3RhdGluZyB0aGF0IGl0IGlz",
        "CiAgICByZWxlYXNlZCB1bmRlciB0aGlzIExpY2Vuc2UgYW5kIGFueSBjb25kaXRpb25zIGFkZGVkIHVuZGVyIHNlY3Rpb24K",
        "ICAgIDcuICBUaGlzIHJlcXVpcmVtZW50IG1vZGlmaWVzIHRoZSByZXF1aXJlbWVudCBpbiBzZWN0aW9uIDQgdG8KICAgICJr",
        "ZWVwIGludGFjdCBhbGwgbm90aWNlcyIuCgogICAgYykgWW91IG11c3QgbGljZW5zZSB0aGUgZW50aXJlIHdvcmssIGFzIGEg",
        "d2hvbGUsIHVuZGVyIHRoaXMKICAgIExpY2Vuc2UgdG8gYW55b25lIHdobyBjb21lcyBpbnRvIHBvc3Nlc3Npb24gb2YgYSBj",
        "b3B5LiAgVGhpcwogICAgTGljZW5zZSB3aWxsIHRoZXJlZm9yZSBhcHBseSwgYWxvbmcgd2l0aCBhbnkgYXBwbGljYWJsZSBz",
        "ZWN0aW9uIDcKICAgIGFkZGl0aW9uYWwgdGVybXMsIHRvIHRoZSB3aG9sZSBvZiB0aGUgd29yaywgYW5kIGFsbCBpdHMgcGFy",
        "dHMsCiAgICByZWdhcmRsZXNzIG9mIGhvdyB0aGV5IGFyZSBwYWNrYWdlZC4gIFRoaXMgTGljZW5zZSBnaXZlcyBubwogICAg",
        "cGVybWlzc2lvbiB0byBsaWNlbnNlIHRoZSB3b3JrIGluIGFueSBvdGhlciB3YXksIGJ1dCBpdCBkb2VzIG5vdAogICAgaW52",
        "YWxpZGF0ZSBzdWNoIHBlcm1pc3Npb24gaWYgeW91IGhhdmUgc2VwYXJhdGVseSByZWNlaXZlZCBpdC4KCiAgICBkKSBJZiB0",
        "aGUgd29yayBoYXMgaW50ZXJhY3RpdmUgdXNlciBpbnRlcmZhY2VzLCBlYWNoIG11c3QgZGlzcGxheQogICAgQXBwcm9wcmlh",
        "dGUgTGVnYWwgTm90aWNlczsgaG93ZXZlciwgaWYgdGhlIFByb2dyYW0gaGFzIGludGVyYWN0aXZlCiAgICBpbnRlcmZhY2Vz",
        "IHRoYXQgZG8gbm90IGRpc3BsYXkgQXBwcm9wcmlhdGUgTGVnYWwgTm90aWNlcywgeW91cgogICAgd29yayBuZWVkIG5vdCBt",
        "YWtlIHRoZW0gZG8gc28uCgogIEEgY29tcGlsYXRpb24gb2YgYSBjb3ZlcmVkIHdvcmsgd2l0aCBvdGhlciBzZXBhcmF0ZSBh",
        "bmQgaW5kZXBlbmRlbnQKd29ya3MsIHdoaWNoIGFyZSBub3QgYnkgdGhlaXIgbmF0dXJlIGV4dGVuc2lvbnMgb2YgdGhlIGNv",
        "dmVyZWQgd29yaywKYW5kIHdoaWNoIGFyZSBub3QgY29tYmluZWQgd2l0aCBpdCBzdWNoIGFzIHRvIGZvcm0gYSBsYXJnZXIg",
        "cHJvZ3JhbSwKaW4gb3Igb24gYSB2b2x1bWUgb2YgYSBzdG9yYWdlIG9yIGRpc3RyaWJ1dGlvbiBtZWRpdW0sIGlzIGNhbGxl",
        "ZCBhbgoiYWdncmVnYXRlIiBpZiB0aGUgY29tcGlsYXRpb24gYW5kIGl0cyByZXN1bHRpbmcgY29weXJpZ2h0IGFyZSBub3QK",
        "dXNlZCB0byBsaW1pdCB0aGUgYWNjZXNzIG9yIGxlZ2FsIHJpZ2h0cyBvZiB0aGUgY29tcGlsYXRpb24ncyB1c2VycwpiZXlv",
        "bmQgd2hhdCB0aGUgaW5kaXZpZHVhbCB3b3JrcyBwZXJtaXQuICBJbmNsdXNpb24gb2YgYSBjb3ZlcmVkIHdvcmsKaW4gYW4g",
        "YWdncmVnYXRlIGRvZXMgbm90IGNhdXNlIHRoaXMgTGljZW5zZSB0byBhcHBseSB0byB0aGUgb3RoZXIKcGFydHMgb2YgdGhl",
        "IGFnZ3JlZ2F0ZS4KCiAgNi4gQ29udmV5aW5nIE5vbi1Tb3VyY2UgRm9ybXMuCgogIFlvdSBtYXkgY29udmV5IGEgY292ZXJl",
        "ZCB3b3JrIGluIG9iamVjdCBjb2RlIGZvcm0gdW5kZXIgdGhlIHRlcm1zCm9mIHNlY3Rpb25zIDQgYW5kIDUsIHByb3ZpZGVk",
        "IHRoYXQgeW91IGFsc28gY29udmV5IHRoZQptYWNoaW5lLXJlYWRhYmxlIENvcnJlc3BvbmRpbmcgU291cmNlIHVuZGVyIHRo",
        "ZSB0ZXJtcyBvZiB0aGlzIExpY2Vuc2UsCmluIG9uZSBvZiB0aGVzZSB3YXlzOgoKICAgIGEpIENvbnZleSB0aGUgb2JqZWN0",
        "IGNvZGUgaW4sIG9yIGVtYm9kaWVkIGluLCBhIHBoeXNpY2FsIHByb2R1Y3QKICAgIChpbmNsdWRpbmcgYSBwaHlzaWNhbCBk",
        "aXN0cmlidXRpb24gbWVkaXVtKSwgYWNjb21wYW5pZWQgYnkgdGhlCiAgICBDb3JyZXNwb25kaW5nIFNvdXJjZSBmaXhlZCBv",
        "biBhIGR1cmFibGUgcGh5c2ljYWwgbWVkaXVtCiAgICBjdXN0b21hcmlseSB1c2VkIGZvciBzb2Z0d2FyZSBpbnRlcmNoYW5n",
        "ZS4KCiAgICBiKSBDb252ZXkgdGhlIG9iamVjdCBjb2RlIGluLCBvciBlbWJvZGllZCBpbiwgYSBwaHlzaWNhbCBwcm9kdWN0",
        "CiAgICAoaW5jbHVkaW5nIGEgcGh5c2ljYWwgZGlzdHJpYnV0aW9uIG1lZGl1bSksIGFjY29tcGFuaWVkIGJ5IGEKICAgIHdy",
        "aXR0ZW4gb2ZmZXIsIHZhbGlkIGZvciBhdCBsZWFzdCB0aHJlZSB5ZWFycyBhbmQgdmFsaWQgZm9yIGFzCiAgICBsb25nIGFz",
        "IHlvdSBvZmZlciBzcGFyZSBwYXJ0cyBvciBjdXN0b21lciBzdXBwb3J0IGZvciB0aGF0IHByb2R1Y3QKICAgIG1vZGVsLCB0",
        "byBnaXZlIGFueW9uZSB3aG8gcG9zc2Vzc2VzIHRoZSBvYmplY3QgY29kZSBlaXRoZXIgKDEpIGEKICAgIGNvcHkgb2YgdGhl",
        "IENvcnJlc3BvbmRpbmcgU291cmNlIGZvciBhbGwgdGhlIHNvZnR3YXJlIGluIHRoZQogICAgcHJvZHVjdCB0aGF0IGlzIGNv",
        "dmVyZWQgYnkgdGhpcyBMaWNlbnNlLCBvbiBhIGR1cmFibGUgcGh5c2ljYWwKICAgIG1lZGl1bSBjdXN0b21hcmlseSB1c2Vk",
        "IGZvciBzb2Z0d2FyZSBpbnRlcmNoYW5nZSwgZm9yIGEgcHJpY2Ugbm8KICAgIG1vcmUgdGhhbiB5b3VyIHJlYXNvbmFibGUg",
        "Y29zdCBvZiBwaHlzaWNhbGx5IHBlcmZvcm1pbmcgdGhpcwogICAgY29udmV5aW5nIG9mIHNvdXJjZSwgb3IgKDIpIGFjY2Vz",
        "cyB0byBjb3B5IHRoZQogICAgQ29ycmVzcG9uZGluZyBTb3VyY2UgZnJvbSBhIG5ldHdvcmsgc2VydmVyIGF0IG5vIGNoYXJn",
        "ZS4KCiAgICBjKSBDb252ZXkgaW5kaXZpZHVhbCBjb3BpZXMgb2YgdGhlIG9iamVjdCBjb2RlIHdpdGggYSBjb3B5IG9mIHRo",
        "ZQogICAgd3JpdHRlbiBvZmZlciB0byBwcm92aWRlIHRoZSBDb3JyZXNwb25kaW5nIFNvdXJjZS4gIFRoaXMKICAgIGFsdGVy",
        "bmF0aXZlIGlzIGFsbG93ZWQgb25seSBvY2Nhc2lvbmFsbHkgYW5kIG5vbmNvbW1lcmNpYWxseSwgYW5kCiAgICBvbmx5IGlm",
        "IHlvdSByZWNlaXZlZCB0aGUgb2JqZWN0IGNvZGUgd2l0aCBzdWNoIGFuIG9mZmVyLCBpbiBhY2NvcmQKICAgIHdpdGggc3Vi",
        "c2VjdGlvbiA2Yi4KCiAgICBkKSBDb252ZXkgdGhlIG9iamVjdCBjb2RlIGJ5IG9mZmVyaW5nIGFjY2VzcyBmcm9tIGEgZGVz",
        "aWduYXRlZAogICAgcGxhY2UgKGdyYXRpcyBvciBmb3IgYSBjaGFyZ2UpLCBhbmQgb2ZmZXIgZXF1aXZhbGVudCBhY2Nlc3Mg",
        "dG8gdGhlCiAgICBDb3JyZXNwb25kaW5nIFNvdXJjZSBpbiB0aGUgc2FtZSB3YXkgdGhyb3VnaCB0aGUgc2FtZSBwbGFjZSBh",
        "dCBubwogICAgZnVydGhlciBjaGFyZ2UuICBZb3UgbmVlZCBub3QgcmVxdWlyZSByZWNpcGllbnRzIHRvIGNvcHkgdGhlCiAg",
        "ICBDb3JyZXNwb25kaW5nIFNvdXJjZSBhbG9uZyB3aXRoIHRoZSBvYmplY3QgY29kZS4gIElmIHRoZSBwbGFjZSB0bwogICAg",
        "Y29weSB0aGUgb2JqZWN0IGNvZGUgaXMgYSBuZXR3b3JrIHNlcnZlciwgdGhlIENvcnJlc3BvbmRpbmcgU291cmNlCiAgICBt",
        "YXkgYmUgb24gYSBkaWZmZXJlbnQgc2VydmVyIChvcGVyYXRlZCBieSB5b3Ugb3IgYSB0aGlyZCBwYXJ0eSkKICAgIHRoYXQg",
        "c3VwcG9ydHMgZXF1aXZhbGVudCBjb3B5aW5nIGZhY2lsaXRpZXMsIHByb3ZpZGVkIHlvdSBtYWludGFpbgogICAgY2xlYXIg",
        "ZGlyZWN0aW9ucyBuZXh0IHRvIHRoZSBvYmplY3QgY29kZSBzYXlpbmcgd2hlcmUgdG8gZmluZCB0aGUKICAgIENvcnJlc3Bv",
        "bmRpbmcgU291cmNlLiAgUmVnYXJkbGVzcyBvZiB3aGF0IHNlcnZlciBob3N0cyB0aGUKICAgIENvcnJlc3BvbmRpbmcgU291",
        "cmNlLCB5b3UgcmVtYWluIG9ibGlnYXRlZCB0byBlbnN1cmUgdGhhdCBpdCBpcwogICAgYXZhaWxhYmxlIGZvciBhcyBsb25n",
        "IGFzIG5lZWRlZCB0byBzYXRpc2Z5IHRoZXNlIHJlcXVpcmVtZW50cy4KCiAgICBlKSBDb252ZXkgdGhlIG9iamVjdCBjb2Rl",
        "IHVzaW5nIHBlZXItdG8tcGVlciB0cmFuc21pc3Npb24sIHByb3ZpZGVkCiAgICB5b3UgaW5mb3JtIG90aGVyIHBlZXJzIHdo",
        "ZXJlIHRoZSBvYmplY3QgY29kZSBhbmQgQ29ycmVzcG9uZGluZwogICAgU291cmNlIG9mIHRoZSB3b3JrIGFyZSBiZWluZyBv",
        "ZmZlcmVkIHRvIHRoZSBnZW5lcmFsIHB1YmxpYyBhdCBubwogICAgY2hhcmdlIHVuZGVyIHN1YnNlY3Rpb24gNmQuCgogIEEg",
        "c2VwYXJhYmxlIHBvcnRpb24gb2YgdGhlIG9iamVjdCBjb2RlLCB3aG9zZSBzb3VyY2UgY29kZSBpcyBleGNsdWRlZApmcm9t",
        "IHRoZSBDb3JyZXNwb25kaW5nIFNvdXJjZSBhcyBhIFN5c3RlbSBMaWJyYXJ5LCBuZWVkIG5vdCBiZQppbmNsdWRlZCBpbiBj",
        "b252ZXlpbmcgdGhlIG9iamVjdCBjb2RlIHdvcmsuCgogIEEgIlVzZXIgUHJvZHVjdCIgaXMgZWl0aGVyICgxKSBhICJjb25z",
        "dW1lciBwcm9kdWN0Iiwgd2hpY2ggbWVhbnMgYW55CnRhbmdpYmxlIHBlcnNvbmFsIHByb3BlcnR5IHdoaWNoIGlzIG5vcm1h",
        "bGx5IHVzZWQgZm9yIHBlcnNvbmFsLCBmYW1pbHksCm9yIGhvdXNlaG9sZCBwdXJwb3Nlcywgb3IgKDIpIGFueXRoaW5nIGRl",
        "c2lnbmVkIG9yIHNvbGQgZm9yIGluY29ycG9yYXRpb24KaW50byBhIGR3ZWxsaW5nLiAgSW4gZGV0ZXJtaW5pbmcgd2hldGhl",
        "ciBhIHByb2R1Y3QgaXMgYSBjb25zdW1lciBwcm9kdWN0LApkb3VidGZ1bCBjYXNlcyBzaGFsbCBiZSByZXNvbHZlZCBpbiBm",
        "YXZvciBvZiBjb3ZlcmFnZS4gIEZvciBhIHBhcnRpY3VsYXIKcHJvZHVjdCByZWNlaXZlZCBieSBhIHBhcnRpY3VsYXIgdXNl",
        "ciwgIm5vcm1hbGx5IHVzZWQiIHJlZmVycyB0byBhCnR5cGljYWwgb3IgY29tbW9uIHVzZSBvZiB0aGF0IGNsYXNzIG9mIHBy",
        "b2R1Y3QsIHJlZ2FyZGxlc3Mgb2YgdGhlIHN0YXR1cwpvZiB0aGUgcGFydGljdWxhciB1c2VyIG9yIG9mIHRoZSB3YXkgaW4g",
        "d2hpY2ggdGhlIHBhcnRpY3VsYXIgdXNlcgphY3R1YWxseSB1c2VzLCBvciBleHBlY3RzIG9yIGlzIGV4cGVjdGVkIHRvIHVz",
        "ZSwgdGhlIHByb2R1Y3QuICBBIHByb2R1Y3QKaXMgYSBjb25zdW1lciBwcm9kdWN0IHJlZ2FyZGxlc3Mgb2Ygd2hldGhlciB0",
        "aGUgcHJvZHVjdCBoYXMgc3Vic3RhbnRpYWwKY29tbWVyY2lhbCwgaW5kdXN0cmlhbCBvciBub24tY29uc3VtZXIgdXNlcywg",
        "dW5sZXNzIHN1Y2ggdXNlcyByZXByZXNlbnQKdGhlIG9ubHkgc2lnbmlmaWNhbnQgbW9kZSBvZiB1c2Ugb2YgdGhlIHByb2R1",
        "Y3QuCgogICJJbnN0YWxsYXRpb24gSW5mb3JtYXRpb24iIGZvciBhIFVzZXIgUHJvZHVjdCBtZWFucyBhbnkgbWV0aG9kcywK",
        "cHJvY2VkdXJlcywgYXV0aG9yaXphdGlvbiBrZXlzLCBvciBvdGhlciBpbmZvcm1hdGlvbiByZXF1aXJlZCB0byBpbnN0YWxs",
        "CmFuZCBleGVjdXRlIG1vZGlmaWVkIHZlcnNpb25zIG9mIGEgY292ZXJlZCB3b3JrIGluIHRoYXQgVXNlciBQcm9kdWN0IGZy",
        "b20KYSBtb2RpZmllZCB2ZXJzaW9uIG9mIGl0cyBDb3JyZXNwb25kaW5nIFNvdXJjZS4gIFRoZSBpbmZvcm1hdGlvbiBtdXN0",
        "CnN1ZmZpY2UgdG8gZW5zdXJlIHRoYXQgdGhlIGNvbnRpbnVlZCBmdW5jdGlvbmluZyBvZiB0aGUgbW9kaWZpZWQgb2JqZWN0",
        "CmNvZGUgaXMgaW4gbm8gY2FzZSBwcmV2ZW50ZWQgb3IgaW50ZXJmZXJlZCB3aXRoIHNvbGVseSBiZWNhdXNlCm1vZGlmaWNh",
        "dGlvbiBoYXMgYmVlbiBtYWRlLgoKICBJZiB5b3UgY29udmV5IGFuIG9iamVjdCBjb2RlIHdvcmsgdW5kZXIgdGhpcyBzZWN0",
        "aW9uIGluLCBvciB3aXRoLCBvcgpzcGVjaWZpY2FsbHkgZm9yIHVzZSBpbiwgYSBVc2VyIFByb2R1Y3QsIGFuZCB0aGUgY29u",
        "dmV5aW5nIG9jY3VycyBhcwpwYXJ0IG9mIGEgdHJhbnNhY3Rpb24gaW4gd2hpY2ggdGhlIHJpZ2h0IG9mIHBvc3Nlc3Npb24g",
        "YW5kIHVzZSBvZiB0aGUKVXNlciBQcm9kdWN0IGlzIHRyYW5zZmVycmVkIHRvIHRoZSByZWNpcGllbnQgaW4gcGVycGV0dWl0",
        "eSBvciBmb3IgYQpmaXhlZCB0ZXJtIChyZWdhcmRsZXNzIG9mIGhvdyB0aGUgdHJhbnNhY3Rpb24gaXMgY2hhcmFjdGVyaXpl",
        "ZCksIHRoZQpDb3JyZXNwb25kaW5nIFNvdXJjZSBjb252ZXllZCB1bmRlciB0aGlzIHNlY3Rpb24gbXVzdCBiZSBhY2NvbXBh",
        "bmllZApieSB0aGUgSW5zdGFsbGF0aW9uIEluZm9ybWF0aW9uLiAgQnV0IHRoaXMgcmVxdWlyZW1lbnQgZG9lcyBub3QgYXBw",
        "bHkKaWYgbmVpdGhlciB5b3Ugbm9yIGFueSB0aGlyZCBwYXJ0eSByZXRhaW5zIHRoZSBhYmlsaXR5IHRvIGluc3RhbGwKbW9k",
        "aWZpZWQgb2JqZWN0IGNvZGUgb24gdGhlIFVzZXIgUHJvZHVjdCAoZm9yIGV4YW1wbGUsIHRoZSB3b3JrIGhhcwpiZWVuIGlu",
        "c3RhbGxlZCBpbiBST00pLgoKICBUaGUgcmVxdWlyZW1lbnQgdG8gcHJvdmlkZSBJbnN0YWxsYXRpb24gSW5mb3JtYXRpb24g",
        "ZG9lcyBub3QgaW5jbHVkZSBhCnJlcXVpcmVtZW50IHRvIGNvbnRpbnVlIHRvIHByb3ZpZGUgc3VwcG9ydCBzZXJ2aWNlLCB3",
        "YXJyYW50eSwgb3IgdXBkYXRlcwpmb3IgYSB3b3JrIHRoYXQgaGFzIGJlZW4gbW9kaWZpZWQgb3IgaW5zdGFsbGVkIGJ5IHRo",
        "ZSByZWNpcGllbnQsIG9yIGZvcgp0aGUgVXNlciBQcm9kdWN0IGluIHdoaWNoIGl0IGhhcyBiZWVuIG1vZGlmaWVkIG9yIGlu",
        "c3RhbGxlZC4gIEFjY2VzcyB0byBhCm5ldHdvcmsgbWF5IGJlIGRlbmllZCB3aGVuIHRoZSBtb2RpZmljYXRpb24gaXRzZWxm",
        "IG1hdGVyaWFsbHkgYW5kCmFkdmVyc2VseSBhZmZlY3RzIHRoZSBvcGVyYXRpb24gb2YgdGhlIG5ldHdvcmsgb3IgdmlvbGF0",
        "ZXMgdGhlIHJ1bGVzIGFuZApwcm90b2NvbHMgZm9yIGNvbW11bmljYXRpb24gYWNyb3NzIHRoZSBuZXR3b3JrLgoKICBDb3Jy",
        "ZXNwb25kaW5nIFNvdXJjZSBjb252ZXllZCwgYW5kIEluc3RhbGxhdGlvbiBJbmZvcm1hdGlvbiBwcm92aWRlZCwKaW4gYWNj",
        "b3JkIHdpdGggdGhpcyBzZWN0aW9uIG11c3QgYmUgaW4gYSBmb3JtYXQgdGhhdCBpcyBwdWJsaWNseQpkb2N1bWVudGVkIChh",
        "bmQgd2l0aCBhbiBpbXBsZW1lbnRhdGlvbiBhdmFpbGFibGUgdG8gdGhlIHB1YmxpYyBpbgpzb3VyY2UgY29kZSBmb3JtKSwg",
        "YW5kIG11c3QgcmVxdWlyZSBubyBzcGVjaWFsIHBhc3N3b3JkIG9yIGtleSBmb3IKdW5wYWNraW5nLCByZWFkaW5nIG9yIGNv",
        "cHlpbmcuCgogIDcuIEFkZGl0aW9uYWwgVGVybXMuCgogICJBZGRpdGlvbmFsIHBlcm1pc3Npb25zIiBhcmUgdGVybXMgdGhh",
        "dCBzdXBwbGVtZW50IHRoZSB0ZXJtcyBvZiB0aGlzCkxpY2Vuc2UgYnkgbWFraW5nIGV4Y2VwdGlvbnMgZnJvbSBvbmUgb3Ig",
        "bW9yZSBvZiBpdHMgY29uZGl0aW9ucy4KQWRkaXRpb25hbCBwZXJtaXNzaW9ucyB0aGF0IGFyZSBhcHBsaWNhYmxlIHRvIHRo",
        "ZSBlbnRpcmUgUHJvZ3JhbSBzaGFsbApiZSB0cmVhdGVkIGFzIHRob3VnaCB0aGV5IHdlcmUgaW5jbHVkZWQgaW4gdGhpcyBM",
        "aWNlbnNlLCB0byB0aGUgZXh0ZW50CnRoYXQgdGhleSBhcmUgdmFsaWQgdW5kZXIgYXBwbGljYWJsZSBsYXcuICBJZiBhZGRp",
        "dGlvbmFsIHBlcm1pc3Npb25zCmFwcGx5IG9ubHkgdG8gcGFydCBvZiB0aGUgUHJvZ3JhbSwgdGhhdCBwYXJ0IG1heSBiZSB1",
        "c2VkIHNlcGFyYXRlbHkKdW5kZXIgdGhvc2UgcGVybWlzc2lvbnMsIGJ1dCB0aGUgZW50aXJlIFByb2dyYW0gcmVtYWlucyBn",
        "b3Zlcm5lZCBieQp0aGlzIExpY2Vuc2Ugd2l0aG91dCByZWdhcmQgdG8gdGhlIGFkZGl0aW9uYWwgcGVybWlzc2lvbnMuCgog",
        "IFdoZW4geW91IGNvbnZleSBhIGNvcHkgb2YgYSBjb3ZlcmVkIHdvcmssIHlvdSBtYXkgYXQgeW91ciBvcHRpb24KcmVtb3Zl",
        "IGFueSBhZGRpdGlvbmFsIHBlcm1pc3Npb25zIGZyb20gdGhhdCBjb3B5LCBvciBmcm9tIGFueSBwYXJ0IG9mCml0LiAgKEFk",
        "ZGl0aW9uYWwgcGVybWlzc2lvbnMgbWF5IGJlIHdyaXR0ZW4gdG8gcmVxdWlyZSB0aGVpciBvd24KcmVtb3ZhbCBpbiBjZXJ0",
        "YWluIGNhc2VzIHdoZW4geW91IG1vZGlmeSB0aGUgd29yay4pICBZb3UgbWF5IHBsYWNlCmFkZGl0aW9uYWwgcGVybWlzc2lv",
        "bnMgb24gbWF0ZXJpYWwsIGFkZGVkIGJ5IHlvdSB0byBhIGNvdmVyZWQgd29yaywKZm9yIHdoaWNoIHlvdSBoYXZlIG9yIGNh",
        "biBnaXZlIGFwcHJvcHJpYXRlIGNvcHlyaWdodCBwZXJtaXNzaW9uLgoKICBOb3R3aXRoc3RhbmRpbmcgYW55IG90aGVyIHBy",
        "b3Zpc2lvbiBvZiB0aGlzIExpY2Vuc2UsIGZvciBtYXRlcmlhbCB5b3UKYWRkIHRvIGEgY292ZXJlZCB3b3JrLCB5b3UgbWF5",
        "IChpZiBhdXRob3JpemVkIGJ5IHRoZSBjb3B5cmlnaHQgaG9sZGVycyBvZgp0aGF0IG1hdGVyaWFsKSBzdXBwbGVtZW50IHRo",
        "ZSB0ZXJtcyBvZiB0aGlzIExpY2Vuc2Ugd2l0aCB0ZXJtczoKCiAgICBhKSBEaXNjbGFpbWluZyB3YXJyYW50eSBvciBsaW1p",
        "dGluZyBsaWFiaWxpdHkgZGlmZmVyZW50bHkgZnJvbSB0aGUKICAgIHRlcm1zIG9mIHNlY3Rpb25zIDE1IGFuZCAxNiBvZiB0",
        "aGlzIExpY2Vuc2U7IG9yCgogICAgYikgUmVxdWlyaW5nIHByZXNlcnZhdGlvbiBvZiBzcGVjaWZpZWQgcmVhc29uYWJsZSBs",
        "ZWdhbCBub3RpY2VzIG9yCiAgICBhdXRob3IgYXR0cmlidXRpb25zIGluIHRoYXQgbWF0ZXJpYWwgb3IgaW4gdGhlIEFwcHJv",
        "cHJpYXRlIExlZ2FsCiAgICBOb3RpY2VzIGRpc3BsYXllZCBieSB3b3JrcyBjb250YWluaW5nIGl0OyBvcgoKICAgIGMpIFBy",
        "b2hpYml0aW5nIG1pc3JlcHJlc2VudGF0aW9uIG9mIHRoZSBvcmlnaW4gb2YgdGhhdCBtYXRlcmlhbCwgb3IKICAgIHJlcXVp",
        "cmluZyB0aGF0IG1vZGlmaWVkIHZlcnNpb25zIG9mIHN1Y2ggbWF0ZXJpYWwgYmUgbWFya2VkIGluCiAgICByZWFzb25hYmxl",
        "IHdheXMgYXMgZGlmZmVyZW50IGZyb20gdGhlIG9yaWdpbmFsIHZlcnNpb247IG9yCgogICAgZCkgTGltaXRpbmcgdGhlIHVz",
        "ZSBmb3IgcHVibGljaXR5IHB1cnBvc2VzIG9mIG5hbWVzIG9mIGxpY2Vuc29ycyBvcgogICAgYXV0aG9ycyBvZiB0aGUgbWF0",
        "ZXJpYWw7IG9yCgogICAgZSkgRGVjbGluaW5nIHRvIGdyYW50IHJpZ2h0cyB1bmRlciB0cmFkZW1hcmsgbGF3IGZvciB1c2Ug",
        "b2Ygc29tZQogICAgdHJhZGUgbmFtZXMsIHRyYWRlbWFya3MsIG9yIHNlcnZpY2UgbWFya3M7IG9yCgogICAgZikgUmVxdWly",
        "aW5nIGluZGVtbmlmaWNhdGlvbiBvZiBsaWNlbnNvcnMgYW5kIGF1dGhvcnMgb2YgdGhhdAogICAgbWF0ZXJpYWwgYnkgYW55",
        "b25lIHdobyBjb252ZXlzIHRoZSBtYXRlcmlhbCAob3IgbW9kaWZpZWQgdmVyc2lvbnMgb2YKICAgIGl0KSB3aXRoIGNvbnRy",
        "YWN0dWFsIGFzc3VtcHRpb25zIG9mIGxpYWJpbGl0eSB0byB0aGUgcmVjaXBpZW50LCBmb3IKICAgIGFueSBsaWFiaWxpdHkg",
        "dGhhdCB0aGVzZSBjb250cmFjdHVhbCBhc3N1bXB0aW9ucyBkaXJlY3RseSBpbXBvc2Ugb24KICAgIHRob3NlIGxpY2Vuc29y",
        "cyBhbmQgYXV0aG9ycy4KCiAgQWxsIG90aGVyIG5vbi1wZXJtaXNzaXZlIGFkZGl0aW9uYWwgdGVybXMgYXJlIGNvbnNpZGVy",
        "ZWQgImZ1cnRoZXIKcmVzdHJpY3Rpb25zIiB3aXRoaW4gdGhlIG1lYW5pbmcgb2Ygc2VjdGlvbiAxMC4gIElmIHRoZSBQcm9n",
        "cmFtIGFzIHlvdQpyZWNlaXZlZCBpdCwgb3IgYW55IHBhcnQgb2YgaXQsIGNvbnRhaW5zIGEgbm90aWNlIHN0YXRpbmcgdGhh",
        "dCBpdCBpcwpnb3Zlcm5lZCBieSB0aGlzIExpY2Vuc2UgYWxvbmcgd2l0aCBhIHRlcm0gdGhhdCBpcyBhIGZ1cnRoZXIKcmVz",
        "dHJpY3Rpb24sIHlvdSBtYXkgcmVtb3ZlIHRoYXQgdGVybS4gIElmIGEgbGljZW5zZSBkb2N1bWVudCBjb250YWlucwphIGZ1",
        "cnRoZXIgcmVzdHJpY3Rpb24gYnV0IHBlcm1pdHMgcmVsaWNlbnNpbmcgb3IgY29udmV5aW5nIHVuZGVyIHRoaXMKTGljZW5z",
        "ZSwgeW91IG1heSBhZGQgdG8gYSBjb3ZlcmVkIHdvcmsgbWF0ZXJpYWwgZ292ZXJuZWQgYnkgdGhlIHRlcm1zCm9mIHRoYXQg",
        "bGljZW5zZSBkb2N1bWVudCwgcHJvdmlkZWQgdGhhdCB0aGUgZnVydGhlciByZXN0cmljdGlvbiBkb2VzCm5vdCBzdXJ2aXZl",
        "IHN1Y2ggcmVsaWNlbnNpbmcgb3IgY29udmV5aW5nLgoKICBJZiB5b3UgYWRkIHRlcm1zIHRvIGEgY292ZXJlZCB3b3JrIGlu",
        "IGFjY29yZCB3aXRoIHRoaXMgc2VjdGlvbiwgeW91Cm11c3QgcGxhY2UsIGluIHRoZSByZWxldmFudCBzb3VyY2UgZmlsZXMs",
        "IGEgc3RhdGVtZW50IG9mIHRoZQphZGRpdGlvbmFsIHRlcm1zIHRoYXQgYXBwbHkgdG8gdGhvc2UgZmlsZXMsIG9yIGEgbm90",
        "aWNlIGluZGljYXRpbmcKd2hlcmUgdG8gZmluZCB0aGUgYXBwbGljYWJsZSB0ZXJtcy4KCiAgQWRkaXRpb25hbCB0ZXJtcywg",
        "cGVybWlzc2l2ZSBvciBub24tcGVybWlzc2l2ZSwgbWF5IGJlIHN0YXRlZCBpbiB0aGUKZm9ybSBvZiBhIHNlcGFyYXRlbHkg",
        "d3JpdHRlbiBsaWNlbnNlLCBvciBzdGF0ZWQgYXMgZXhjZXB0aW9uczsKdGhlIGFib3ZlIHJlcXVpcmVtZW50cyBhcHBseSBl",
        "aXRoZXIgd2F5LgoKICA4LiBUZXJtaW5hdGlvbi4KCiAgWW91IG1heSBub3QgcHJvcGFnYXRlIG9yIG1vZGlmeSBhIGNvdmVy",
        "ZWQgd29yayBleGNlcHQgYXMgZXhwcmVzc2x5CnByb3ZpZGVkIHVuZGVyIHRoaXMgTGljZW5zZS4gIEFueSBhdHRlbXB0IG90",
        "aGVyd2lzZSB0byBwcm9wYWdhdGUgb3IKbW9kaWZ5IGl0IGlzIHZvaWQsIGFuZCB3aWxsIGF1dG9tYXRpY2FsbHkgdGVybWlu",
        "YXRlIHlvdXIgcmlnaHRzIHVuZGVyCnRoaXMgTGljZW5zZSAoaW5jbHVkaW5nIGFueSBwYXRlbnQgbGljZW5zZXMgZ3JhbnRl",
        "ZCB1bmRlciB0aGUgdGhpcmQKcGFyYWdyYXBoIG9mIHNlY3Rpb24gMTEpLgoKICBIb3dldmVyLCBpZiB5b3UgY2Vhc2UgYWxs",
        "IHZpb2xhdGlvbiBvZiB0aGlzIExpY2Vuc2UsIHRoZW4geW91cgpsaWNlbnNlIGZyb20gYSBwYXJ0aWN1bGFyIGNvcHlyaWdo",
        "dCBob2xkZXIgaXMgcmVpbnN0YXRlZCAoYSkKcHJvdmlzaW9uYWxseSwgdW5sZXNzIGFuZCB1bnRpbCB0aGUgY29weXJpZ2h0",
        "IGhvbGRlciBleHBsaWNpdGx5IGFuZApmaW5hbGx5IHRlcm1pbmF0ZXMgeW91ciBsaWNlbnNlLCBhbmQgKGIpIHBlcm1hbmVu",
        "dGx5LCBpZiB0aGUgY29weXJpZ2h0CmhvbGRlciBmYWlscyB0byBub3RpZnkgeW91IG9mIHRoZSB2aW9sYXRpb24gYnkgc29t",
        "ZSByZWFzb25hYmxlIG1lYW5zCnByaW9yIHRvIDYwIGRheXMgYWZ0ZXIgdGhlIGNlc3NhdGlvbi4KCiAgTW9yZW92ZXIsIHlv",
        "dXIgbGljZW5zZSBmcm9tIGEgcGFydGljdWxhciBjb3B5cmlnaHQgaG9sZGVyIGlzCnJlaW5zdGF0ZWQgcGVybWFuZW50bHkg",
        "aWYgdGhlIGNvcHlyaWdodCBob2xkZXIgbm90aWZpZXMgeW91IG9mIHRoZQp2aW9sYXRpb24gYnkgc29tZSByZWFzb25hYmxl",
        "IG1lYW5zLCB0aGlzIGlzIHRoZSBmaXJzdCB0aW1lIHlvdSBoYXZlCnJlY2VpdmVkIG5vdGljZSBvZiB2aW9sYXRpb24gb2Yg",
        "dGhpcyBMaWNlbnNlIChmb3IgYW55IHdvcmspIGZyb20gdGhhdApjb3B5cmlnaHQgaG9sZGVyLCBhbmQgeW91IGN1cmUgdGhl",
        "IHZpb2xhdGlvbiBwcmlvciB0byAzMCBkYXlzIGFmdGVyCnlvdXIgcmVjZWlwdCBvZiB0aGUgbm90aWNlLgoKICBUZXJtaW5h",
        "dGlvbiBvZiB5b3VyIHJpZ2h0cyB1bmRlciB0aGlzIHNlY3Rpb24gZG9lcyBub3QgdGVybWluYXRlIHRoZQpsaWNlbnNlcyBv",
        "ZiBwYXJ0aWVzIHdobyBoYXZlIHJlY2VpdmVkIGNvcGllcyBvciByaWdodHMgZnJvbSB5b3UgdW5kZXIKdGhpcyBMaWNlbnNl",
        "LiAgSWYgeW91ciByaWdodHMgaGF2ZSBiZWVuIHRlcm1pbmF0ZWQgYW5kIG5vdCBwZXJtYW5lbnRseQpyZWluc3RhdGVkLCB5",
        "b3UgZG8gbm90IHF1YWxpZnkgdG8gcmVjZWl2ZSBuZXcgbGljZW5zZXMgZm9yIHRoZSBzYW1lCm1hdGVyaWFsIHVuZGVyIHNl",
        "Y3Rpb24gMTAuCgogIDkuIEFjY2VwdGFuY2UgTm90IFJlcXVpcmVkIGZvciBIYXZpbmcgQ29waWVzLgoKICBZb3UgYXJlIG5v",
        "dCByZXF1aXJlZCB0byBhY2NlcHQgdGhpcyBMaWNlbnNlIGluIG9yZGVyIHRvIHJlY2VpdmUgb3IKcnVuIGEgY29weSBvZiB0",
        "aGUgUHJvZ3JhbS4gIEFuY2lsbGFyeSBwcm9wYWdhdGlvbiBvZiBhIGNvdmVyZWQgd29yawpvY2N1cnJpbmcgc29sZWx5IGFz",
        "IGEgY29uc2VxdWVuY2Ugb2YgdXNpbmcgcGVlci10by1wZWVyIHRyYW5zbWlzc2lvbgp0byByZWNlaXZlIGEgY29weSBsaWtl",
        "d2lzZSBkb2VzIG5vdCByZXF1aXJlIGFjY2VwdGFuY2UuICBIb3dldmVyLApub3RoaW5nIG90aGVyIHRoYW4gdGhpcyBMaWNl",
        "bnNlIGdyYW50cyB5b3UgcGVybWlzc2lvbiB0byBwcm9wYWdhdGUgb3IKbW9kaWZ5IGFueSBjb3ZlcmVkIHdvcmsuICBUaGVz",
        "ZSBhY3Rpb25zIGluZnJpbmdlIGNvcHlyaWdodCBpZiB5b3UgZG8Kbm90IGFjY2VwdCB0aGlzIExpY2Vuc2UuICBUaGVyZWZv",
        "cmUsIGJ5IG1vZGlmeWluZyBvciBwcm9wYWdhdGluZyBhCmNvdmVyZWQgd29yaywgeW91IGluZGljYXRlIHlvdXIgYWNjZXB0",
        "YW5jZSBvZiB0aGlzIExpY2Vuc2UgdG8gZG8gc28uCgogIDEwLiBBdXRvbWF0aWMgTGljZW5zaW5nIG9mIERvd25zdHJlYW0g",
        "UmVjaXBpZW50cy4KCiAgRWFjaCB0aW1lIHlvdSBjb252ZXkgYSBjb3ZlcmVkIHdvcmssIHRoZSByZWNpcGllbnQgYXV0b21h",
        "dGljYWxseQpyZWNlaXZlcyBhIGxpY2Vuc2UgZnJvbSB0aGUgb3JpZ2luYWwgbGljZW5zb3JzLCB0byBydW4sIG1vZGlmeSBh",
        "bmQKcHJvcGFnYXRlIHRoYXQgd29yaywgc3ViamVjdCB0byB0aGlzIExpY2Vuc2UuICBZb3UgYXJlIG5vdCByZXNwb25zaWJs",
        "ZQpmb3IgZW5mb3JjaW5nIGNvbXBsaWFuY2UgYnkgdGhpcmQgcGFydGllcyB3aXRoIHRoaXMgTGljZW5zZS4KCiAgQW4gImVu",
        "dGl0eSB0cmFuc2FjdGlvbiIgaXMgYSB0cmFuc2FjdGlvbiB0cmFuc2ZlcnJpbmcgY29udHJvbCBvZiBhbgpvcmdhbml6YXRp",
        "b24sIG9yIHN1YnN0YW50aWFsbHkgYWxsIGFzc2V0cyBvZiBvbmUsIG9yIHN1YmRpdmlkaW5nIGFuCm9yZ2FuaXphdGlvbiwg",
        "b3IgbWVyZ2luZyBvcmdhbml6YXRpb25zLiAgSWYgcHJvcGFnYXRpb24gb2YgYSBjb3ZlcmVkCndvcmsgcmVzdWx0cyBmcm9t",
        "IGFuIGVudGl0eSB0cmFuc2FjdGlvbiwgZWFjaCBwYXJ0eSB0byB0aGF0CnRyYW5zYWN0aW9uIHdobyByZWNlaXZlcyBhIGNv",
        "cHkgb2YgdGhlIHdvcmsgYWxzbyByZWNlaXZlcyB3aGF0ZXZlcgpsaWNlbnNlcyB0byB0aGUgd29yayB0aGUgcGFydHkncyBw",
        "cmVkZWNlc3NvciBpbiBpbnRlcmVzdCBoYWQgb3IgY291bGQKZ2l2ZSB1bmRlciB0aGUgcHJldmlvdXMgcGFyYWdyYXBoLCBw",
        "bHVzIGEgcmlnaHQgdG8gcG9zc2Vzc2lvbiBvZiB0aGUKQ29ycmVzcG9uZGluZyBTb3VyY2Ugb2YgdGhlIHdvcmsgZnJvbSB0",
        "aGUgcHJlZGVjZXNzb3IgaW4gaW50ZXJlc3QsIGlmCnRoZSBwcmVkZWNlc3NvciBoYXMgaXQgb3IgY2FuIGdldCBpdCB3aXRo",
        "IHJlYXNvbmFibGUgZWZmb3J0cy4KCiAgWW91IG1heSBub3QgaW1wb3NlIGFueSBmdXJ0aGVyIHJlc3RyaWN0aW9ucyBvbiB0",
        "aGUgZXhlcmNpc2Ugb2YgdGhlCnJpZ2h0cyBncmFudGVkIG9yIGFmZmlybWVkIHVuZGVyIHRoaXMgTGljZW5zZS4gIEZvciBl",
        "eGFtcGxlLCB5b3UgbWF5Cm5vdCBpbXBvc2UgYSBsaWNlbnNlIGZlZSwgcm95YWx0eSwgb3Igb3RoZXIgY2hhcmdlIGZvciBl",
        "eGVyY2lzZSBvZgpyaWdodHMgZ3JhbnRlZCB1bmRlciB0aGlzIExpY2Vuc2UsIGFuZCB5b3UgbWF5IG5vdCBpbml0aWF0ZSBs",
        "aXRpZ2F0aW9uCihpbmNsdWRpbmcgYSBjcm9zcy1jbGFpbSBvciBjb3VudGVyY2xhaW0gaW4gYSBsYXdzdWl0KSBhbGxlZ2lu",
        "ZyB0aGF0CmFueSBwYXRlbnQgY2xhaW0gaXMgaW5mcmluZ2VkIGJ5IG1ha2luZywgdXNpbmcsIHNlbGxpbmcsIG9mZmVyaW5n",
        "IGZvcgpzYWxlLCBvciBpbXBvcnRpbmcgdGhlIFByb2dyYW0gb3IgYW55IHBvcnRpb24gb2YgaXQuCgogIDExLiBQYXRlbnRz",
        "LgoKICBBICJjb250cmlidXRvciIgaXMgYSBjb3B5cmlnaHQgaG9sZGVyIHdobyBhdXRob3JpemVzIHVzZSB1bmRlciB0aGlz",
        "CkxpY2Vuc2Ugb2YgdGhlIFByb2dyYW0gb3IgYSB3b3JrIG9uIHdoaWNoIHRoZSBQcm9ncmFtIGlzIGJhc2VkLiAgVGhlCndv",
        "cmsgdGh1cyBsaWNlbnNlZCBpcyBjYWxsZWQgdGhlIGNvbnRyaWJ1dG9yJ3MgImNvbnRyaWJ1dG9yIHZlcnNpb24iLgoKICBB",
        "IGNvbnRyaWJ1dG9yJ3MgImVzc2VudGlhbCBwYXRlbnQgY2xhaW1zIiBhcmUgYWxsIHBhdGVudCBjbGFpbXMKb3duZWQgb3Ig",
        "Y29udHJvbGxlZCBieSB0aGUgY29udHJpYnV0b3IsIHdoZXRoZXIgYWxyZWFkeSBhY3F1aXJlZCBvcgpoZXJlYWZ0ZXIgYWNx",
        "dWlyZWQsIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkIGJ5IHNvbWUgbWFubmVyLCBwZXJtaXR0ZWQKYnkgdGhpcyBMaWNlbnNl",
        "LCBvZiBtYWtpbmcsIHVzaW5nLCBvciBzZWxsaW5nIGl0cyBjb250cmlidXRvciB2ZXJzaW9uLApidXQgZG8gbm90IGluY2x1",
        "ZGUgY2xhaW1zIHRoYXQgd291bGQgYmUgaW5mcmluZ2VkIG9ubHkgYXMgYQpjb25zZXF1ZW5jZSBvZiBmdXJ0aGVyIG1vZGlm",
        "aWNhdGlvbiBvZiB0aGUgY29udHJpYnV0b3IgdmVyc2lvbi4gIEZvcgpwdXJwb3NlcyBvZiB0aGlzIGRlZmluaXRpb24sICJj",
        "b250cm9sIiBpbmNsdWRlcyB0aGUgcmlnaHQgdG8gZ3JhbnQKcGF0ZW50IHN1YmxpY2Vuc2VzIGluIGEgbWFubmVyIGNvbnNp",
        "c3RlbnQgd2l0aCB0aGUgcmVxdWlyZW1lbnRzIG9mCnRoaXMgTGljZW5zZS4KCiAgRWFjaCBjb250cmlidXRvciBncmFudHMg",
        "eW91IGEgbm9uLWV4Y2x1c2l2ZSwgd29ybGR3aWRlLCByb3lhbHR5LWZyZWUKcGF0ZW50IGxpY2Vuc2UgdW5kZXIgdGhlIGNv",
        "bnRyaWJ1dG9yJ3MgZXNzZW50aWFsIHBhdGVudCBjbGFpbXMsIHRvCm1ha2UsIHVzZSwgc2VsbCwgb2ZmZXIgZm9yIHNhbGUs",
        "IGltcG9ydCBhbmQgb3RoZXJ3aXNlIHJ1biwgbW9kaWZ5IGFuZApwcm9wYWdhdGUgdGhlIGNvbnRlbnRzIG9mIGl0cyBjb250",
        "cmlidXRvciB2ZXJzaW9uLgoKICBJbiB0aGUgZm9sbG93aW5nIHRocmVlIHBhcmFncmFwaHMsIGEgInBhdGVudCBsaWNlbnNl",
        "IiBpcyBhbnkgZXhwcmVzcwphZ3JlZW1lbnQgb3IgY29tbWl0bWVudCwgaG93ZXZlciBkZW5vbWluYXRlZCwgbm90IHRvIGVu",
        "Zm9yY2UgYSBwYXRlbnQKKHN1Y2ggYXMgYW4gZXhwcmVzcyBwZXJtaXNzaW9uIHRvIHByYWN0aWNlIGEgcGF0ZW50IG9yIGNv",
        "dmVuYW50IG5vdCB0bwpzdWUgZm9yIHBhdGVudCBpbmZyaW5nZW1lbnQpLiAgVG8gImdyYW50IiBzdWNoIGEgcGF0ZW50IGxp",
        "Y2Vuc2UgdG8gYQpwYXJ0eSBtZWFucyB0byBtYWtlIHN1Y2ggYW4gYWdyZWVtZW50IG9yIGNvbW1pdG1lbnQgbm90IHRvIGVu",
        "Zm9yY2UgYQpwYXRlbnQgYWdhaW5zdCB0aGUgcGFydHkuCgogIElmIHlvdSBjb252ZXkgYSBjb3ZlcmVkIHdvcmssIGtub3dp",
        "bmdseSByZWx5aW5nIG9uIGEgcGF0ZW50IGxpY2Vuc2UsCmFuZCB0aGUgQ29ycmVzcG9uZGluZyBTb3VyY2Ugb2YgdGhlIHdv",
        "cmsgaXMgbm90IGF2YWlsYWJsZSBmb3IgYW55b25lCnRvIGNvcHksIGZyZWUgb2YgY2hhcmdlIGFuZCB1bmRlciB0aGUgdGVy",
        "bXMgb2YgdGhpcyBMaWNlbnNlLCB0aHJvdWdoIGEKcHVibGljbHkgYXZhaWxhYmxlIG5ldHdvcmsgc2VydmVyIG9yIG90aGVy",
        "IHJlYWRpbHkgYWNjZXNzaWJsZSBtZWFucywKdGhlbiB5b3UgbXVzdCBlaXRoZXIgKDEpIGNhdXNlIHRoZSBDb3JyZXNwb25k",
        "aW5nIFNvdXJjZSB0byBiZSBzbwphdmFpbGFibGUsIG9yICgyKSBhcnJhbmdlIHRvIGRlcHJpdmUgeW91cnNlbGYgb2YgdGhl",
        "IGJlbmVmaXQgb2YgdGhlCnBhdGVudCBsaWNlbnNlIGZvciB0aGlzIHBhcnRpY3VsYXIgd29yaywgb3IgKDMpIGFycmFuZ2Us",
        "IGluIGEgbWFubmVyCmNvbnNpc3RlbnQgd2l0aCB0aGUgcmVxdWlyZW1lbnRzIG9mIHRoaXMgTGljZW5zZSwgdG8gZXh0ZW5k",
        "IHRoZSBwYXRlbnQKbGljZW5zZSB0byBkb3duc3RyZWFtIHJlY2lwaWVudHMuICAiS25vd2luZ2x5IHJlbHlpbmciIG1lYW5z",
        "IHlvdSBoYXZlCmFjdHVhbCBrbm93bGVkZ2UgdGhhdCwgYnV0IGZvciB0aGUgcGF0ZW50IGxpY2Vuc2UsIHlvdXIgY29udmV5",
        "aW5nIHRoZQpjb3ZlcmVkIHdvcmsgaW4gYSBjb3VudHJ5LCBvciB5b3VyIHJlY2lwaWVudCdzIHVzZSBvZiB0aGUgY292ZXJl",
        "ZCB3b3JrCmluIGEgY291bnRyeSwgd291bGQgaW5mcmluZ2Ugb25lIG9yIG1vcmUgaWRlbnRpZmlhYmxlIHBhdGVudHMgaW4g",
        "dGhhdApjb3VudHJ5IHRoYXQgeW91IGhhdmUgcmVhc29uIHRvIGJlbGlldmUgYXJlIHZhbGlkLgoKICBJZiwgcHVyc3VhbnQg",
        "dG8gb3IgaW4gY29ubmVjdGlvbiB3aXRoIGEgc2luZ2xlIHRyYW5zYWN0aW9uIG9yCmFycmFuZ2VtZW50LCB5b3UgY29udmV5",
        "LCBvciBwcm9wYWdhdGUgYnkgcHJvY3VyaW5nIGNvbnZleWFuY2Ugb2YsIGEKY292ZXJlZCB3b3JrLCBhbmQgZ3JhbnQgYSBw",
        "YXRlbnQgbGljZW5zZSB0byBzb21lIG9mIHRoZSBwYXJ0aWVzCnJlY2VpdmluZyB0aGUgY292ZXJlZCB3b3JrIGF1dGhvcml6",
        "aW5nIHRoZW0gdG8gdXNlLCBwcm9wYWdhdGUsIG1vZGlmeQpvciBjb252ZXkgYSBzcGVjaWZpYyBjb3B5IG9mIHRoZSBjb3Zl",
        "cmVkIHdvcmssIHRoZW4gdGhlIHBhdGVudCBsaWNlbnNlCnlvdSBncmFudCBpcyBhdXRvbWF0aWNhbGx5IGV4dGVuZGVkIHRv",
        "IGFsbCByZWNpcGllbnRzIG9mIHRoZSBjb3ZlcmVkCndvcmsgYW5kIHdvcmtzIGJhc2VkIG9uIGl0LgoKICBBIHBhdGVudCBs",
        "aWNlbnNlIGlzICJkaXNjcmltaW5hdG9yeSIgaWYgaXQgZG9lcyBub3QgaW5jbHVkZSB3aXRoaW4KdGhlIHNjb3BlIG9mIGl0",
        "cyBjb3ZlcmFnZSwgcHJvaGliaXRzIHRoZSBleGVyY2lzZSBvZiwgb3IgaXMKY29uZGl0aW9uZWQgb24gdGhlIG5vbi1leGVy",
        "Y2lzZSBvZiBvbmUgb3IgbW9yZSBvZiB0aGUgcmlnaHRzIHRoYXQgYXJlCnNwZWNpZmljYWxseSBncmFudGVkIHVuZGVyIHRo",
        "aXMgTGljZW5zZS4gIFlvdSBtYXkgbm90IGNvbnZleSBhIGNvdmVyZWQKd29yayBpZiB5b3UgYXJlIGEgcGFydHkgdG8gYW4g",
        "YXJyYW5nZW1lbnQgd2l0aCBhIHRoaXJkIHBhcnR5IHRoYXQgaXMKaW4gdGhlIGJ1c2luZXNzIG9mIGRpc3RyaWJ1dGluZyBz",
        "b2Z0d2FyZSwgdW5kZXIgd2hpY2ggeW91IG1ha2UgcGF5bWVudAp0byB0aGUgdGhpcmQgcGFydHkgYmFzZWQgb24gdGhlIGV4",
        "dGVudCBvZiB5b3VyIGFjdGl2aXR5IG9mIGNvbnZleWluZwp0aGUgd29yaywgYW5kIHVuZGVyIHdoaWNoIHRoZSB0aGlyZCBw",
        "YXJ0eSBncmFudHMsIHRvIGFueSBvZiB0aGUKcGFydGllcyB3aG8gd291bGQgcmVjZWl2ZSB0aGUgY292ZXJlZCB3b3JrIGZy",
        "b20geW91LCBhIGRpc2NyaW1pbmF0b3J5CnBhdGVudCBsaWNlbnNlIChhKSBpbiBjb25uZWN0aW9uIHdpdGggY29waWVzIG9m",
        "IHRoZSBjb3ZlcmVkIHdvcmsKY29udmV5ZWQgYnkgeW91IChvciBjb3BpZXMgbWFkZSBmcm9tIHRob3NlIGNvcGllcyksIG9y",
        "IChiKSBwcmltYXJpbHkKZm9yIGFuZCBpbiBjb25uZWN0aW9uIHdpdGggc3BlY2lmaWMgcHJvZHVjdHMgb3IgY29tcGlsYXRp",
        "b25zIHRoYXQKY29udGFpbiB0aGUgY292ZXJlZCB3b3JrLCB1bmxlc3MgeW91IGVudGVyZWQgaW50byB0aGF0IGFycmFuZ2Vt",
        "ZW50LApvciB0aGF0IHBhdGVudCBsaWNlbnNlIHdhcyBncmFudGVkLCBwcmlvciB0byAyOCBNYXJjaCAyMDA3LgoKICBOb3Ro",
        "aW5nIGluIHRoaXMgTGljZW5zZSBzaGFsbCBiZSBjb25zdHJ1ZWQgYXMgZXhjbHVkaW5nIG9yIGxpbWl0aW5nCmFueSBpbXBs",
        "aWVkIGxpY2Vuc2Ugb3Igb3RoZXIgZGVmZW5zZXMgdG8gaW5mcmluZ2VtZW50IHRoYXQgbWF5Cm90aGVyd2lzZSBiZSBhdmFp",
        "bGFibGUgdG8geW91IHVuZGVyIGFwcGxpY2FibGUgcGF0ZW50IGxhdy4KCiAgMTIuIE5vIFN1cnJlbmRlciBvZiBPdGhlcnMn",
        "IEZyZWVkb20uCgogIElmIGNvbmRpdGlvbnMgYXJlIGltcG9zZWQgb24geW91ICh3aGV0aGVyIGJ5IGNvdXJ0IG9yZGVyLCBh",
        "Z3JlZW1lbnQgb3IKb3RoZXJ3aXNlKSB0aGF0IGNvbnRyYWRpY3QgdGhlIGNvbmRpdGlvbnMgb2YgdGhpcyBMaWNlbnNlLCB0",
        "aGV5IGRvIG5vdApleGN1c2UgeW91IGZyb20gdGhlIGNvbmRpdGlvbnMgb2YgdGhpcyBMaWNlbnNlLiAgSWYgeW91IGNhbm5v",
        "dCBjb252ZXkgYQpjb3ZlcmVkIHdvcmsgc28gYXMgdG8gc2F0aXNmeSBzaW11bHRhbmVvdXNseSB5b3VyIG9ibGlnYXRpb25z",
        "IHVuZGVyIHRoaXMKTGljZW5zZSBhbmQgYW55IG90aGVyIHBlcnRpbmVudCBvYmxpZ2F0aW9ucywgdGhlbiBhcyBhIGNvbnNl",
        "cXVlbmNlIHlvdSBtYXkKbm90IGNvbnZleSBpdCBhdCBhbGwuICBGb3IgZXhhbXBsZSwgaWYgeW91IGFncmVlIHRvIHRlcm1z",
        "IHRoYXQgb2JsaWdhdGUgeW91CnRvIGNvbGxlY3QgYSByb3lhbHR5IGZvciBmdXJ0aGVyIGNvbnZleWluZyBmcm9tIHRob3Nl",
        "IHRvIHdob20geW91IGNvbnZleQp0aGUgUHJvZ3JhbSwgdGhlIG9ubHkgd2F5IHlvdSBjb3VsZCBzYXRpc2Z5IGJvdGggdGhv",
        "c2UgdGVybXMgYW5kIHRoaXMKTGljZW5zZSB3b3VsZCBiZSB0byByZWZyYWluIGVudGlyZWx5IGZyb20gY29udmV5aW5nIHRo",
        "ZSBQcm9ncmFtLgoKICAxMy4gVXNlIHdpdGggdGhlIEdOVSBBZmZlcm8gR2VuZXJhbCBQdWJsaWMgTGljZW5zZS4KCiAgTm90",
        "d2l0aHN0YW5kaW5nIGFueSBvdGhlciBwcm92aXNpb24gb2YgdGhpcyBMaWNlbnNlLCB5b3UgaGF2ZQpwZXJtaXNzaW9uIHRv",
        "IGxpbmsgb3IgY29tYmluZSBhbnkgY292ZXJlZCB3b3JrIHdpdGggYSB3b3JrIGxpY2Vuc2VkCnVuZGVyIHZlcnNpb24gMyBv",
        "ZiB0aGUgR05VIEFmZmVybyBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGludG8gYSBzaW5nbGUKY29tYmluZWQgd29yaywgYW5k",
        "IHRvIGNvbnZleSB0aGUgcmVzdWx0aW5nIHdvcmsuICBUaGUgdGVybXMgb2YgdGhpcwpMaWNlbnNlIHdpbGwgY29udGludWUg",
        "dG8gYXBwbHkgdG8gdGhlIHBhcnQgd2hpY2ggaXMgdGhlIGNvdmVyZWQgd29yaywKYnV0IHRoZSBzcGVjaWFsIHJlcXVpcmVt",
        "ZW50cyBvZiB0aGUgR05VIEFmZmVybyBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlLApzZWN0aW9uIDEzLCBjb25jZXJuaW5nIGlu",
        "dGVyYWN0aW9uIHRocm91Z2ggYSBuZXR3b3JrIHdpbGwgYXBwbHkgdG8gdGhlCmNvbWJpbmF0aW9uIGFzIHN1Y2guCgogIDE0",
        "LiBSZXZpc2VkIFZlcnNpb25zIG9mIHRoaXMgTGljZW5zZS4KCiAgVGhlIEZyZWUgU29mdHdhcmUgRm91bmRhdGlvbiBtYXkg",
        "cHVibGlzaCByZXZpc2VkIGFuZC9vciBuZXcgdmVyc2lvbnMgb2YKdGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlIGZy",
        "b20gdGltZSB0byB0aW1lLiAgU3VjaCBuZXcgdmVyc2lvbnMgd2lsbApiZSBzaW1pbGFyIGluIHNwaXJpdCB0byB0aGUgcHJl",
        "c2VudCB2ZXJzaW9uLCBidXQgbWF5IGRpZmZlciBpbiBkZXRhaWwgdG8KYWRkcmVzcyBuZXcgcHJvYmxlbXMgb3IgY29uY2Vy",
        "bnMuCgogIEVhY2ggdmVyc2lvbiBpcyBnaXZlbiBhIGRpc3Rpbmd1aXNoaW5nIHZlcnNpb24gbnVtYmVyLiAgSWYgdGhlClBy",
        "b2dyYW0gc3BlY2lmaWVzIHRoYXQgYSBjZXJ0YWluIG51bWJlcmVkIHZlcnNpb24gb2YgdGhlIEdOVSBHZW5lcmFsClB1Ymxp",
        "YyBMaWNlbnNlICJvciBhbnkgbGF0ZXIgdmVyc2lvbiIgYXBwbGllcyB0byBpdCwgeW91IGhhdmUgdGhlCm9wdGlvbiBvZiBm",
        "b2xsb3dpbmcgdGhlIHRlcm1zIGFuZCBjb25kaXRpb25zIGVpdGhlciBvZiB0aGF0IG51bWJlcmVkCnZlcnNpb24gb3Igb2Yg",
        "YW55IGxhdGVyIHZlcnNpb24gcHVibGlzaGVkIGJ5IHRoZSBGcmVlIFNvZnR3YXJlCkZvdW5kYXRpb24uICBJZiB0aGUgUHJv",
        "Z3JhbSBkb2VzIG5vdCBzcGVjaWZ5IGEgdmVyc2lvbiBudW1iZXIgb2YgdGhlCkdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNl",
        "LCB5b3UgbWF5IGNob29zZSBhbnkgdmVyc2lvbiBldmVyIHB1Ymxpc2hlZApieSB0aGUgRnJlZSBTb2Z0d2FyZSBGb3VuZGF0",
        "aW9uLgoKICBJZiB0aGUgUHJvZ3JhbSBzcGVjaWZpZXMgdGhhdCBhIHByb3h5IGNhbiBkZWNpZGUgd2hpY2ggZnV0dXJlCnZl",
        "cnNpb25zIG9mIHRoZSBHTlUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZSBjYW4gYmUgdXNlZCwgdGhhdCBwcm94eSdzCnB1Ymxp",
        "YyBzdGF0ZW1lbnQgb2YgYWNjZXB0YW5jZSBvZiBhIHZlcnNpb24gcGVybWFuZW50bHkgYXV0aG9yaXplcyB5b3UKdG8gY2hv",
        "b3NlIHRoYXQgdmVyc2lvbiBmb3IgdGhlIFByb2dyYW0uCgogIExhdGVyIGxpY2Vuc2UgdmVyc2lvbnMgbWF5IGdpdmUgeW91",
        "IGFkZGl0aW9uYWwgb3IgZGlmZmVyZW50CnBlcm1pc3Npb25zLiAgSG93ZXZlciwgbm8gYWRkaXRpb25hbCBvYmxpZ2F0aW9u",
        "cyBhcmUgaW1wb3NlZCBvbiBhbnkKYXV0aG9yIG9yIGNvcHlyaWdodCBob2xkZXIgYXMgYSByZXN1bHQgb2YgeW91ciBjaG9v",
        "c2luZyB0byBmb2xsb3cgYQpsYXRlciB2ZXJzaW9uLgoKICAxNS4gRGlzY2xhaW1lciBvZiBXYXJyYW50eS4KCiAgVEhFUkUg",
        "SVMgTk8gV0FSUkFOVFkgRk9SIFRIRSBQUk9HUkFNLCBUTyBUSEUgRVhURU5UIFBFUk1JVFRFRCBCWQpBUFBMSUNBQkxFIExB",
        "Vy4gIEVYQ0VQVCBXSEVOIE9USEVSV0lTRSBTVEFURUQgSU4gV1JJVElORyBUSEUgQ09QWVJJR0hUCkhPTERFUlMgQU5EL09S",
        "IE9USEVSIFBBUlRJRVMgUFJPVklERSBUSEUgUFJPR1JBTSAiQVMgSVMiIFdJVEhPVVQgV0FSUkFOVFkKT0YgQU5ZIEtJTkQs",
        "IEVJVEhFUiBFWFBSRVNTRUQgT1IgSU1QTElFRCwgSU5DTFVESU5HLCBCVVQgTk9UIExJTUlURUQgVE8sClRIRSBJTVBMSUVE",
        "IFdBUlJBTlRJRVMgT0YgTUVSQ0hBTlRBQklMSVRZIEFORCBGSVRORVNTIEZPUiBBIFBBUlRJQ1VMQVIKUFVSUE9TRS4gIFRI",
        "RSBFTlRJUkUgUklTSyBBUyBUTyBUSEUgUVVBTElUWSBBTkQgUEVSRk9STUFOQ0UgT0YgVEhFIFBST0dSQU0KSVMgV0lUSCBZ",
        "T1UuICBTSE9VTEQgVEhFIFBST0dSQU0gUFJPVkUgREVGRUNUSVZFLCBZT1UgQVNTVU1FIFRIRSBDT1NUIE9GCkFMTCBORUNF",
        "U1NBUlkgU0VSVklDSU5HLCBSRVBBSVIgT1IgQ09SUkVDVElPTi4KCiAgMTYuIExpbWl0YXRpb24gb2YgTGlhYmlsaXR5LgoK",
        "ICBJTiBOTyBFVkVOVCBVTkxFU1MgUkVRVUlSRUQgQlkgQVBQTElDQUJMRSBMQVcgT1IgQUdSRUVEIFRPIElOIFdSSVRJTkcK",
        "V0lMTCBBTlkgQ09QWVJJR0hUIEhPTERFUiwgT1IgQU5ZIE9USEVSIFBBUlRZIFdITyBNT0RJRklFUyBBTkQvT1IgQ09OVkVZ",
        "UwpUSEUgUFJPR1JBTSBBUyBQRVJNSVRURUQgQUJPVkUsIEJFIExJQUJMRSBUTyBZT1UgRk9SIERBTUFHRVMsIElOQ0xVRElO",
        "RyBBTlkKR0VORVJBTCwgU1BFQ0lBTCwgSU5DSURFTlRBTCBPUiBDT05TRVFVRU5USUFMIERBTUFHRVMgQVJJU0lORyBPVVQg",
        "T0YgVEhFClVTRSBPUiBJTkFCSUxJVFkgVE8gVVNFIFRIRSBQUk9HUkFNIChJTkNMVURJTkcgQlVUIE5PVCBMSU1JVEVEIFRP",
        "IExPU1MgT0YKREFUQSBPUiBEQVRBIEJFSU5HIFJFTkRFUkVEIElOQUNDVVJBVEUgT1IgTE9TU0VTIFNVU1RBSU5FRCBCWSBZ",
        "T1UgT1IgVEhJUkQKUEFSVElFUyBPUiBBIEZBSUxVUkUgT0YgVEhFIFBST0dSQU0gVE8gT1BFUkFURSBXSVRIIEFOWSBPVEhF",
        "UiBQUk9HUkFNUyksCkVWRU4gSUYgU1VDSCBIT0xERVIgT1IgT1RIRVIgUEFSVFkgSEFTIEJFRU4gQURWSVNFRCBPRiBUSEUg",
        "UE9TU0lCSUxJVFkgT0YKU1VDSCBEQU1BR0VTLgoKICAxNy4gSW50ZXJwcmV0YXRpb24gb2YgU2VjdGlvbnMgMTUgYW5kIDE2",
        "LgoKICBJZiB0aGUgZGlzY2xhaW1lciBvZiB3YXJyYW50eSBhbmQgbGltaXRhdGlvbiBvZiBsaWFiaWxpdHkgcHJvdmlkZWQK",
        "YWJvdmUgY2Fubm90IGJlIGdpdmVuIGxvY2FsIGxlZ2FsIGVmZmVjdCBhY2NvcmRpbmcgdG8gdGhlaXIgdGVybXMsCnJldmll",
        "d2luZyBjb3VydHMgc2hhbGwgYXBwbHkgbG9jYWwgbGF3IHRoYXQgbW9zdCBjbG9zZWx5IGFwcHJveGltYXRlcwphbiBhYnNv",
        "bHV0ZSB3YWl2ZXIgb2YgYWxsIGNpdmlsIGxpYWJpbGl0eSBpbiBjb25uZWN0aW9uIHdpdGggdGhlClByb2dyYW0sIHVubGVz",
        "cyBhIHdhcnJhbnR5IG9yIGFzc3VtcHRpb24gb2YgbGlhYmlsaXR5IGFjY29tcGFuaWVzIGEKY29weSBvZiB0aGUgUHJvZ3Jh",
        "bSBpbiByZXR1cm4gZm9yIGEgZmVlLgoKICAgICAgICAgICAgICAgICAgICAgRU5EIE9GIFRFUk1TIEFORCBDT05ESVRJT05T",
        "CgogICAgICAgICAgICBIb3cgdG8gQXBwbHkgVGhlc2UgVGVybXMgdG8gWW91ciBOZXcgUHJvZ3JhbXMKCiAgSWYgeW91IGRl",
        "dmVsb3AgYSBuZXcgcHJvZ3JhbSwgYW5kIHlvdSB3YW50IGl0IHRvIGJlIG9mIHRoZSBncmVhdGVzdApwb3NzaWJsZSB1c2Ug",
        "dG8gdGhlIHB1YmxpYywgdGhlIGJlc3Qgd2F5IHRvIGFjaGlldmUgdGhpcyBpcyB0byBtYWtlIGl0CmZyZWUgc29mdHdhcmUg",
        "d2hpY2ggZXZlcnlvbmUgY2FuIHJlZGlzdHJpYnV0ZSBhbmQgY2hhbmdlIHVuZGVyIHRoZXNlIHRlcm1zLgoKICBUbyBkbyBz",
        "bywgYXR0YWNoIHRoZSBmb2xsb3dpbmcgbm90aWNlcyB0byB0aGUgcHJvZ3JhbS4gIEl0IGlzIHNhZmVzdAp0byBhdHRhY2gg",
        "dGhlbSB0byB0aGUgc3RhcnQgb2YgZWFjaCBzb3VyY2UgZmlsZSB0byBtb3N0IGVmZmVjdGl2ZWx5CnN0YXRlIHRoZSBleGNs",
        "dXNpb24gb2Ygd2FycmFudHk7IGFuZCBlYWNoIGZpbGUgc2hvdWxkIGhhdmUgYXQgbGVhc3QKdGhlICJjb3B5cmlnaHQiIGxp",
        "bmUgYW5kIGEgcG9pbnRlciB0byB3aGVyZSB0aGUgZnVsbCBub3RpY2UgaXMgZm91bmQuCgogICAgPG9uZSBsaW5lIHRvIGdp",
        "dmUgdGhlIHByb2dyYW0ncyBuYW1lIGFuZCBhIGJyaWVmIGlkZWEgb2Ygd2hhdCBpdCBkb2VzLj4KICAgIENvcHlyaWdodCAo",
        "QykgPHllYXI+ICA8bmFtZSBvZiBhdXRob3I+CgogICAgVGhpcyBwcm9ncmFtIGlzIGZyZWUgc29mdHdhcmU6IHlvdSBjYW4g",
        "cmVkaXN0cmlidXRlIGl0IGFuZC9vciBtb2RpZnkKICAgIGl0IHVuZGVyIHRoZSB0ZXJtcyBvZiB0aGUgR05VIEdlbmVyYWwg",
        "UHVibGljIExpY2Vuc2UgYXMgcHVibGlzaGVkIGJ5CiAgICB0aGUgRnJlZSBTb2Z0d2FyZSBGb3VuZGF0aW9uLCBlaXRoZXIg",
        "dmVyc2lvbiAzIG9mIHRoZSBMaWNlbnNlLCBvcgogICAgKGF0IHlvdXIgb3B0aW9uKSBhbnkgbGF0ZXIgdmVyc2lvbi4KCiAg",
        "ICBUaGlzIHByb2dyYW0gaXMgZGlzdHJpYnV0ZWQgaW4gdGhlIGhvcGUgdGhhdCBpdCB3aWxsIGJlIHVzZWZ1bCwKICAgIGJ1",
        "dCBXSVRIT1VUIEFOWSBXQVJSQU5UWTsgd2l0aG91dCBldmVuIHRoZSBpbXBsaWVkIHdhcnJhbnR5IG9mCiAgICBNRVJDSEFO",
        "VEFCSUxJVFkgb3IgRklUTkVTUyBGT1IgQSBQQVJUSUNVTEFSIFBVUlBPU0UuICBTZWUgdGhlCiAgICBHTlUgR2VuZXJhbCBQ",
        "dWJsaWMgTGljZW5zZSBmb3IgbW9yZSBkZXRhaWxzLgoKICAgIFlvdSBzaG91bGQgaGF2ZSByZWNlaXZlZCBhIGNvcHkgb2Yg",
        "dGhlIEdOVSBHZW5lcmFsIFB1YmxpYyBMaWNlbnNlCiAgICBhbG9uZyB3aXRoIHRoaXMgcHJvZ3JhbS4gIElmIG5vdCwgc2Vl",
        "IDxodHRwczovL3d3dy5nbnUub3JnL2xpY2Vuc2VzLz4uCgpBbHNvIGFkZCBpbmZvcm1hdGlvbiBvbiBob3cgdG8gY29udGFj",
        "dCB5b3UgYnkgZWxlY3Ryb25pYyBhbmQgcGFwZXIgbWFpbC4KCiAgSWYgdGhlIHByb2dyYW0gZG9lcyB0ZXJtaW5hbCBpbnRl",
        "cmFjdGlvbiwgbWFrZSBpdCBvdXRwdXQgYSBzaG9ydApub3RpY2UgbGlrZSB0aGlzIHdoZW4gaXQgc3RhcnRzIGluIGFuIGlu",
        "dGVyYWN0aXZlIG1vZGU6CgogICAgPHByb2dyYW0+ICBDb3B5cmlnaHQgKEMpIDx5ZWFyPiAgPG5hbWUgb2YgYXV0aG9yPgog",
        "ICAgVGhpcyBwcm9ncmFtIGNvbWVzIHdpdGggQUJTT0xVVEVMWSBOTyBXQVJSQU5UWTsgZm9yIGRldGFpbHMgdHlwZSBgc2hv",
        "dyB3Jy4KICAgIFRoaXMgaXMgZnJlZSBzb2Z0d2FyZSwgYW5kIHlvdSBhcmUgd2VsY29tZSB0byByZWRpc3RyaWJ1dGUgaXQK",
        "ICAgIHVuZGVyIGNlcnRhaW4gY29uZGl0aW9uczsgdHlwZSBgc2hvdyBjJyBmb3IgZGV0YWlscy4KClRoZSBoeXBvdGhldGlj",
        "YWwgY29tbWFuZHMgYHNob3cgdycgYW5kIGBzaG93IGMnIHNob3VsZCBzaG93IHRoZSBhcHByb3ByaWF0ZQpwYXJ0cyBvZiB0",
        "aGUgR2VuZXJhbCBQdWJsaWMgTGljZW5zZS4gIE9mIGNvdXJzZSwgeW91ciBwcm9ncmFtJ3MgY29tbWFuZHMKbWlnaHQgYmUg",
        "ZGlmZmVyZW50OyBmb3IgYSBHVUkgaW50ZXJmYWNlLCB5b3Ugd291bGQgdXNlIGFuICJhYm91dCBib3giLgoKICBZb3Ugc2hv",
        "dWxkIGFsc28gZ2V0IHlvdXIgZW1wbG95ZXIgKGlmIHlvdSB3b3JrIGFzIGEgcHJvZ3JhbW1lcikgb3Igc2Nob29sLAppZiBh",
        "bnksIHRvIHNpZ24gYSAiY29weXJpZ2h0IGRpc2NsYWltZXIiIGZvciB0aGUgcHJvZ3JhbSwgaWYgbmVjZXNzYXJ5LgpGb3Ig",
        "bW9yZSBpbmZvcm1hdGlvbiBvbiB0aGlzLCBhbmQgaG93IHRvIGFwcGx5IGFuZCBmb2xsb3cgdGhlIEdOVSBHUEwsIHNlZQo8",
        "aHR0cHM6Ly93d3cuZ251Lm9yZy9saWNlbnNlcy8+LgoKICBUaGUgR05VIEdlbmVyYWwgUHVibGljIExpY2Vuc2UgZG9lcyBu",
        "b3QgcGVybWl0IGluY29ycG9yYXRpbmcgeW91ciBwcm9ncmFtCmludG8gcHJvcHJpZXRhcnkgcHJvZ3JhbXMuICBJZiB5b3Vy",
        "IHByb2dyYW0gaXMgYSBzdWJyb3V0aW5lIGxpYnJhcnksIHlvdQptYXkgY29uc2lkZXIgaXQgbW9yZSB1c2VmdWwgdG8gcGVy",
        "bWl0IGxpbmtpbmcgcHJvcHJpZXRhcnkgYXBwbGljYXRpb25zIHdpdGgKdGhlIGxpYnJhcnkuICBJZiB0aGlzIGlzIHdoYXQg",
        "eW91IHdhbnQgdG8gZG8sIHVzZSB0aGUgR05VIExlc3NlciBHZW5lcmFsClB1YmxpYyBMaWNlbnNlIGluc3RlYWQgb2YgdGhp",
        "cyBMaWNlbnNlLiAgQnV0IGZpcnN0LCBwbGVhc2UgcmVhZAo8aHR0cHM6Ly93d3cuZ251Lm9yZy9saWNlbnNlcy93aHktbm90",
        "LWxncGwuaHRtbD4uCg=="
    ].joined()
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            return "The GPL-3.0 license text could not be loaded. See LICENSE in the source distribution."
        }
        return text
    }

    private var zsignLicense: String {
        let encoded = [
        "TUlUIExpY2Vuc2UKCkNvcHlyaWdodCAoYykgMjAyNiB6aGx5bm4KClBlcm1pc3Npb24gaXMgaGVyZWJ5IGdyYW50ZWQsIGZy",
        "ZWUgb2YgY2hhcmdlLCB0byBhbnkgcGVyc29uIG9idGFpbmluZyBhIGNvcHkKb2YgdGhpcyBzb2Z0d2FyZSBhbmQgYXNzb2Np",
        "YXRlZCBkb2N1bWVudGF0aW9uIGZpbGVzICh0aGUgIlNvZnR3YXJlIiksIHRvIGRlYWwKaW4gdGhlIFNvZnR3YXJlIHdpdGhv",
        "dXQgcmVzdHJpY3Rpb24sIGluY2x1ZGluZyB3aXRob3V0IGxpbWl0YXRpb24gdGhlIHJpZ2h0cwp0byB1c2UsIGNvcHksIG1v",
        "ZGlmeSwgbWVyZ2UsIHB1Ymxpc2gsIGRpc3RyaWJ1dGUsIHN1YmxpY2Vuc2UsIGFuZC9vciBzZWxsCmNvcGllcyBvZiB0aGUg",
        "U29mdHdhcmUsIGFuZCB0byBwZXJtaXQgcGVyc29ucyB0byB3aG9tIHRoZSBTb2Z0d2FyZSBpcwpmdXJuaXNoZWQgdG8gZG8g",
        "c28sIHN1YmplY3QgdG8gdGhlIGZvbGxvd2luZyBjb25kaXRpb25zOgoKVGhlIGFib3ZlIGNvcHlyaWdodCBub3RpY2UgYW5k",
        "IHRoaXMgcGVybWlzc2lvbiBub3RpY2Ugc2hhbGwgYmUgaW5jbHVkZWQgaW4gYWxsCmNvcGllcyBvciBzdWJzdGFudGlhbCBw",
        "b3J0aW9ucyBvZiB0aGUgU29mdHdhcmUuCgpUSEUgU09GVFdBUkUgSVMgUFJPVklERUQgIkFTIElTIiwgV0lUSE9VVCBXQVJS",
        "QU5UWSBPRiBBTlkgS0lORCwgRVhQUkVTUyBPUgpJTVBMSUVELCBJTkNMVURJTkcgQlVUIE5PVCBMSU1JVEVEIFRPIFRIRSBX",
        "QVJSQU5USUVTIE9GIE1FUkNIQU5UQUJJTElUWSwKRklUTkVTUyBGT1IgQSBQQVJUSUNVTEFSIFBVUlBPU0UgQU5EIE5PTklO",
        "RlJJTkdFTUVOVC4gSU4gTk8gRVZFTlQgU0hBTEwgVEhFCkFVVEhPUlMgT1IgQ09QWVJJR0hUIEhPTERFUlMgQkUgTElBQkxF",
        "IEZPUiBBTlkgQ0xBSU0sIERBTUFHRVMgT1IgT1RIRVIKTElBQklMSVRZLCBXSEVUSEVSIElOIEFOIEFDVElPTiBPRiBDT05U",
        "UkFDVCwgVE9SVCBPUiBPVEhFUldJU0UsIEFSSVNJTkcgRlJPTSwKT1VUIE9GIE9SIElOIENPTk5FQ1RJT04gV0lUSCBUSEUg",
        "U09GVFdBUkUgT1IgVEhFIFVTRSBPUiBPVEhFUiBERUFMSU5HUyBJTiBUSEUKU09GVFdBUkUuCg=="
    ].joined()
        guard let data = Data(base64Encoded: encoded),
              let text = String(data: data, encoding: .utf8) else {
            return "The MIT license text could not be loaded. See Vendor/Zsign/LICENSE in the source distribution."
        }
        return text
    }


        var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    Image("AboutLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 68, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 15))
                        .accessibilityLabel("KhmerInstaller logo")
                    Text("KhmerInstaller")
                        .font(.title2.bold())
                    Text("tvOS IPA Signing & Installer")
                        .foregroundStyle(.secondary)
                    Text(appVersion)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Made by TheDevilz")
                        .font(.footnote)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }

            Section("About") {
                Text("KhmerInstaller is an independent iOS application for signing tvOS IPA files and installing them on compatible Apple TV devices.")
                Text("Not affiliated with or endorsed by Apple Inc.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Original Project Attribution") {
                Text("If you fork or modify KhmerInstaller, please credit the original project and include a link to the KhmerInstaller GitHub page.")
                Text("Attribution is appreciated but voluntary.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Link(destination: URL(string: "https://github.com/konrepo")!) {
                    Label("Original project: github.com/konrepo", systemImage: "arrow.up.right.square")
                }
            }

            Section("Project License") {
                NavigationLink("GNU General Public License v3.0") {
                    ScrollView {
                        Text(gplLicense)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("GNU GPL v3.0")
                    .navigationBarTitleDisplayMode(.inline)
                }
                Text("The complete license is also provided in the repository root as LICENSE.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Acknowledgements") {
                Text("Zsign")
                    .font(.headline)
                Text("KhmerInstaller includes the Zsign code-signing project. Zsign is distributed under the MIT License.")
                Text("Copyright (c) 2026 zhlynn")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                NavigationLink("Zsign MIT License") {
                    ScrollView {
                        Text(zsignLicense)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding()
                    }
                    .navigationTitle("Zsign MIT License")
                    .navigationBarTitleDisplayMode(.inline)
                }
                legalResourceLink(
                    "SRP MIT License",
                    resourceName: "SRP-LICENSE",
                    fileExtension: "txt"
                )
                legalResourceLink(
                    "Swift Crypto Apache 2.0 License",
                    resourceName: "swift-crypto-LICENSE",
                    fileExtension: "txt"
                )
                legalResourceLink(
                    "Swift Crypto NOTICE",
                    resourceName: "swift-crypto-NOTICE",
                    fileExtension: "txt"
                )
                legalResourceLink(
                    "BigInt MIT License",
                    resourceName: "BigInt-LICENSE",
                    fileExtension: "md"
                )
                legalResourceLink(
                    "OpenSSL Apache 2.0 License",
                    resourceName: "OpenSSL-LICENSE",
                    fileExtension: "txt"
                )
                legalResourceLink(
                    "Info-ZIP License",
                    resourceName: "Info-ZIP-LICENSE",
                    fileExtension: "txt"
                )
                legalResourceLink(
                    "Third-Party Notices",
                    resourceName: "THIRD_PARTY_NOTICES",
                    fileExtension: "md"
                )
            }

            // KI_PYMOBILEDEVICE3_DEVELOPMENT_REFERENCE
            Section("Development Reference") {
                Text("pymobiledevice3")
                    .font(.headline)
                Text("The pymobiledevice3 project was consulted as a technical reference while developing KhmerInstaller’s Apple TV pairing and RemoteXPC behavior. KhmerInstaller does not bundle the pymobiledevice3 Python package.")
                Link("pymobiledevice3 project", destination: URL(string: "https://github.com/doronz88/pymobiledevice3")!)

            }

        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }


    private func legalResourceLink(
        _ title: String,
        resourceName: String,
        fileExtension: String
    ) -> some View {
        NavigationLink(title) {
            ScrollView {
                Group {
                    if let url = Bundle.main.url(
                        forResource: resourceName,
                        withExtension: fileExtension
                    ), let text = try? String(contentsOf: url, encoding: .utf8) {
                        Text(text)
                    } else {
                        Text("Unable to load this document. Please refer to the matching file in the source distribution.")
                    }
                }
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

}
