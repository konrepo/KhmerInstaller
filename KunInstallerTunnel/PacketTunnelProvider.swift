// KI_RELEASE_LOG_CLEANUP: Removed console print diagnostics.
import NetworkExtension
import CryptoKit
import Network

final class PacketTunnelProvider: NEPacketTunnelProvider {

    private var pairingClient: RemotePairingClient?

    private var packetSendTask: Task<Void, Never>?

    private var packetReceiveTask: Task<Void, Never>?

    private var tunnelReady = false

    // Temporary diagnostic connection used to prove that traffic
    // to Apple TV's RSD endpoint traverses packetFlow.
    private var rsdRemoteXPC: RemoteXPC?

    // RSD endpoint for the currently connected Apple TV.
    // Connecting the VPN only records this endpoint.
    // IPA installation is started explicitly by the main app.
    private var currentRSDAddress: String?
    private var currentRSDPort: Int?

    // KI_INSTALL_SESSION_COORDINATOR
    // Synchronize installation admission across asynchronous tasks.
    private let installationSessionLock = NSLock()
    private var activeInstallationID: String?

    // KI_INSTALL_CANCELLATION_STATE
    // Track cancellation for the currently admitted attempt.
    private var cancelledInstallationID: String?

    // KI_LIFECYCLE_TASK_REGISTRY
    private var installationWorkers = 0
    private var installationFinishRequested = false
    private var installationConnections: [String: RemoteXPC] = [:]
    // KI_CLEANUP_QUERY_V1: Only the most recently cancelled attempt.
    private var completedCancellationID: String?
    // KI_FAILURE_RECOVERY_RECEIPT
    private var completedInstallationID: String?

    private func cleanupState(for id: String) -> String {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }
        if activeInstallationID == id { return "CLEANUP_PENDING" }
        if completedCancellationID == id || completedInstallationID == id { return "CLEANUP_COMPLETE" }
        return "CLEANUP_UNKNOWN"
    }

    private func releaseInstallationLocked() {
        if let id = activeInstallationID {
            completedInstallationID = id
            if cancelledInstallationID == id { completedCancellationID = id }
        }
        activeInstallationID = nil
        cancelledInstallationID = nil
        installationFinishRequested = false
    }

    private func registerInstallationWorker(_ id: String, role: String,
                                            connection: RemoteXPC) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }
        guard activeInstallationID == id,
              cancelledInstallationID != id,
              !installationFinishRequested else {
            return false
        }
        installationWorkers += 1
        installationConnections[role] = connection
        return true
    }

    private func installationWorkerEnded(_ id: String, role: String) {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }
        guard activeInstallationID == id else { return }
        installationConnections.removeValue(forKey: role)
        installationWorkers = max(0, installationWorkers - 1)
        if installationWorkers == 0 && installationFinishRequested {
            releaseInstallationLocked()
        }
    }

    private func cancelInstallationConnections(_ id: String) -> Bool {
        installationSessionLock.lock()
        guard activeInstallationID == id else {
            installationSessionLock.unlock()
            return false
        }
        cancelledInstallationID = id
        installationFinishRequested = true
        let connections = Array(installationConnections.values)
        let noWorkers = installationWorkers == 0
        if noWorkers {
            releaseInstallationLocked()
        }
        installationSessionLock.unlock()
        for connection in connections { connection.cancel() }
        return true
    }

    private func requestInstallationCancellation(
        _ installationID: String
    ) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        guard activeInstallationID == installationID else {
            return false
        }

        cancelledInstallationID = installationID
        return true
    }

    private func isInstallationCancelled(
        _ installationID: String
    ) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        return cancelledInstallationID == installationID
    }

    private func beginInstallationSession(
        _ selectionID: String
    ) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        guard activeInstallationID == nil else {
            return false
        }

        // KI_SESSION_OWNED_MARKER_RESET
        // Reset the marker before admitting this attempt.
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            return false
        }

        let markerURL = container.appendingPathComponent(
            "ipa-upload-complete.txt"
        )

        do {
            if FileManager.default.fileExists(
                atPath: markerURL.path
            ) {
                try FileManager.default.removeItem(at: markerURL)
            }
        } catch {
            return false
        }

        activeInstallationID = selectionID
        completedCancellationID = nil
        completedInstallationID = nil
        cancelledInstallationID = nil
        installationFinishRequested = false
        installationWorkers = 0
        installationConnections.removeAll()
        return true
    }

    private func finishInstallationSession(
        _ selectionID: String
    ) {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        guard activeInstallationID == selectionID else {
            return
        }

        installationFinishRequested = true
        if installationWorkers == 0 {
            releaseInstallationLocked()
        }
    }

    private func hasActiveInstallationSession() -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        return activeInstallationID != nil
    }

    // KI_SESSION_TERMINAL_PUBLICATION
    // Publish terminal status only for the active attempt.
    // KI_FINAL_CLEANUP_20261018
    // Legacy terminal diagnostics retired; JSON status is authoritative.
    private func publishInstallationTerminalStatus(
        _ message: String,
        installationID: String
    ) -> Bool {
        return false
    }

    // KI_DEDICATED_INSTALL_STATUS
    // Publish installation state separately from diagnostics.
    private func publishInstallationStatus(
        installationID: String,
        phase: String,
        progress: Double?,
        detail: String,
        terminal: Bool
    ) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        guard activeInstallationID == installationID else {
            return false
        }

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            return false
        }

        let statusURL = container.appendingPathComponent(
            "installation-status.json"
        )

        let allowedPhases: Set<String> = [
            "preparing",
            "uploading",
            "installing",
            "verifying",
            "complete",
            "failed"
        ]

        guard allowedPhases.contains(phase),
              progress == nil ||
              (progress!.isFinite &&
               progress! >= 0 &&
               progress! <= 1) else {
            return false
        }

        // KI_INSTALL_TERMINAL_STATE_GUARD
        // A terminal result cannot be replaced by late progress.
        if let existingData = try? Data(
            contentsOf: statusURL
        ),
        let existing = try? JSONSerialization.jsonObject(
            with: existingData
        ) as? [String: Any],
        let existingID = existing["installationID"] as? String,
        existingID == installationID,
        existing["terminal"] as? Bool == true {
            return false
        }

        guard terminal == (
            phase == "complete" || phase == "failed"
        ) else {
            return false
        }

        // KI_INSTALL_PHASE_ORDER_GUARD
        // Prevent late progress from moving installation backward.
        let phaseOrder: [String: Int] = [
            "preparing": 0,
            "uploading": 1,
            "installing": 2,
            "verifying": 3,
            "complete": 4,
            "failed": 4
        ]

        if let existingData = try? Data(contentsOf: statusURL),
           let existing = try? JSONSerialization.jsonObject(
                with: existingData
           ) as? [String: Any],
           existing["installationID"] as? String == installationID,
           let previousPhase = existing["phase"] as? String,
           let previousOrder = phaseOrder[previousPhase],
           let nextOrder = phaseOrder[phase],
           nextOrder < previousOrder {
            return false
        }

        // KI_INSTALL_MONOTONIC_PROGRESS
        // Progress cannot decrease within the same phase.
        if let progress,
           let existingData = try? Data(contentsOf: statusURL),
           let existing = try? JSONSerialization.jsonObject(
                with: existingData
           ) as? [String: Any],
           existing["installationID"] as? String == installationID,
           existing["phase"] as? String == phase,
           let previousProgress = existing["progress"] as? Double,
           progress < previousProgress {
            return false
        }

        var status: [String: Any] = [
            "installationID": installationID,
            "phase": phase,
            "detail": detail,
            "terminal": terminal
        ]

        if let progress {
            status["progress"] = progress
        }

        do {
            let data = try JSONSerialization.data(
                withJSONObject: status
            )

            try data.write(
                to: statusURL,
                options: .atomic
            )

            return true
        } catch {
            return false
        }
    }

    // KI_INSTALL_SESSION_OWNERSHIP
    // Verify that an asynchronous task still owns the session.
    private func ownsInstallationSession(
        _ selectionID: String
    ) -> Bool {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        return activeInstallationID == selectionID
    }

    override func startTunnel(
        options: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {


        guard
            let options,
            let pairingHost =
                options["pairingHost"] as? String,
            let pairingPortNumber =
                options["pairingPort"] as? NSNumber
        else {

            completionHandler(
                NSError(
                    domain: "KunInstallerTunnel",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Missing pairing host/port."
                    ]
                )
            )

            return
        }

        let pairingPort =
            pairingPortNumber.intValue





        Task {

            do {

                // --------------------------------------------------------
                // Load the full saved pairing record from the App Group.
                // --------------------------------------------------------

                guard
                    let containerURL =
                        FileManager.default.containerURL(
                            forSecurityApplicationGroupIdentifier:
                                KhmerInstallerConfig.appGroupID
                        )
                else {
                    throw NSError(
                        domain: "KunInstallerTunnel",
                        code: 10,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "App Group container unavailable."
                        ]
                    )
                }

                let recordURL =
                    containerURL.appendingPathComponent(
                        "remote-pairing-record.json"
                    )

                let data =
                    try Data(contentsOf: recordURL)

                let record =
                    try JSONDecoder().decode(
                        RemotePairingRecord.self,
                        from: data
                    )








                // --------------------------------------------------------
                // The extension now owns the Apple TV RemotePairing
                // transport.
                // --------------------------------------------------------


                let pairingClient =
                    RemotePairingClient()

                let tunnel =
                    try await pairingClient.connectTunnel(
                        host: pairingHost,
                        port: pairingPort,
                        record: record
                    )








                // --------------------------------------------------------
                // Configure the iOS Packet Tunnel interface.
                // --------------------------------------------------------

                // IMPORTANT:
                // Configure the iOS TUN from THIS extension-owned
                // Cumulative Tunnel handshake, not the earlier
                // main-app tunnel addresses.
                let networkSettings =
                    NEPacketTunnelNetworkSettings(
                        tunnelRemoteAddress:
                            tunnel.serverAddress
                    )

                let ipv6Settings =
                    NEIPv6Settings(
                        addresses: [tunnel.clientAddress],
                        networkPrefixLengths: [64]
                    )

                // NEIPv6Route expects the network address for a /64,
                // not the Apple TV's ::1 host address.
                //
                // Cumulative Tunnel addresses are allocated as:
                //     <prefix>::1  Apple TV
                //     <prefix>::2  iPhone
                //
                // Therefore route the complete <prefix>::/64.
                guard
                    let doubleColonRange =
                        tunnel.serverAddress.range(
                            of: "::"
                        )
                else {
                    throw NSError(
                        domain: "KunInstallerTunnel",
                        code: 20,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Unexpected Apple TV tunnel IPv6 address."
                        ]
                    )
                }

                let tunnelNetworkPrefix =
                    String(
                        tunnel.serverAddress[
                            ..<doubleColonRange.lowerBound
                        ]
                    ) + "::"


                ipv6Settings.includedRoutes = [
                    NEIPv6Route(
                        destinationAddress:
                            tunnelNetworkPrefix,
                        networkPrefixLength: 64
                    )
                ]

                networkSettings.ipv6Settings =
                    ipv6Settings

                // Keep the working iOS TUN MTU.
                let packetTunnelMTU = 1500

                networkSettings.mtu =
                    NSNumber(
                        value:
                            packetTunnelMTU
                    )




                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Void, Error>
                    ) in

                    setTunnelNetworkSettings(
                        networkSettings
                    ) { error in

                        if let error {

                            continuation.resume(
                                throwing: error
                            )

                        } else {


                            continuation.resume()
                        }
                    }
                }


                // Keep the RemotePairingClient alive for the entire
                // lifetime of the Packet Tunnel. Its NWConnection is
                // owned by the client.
                self.pairingClient =
                    pairingClient

                self.tunnelReady = true


                self.startPacketPumps()


                completionHandler(nil)

                // Keep the VPN/tunnel connected, but do not begin
                // RSD/AFC/InstallationProxy automatically.
                // The main app explicitly starts installation through
                // handleAppMessage("KunInstaller Install IPA").
                self.currentRSDAddress =
                    tunnel.serverAddress

                self.currentRSDPort =
                    tunnel.serverRSDPort

                self.writeRSDDebug(
                    "TUNNEL_READY_FOR_INSTALL address=\(tunnel.serverAddress) port=\(tunnel.serverRSDPort)"
                )


            } catch {



                completionHandler(error)
            }
        }
    }




    private func clearIPAUploadMarker() {

        guard
            let container =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        KhmerInstallerConfig.appGroupID
                )
        else {
            return
        }

        let markerURL =
            container.appendingPathComponent(
                "ipa-upload-complete.txt"
            )

        try? FileManager.default.removeItem(
            at:
                markerURL
        )
    }

    // KI_TUNNEL_STREAMING_SHA256
    private static func sha256ForIPA(_ url: URL) throws -> String {
        let started = Date()

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1

        NSLog("KI_SHA256: BEGIN sizeBytes=%lld", fileSize)

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var processed: Int64 = 0
        var nextReport: Int64 = 64 * 1024 * 1024

        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024)
                ?? Data()

            if chunk.isEmpty {
                break
            }

            hasher.update(data: chunk)
            processed += Int64(chunk.count)

            if processed >= nextReport {
                NSLog(
                    "KI_SHA256: PROGRESS bytes=%lld elapsed=%.1fs",
                    processed,
                    Date().timeIntervalSince(started)
                )
                nextReport = processed + 64 * 1024 * 1024
            }
        }

        let digest = hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        NSLog(
            "KI_SHA256: COMPLETE bytes=%lld elapsed=%.1fs",
            processed,
            Date().timeIntervalSince(started)
        )

        return digest
    }

    // KI_INSTALL_IDENTITY_PREFLIGHT
    // Capture and validate the selected IPA before installation.
    private struct InstallationIdentity {
        let filename: String
        let bundleID: String
        let selectionID: String
        let installationID: String
        let sha256: String
    }

    private func validatedInstallationIdentity() throws
        -> InstallationIdentity {

        writeRSDDebug("IDENTITY_CHECK: BEGIN")

        let fm = FileManager.default
        writeRSDDebug("IDENTITY_CHECK: APP_GROUP_LOOKUP")

        guard let container = fm.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            throw NSError(
                domain: "KhmerInstaller.Install",
                code: 301,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installation App Group unavailable."
                ]
            )
        }

        writeRSDDebug("IDENTITY_CHECK: APP_GROUP_READY")

        let selectionURL = container.appendingPathComponent(
            "selected-ipa.txt"
        )

        let metadataURL = container.appendingPathComponent(
            "selected-ipa-metadata.json"
        )

        writeRSDDebug("IDENTITY_CHECK: SELECTION_FILE_READ_BEGIN")

        let selectedFilename = try String(
            contentsOf: selectionURL,
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        writeRSDDebug("IDENTITY_CHECK: SELECTION_FILE_READ_OK")

        writeRSDDebug("IDENTITY_CHECK: METADATA_READ_BEGIN")

        let metadataData = try Data(contentsOf: metadataURL)

        writeRSDDebug(
            "IDENTITY_CHECK: METADATA_READ_OK bytes=\(metadataData.count)"
        )

        guard let metadata = try JSONSerialization.jsonObject(
            with: metadataData
        ) as? [String: String],
        let filename = metadata["filename"],
        let bundleID = metadata["bundleID"],
        let selectionID = metadata["selectionID"],
        let expectedSHA256 = metadata["sha256"],
        expectedSHA256.count == 64,
        expectedSHA256.utf8.allSatisfy({
            (48...57).contains($0) || (97...102).contains($0)
        }),
        !filename.isEmpty,
        !bundleID.isEmpty,
        !selectionID.isEmpty,
        filename == selectedFilename,
        filename == URL(fileURLWithPath: filename).lastPathComponent,
        filename.lowercased().hasSuffix(".ipa"),
        UUID(uuidString: selectionID) != nil else {
            throw NSError(
                domain: "KhmerInstaller.Install",
                code: 302,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Selected IPA metadata is invalid or inconsistent."
                ]
            )
        }

        writeRSDDebug(
            "IDENTITY_CHECK: METADATA_VALID bundleID=\(bundleID) filename=\(filename)"
        )

        let directory = container.appendingPathComponent(
            "IPA",
            isDirectory: true
        ).standardizedFileURL

        let ipaURL = directory.appendingPathComponent(
            filename
        ).standardizedFileURL

        guard ipaURL.deletingLastPathComponent() == directory,
              let values = try? ipaURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ),
              values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw NSError(
                domain: "KhmerInstaller.Install",
                code: 303,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Selected IPA file is missing or invalid."
                ]
            )
        }

        writeRSDDebug("IDENTITY_CHECK: IPA_FILE_VALID")

        // KI_INSTALL_SHA256_DEFERRED_TO_UPLOAD
        // The AFC upload worker hashes the exact bytes it streams
        // and compares them with the main app's expected SHA-256.
        // Avoid hashing the entire IPA synchronously before IPC acknowledgment.
        writeRSDDebug("IDENTITY_CHECK: SHA256_DEFERRED_TO_UPLOAD")

        // KI_UNIQUE_INSTALLATION_ATTEMPT
        // Generate a new identity for every Install request.
        return InstallationIdentity(
            filename: filename,
            bundleID: bundleID,
            selectionID: selectionID,
            installationID: UUID().uuidString,
            sha256: expectedSHA256
        )
    }

    // KI_AFC_SESSION_MARKER_PUBLICATION
    // Serialize marker writes with installation-session changes.
    private func publishInstallationMarker(
        _ marker: String,
        selectionID: String,
        isFailure: Bool
    ) throws {
        installationSessionLock.lock()
        defer { installationSessionLock.unlock() }

        guard activeInstallationID == selectionID else {
            throw NSError(
                domain: "KhmerInstaller.Install",
                code: 310,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installation session is no longer active."
                ]
            )
        }

        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            throw NSError(
                domain: "KhmerInstaller.Install",
                code: 311,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installation App Group unavailable."
                ]
            )
        }

        let markerURL = container.appendingPathComponent(
            "ipa-upload-complete.txt"
        )

        if isFailure,
           let existing = try? String(
                contentsOf: markerURL,
                encoding: .utf8
           ),
           existing.hasPrefix("SUCCESS:" + selectionID + ":") {
            return
        }

        try marker.write(
            to: markerURL,
            atomically: true,
            encoding: .utf8
        )
    }

    // KI_AFC_FAILURE_MARKER
    // Notify the installation proxy that AFC upload failed.
    private func writeIPAUploadFailureMarker(
        selectionID: String
    ) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            return
        }

        let markerURL = container.appendingPathComponent(
            "ipa-upload-complete.txt"
        )

        let failure = "FAILED:" + selectionID

        // KI_AFC_FAILURE_SESSION_PUBLICATION
        try? publishInstallationMarker(
            failure,
            selectionID: selectionID,
            isFailure: true
        )
    }

    private func writeIPAUploadMarker(
        remotePath: String,
        selectionID: String
    ) throws {

        guard
            let container =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        KhmerInstallerConfig.appGroupID
                )
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    210,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "App Group unavailable for IPA upload marker."
                ]
            )
        }

        let markerURL =
            container.appendingPathComponent(
                "ipa-upload-complete.txt"
            )

        // KI_AFC_SUCCESS_SESSION_MARKER
        let marker = "SUCCESS:" + selectionID + ":" + remotePath

        // KI_AFC_SUCCESS_SESSION_PUBLICATION
        try publishInstallationMarker(
            marker,
            selectionID: selectionID,
            isFailure: false
        )
    }

    private func waitForIPAUploadCompletion(
        selectionID: String
    ) async throws -> String {

        guard
            let container =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        KhmerInstallerConfig.appGroupID
                )
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    211,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "App Group unavailable while waiting for IPA upload."
                ]
            )
        }

        let markerURL =
            container.appendingPathComponent(
                "ipa-upload-complete.txt"
            )

        // KI_AFC_UPLOAD_COMPLETION_TIMEOUT
        // Allow large IPA uploads to finish before reporting timeout.
        let deadline =
            Date().addingTimeInterval(
                600
            )

        while Date() < deadline {
            try Task.checkCancellation()
            if isInstallationCancelled(selectionID) {
                throw CancellationError()
            }

            if
                let remotePath =
                    try? String(
                        contentsOf:
                            markerURL,
                        encoding:
                            .utf8
                    )
            {

                let trimmed =
                    remotePath.trimmingCharacters(
                        in:
                            .whitespacesAndNewlines
                    )

                if !trimmed.isEmpty {

                    // KI_AFC_FAILURE_MARKER_READER
                    if trimmed.hasPrefix("FAILED:") {
                        let failedSelectionID =
                            String(trimmed.dropFirst(7))

                        guard failedSelectionID == selectionID else {
                            throw NSError(
                                domain: "KhmerInstaller.AFC",
                                code: 306,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "Upload marker belongs to another installation."
                                ]
                            )
                        }

                        throw NSError(
                            domain: "KhmerInstaller.AFC",
                            code: 307,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "IPA upload failed."
                            ]
                        )
                    }

                    // KI_AFC_SUCCESS_SESSION_READER
                    let prefix = "SUCCESS:" + selectionID + ":"

                    guard trimmed.hasPrefix(prefix) else {
                        throw NSError(
                            domain: "KhmerInstaller.AFC",
                            code: 308,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Upload marker does not match installation."
                            ]
                        )
                    }

                    let remotePath = String(
                        trimmed.dropFirst(prefix.count)
                    )

                    guard !remotePath.isEmpty,
                          remotePath.hasPrefix(
                            "/PublicStaging/pymobiledevice3/"
                          ) else {
                        throw NSError(
                            domain: "KhmerInstaller.AFC",
                            code: 309,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid uploaded IPA path."
                            ]
                        )
                    }

                    writeRSDDebug(
                        "IPA_UPLOAD_MARKER_FOUND path=\(remotePath)"
                    )

                    return remotePath
                }
            }

            try await Task.sleep(
                nanoseconds:
                    500_000_000
            )
        }

        throw NSError(
            domain:
                "KunInstaller.AFC",
            code:
                212,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Timed out waiting for IPA upload to complete."
            ]
        )
    }

    // KI_RESTORED_RSD_DEBUG_WRITER
    // Write bounded diagnostics to the shared App Group.
    // Never log credentials, private keys, or pairing secrets.
    private func writeRSDDebug(_ message: String) {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier:
                KhmerInstallerConfig.appGroupID
        ) else {
            return
        }

        let url = container.appendingPathComponent(
            "remotexpc-debug.txt"
        )

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(timestamp)] \(message)\n"

        do {
            var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            existing += entry

            if existing.utf8.count > 1_000_000 {
                existing = String(existing.suffix(800_000))
            }

            try existing.write(
                to: url,
                atomically: true,
                encoding: .utf8
            )
        } catch {
            NSLog("KhmerInstaller: Unable to write RSD diagnostic: \(error.localizedDescription)")
        }
    }

    private func extractInstallationProxyPort(
        from summary: String
    ) -> Int? {

        let serviceName =
            "com.apple.mobile.installation_proxy.shim.remote"

        guard
            let serviceRange =
                summary.range(
                    of: serviceName
                )
        else {
            return nil
        }

        let afterService =
            summary[
                serviceRange.upperBound...
            ]

        let portMarker =
            "Port=String(\""

        guard
            let portRange =
                afterService.range(
                    of: portMarker
                )
        else {
            return nil
        }

        let portStart =
            portRange.upperBound

        guard
            let portEnd =
                afterService[
                    portStart...
                ].firstIndex(
                    of: "\""
                )
        else {
            return nil
        }

        let portText =
            String(
                afterService[
                    portStart..<portEnd
                ]
            )

        return Int(portText)
    }

    private func extractAFCPort(
        from summary: String
    ) -> Int? {

        let serviceName =
            "com.apple.afc.shim.remote"

        guard
            let serviceRange =
                summary.range(
                    of: serviceName
                )
        else {
            return nil
        }

        let afterService =
            summary[
                serviceRange.upperBound...
            ]

        let portMarker =
            "Port=String(\""

        guard
            let portRange =
                afterService.range(
                    of: portMarker
                )
        else {
            return nil
        }

        let portStart =
            portRange.upperBound

        guard
            let portEnd =
                afterService[
                    portStart...
                ].firstIndex(
                    of: "\""
                )
        else {
            return nil
        }

        let portText =
            String(
                afterService[
                    portStart..<portEnd
                ]
            )

        return Int(portText)
    }

    private func installationProxyPlistFrame(
        _ plist: [String: Any]
    ) throws -> Data {

        let payload =
            try PropertyListSerialization.data(
                fromPropertyList:
                    plist,
                format:
                    .xml,
                options:
                    0
            )

        guard payload.count <= Int(UInt32.max) else {
            throw NSError(
                domain:
                    "KunInstaller.InstallationProxy",
                code:
                    1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installation proxy plist is too large."
                ]
            )
        }

        let length =
            UInt32(
                payload.count
            )

        var frame =
            Data()

        frame.append(
            UInt8(
                (length >> 24) & 0xff
            )
        )

        frame.append(
            UInt8(
                (length >> 16) & 0xff
            )
        )

        frame.append(
            UInt8(
                (length >> 8) & 0xff
            )
        )

        frame.append(
            UInt8(
                length & 0xff
            )
        )

        frame.append(
            payload
        )

        return frame
    }

    private func parseInstallationProxyPlist(
        from buffer: inout Data
    ) throws -> [String: Any] {

        writeRSDDebug(
            "INSTALL_PROXY_PARSE_ENTER bufferBytes=\(buffer.count)"
        )

        guard buffer.count >= 4 else {
            throw NSError(
                domain: "KunInstaller.InstallationProxy",
                code: 10,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Not enough bytes for plist frame header."
                ]
            )
        }

        writeRSDDebug(
            "INSTALL_PROXY_PARSE_BEFORE_LENGTH"
        )

        let bytes =
            Array(buffer)

        writeRSDDebug(
            "INSTALL_PROXY_PARSE_SNAPSHOT bytes=\(bytes.count)"
        )

        let length =
            (Int(bytes[0]) << 24) |
            (Int(bytes[1]) << 16) |
            (Int(bytes[2]) << 8) |
            Int(bytes[3])

        let frameLength =
            4 + length

        writeRSDDebug(
            "INSTALL_PROXY_FRAME_HEADER length=\(length) frameBytes=\(frameLength) bufferBytes=\(buffer.count)"
        )

        guard buffer.count >= frameLength else {
            throw NSError(
                domain: "KunInstaller.InstallationProxy",
                code: 11,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Complete plist frame is not buffered."
                ]
            )
        }

        writeRSDDebug(
            "INSTALL_PROXY_PARSE_BEFORE_PAYLOAD"
        )

        let payload =
            Data(
                bytes[
                    4..<frameLength
                ]
            )

        writeRSDDebug(
            "INSTALL_PROXY_PLIST_PAYLOAD_READY bytes=\(payload.count)"
        )

        buffer.removeFirst(frameLength)

        let object =
            try PropertyListSerialization.propertyList(
                from: payload,
                options: [],
                format: nil
            )

        guard let dictionary =
            object as? [String: Any]
        else {
            throw NSError(
                domain: "KunInstaller.InstallationProxy",
                code: 12,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Installation proxy response was not a dictionary."
                ]
            )
        }

        writeRSDDebug(
            "INSTALL_PROXY_PLIST_PARSED remainingBufferBytes=\(buffer.count)"
        )

        return dictionary
    }

    private func receiveInstallationProxyPlist(
        from connection: RemoteXPC,
        buffer: inout Data
    ) async throws -> [String: Any] {

        writeRSDDebug(
            "INSTALL_PROXY_RECEIVE_ENTER bufferBytes=\(buffer.count)"
        )

        while buffer.count < 4 {

            let needed =
                4 - buffer.count

            writeRSDDebug(
                "INSTALL_PROXY_HEADER_RECEIVE_NEEDED bytes=\(needed)"
            )

            let chunk =
                try await connection.receiveRaw(
                    minimumIncompleteLength: needed,
                    maximumLength: needed
                )

            guard !chunk.isEmpty else {
                throw NSError(
                    domain:
                        "KunInstaller.InstallationProxy",
                    code:
                        13,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Installation proxy connection closed while waiting for plist header."
                    ]
                )
            }

            buffer.append(chunk)

            writeRSDDebug(
                "INSTALL_PROXY_HEADER_RECEIVED chunkBytes=\(chunk.count) bufferBytes=\(buffer.count)"
            )
        }

        let bytes =
            Array(buffer)

        let length =
            (Int(bytes[0]) << 24) |
            (Int(bytes[1]) << 16) |
            (Int(bytes[2]) << 8) |
            Int(bytes[3])

        let frameLength =
            4 + length

        writeRSDDebug(
            "INSTALL_PROXY_FRAME_EXPECTED bodyBytes=\(length) frameBytes=\(frameLength) bufferBytes=\(buffer.count)"
        )

        while buffer.count < frameLength {

            let needed =
                frameLength - buffer.count

            writeRSDDebug(
                "INSTALL_PROXY_BODY_RECEIVE_NEEDED bytes=\(needed)"
            )

            let chunk =
                try await connection.receiveRaw(
                    minimumIncompleteLength: needed,
                    maximumLength: needed
                )

            guard !chunk.isEmpty else {
                throw NSError(
                    domain:
                        "KunInstaller.InstallationProxy",
                    code:
                        14,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Installation proxy connection closed while waiting for plist body."
                    ]
                )
            }

            buffer.append(chunk)

            writeRSDDebug(
                "INSTALL_PROXY_BODY_RECEIVED chunkBytes=\(chunk.count) bufferBytes=\(buffer.count)"
            )
        }

        writeRSDDebug(
            "INSTALL_PROXY_RECEIVE_RETURN bufferBytes=\(buffer.count)"
        )

        return try parseInstallationProxyPlist(
            from: &buffer
        )
    }

    // Apple TV HD / AppleTV5,3 compatibility:
    // some devices do not have /PublicStaging/pymobiledevice3
    // present when the AFC service starts. Create it before
    // the existing AFC staging/probe flow so IPA installation
    // works on both Apple TV HD and Apple TV 4K.
    //
    // Keep this helper isolated to the AFC service-ready path.
    // It intentionally does not modify the Packet Tunnel or
    // RemoteXPC architecture. This can be cleaned up later if
    // the AFC staging flow is refactored into a reusable helper.
    private func ensureAFCDirectory(
        connection: RemoteXPC,
        path: String
    ) async throws {

        let pathData =
            Data(
                (path + "\0").utf8
            )

        let entireLength =
            UInt64(
                40 + pathData.count
            )

        var packet =
            Data()

        packet.append(
            Data(
                "CFA6LPAA".utf8
            )
        )

        let values: [UInt64] = [
            entireLength,
            entireLength,
            1,
            9
        ]

        for value in values {

            var littleEndianValue =
                value.littleEndian

            withUnsafeBytes(
                of:
                    &littleEndianValue
            ) { rawBytes in

                packet.append(
                    contentsOf:
                        rawBytes
                )
            }
        }

        packet.append(
            pathData
        )

        writeRSDDebug(
            "AFC_MAKE_DIR_SENDING path=\(path)"
        )

        try await connection.sendRaw(
            packet
        )

        let responseHeader =
            try await connection.receiveExact(
                40
            )

        let headerBytes =
            Array(responseHeader)

        let responseEntireLength =
            readUInt64LE(
                headerBytes,
                offset: 8
            )

        let responseOperation =
            readUInt64LE(
                headerBytes,
                offset: 32
            )

        guard
            responseEntireLength >= 48,
            responseOperation == 1
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    300,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid AFC MAKE_DIR response."
                ]
            )
        }

        let responseBody =
            try await connection.receiveExact(
                Int(
                    responseEntireLength - 40
                )
            )

        guard responseBody.count >= 8 else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    301,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "AFC MAKE_DIR response did not contain a status."
                ]
            )
        }

        let status =
            readUInt64LE(
                Array(responseBody),
                offset: 0
            )

        writeRSDDebug(
            "AFC_MAKE_DIR_STATUS=\(status)"
        )

        // 0 = success
        // 16 = object already exists
        guard
            status == 0 ||
            status == 16
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    Int(status),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "AFC MAKE_DIR failed with status \(status)."
                ]
            )
        }

        writeRSDDebug(
            status == 16
                ? "AFC_MAKE_DIR_EXISTS"
                : "AFC_MAKE_DIR_COMPLETE"
        )
    }

    private func startAFCProbe(
        address: String,
        port: Int,
        installationIdentity: InstallationIdentity
    ) {

        writeRSDDebug(
            "AFC_PROBE_START address=\(address) port=\(port)"
        )

        guard let virtualInterface else {

            writeRSDDebug(
                "AFC_PROBE_FAILED virtualInterface=NIL"
            )

            // KI_AFC_JSON_INTERFACE_FAILURE
            // Report failure before notifying Installation Proxy.
            _ = publishInstallationStatus(
                installationID:
                    installationIdentity.installationID,
                phase: "failed",
                progress: nil,
                detail: "Apple TV AFC network interface unavailable.",
                terminal: true
            )

            // KI_AFC_FAILURE_EARLY_EXIT
            writeIPAUploadFailureMarker(
                selectionID: installationIdentity.installationID
            )

            return
        }

        do {

            let connection =
                try RemoteXPC(
                    address:
                        address,
                    port:
                        port,
                    interface:
                        virtualInterface
                )

            guard registerInstallationWorker(
                installationIdentity.installationID,
                role: "afc", connection: connection
            ) else {
                connection.cancel()
                return
            }

            Task { [weak self, connection] in
                defer {
                    connection.cancel()
                    self?.installationWorkerEnded(
                        installationIdentity.installationID, role: "afc"
                    )
                }

                do {

                    try await
                        connection.connect()

                    self?.writeRSDDebug(
                        "AFC_TCP_CONNECTED port=\(port)"
                    )

                    let checkin =
                        try self?.installationProxyPlistFrame(
                            [
                                "Label":
                                    "KunInstaller",

                                "ProtocolVersion":
                                    "2",

                                "Request":
                                    "RSDCheckin"
                            ]
                        )

                    guard let checkin else {

                        self?.writeRSDDebug(
                            "AFC_CHECKIN_BUILD_FAILED"
                        )

                        connection.cancel()

                        return
                    }

                    try await
                        connection.sendRaw(
                            checkin
                        )

                    self?.writeRSDDebug(
                        "AFC_RSDCHECKIN_SENT bytes=\(checkin.count)"
                    )

                    var buffer =
                        Data()

                    let checkinResponse =
                        try await
                            self?.receiveInstallationProxyPlist(
                                from:
                                    connection,
                                buffer:
                                    &buffer
                            )

                    guard let checkinResponse else {

                        self?.writeRSDDebug(
                            "AFC_RSDCHECKIN_RESPONSE_MISSING"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "AFC_RSDCHECKIN_RESPONSE=\(checkinResponse)"
                    )

                    let startServiceChunk =
                        try await connection.receiveRaw(
                            maximumLength: 65536
                        )

                    self?.writeRSDDebug(
                        "AFC_STARTSERVICE_RECEIVED bytes=\(startServiceChunk.count)"
                    )

                    buffer.append(
                        startServiceChunk
                    )

                    let startServiceResponse =
                        try self?.parseInstallationProxyPlist(
                            from:
                                &buffer
                        )

                    guard let startServiceResponse else {

                        self?.writeRSDDebug(
                            "AFC_STARTSERVICE_RESPONSE_MISSING"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "AFC_STARTSERVICE_RESPONSE=\(startServiceResponse)"
                    )

                    self?.writeRSDDebug(
                        "AFC_SERVICE_READY"
                    )

                    try await self?.ensureAFCDirectory(
                        connection:
                            connection,
                        path:
                            "/PublicStaging/pymobiledevice3"
                    )

                    var getDeviceInfoPacket =
                        Data()

                    getDeviceInfoPacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let getDeviceInfoValues:
                        [UInt64] = [
                            40,  // entire_length
                            40,  // this_length
                            0,   // packet_num
                            11   // GET_DEVINFO
                        ]

                    for value in getDeviceInfoValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            getDeviceInfoPacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    self?.writeRSDDebug(
                        "AFC_GET_DEVINFO_SENDING bytes=\(getDeviceInfoPacket.count)"
                    )

                    self?.writeRSDDebug(
                        "AFC_GET_DEVINFO_HEX=" +
                            getDeviceInfoPacket.map {
                                String(
                                    format: "%02x",
                                    $0
                                )
                            }.joined()
                    )

                    try await connection.sendRaw(
                        getDeviceInfoPacket
                    )

                    self?.writeRSDDebug(
                        "AFC_GET_DEVINFO_SENT"
                    )

                    let afcResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    guard
                        afcResponseHeader.count == 40
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC response header was not 40 bytes."
                            ]
                        )
                    }

                    let afcHeaderBytes =
                        Array(
                            afcResponseHeader
                        )

                    let afcMagic =
                        String(
                            data:
                                Data(
                                    afcHeaderBytes[
                                        0..<8
                                    ]
                                ),
                            encoding:
                                .utf8
                        ) ?? ""

                    guard
                        afcMagic == "CFA6LPAA"
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                2,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC response magic: \(afcMagic)"
                            ]
                        )
                    }

                    let responseEntireLength =
                        readUInt64LE(
                            afcHeaderBytes,
                            offset:
                                8
                        )

                    let responseThisLength =
                        readUInt64LE(
                            afcHeaderBytes,
                            offset:
                                16
                        )

                    let responsePacketNumber =
                        readUInt64LE(
                            afcHeaderBytes,
                            offset:
                                24
                        )

                    let responseOperation =
                        readUInt64LE(
                            afcHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_RESPONSE_HEADER entire=\(responseEntireLength) this=\(responseThisLength) packet=\(responsePacketNumber) operation=\(responseOperation)"
                    )

                    guard
                        responseEntireLength >= 40
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                3,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC response length."
                            ]
                        )
                    }

                    let responseBodyLength =
                        Int(
                            responseEntireLength - 40
                        )

                    let responseBody =
                        try await connection.receiveExact(
                            responseBodyLength
                        )

                    self?.writeRSDDebug(
                        "AFC_GET_DEVINFO_RESPONSE_BODY bytes=\(responseBody.count)"
                    )

                    if responseOperation == 1,
                       responseBody.count == 8 {

                        let status =
                            readUInt64LE(
                                Array(
                                    responseBody
                                ),
                                offset:
                                    0
                            )

                        self?.writeRSDDebug(
                            "AFC_GET_DEVINFO_STATUS=\(status)"
                        )

                    } else {

                        let deviceInfoText =
                            String(
                                data:
                                    responseBody,
                                encoding:
                                    .utf8
                            ) ?? ""

                        self?.writeRSDDebug(
                            "AFC_GET_DEVINFO_DATA=\(deviceInfoText)"
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_GET_DEVINFO_COMPLETE"
                    )

                    var readDirPacket =
                        Data()

                    readDirPacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let readDirValues:
                        [UInt64] = [
                            71,
                            71,
                            1,
                            3
                        ]

                    for value in readDirValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            readDirPacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    readDirPacket.append(
                        Data(
                            "/PublicStaging/pymobiledevice3\0".utf8
                        )
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_SENDING path=/PublicStaging/pymobiledevice3 bytes=\(readDirPacket.count)"
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_HEX=" +
                            readDirPacket.map {
                                String(
                                    format: "%02x",
                                    $0
                                )
                            }.joined()
                    )

                    try await connection.sendRaw(
                        readDirPacket
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_SENT"
                    )

                    let readDirResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    guard
                        readDirResponseHeader.count == 40
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                10,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC READ_DIR response header was not 40 bytes."
                            ]
                        )
                    }

                    let readDirHeaderBytes =
                        Array(
                            readDirResponseHeader
                        )

                    let readDirEntireLength =
                        readUInt64LE(
                            readDirHeaderBytes,
                            offset:
                                8
                        )

                    let readDirThisLength =
                        readUInt64LE(
                            readDirHeaderBytes,
                            offset:
                                16
                        )

                    let readDirPacketNumber =
                        readUInt64LE(
                            readDirHeaderBytes,
                            offset:
                                24
                        )

                    let readDirOperation =
                        readUInt64LE(
                            readDirHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_RESPONSE_HEADER entire=\(readDirEntireLength) this=\(readDirThisLength) packet=\(readDirPacketNumber) operation=\(readDirOperation)"
                    )

                    guard
                        readDirEntireLength >= 40
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                11,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC READ_DIR response length."
                            ]
                        )
                    }

                    let readDirBodyLength =
                        Int(
                            readDirEntireLength - 40
                        )

                    let readDirBody =
                        try await connection.receiveExact(
                            readDirBodyLength
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_RESPONSE_BODY bytes=\(readDirBody.count)"
                    )

                    let readDirNames =
                        [UInt8](
                            readDirBody
                        )
                        .split(
                            separator:
                                0
                        )
                        .map {
                            String(
                                decoding:
                                    $0,
                                as:
                                    UTF8.self
                            )
                        }

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_NAMES=\(readDirNames)"
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_DIR_COMPLETE"
                    )

                    let testPath =
                        "/PublicStaging/pymobiledevice3/kun-test.bin"

                    var fileOpenPacket =
                        Data()

                    fileOpenPacket.append(
                        Data("CFA6LPAA".utf8)
                    )

                    let testPathData =
                        Data(
                            (testPath + "\0").utf8
                        )

                    let fileOpenEntireLength =
                        UInt64(
                            40 + 8 + testPathData.count
                        )

                    let fileOpenValues:
                        [UInt64] = [
                            fileOpenEntireLength,
                            fileOpenEntireLength,
                            2, // packet_num
                            13 // FILE_OPEN
                        ]

                    for value in fileOpenValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            fileOpenPacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var writeModeValue =
                        UInt64(3).littleEndian
                        // AFC WRONLY = 3
                        // O_WRONLY | O_CREAT | O_TRUNC

                    withUnsafeBytes(
                        of:
                            &writeModeValue
                    ) { rawBytes in

                        fileOpenPacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    fileOpenPacket.append(
                        testPathData
                    )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_SENDING path=\(testPath) bytes=\(fileOpenPacket.count)"
                    )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_HEX=" +
                        fileOpenPacket.map {
                            String(
                                format: "%02x",
                                $0
                            )
                        }.joined()
                    )

                    try await connection.sendRaw(
                        fileOpenPacket
                    )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_SENT"
                    )

                    let fileOpenResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    guard
                        fileOpenResponseHeader.count == 40
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                20,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC FILE_OPEN response header was not 40 bytes."
                            ]
                        )
                    }

                    let fileOpenHeaderBytes =
                        Array(
                            fileOpenResponseHeader
                        )

                    let fileOpenEntireLengthResponse =
                        readUInt64LE(
                            fileOpenHeaderBytes,
                            offset:
                                8
                        )

                    let fileOpenThisLengthResponse =
                        readUInt64LE(
                            fileOpenHeaderBytes,
                            offset:
                                16
                        )

                    let fileOpenPacketNumberResponse =
                        readUInt64LE(
                            fileOpenHeaderBytes,
                            offset:
                                24
                        )

                    let fileOpenOperationResponse =
                        readUInt64LE(
                            fileOpenHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_RESPONSE_HEADER entire=\(fileOpenEntireLengthResponse) this=\(fileOpenThisLengthResponse) packet=\(fileOpenPacketNumberResponse) operation=\(fileOpenOperationResponse)"
                    )

                    guard
                        fileOpenEntireLengthResponse >= 48
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                21,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC FILE_OPEN response length."
                            ]
                        )
                    }

                    let fileOpenBodyLength =
                        Int(
                            fileOpenEntireLengthResponse - 40
                        )

                    let fileOpenBody =
                        try await connection.receiveExact(
                            fileOpenBodyLength
                        )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_RESPONSE_BODY bytes=\(fileOpenBody.count)"
                    )

                    guard
                        fileOpenBody.count >= 8
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                22,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC FILE_OPEN response did not contain a handle."
                            ]
                        )
                    }

                    let fileHandle =
                        readUInt64LE(
                            Array(fileOpenBody),
                            offset:
                                0
                        )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_HANDLE=\(fileHandle)"
                    )

                    self?.writeRSDDebug(
                        "AFC_FILE_OPEN_COMPLETE"
                    )

                    // ---------------------------------------------------------
                    // AFC WRITE
                    // ---------------------------------------------------------

                    let testPayload =
                        Data(
                            "KunInstaller AFC write test\n".utf8
                        )

                    var writePacket =
                        Data()

                    writePacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let writeEntireLength =
                        UInt64(
                            48 + testPayload.count
                        )

                    let writeValues: [UInt64] = [
                        writeEntireLength,
                        48,         // this_length: header + file handle
                        3,          // packet_num
                        16          // WRITE
                    ]

                    for value in writeValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            writePacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var littleEndianHandle =
                        fileHandle.littleEndian

                    withUnsafeBytes(
                        of:
                            &littleEndianHandle
                    ) { rawBytes in

                        writePacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    writePacket.append(
                        testPayload
                    )

                    self?.writeRSDDebug(
                        "AFC_WRITE_SENDING handle=\(fileHandle) payloadBytes=\(testPayload.count) packetBytes=\(writePacket.count)"
                    )

                    self?.writeRSDDebug(
                        "AFC_WRITE_HEX=" +
                            writePacket.map {
                                String(
                                    format: "%02x",
                                    $0
                                )
                            }.joined()
                    )

                    try await connection.sendRaw(
                        writePacket
                    )

                    self?.writeRSDDebug(
                        "AFC_WRITE_SENT"
                    )

                    let writeResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    guard writeResponseHeader.count == 40 else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                20,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC WRITE response header was not 40 bytes."
                            ]
                        )
                    }

                    let writeHeaderBytes =
                        Array(
                            writeResponseHeader
                        )

                    let writeResponseEntireLength =
                        readUInt64LE(
                            writeHeaderBytes,
                            offset:
                                8
                        )

                    let writeResponseThisLength =
                        readUInt64LE(
                            writeHeaderBytes,
                            offset:
                                16
                        )

                    let writeResponsePacketNumber =
                        readUInt64LE(
                            writeHeaderBytes,
                            offset:
                                24
                        )

                    let writeResponseOperation =
                        readUInt64LE(
                            writeHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_WRITE_RESPONSE_HEADER entire=\(writeResponseEntireLength) this=\(writeResponseThisLength) packet=\(writeResponsePacketNumber) operation=\(writeResponseOperation)"
                    )

                    guard
                        writeResponseEntireLength >= 40
                    else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                21,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC WRITE response length."
                            ]
                        )
                    }

                    let writeResponseBodyLength =
                        Int(
                            writeResponseEntireLength - 40
                        )

                    let writeResponseBody =
                        try await connection.receiveExact(
                            writeResponseBodyLength
                        )

                    self?.writeRSDDebug(
                        "AFC_WRITE_RESPONSE_BODY bytes=\(writeResponseBody.count)"
                    )

                    if writeResponseOperation == 1 {

                        guard writeResponseBody.count >= 8 else {

                            throw NSError(
                                domain:
                                    "KunInstaller.AFC",
                                code:
                                    22,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "AFC WRITE STATUS response missing status value."
                                ]
                            )
                        }

                        let status =
                            readUInt64LE(
                                Array(writeResponseBody),
                                offset:
                                    0
                            )

                        self?.writeRSDDebug(
                            "AFC_WRITE_STATUS=\(status)"
                        )

                        guard status == 0 else {

                            throw NSError(
                                domain:
                                    "KunInstaller.AFC",
                                code:
                                    Int(status),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "AFC WRITE failed with status \(status)."
                                ]
                            )
                        }
                    }

                    self?.writeRSDDebug(
                        "AFC_WRITE_COMPLETE"
                    )

                    // ---------------------------------------------------------
                    // AFC FILE_CLOSE
                    // ---------------------------------------------------------

                    var closePacket =
                        Data()

                    closePacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let closeValues: [UInt64] = [
                        48,
                        48,
                        4,          // packet_num
                        20          // FILE_CLOSE
                    ]

                    for value in closeValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            closePacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var closeHandle =
                        fileHandle.littleEndian

                    withUnsafeBytes(
                        of:
                            &closeHandle
                    ) { rawBytes in

                        closePacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_FILE_CLOSE_SENDING handle=\(fileHandle) bytes=\(closePacket.count)"
                    )

                    try await connection.sendRaw(
                        closePacket
                    )

                    self?.writeRSDDebug(
                        "AFC_FILE_CLOSE_SENT"
                    )

                    let closeResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    guard closeResponseHeader.count == 40 else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                23,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC FILE_CLOSE response header was not 40 bytes."
                            ]
                        )
                    }

                    let closeHeaderBytes =
                        Array(
                            closeResponseHeader
                        )

                    let closeResponseEntireLength =
                        readUInt64LE(
                            closeHeaderBytes,
                            offset:
                                8
                        )

                    let closeResponsePacketNumber =
                        readUInt64LE(
                            closeHeaderBytes,
                            offset:
                                24
                        )

                    let closeResponseOperation =
                        readUInt64LE(
                            closeHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_FILE_CLOSE_RESPONSE_HEADER entire=\(closeResponseEntireLength) packet=\(closeResponsePacketNumber) operation=\(closeResponseOperation)"
                    )

                    let closeResponseBodyLength =
                        Int(
                            closeResponseEntireLength - 40
                        )

                    let closeResponseBody =
                        try await connection.receiveExact(
                            closeResponseBodyLength
                        )

                    if closeResponseOperation == 1 {

                        guard closeResponseBody.count >= 8 else {

                            throw NSError(
                                domain:
                                    "KunInstaller.AFC",
                                code:
                                    24,
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "AFC FILE_CLOSE STATUS response missing status value."
                                ]
                            )
                        }

                        let status =
                            readUInt64LE(
                                Array(closeResponseBody),
                                offset:
                                    0
                            )

                        self?.writeRSDDebug(
                            "AFC_FILE_CLOSE_STATUS=\(status)"
                        )

                        guard status == 0 else {

                            throw NSError(
                                domain:
                                    "KunInstaller.AFC",
                                code:
                                    Int(status),
                                userInfo: [
                                    NSLocalizedDescriptionKey:
                                        "AFC FILE_CLOSE failed with status \(status)."
                                ]
                            )
                        }
                    }

                    self?.writeRSDDebug(
                        "AFC_FILE_CLOSE_COMPLETE"
                    )

                    // ---------------------------------------------------------
                    // AFC READ-BACK: FILE_OPEN RDONLY
                    // ---------------------------------------------------------

                    var readOpenPacket =
                        Data()

                    readOpenPacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let readOpenEntireLength =
                        UInt64(
                            40 + 8 + testPathData.count
                        )

                    let readOpenValues: [UInt64] = [
                        readOpenEntireLength,
                        readOpenEntireLength,
                        5,      // packet_num
                        13      // FILE_OPEN
                    ]

                    for value in readOpenValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            readOpenPacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var readOnlyMode =
                        UInt64(1).littleEndian
                        // AFC RDONLY

                    withUnsafeBytes(
                        of:
                            &readOnlyMode
                    ) { rawBytes in

                        readOpenPacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    readOpenPacket.append(
                        testPathData
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_OPEN_SENDING path=\(testPath)"
                    )

                    try await connection.sendRaw(
                        readOpenPacket
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_OPEN_SENT"
                    )

                    let readOpenResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    let readOpenHeaderBytes =
                        Array(
                            readOpenResponseHeader
                        )

                    let readOpenResponseLength =
                        readUInt64LE(
                            readOpenHeaderBytes,
                            offset:
                                8
                        )

                    let readOpenResponsePacket =
                        readUInt64LE(
                            readOpenHeaderBytes,
                            offset:
                                24
                        )

                    let readOpenResponseOperation =
                        readUInt64LE(
                            readOpenHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_OPEN_RESPONSE_HEADER entire=\(readOpenResponseLength) packet=\(readOpenResponsePacket) operation=\(readOpenResponseOperation)"
                    )

                    guard
                        readOpenResponseLength >= 48
                    else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                30,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC read-open response."
                            ]
                        )
                    }

                    let readOpenBody =
                        try await connection.receiveExact(
                            Int(
                                readOpenResponseLength - 40
                            )
                        )

                    guard
                        readOpenResponseOperation == 14,
                        readOpenBody.count >= 8
                    else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                31,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC read-open did not return FILE_OPEN_RES."
                            ]
                        )
                    }

                    let readHandle =
                        readUInt64LE(
                            Array(readOpenBody),
                            offset:
                                0
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_HANDLE=\(readHandle)"
                    )

                    // ---------------------------------------------------------
                    // AFC READ
                    // ---------------------------------------------------------

                    var readPacket =
                        Data()

                    readPacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let readValues: [UInt64] = [
                        56,     // 40 header + 8 handle + 8 size
                        56,
                        6,      // packet_num
                        15      // READ
                    ]

                    for value in readValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            readPacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var readHandleLE =
                        readHandle.littleEndian

                    withUnsafeBytes(
                        of:
                            &readHandleLE
                    ) { rawBytes in

                        readPacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    var requestedReadSize =
                        UInt64(
                            testPayload.count
                        ).littleEndian

                    withUnsafeBytes(
                        of:
                            &requestedReadSize
                    ) { rawBytes in

                        readPacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_READ_SENDING handle=\(readHandle) requestedBytes=\(testPayload.count)"
                    )

                    try await connection.sendRaw(
                        readPacket
                    )

                    self?.writeRSDDebug(
                        "AFC_READ_SENT"
                    )

                    let readResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    let readResponseHeaderBytes =
                        Array(
                            readResponseHeader
                        )

                    let readResponseLength =
                        readUInt64LE(
                            readResponseHeaderBytes,
                            offset:
                                8
                        )

                    let readResponsePacket =
                        readUInt64LE(
                            readResponseHeaderBytes,
                            offset:
                                24
                        )

                    let readResponseOperation =
                        readUInt64LE(
                            readResponseHeaderBytes,
                            offset:
                                32
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_RESPONSE_HEADER entire=\(readResponseLength) packet=\(readResponsePacket) operation=\(readResponseOperation)"
                    )

                    guard
                        readResponseLength >= 40
                    else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                32,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC READ response length."
                            ]
                        )
                    }

                    let readResponseBody =
                        try await connection.receiveExact(
                            Int(
                                readResponseLength - 40
                            )
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_RESPONSE_BODY bytes=\(readResponseBody.count)"
                    )

                    guard readResponseOperation == 2 else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                33,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC READ did not return DATA."
                            ]
                        )
                    }

                    let readText =
                        String(
                            data:
                                readResponseBody,
                            encoding:
                                .utf8
                        ) ?? ""

                    self?.writeRSDDebug(
                        "AFC_READ_DATA=\(readText)"
                    )

                    guard readResponseBody == testPayload else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                34,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC read-back did not match written payload."
                            ]
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_READ_VERIFY_SUCCESS"
                    )

                    // ---------------------------------------------------------
                    // Close read handle
                    // ---------------------------------------------------------

                    var readClosePacket =
                        Data()

                    readClosePacket.append(
                        Data(
                            "CFA6LPAA".utf8
                        )
                    )

                    let readCloseValues: [UInt64] = [
                        48,
                        48,
                        7,      // packet_num
                        20      // FILE_CLOSE
                    ]

                    for value in readCloseValues {

                        var littleEndianValue =
                            value.littleEndian

                        withUnsafeBytes(
                            of:
                                &littleEndianValue
                        ) { rawBytes in

                            readClosePacket.append(
                                contentsOf:
                                    rawBytes
                            )
                        }
                    }

                    var readCloseHandle =
                        readHandle.littleEndian

                    withUnsafeBytes(
                        of:
                            &readCloseHandle
                    ) { rawBytes in

                        readClosePacket.append(
                            contentsOf:
                                rawBytes
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_READ_CLOSE_SENDING handle=\(readHandle)"
                    )

                    try await connection.sendRaw(
                        readClosePacket
                    )

                    let readCloseResponseHeader =
                        try await connection.receiveExact(
                            40
                        )

                    let readCloseHeaderBytes =
                        Array(
                            readCloseResponseHeader
                        )

                    let readCloseResponseLength =
                        readUInt64LE(
                            readCloseHeaderBytes,
                            offset:
                                8
                        )

                    let readCloseResponsePacket =
                        readUInt64LE(
                            readCloseHeaderBytes,
                            offset:
                                24
                        )

                    let readCloseResponseOperation =
                        readUInt64LE(
                            readCloseHeaderBytes,
                            offset:
                                32
                        )

                    let readCloseResponseBody =
                        try await connection.receiveExact(
                            Int(
                                readCloseResponseLength - 40
                            )
                        )

                    guard
                        readCloseResponseOperation == 1,
                        readCloseResponseBody.count >= 8
                    else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                35,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Invalid AFC read-close response."
                            ]
                        )
                    }

                    let readCloseStatus =
                        readUInt64LE(
                            Array(readCloseResponseBody),
                            offset:
                                0
                        )

                    self?.writeRSDDebug(
                        "AFC_READ_CLOSE_RESPONSE packet=\(readCloseResponsePacket) operation=\(readCloseResponseOperation) status=\(readCloseStatus)"
                    )

                    guard readCloseStatus == 0 else {

                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                Int(readCloseStatus),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "AFC read handle close failed."
                            ]
                        )
                    }

                    self?.writeRSDDebug(
                        "AFC_READBACK_COMPLETE"
                    )

                    guard
                        let container =
                            FileManager.default.containerURL(
                                forSecurityApplicationGroupIdentifier:
                                    KhmerInstallerConfig.appGroupID
                            )
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                200,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "App Group unavailable for IPA upload."
                            ]
                        )
                    }

                    let ipaDirectory =
                        container.appendingPathComponent(
                            "IPA",
                            isDirectory:
                                true
                        )

                    // KI_AFC_CAPTURED_IPA_FILENAME
                    // Use the identity captured when installation began.
                    let selectedIPAFileName =
                        installationIdentity.filename

                    guard
                        !selectedIPAFileName.isEmpty
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                201,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "No selected IPA has been recorded."
                            ]
                        )
                    }

                    self?.writeRSDDebug(
                        "IPA_SELECTED_FILE=\(selectedIPAFileName)"
                    )

                    let ipaURL =
                        ipaDirectory.appendingPathComponent(
                            selectedIPAFileName
                        )

                    guard
                        FileManager.default.fileExists(
                            atPath:
                                ipaURL.path
                        )
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                202,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Selected IPA file is missing: \(selectedIPAFileName)"
                            ]
                        )
                    }

                    let selectedIPAValues =
                        try ipaURL.resourceValues(
                            forKeys: [
                                .fileSizeKey,
                                .isRegularFileKey
                            ]
                        )

                    guard
                        selectedIPAValues.isRegularFile == true
                    else {
                        throw NSError(
                            domain:
                                "KunInstaller.AFC",
                            code:
                                203,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Selected IPA is not a regular file."
                            ]
                        )
                    }

                    self?.writeRSDDebug(
                        "IPA_SELECTED_PATH=\(ipaURL.path) bytes=\(selectedIPAValues.fileSize ?? 0)"
                    )

                    let remoteIPAPath =
                        "/PublicStaging/pymobiledevice3/" +
                        ipaURL.lastPathComponent

                    self?.writeRSDDebug(
                        "IPA_UPLOAD_START file=\(ipaURL.lastPathComponent)"
                    )

                    guard let self else {
                        connection.cancel()
                        return
                    }

                    try await self.uploadIPAOverAFC(
                        connection:
                            connection,
                        sourceURL:
                            ipaURL,
                        remotePath:
                            remoteIPAPath,
                        expectedSHA256:
                            installationIdentity.sha256,
                        selectionID:
                            installationIdentity.installationID
                    )

                    self.writeRSDDebug(
                        "IPA_UPLOAD_REMOTE_PATH=\(remoteIPAPath)"
                    )

                    connection.cancel()

                } catch {

                    self?.writeRSDDebug(
                        "AFC_PROBE_FAILED \(error.localizedDescription)"
                    )

                    // KI_AFC_JSON_ASYNC_FAILURE
                    _ = self?.publishInstallationStatus(
                        installationID:
                            installationIdentity.installationID,
                        phase: "failed",
                        progress: nil,
                        detail: "IPA upload failed: \(error.localizedDescription)",
                        terminal: true
                    )

                    // KI_AFC_FAILURE_TASK
                    self?.writeIPAUploadFailureMarker(
                        selectionID: installationIdentity.installationID
                    )

                }
            }

        } catch {

            writeRSDDebug(
                "AFC_PROBE_SETUP_FAILED \(error.localizedDescription)"
            )

            // KI_AFC_JSON_SETUP_FAILURE
            _ = publishInstallationStatus(
                installationID:
                    installationIdentity.installationID,
                phase: "failed",
                progress: nil,
                detail: "AFC setup failed: \(error.localizedDescription)",
                terminal: true
            )

            // KI_AFC_FAILURE_SETUP
            writeIPAUploadFailureMarker(
                selectionID: installationIdentity.installationID
            )
        }
    }

    private func readUInt64LE(
        _ bytes: [UInt8],
        offset: Int
    ) -> UInt64 {

        var value: UInt64 = 0

        for index in 0..<8 {

            value |=
                UInt64(
                    bytes[offset + index]
                ) << UInt64(
                    index * 8
                )
        }

        return value
    }

    private func uploadIPAOverAFC(
        connection: RemoteXPC,
        sourceURL: URL,
        remotePath: String,
        expectedSHA256: String,
        selectionID: String
    ) async throws {

        let fileManager =
            FileManager.default

        let attributes =
            try fileManager.attributesOfItem(
                atPath:
                    sourceURL.path
            )

        let sourceSize =
            (attributes[.size] as? NSNumber)?
                .uint64Value ?? 0

        writeRSDDebug(
            "IPA_UPLOAD_SOURCE=\(sourceURL.lastPathComponent)"
        )

        writeRSDDebug(
            "IPA_UPLOAD_SOURCE_BYTES=\(sourceSize)"
        )

        let destinationPathData =
            Data(
                (remotePath + "\0").utf8
            )

        let fileOpenEntireLength =
            UInt64(
                40 +
                8 +
                destinationPathData.count
            )

        var openPacket =
            Data()

        openPacket.append(
            Data(
                "CFA6LPAA".utf8
            )
        )

        let openValues: [UInt64] = [
            fileOpenEntireLength,
            fileOpenEntireLength,
            100,
            13
        ]

        for value in openValues {

            var littleEndianValue =
                value.littleEndian

            withUnsafeBytes(
                of:
                    &littleEndianValue
            ) { rawBytes in

                openPacket.append(
                    contentsOf:
                        rawBytes
                )
            }
        }

        var writeOnlyMode =
            UInt64(3).littleEndian

        withUnsafeBytes(
            of:
                &writeOnlyMode
        ) { rawBytes in

            openPacket.append(
                contentsOf:
                    rawBytes
            )
        }

        openPacket.append(
            destinationPathData
        )

        writeRSDDebug(
            "IPA_UPLOAD_OPEN path=\(remotePath) bytes=\(openPacket.count)"
        )

        try await connection.sendRaw(
            openPacket
        )

        let openResponseHeader =
            try await connection.receiveExact(
                40
            )

        let openHeaderBytes =
            Array(
                openResponseHeader
            )

        let openResponseLength =
            readUInt64LE(
                openHeaderBytes,
                offset:
                    8
            )

        let openResponseOperation =
            readUInt64LE(
                openHeaderBytes,
                offset:
                    32
            )

        guard
            openResponseLength >= 40
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    100,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid IPA FILE_OPEN response."
                ]
            )
        }

        let openResponseBody =
            try await connection.receiveExact(
                Int(
                    openResponseLength - 40
                )
            )

        guard
            openResponseOperation == 14,
            openResponseBody.count >= 8
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    101,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "IPA FILE_OPEN did not return a handle."
                ]
            )
        }

        let fileHandle =
            readUInt64LE(
                Array(openResponseBody),
                offset:
                    0
            )

        writeRSDDebug(
            "IPA_UPLOAD_HANDLE=\(fileHandle)"
        )

        let input =
            try FileHandle(
                forReadingFrom:
                    sourceURL
            )

        defer {
            try? input.close()
        }

        let chunkSize =
            64 * 1024

        var packetNumber: UInt64 =
            101

        var written: UInt64 =
            0

        // KI_AFC_STREAM_SHA256
        var uploadHasher = SHA256()

        // KI_AFC_JSON_PROGRESS_TRACKER
        var lastPublishedPercent = -1

        while true {
            try Task.checkCancellation()
            if isInstallationCancelled(selectionID) {
                throw CancellationError()
            }

            let chunk =
                try input.read(
                    upToCount:
                        chunkSize
                ) ?? Data()

            if chunk.isEmpty {
                break
            }

            uploadHasher.update(data: chunk)

            let entireLength =
                UInt64(
                    48 +
                    chunk.count
                )

            var writePacket =
                Data()

            writePacket.append(
                Data(
                    "CFA6LPAA".utf8
                )
            )

            let writeValues: [UInt64] = [
                entireLength,
                48,
                packetNumber,
                16
            ]

            for value in writeValues {

                var littleEndianValue =
                    value.littleEndian

                withUnsafeBytes(
                    of:
                        &littleEndianValue
                ) { rawBytes in

                    writePacket.append(
                        contentsOf:
                            rawBytes
                    )
                }
            }

            var littleEndianHandle =
                fileHandle.littleEndian

            withUnsafeBytes(
                of:
                    &littleEndianHandle
            ) { rawBytes in

                writePacket.append(
                    contentsOf:
                        rawBytes
                )
            }

            writePacket.append(
                chunk
            )

            try await connection.sendRaw(
                writePacket
            )

            let responseHeader =
                try await connection.receiveExact(
                    40
                )

            let responseHeaderBytes =
                Array(
                    responseHeader
                )

            let responseLength =
                readUInt64LE(
                    responseHeaderBytes,
                    offset:
                        8
                )

            let responseOperation =
                readUInt64LE(
                    responseHeaderBytes,
                    offset:
                        32
                )

            guard
                responseLength >= 40
            else {
                throw NSError(
                    domain:
                        "KunInstaller.AFC",
                    code:
                        102,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Invalid AFC WRITE response."
                    ]
                )
            }

            let responseBody =
                try await connection.receiveExact(
                    Int(
                        responseLength - 40
                    )
                )

            guard
                responseOperation == 1,
                responseBody.count >= 8
            else {
                throw NSError(
                    domain:
                        "KunInstaller.AFC",
                    code:
                        103,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AFC WRITE did not return STATUS."
                    ]
                )
            }

            let status =
                readUInt64LE(
                    Array(responseBody),
                    offset:
                        0
                )

            guard status == 0 else {
                throw NSError(
                    domain:
                        "KunInstaller.AFC",
                    code:
                        Int(status),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "AFC WRITE failed with status \(status)."
                    ]
                )
            }

            written +=
                UInt64(
                    chunk.count
                )

            // KI_AFC_JSON_UPLOAD_PROGRESS
            // Update diagnostic and UI progress only when the
            // integer percentage changes, not for every AFC packet.
            if sourceSize > 0 {
                let percent = Int(
                    min(
                        (Double(written) / Double(sourceSize)) * 100,
                        100
                    )
                )

                if percent != lastPublishedPercent {
                    writeRSDDebug(
                        "IPA_UPLOAD_PROGRESS=\(written)/\(sourceSize) percent=\(percent)"
                    )

                    let published = publishInstallationStatus(
                        installationID: selectionID,
                        phase: "uploading",
                        progress: Double(percent) / 100.0,
                        detail: "Uploading IPA to Apple TV...",
                        terminal: false
                    )

                    if published {
                        lastPublishedPercent = percent
                    }
                }
            }

            packetNumber +=
                1
        }

        writeRSDDebug(
            "IPA_UPLOAD_WRITTEN_BYTES=\(written)"
        )

        // FILE_CLOSE
        var closePacket =
            Data()

        closePacket.append(
            Data(
                "CFA6LPAA".utf8
            )
        )

        let closeValues: [UInt64] = [
            48,
            48,
            packetNumber,
            20
        ]

        for value in closeValues {

            var littleEndianValue =
                value.littleEndian

            withUnsafeBytes(
                of:
                    &littleEndianValue
            ) { rawBytes in

                closePacket.append(
                    contentsOf:
                        rawBytes
                )
            }
        }

        var closeHandle =
            fileHandle.littleEndian

        withUnsafeBytes(
            of:
                &closeHandle
        ) { rawBytes in

            closePacket.append(
                contentsOf:
                    rawBytes
            )
        }

        try await connection.sendRaw(
            closePacket
        )

        let closeResponseHeader =
            try await connection.receiveExact(
                40
            )

        let closeHeaderBytes =
            Array(
                closeResponseHeader
            )

        let closeResponseLength =
            readUInt64LE(
                closeHeaderBytes,
                offset:
                    8
            )

        let closeResponseOperation =
            readUInt64LE(
                closeHeaderBytes,
                offset:
                    32
            )

        let closeResponseBody =
            try await connection.receiveExact(
                Int(
                    closeResponseLength - 40
                )
            )

        guard
            closeResponseOperation == 1,
            closeResponseBody.count >= 8
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    104,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Invalid AFC CLOSE response."
                ]
            )
        }

        let closeStatus =
            readUInt64LE(
                Array(closeResponseBody),
                offset:
                    0
            )

        guard closeStatus == 0 else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    Int(closeStatus),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "AFC FILE_CLOSE failed with status \(closeStatus)."
                ]
            )
        }

        writeRSDDebug(
            "IPA_UPLOAD_CLOSE_STATUS=\(closeStatus)"
        )

        guard
            written == sourceSize
        else {
            throw NSError(
                domain:
                    "KunInstaller.AFC",
                code:
                    105,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "IPA upload byte count mismatch."
                ]
            )
        }

        // KI_AFC_UPLOAD_SHA256_VERIFY
        // Never publish a successful upload marker for
        // bytes that differ from the selected IPA metadata.
        let uploadedSHA256 = uploadHasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()

        guard uploadedSHA256 == expectedSHA256 else {
            throw NSError(
                domain: "KhmerInstaller.AFC",
                code: 305,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "IPA changed during upload."
                ]
            )
        }

        try writeIPAUploadMarker(
            remotePath: remotePath,
            selectionID: selectionID
        )

        writeRSDDebug(
            "IPA_UPLOAD_MARKER_WRITTEN path=\(remotePath)"
        )

        writeRSDDebug(
            "IPA_UPLOAD_COMPLETE bytes=\(written)"
        )
    }

    private func containsBundleIdentifier(
        _ value: Any,
        bundleIdentifier: String
    ) -> Bool {

        if let stringValue = value as? String {
            return stringValue == bundleIdentifier
        }

        if let dictionary = value as? [String: Any] {
            for (_, child) in dictionary {
                if containsBundleIdentifier(
                    child,
                    bundleIdentifier:
                        bundleIdentifier
                ) {
                    return true
                }
            }

            return false
        }

        if let array = value as? [Any] {
            for child in array {
                if containsBundleIdentifier(
                    child,
                    bundleIdentifier:
                        bundleIdentifier
                ) {
                    return true
                }
            }

            return false
        }

        return false
    }

    private func startInstallationProxyProbe(
        address: String,
        port installationProxyPort: Int,
        installationIdentity: InstallationIdentity
    ) {

        writeRSDDebug(
            "INSTALL_PROXY_CONNECTING address=\(address) port=\(installationProxyPort)"
        )

        guard let virtualInterface else {

            writeRSDDebug(
                "INSTALL_PROXY_FAILED virtualInterface=NIL"
            )

            return
        }

        do {

            let connection =
                try RemoteXPC(
                    address:
                        address,
                    port:
                        installationProxyPort,
                    interface:
                        virtualInterface
                )

            guard registerInstallationWorker(
                installationIdentity.installationID,
                role: "proxy", connection: connection
            ) else {
                connection.cancel()
                return
            }

            Task { [weak self, connection] in
                defer {
                    connection.cancel()
                    self?.installationWorkerEnded(
                        installationIdentity.installationID, role: "proxy"
                    )
                }


                // KI_PROXY_TERMINAL_RESULT
                var terminalResultReported = false

                defer {
                    if !terminalResultReported,
                       let self,
                       self.ownsInstallationSession(
                           installationIdentity.installationID
                       ) {
                        // KI_PROXY_JSON_FALLBACK
                        _ = self.publishInstallationStatus(
                            installationID:
                                installationIdentity.installationID,
                            phase: "failed",
                            progress: nil,
                            detail: "Installation ended unexpectedly.",
                            terminal: true
                        )

                        // KI_PROXY_SESSION_TERMINAL_FALLBACK
                        _ = self.publishInstallationTerminalStatus(
                            "INSTALL_PROXY_FAILED incomplete_proxy_session",
                            installationID:
                                installationIdentity.installationID
                        )
                    }

                    self?.finishInstallationSession(
                        installationIdentity.installationID
                    )
                }

                do {

                    var serviceReceiveBuffer =
                        Data()

                    try await
                        connection.connect()

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_TCP_CONNECTED port=\(installationProxyPort)"
                    )

                    let checkin =
                        try self?.installationProxyPlistFrame(
                            [
                                "Label":
                                    "KunInstaller",

                                "ProtocolVersion":
                                    "2",

                                "Request":
                                    "RSDCheckin"
                            ]
                        )

                    guard let checkin else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_CHECKIN_BUILD_FAILED"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_RSDCHECKIN_SENDING bytes=\(checkin.count)"
                    )

                    try await
                        connection.sendRaw(
                            checkin
                        )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_RSDCHECKIN_SENT"
                    )

                    let checkinResponse =
                        try await
                            self?.receiveInstallationProxyPlist(
                                from:
                                    connection,
                                buffer:
                                    &serviceReceiveBuffer
                            )

                    guard let checkinResponse else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_RSDCHECKIN_RESPONSE_MISSING"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_RSDCHECKIN_RESPONSE=\(checkinResponse)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STATE_AFTER_CHECKIN=\(connection.debugTCPConnectionState())"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_AFTER_CHECKIN bufferBytes=\(serviceReceiveBuffer.count)"
                    )

                    guard
                        (checkinResponse["Request"] as? String)
                            == "RSDCheckin"
                    else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_RSDCHECKIN_UNEXPECTED_RESPONSE"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_BEFORE_STARTSERVICE_BLOCK"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_PARSE_DIRECT bufferBytes=\(serviceReceiveBuffer.count)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_RECEIVE_BEGIN"
                    )

                    let startServiceChunk =
                        try await connection.receiveRaw(
                            maximumLength: 65536
                        )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_RECEIVED bytes=\(startServiceChunk.count)"
                    )

                    serviceReceiveBuffer.append(
                        startServiceChunk
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_BUFFER_AFTER_RECEIVE bufferBytes=\(serviceReceiveBuffer.count)"
                    )

                    let startServiceResponse =
                        try self?.parseInstallationProxyPlist(
                            from:
                                &serviceReceiveBuffer
                        )

                    guard let startServiceResponse else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_STARTSERVICE_RESPONSE_MISSING"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_DIRECT_PARSED bufferBytes=\(serviceReceiveBuffer.count)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_STARTSERVICE_RESPONSE=\(startServiceResponse)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_AFTER_STARTSERVICE_BLOCK"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_SERVICE_READY"
                    )

                    let lookup =
                        try self?.installationProxyPlistFrame(
                            [
                                "Command":
                                    "Lookup",

                                "ClientOptions":
                                    [String: Any]()
                            ]
                        )

                    guard let lookup else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_LOOKUP_BUILD_FAILED"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_LOOKUP_SENDING bytes=\(lookup.count)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_LOOKUP_HEX=" +
                        lookup.map {
                            String(format: "%02x", $0)
                        }.joined()
                    )

                    try await
                        connection.sendRaw(
                            lookup
                        )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_LOOKUP_SENT"
                    )

                    let lookupResponse =
                        try await
                            self?.receiveInstallationProxyPlist(
                                from:
                                    connection,
                                buffer:
                                    &serviceReceiveBuffer
                            )

                    guard let lookupResponse else {

                        self?.writeRSDDebug(
                            "INSTALL_PROXY_LOOKUP_RESPONSE_MISSING"
                        )

                        connection.cancel()

                        return
                    }

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_LOOKUP_RESPONSE=\(lookupResponse)"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_LOOKUP_PROBE_COMPLETE"
                    )

                    self?.writeRSDDebug(
                        "INSTALL_PROXY_WAITING_FOR_IPA_UPLOAD"
                    )

                    guard let self else {
                        connection.cancel()
                        return
                    }

                    let installPackagePath =
                        try await
                            self.waitForIPAUploadCompletion(
                                    selectionID: installationIdentity.installationID
                                )

                    self.writeRSDDebug(
                        "INSTALL_PROXY_INSTALL_PACKAGE_PATH=\(installPackagePath)"
                    )

                    let install =
                        try self.installationProxyPlistFrame(
                            [
                                "Command":
                                    "Install",

                                "PackagePath":
                                    installPackagePath,

                                "ClientOptions":
                                    [String: Any]()
                            ]
                        )

                    self.writeRSDDebug(
                        "INSTALL_PROXY_INSTALL_SENDING path=\(installPackagePath) bytes=\(install.count)"
                    )

                    try await connection.sendRaw(
                        install
                    )

                    self.writeRSDDebug(
                        "INSTALL_PROXY_INSTALL_SENT"
                    )

                    while true {

                        let installResponse =
                            try await self.receiveInstallationProxyPlist(
                                from:
                                    connection,
                                buffer:
                                    &serviceReceiveBuffer
                            )

                        self.writeRSDDebug(
                            "INSTALL_PROXY_INSTALL_RESPONSE=\(installResponse)"
                        )

                        if let percentComplete =
                            installResponse["PercentComplete"] {

                            self.writeRSDDebug(
                                "INSTALL_PROXY_INSTALL_PROGRESS=\(percentComplete)"
                            )

                            // KI_PROXY_JSON_INSTALL_PROGRESS
                            if let number = percentComplete as? NSNumber {
                                let percentage = number.doubleValue

                                if percentage.isFinite,
                                   percentage >= 0,
                                   percentage <= 100 {
                                    _ = self.publishInstallationStatus(
                                        installationID:
                                            installationIdentity.installationID,
                                        phase: "installing",
                                        progress: percentage / 100.0,
                                        detail: "Installing app on Apple TV...",
                                        terminal: false
                                    )
                                }
                            }
                        }

                        if let error =
                            installResponse["Error"] {

                            // KI_PROXY_SESSION_TERMINAL_ERROR
                            _ = self.publishInstallationTerminalStatus(
                                "INSTALL_PROXY_INSTALL_ERROR=\(error)",
                                installationID:
                                    installationIdentity.installationID
                            )

                            if let description =
                                installResponse[
                                    "ErrorDescription"
                                ] {

                                self.writeRSDDebug(
                                    "INSTALL_PROXY_INSTALL_ERROR_DESCRIPTION=\(description)"
                                )
                            }

                            // KI_PROXY_JSON_INSTALL_ERROR
                            _ = self.publishInstallationStatus(
                                installationID:
                                    installationIdentity.installationID,
                                phase: "failed",
                                progress: nil,
                                detail: "Apple TV installation failed: \(error)",
                                terminal: true
                            )

                            terminalResultReported = true

                            // KI_INSTALL_SESSION_INSTALL_ERROR
                            self.finishInstallationSession(
                                installationIdentity.installationID
                            )

                            break
                        }

                        if let status =
                            installResponse["Status"] as? String {

                            self.writeRSDDebug(
                                "INSTALL_PROXY_INSTALL_STATUS=\(status)"
                            )

                            if status == "Complete" {

                                self.writeRSDDebug(
                                    "INSTALL_PROXY_INSTALL_COMPLETE"
                                )

                                self.writeRSDDebug(
                                    "POST_INSTALL_LOOKUP_SENDING"
                                )

                                // KI_PROXY_JSON_VERIFYING
                                _ = self.publishInstallationStatus(
                                    installationID:
                                        installationIdentity.installationID,
                                    phase: "verifying",
                                    progress: nil,
                                    detail: "Verifying app on Apple TV...",
                                    terminal: false
                                )

                                let postInstallLookup =
                                    try self.installationProxyPlistFrame(
                                        [
                                            "Command":
                                                "Lookup",

                                            "ClientOptions":
                                                [String: Any]()
                                        ]
                                    )

                                try await connection.sendRaw(
                                    postInstallLookup
                                )

                                self.writeRSDDebug(
                                    "POST_INSTALL_LOOKUP_SENT bytes=\(postInstallLookup.count)"
                                )

                                let postInstallLookupResponse =
                                    try await
                                        self.receiveInstallationProxyPlist(
                                            from:
                                                connection,
                                            buffer:
                                                &serviceReceiveBuffer
                                        )

                                self.writeRSDDebug(
                                    "POST_INSTALL_LOOKUP_RESPONSE=\(postInstallLookupResponse)"
                                )

                                // KI_DYNAMIC_BUNDLE_VERIFICATION
                                let installed =
                                    self.containsBundleIdentifier(
                                        postInstallLookupResponse,
                                        bundleIdentifier:
                                            installationIdentity.bundleID
                                    )

                                self.writeRSDDebug(
                                    "POST_INSTALL_LOOKUP_FOUND=\(installed) bundleID=\(installationIdentity.bundleID)"
                                )

                                if installed {
                                    // KI_PROXY_SESSION_TERMINAL_SUCCESS
                                    _ = self.publishInstallationTerminalStatus(
                                        "POST_INSTALL_VERIFICATION_SUCCESS bundleID=\(installationIdentity.bundleID)",
                                        installationID:
                                            installationIdentity.installationID
                                    )
                                } else {
                                    // KI_PROXY_SESSION_TERMINAL_VERIFY_FAILURE
                                    _ = self.publishInstallationTerminalStatus(
                                        "POST_INSTALL_VERIFICATION_FAILED bundleID=\(installationIdentity.bundleID)",
                                        installationID:
                                            installationIdentity.installationID
                                    )
                                }

                                // KI_PROXY_JSON_VERIFICATION_RESULT
                                _ = self.publishInstallationStatus(
                                    installationID:
                                        installationIdentity.installationID,
                                    phase: installed ? "complete" : "failed",
                                    progress: installed ? 1.0 : nil,
                                    detail: installed
                                        ? "App installed and verified on Apple TV."
                                        : "Post-install verification failed.",
                                    terminal: true
                                )

                                terminalResultReported = true

                                // KI_INSTALL_SESSION_VERIFICATION_FINISH
                                self.finishInstallationSession(
                                    installationIdentity.installationID
                                )

                                break
                            }
                        }
                    }

                    connection.cancel()

                } catch {

                    terminalResultReported = true

                    // KI_PROXY_JSON_EXCEPTION
                    _ = self?.publishInstallationStatus(
                        installationID:
                            installationIdentity.installationID,
                        phase: "failed",
                        progress: nil,
                        detail: "Installation failed: \(error.localizedDescription)",
                        terminal: true
                    )

                    // KI_PROXY_SESSION_TERMINAL_EXCEPTION
                    _ = self?.publishInstallationTerminalStatus(
                        "INSTALL_PROXY_FAILED \(error.localizedDescription)",
                        installationID:
                            installationIdentity.installationID
                    )

                    // KI_INSTALL_SESSION_PROXY_FAILURE
                    self?.finishInstallationSession(
                        installationIdentity.installationID
                    )

                }
            }

        } catch {

            // KI_PROXY_JSON_SETUP_FAILURE
            _ = publishInstallationStatus(
                installationID:
                    installationIdentity.installationID,
                phase: "failed",
                progress: nil,
                detail: "Installation Proxy setup failed: \(error.localizedDescription)",
                terminal: true
            )

            // KI_PROXY_SESSION_TERMINAL_SETUP
            _ = publishInstallationTerminalStatus(
                "INSTALL_PROXY_FAILED setup=\(error.localizedDescription)",
                installationID:
                    installationIdentity.installationID
            )

            // KI_PROXY_SETUP_SESSION_RELEASE
            finishInstallationSession(
                installationIdentity.installationID
            )
        }
    }

    private func startRSDProbe(
        address: String,
        port: Int,
        udidCompletion: ((String?) -> Void)? = nil,
        silent: Bool = false,
        installationIdentity: InstallationIdentity? = nil
    ) {
        func debugLog(_ message: String) {
            if !silent {
                writeRSDDebug(message)
            }
        }



        if !silent {

            debugLog(
                "START_RSD_ENTER address=\(address) port=\(port)"
            )
        }

        let ipaDirectory =
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier:
                    KhmerInstallerConfig.appGroupID
            )?.appendingPathComponent(
                "IPA",
                isDirectory:
                    true
            )

        debugLog(
            "IPA_CHECK_DIRECTORY=\(ipaDirectory?.path ?? "NIL")"
        )

        if let ipaDirectory {

            do {

                let ipaFiles =
                    try FileManager.default.contentsOfDirectory(
                        at:
                            ipaDirectory,
                        includingPropertiesForKeys: [
                            .fileSizeKey
                        ],
                        options: [
                            .skipsHiddenFiles
                        ]
                    )

                debugLog(
                    "IPA_SHARED_FILE_COUNT=\(ipaFiles.count)"
                )

                for ipaURL in ipaFiles {

                    let values =
                        try ipaURL.resourceValues(
                            forKeys: [
                                .fileSizeKey
                            ]
                        )

                    debugLog(
                        "IPA_SHARED_FILE=\(ipaURL.lastPathComponent) bytes=\(values.fileSize ?? 0)"
                    )
                }

            } catch {

                debugLog(
                    "IPA_SHARED_READ_FAILED \(error.localizedDescription)"
                )
            }

        } else {

            debugLog(
                "IPA_SHARED_DIRECTORY_NIL"
            )
        }

        debugLog(
            "START_RSD_AFTER_CLEAR address=\(address) port=\(port)"
        )




        guard let virtualInterface else {

            // KI_RSD_SESSION_INTERFACE_FAILURE
            if let installationIdentity {
                // KI_RSD_JSON_INTERFACE_FAILURE
                _ = publishInstallationStatus(
                    installationID:
                        installationIdentity.installationID,
                    phase: "failed",
                    progress: nil,
                    detail: "Apple TV network interface unavailable.",
                    terminal: true
                )

                // KI_RSD_TERMINAL_INTERFACE
                _ = publishInstallationTerminalStatus(
                    "INSTALL_RSD_FAILED virtualInterface=NIL",
                    installationID:
                        installationIdentity.installationID
                )
                finishInstallationSession(
                    installationIdentity.installationID
                )
            }


            return
        }

        do {

            let remoteXPC =
                try RemoteXPC(
                    address:
                        address,
                    port:
                        port,
                    interface:
                        virtualInterface
                )

            rsdRemoteXPC =
                remoteXPC

            let handshakeUUID =
                UUID()


            if let installationIdentity {
                guard registerInstallationWorker(
                    installationIdentity.installationID,
                    role: "rsd", connection: remoteXPC
                ) else {
                    remoteXPC.cancel()
                    return
                }
            }

            Task { [weak self, remoteXPC] in
                defer {
                    if installationIdentity != nil { remoteXPC.cancel() }
                    if let installationIdentity {
                        self?.installationWorkerEnded(
                            installationIdentity.installationID, role: "rsd"
                        )
                    }
                }


                do {

                    debugLog(
                        "CONNECTING_THROUGH_VIRTUAL_INTERFACE"
                    )


                    try await
                        remoteXPC.connect()

                    debugLog(
                        "TCP_CONNECTED"
                    )


                    debugLog(
                        "SENDING_HANDSHAKE"
                    )


                    try await
                        remoteXPC.sendInitialHandshake(
                            hostUUID:
                                handshakeUUID
                        )

                    debugLog(
                        "HANDSHAKE_SENT"
                    )


                    debugLog(
                        "WAITING_FOR_RESPONSE"
                    )


                    let response =
                        try await
                            remoteXPC.receiveFirstResponse()

                    debugLog(
                        "FIRST_RESPONSE_RECEIVED bytes=\(response.count)"
                    )

                    debugLog(
                        "RSD_BEFORE_RESPONSE_SUMMARY"
                    )

                    let frameSummary =
                        remoteXPC.debugResponseSummary(
                            response
                        )

                    if let udidCompletion {
                        let prefix = "XPC_UNIQUE_DEVICE_ID="

                        let udid =
                            frameSummary
                                .components(separatedBy: "\n")
                                .first {
                                    $0.hasPrefix(prefix)
                                }
                                .map {
                                    String($0.dropFirst(prefix.count))
                                }

                        udidCompletion(
                            udid == "NOT_FOUND" ? nil : udid
                        )

                        remoteXPC.cancel()
                        self?.rsdRemoteXPC = nil

                        return
                    }

                    debugLog(
                        "RSD_AFTER_RESPONSE_SUMMARY"
                    )

                    debugLog(
                        frameSummary
                    )

                    debugLog(
                        remoteXPC.debugBufferedHTTP2Frames()
                    )

                    // KI_RSD_REQUIRED_SERVICES_PREFLIGHT
                    // Both services must exist before either starts.
                    if let installationIdentity {
                        let discoveredAFCPort =
                            self?.extractAFCPort(
                                from: frameSummary
                            )

                        let discoveredProxyPort =
                            self?.extractInstallationProxyPort(
                                from: frameSummary
                            )

                        guard discoveredAFCPort != nil,
                              discoveredProxyPort != nil else {
                            // KI_RSD_JSON_SERVICE_FAILURE
                            _ = self?.publishInstallationStatus(
                                installationID:
                                    installationIdentity.installationID,
                                phase: "failed",
                                progress: nil,
                                detail: "Required Apple TV services unavailable.",
                                terminal: true
                            )

                            // KI_RSD_TERMINAL_SERVICES
                            _ = self?.publishInstallationTerminalStatus(
                                "INSTALL_RSD_FAILED required_service_missing",
                                installationID:
                                    installationIdentity.installationID
                            )

                            self?.finishInstallationSession(
                                installationIdentity.installationID
                            )

                            remoteXPC.cancel()
                            self?.rsdRemoteXPC = nil
                            return
                        }
                    }

                    debugLog(
                        "RSD_BEFORE_AFC_DISCOVERY"
                    )

                    if let afcPort =
                        self?.extractAFCPort(
                            from: frameSummary
                        ) {

                        debugLog(
                            "AFC_DISCOVERY_CHECK_SUCCESS port=\(afcPort)"
                        )

                        // KI_AFC_IMMUTABLE_INSTALL_IDENTITY
                        if let installationIdentity {
                            self?.startAFCProbe(
                                address: address,
                                port: afcPort,
                                installationIdentity: installationIdentity
                            )
                        } else {
                            debugLog(
                                "AFC_PROBE_FAILED missing_installation_identity"
                            )
                        }

                    } else {

                        debugLog(
                            "AFC_PORT_DISCOVERY_FAILED"
                        )
                    }

                    if let installationProxyPort =
                        self?.extractInstallationProxyPort(
                            from: frameSummary
                        ) {

                        debugLog(
                            "INSTALL_PROXY_PORT_DISCOVERED=\(installationProxyPort)"
                        )

                        debugLog(
                            "STARTING_INSTALL_PROXY_PROBE"
                        )

                        // KI_DYNAMIC_INSTALL_PROXY_IDENTITY
                        if let installationIdentity {
                            self?.startInstallationProxyProbe(
                                address: address,
                                port: installationProxyPort,
                                installationIdentity: installationIdentity
                            )
                        } else {
                            debugLog(
                                "INSTALL_PROXY_FAILED missing_installation_identity"
                            )
                        }

                    } else {

                        debugLog(
                            "INSTALL_PROXY_PORT_DISCOVERY_FAILED"
                        )
                    }




                } catch {

                    debugLog(
                        "FAILED error=\(error.localizedDescription)"
                    )

                    // KI_RSD_ASYNC_SESSION_FAILURE
                    if let installationIdentity {
                        // KI_RSD_JSON_ASYNC_FAILURE
                        _ = self?.publishInstallationStatus(
                            installationID:
                                installationIdentity.installationID,
                            phase: "failed",
                            progress: nil,
                            detail: "Apple TV connection failed: \(error.localizedDescription)",
                            terminal: true
                        )

                        // KI_RSD_TERMINAL_ASYNC
                        _ = self?.publishInstallationTerminalStatus(
                            "INSTALL_RSD_FAILED async=\(error.localizedDescription)",
                            installationID:
                                installationIdentity.installationID
                        )

                        self?.finishInstallationSession(
                            installationIdentity.installationID
                        )
                    }



                    self?.rsdRemoteXPC =
                        nil
                }
            }

        } catch {



            // KI_RSD_SESSION_SETUP_FAILURE
            if let installationIdentity {
                // KI_RSD_JSON_SETUP_FAILURE
                _ = publishInstallationStatus(
                    installationID:
                        installationIdentity.installationID,
                    phase: "failed",
                    progress: nil,
                    detail: "Apple TV service setup failed: \(error.localizedDescription)",
                    terminal: true
                )

                // KI_RSD_TERMINAL_SETUP
                _ = publishInstallationTerminalStatus(
                    "INSTALL_RSD_FAILED setup=\(error.localizedDescription)",
                    installationID:
                        installationIdentity.installationID
                )
                finishInstallationSession(
                    installationIdentity.installationID
                )
            }
        }
    }

    private func startPacketPumps() {

        guard
            let pairingClient
        else {


            return
        }

        packetSendTask?.cancel()
        packetReceiveTask?.cancel()

        packetSendTask = Task { [weak self, pairingClient] in

            guard let self else {
                return
            }


            while !Task.isCancelled {

                let result =
                    await self.packetFlow.readPackets()

                guard !result.0.isEmpty else {
                    if Task.isCancelled {
                        break
                    }

                    continue
                }

                for (packet, _) in
                    zip(result.0, result.1)
                {

                    guard
                        !Task.isCancelled,
                        self.tunnelReady
                    else {
                        return
                    }

                    guard
                        !packet.isEmpty,
                        (packet[packet.startIndex] >> 4) == 6
                    else {


                        continue
                    }

                    do {

                        try await pairingClient
                            .sendTunnelIPv6Packet(packet)


                    } catch {


                        return
                    }
                }
            }

        }

        packetReceiveTask = Task { [weak self, pairingClient] in

            guard let self else {
                return
            }


            while !Task.isCancelled {

                do {

                    let packet =
                        try await pairingClient
                            .receiveTunnelIPv6Packet()

                    guard
                        !Task.isCancelled,
                        self.tunnelReady
                    else {
                        return
                    }

                    guard
                        !packet.isEmpty,
                        (packet[packet.startIndex] >> 4) == 6
                    else {


                        continue
                    }

                    self.packetFlow.writePackets(
                        [packet],
                        withProtocols: [
                            NSNumber(value: AF_INET6)
                        ]
                    )


                } catch {

                    if !Task.isCancelled {

                    }

                    return
                }
            }

        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {


        tunnelReady = false

        // KI_LIFECYCLE_TUNNEL_STOP
        installationSessionLock.lock()
        let stoppingID = activeInstallationID
        installationSessionLock.unlock()
        if let stoppingID {
            _ = publishInstallationStatus(
                installationID: stoppingID, phase: "failed", progress: nil,
                detail: "Apple TV tunnel disconnected.", terminal: true
            )
            _ = cancelInstallationConnections(stoppingID)
        }

        rsdRemoteXPC?.cancel()
        rsdRemoteXPC = nil

        packetSendTask?.cancel()
        packetSendTask = nil

        packetReceiveTask?.cancel()
        packetReceiveTask = nil

        pairingClient = nil

        currentRSDAddress = nil
        currentRSDPort = nil


        completionHandler()
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)?
    ) {


        let message =
            String(
                data: messageData,
                encoding: .utf8
            ) ?? ""

        if message == "KunInstaller Install IPA" {
            writeRSDDebug("INSTALL_MESSAGE_RECEIVED")
        }

        guard let completionHandler else {


            return
        }

        // KI_CLEANUP_QUERY_V1: No session mutation; exact attempt identity.
        if message.hasPrefix("KunInstaller Cleanup Status:") {
            let id = String(message.dropFirst("KunInstaller Cleanup Status:".count))
            guard UUID(uuidString: id) != nil else {
                completionHandler(Data("CLEANUP_UNKNOWN".utf8))
                return
            }
            completionHandler(Data(cleanupState(for: id).utf8))
            return
        }

        // KI_LIFECYCLE_CANCEL_IPC
        if message.hasPrefix("KunInstaller Cancel IPA:") {
            let id = String(message.dropFirst("KunInstaller Cancel IPA:".count))
            guard UUID(uuidString: id) != nil else {
                completionHandler(Data("ERROR: Invalid installation ID.".utf8))
                return
            }
            guard requestInstallationCancellation(id) else {
                completionHandler(
                    Data("ERROR: Installation not active.".utf8)
                )
                return
            }
            _ = publishInstallationStatus(
                installationID: id, phase: "failed", progress: nil,
                detail: "Installation cancelled or timed out.", terminal: true
            )
            let accepted = cancelInstallationConnections(id)
            completionHandler(
                Data(
                    (accepted ? "CANCEL_ACCEPTED" : "ERROR: Installation not active.").utf8
                )
            )
            return
        }

        if message == "KunInstaller Get UDID" {

            guard
                let address = currentRSDAddress,
                let port = currentRSDPort
            else {

                completionHandler(
                    Data(
                        "ERROR: Apple TV tunnel is not ready.".utf8
                    )
                )

                return
            }

            startRSDProbe(
                address: address,
                port: port,
                udidCompletion: { udid in

                    if let udid,
                       !udid.isEmpty {

                        completionHandler(
                            Data(udid.utf8)
                        )

                    } else {

                        completionHandler(
                            Data(
                                "ERROR: Apple TV UDID not found.".utf8
                            )
                        )
                    }
                },
                silent: true
            )

        } else if message == "KunInstaller Install IPA" {

            writeRSDDebug("INSTALL_BRANCH_ENTERED")

            guard
                let address = currentRSDAddress,
                let port = currentRSDPort
            else {

                let result =
                    "ERROR: Apple TV tunnel is not ready."

                writeRSDDebug(
                    "INSTALL_COMMAND_REJECTED tunnel_not_ready"
                )

                completionHandler(
                    Data(result.utf8)
                )

                return
            }

            writeRSDDebug(
                "INSTALL_ENDPOINT_READY address=\(address) port=\(port)"
            )

            // KI_INSTALL_IDENTITY_COMMAND_PREFLIGHT
            // Reject missing or inconsistent IPA selection metadata.
            let installationIdentity: InstallationIdentity

            writeRSDDebug("INSTALL_IDENTITY_VALIDATION_BEGIN")

            do {
                installationIdentity =
                    try validatedInstallationIdentity()
            } catch {
                writeRSDDebug(
                    "INSTALL_COMMAND_REJECTED invalid_identity reason=\(error.localizedDescription)"
                )

                completionHandler(
                    Data(
                        "ERROR: Invalid IPA selection: \(error.localizedDescription)".utf8
                    )
                )
                return
            }

            writeRSDDebug("INSTALL_IDENTITY_VALIDATED bundleID=\(installationIdentity.bundleID)")

            // KI_INSTALL_SESSION_ADMISSION
            writeRSDDebug("INSTALL_SESSION_ADMISSION_BEGIN")

            guard beginInstallationSession(
                installationIdentity.installationID
            ) else {
                writeRSDDebug("INSTALL_SESSION_ADMISSION_FAILED already_active")
                completionHandler(
                    Data(
                        "ERROR: Another installation is already in progress.".utf8
                    )
                )
                return
            }

            writeRSDDebug("INSTALL_SESSION_ADMISSION_PASSED")

            // KI_INITIAL_INSTALL_STATUS
            // Create the status record before starting RSD.
            writeRSDDebug("INSTALL_STATUS_PUBLISH_BEGIN")

            guard publishInstallationStatus(
                installationID: installationIdentity.installationID,
                phase: "preparing",
                progress: nil,
                detail: "Preparing Apple TV services...",
                terminal: false
            ) else {
                writeRSDDebug("INSTALL_STATUS_PUBLISH_FAILED")

                finishInstallationSession(
                    installationIdentity.installationID
                )

                completionHandler(
                    Data(
                        "ERROR: Unable to initialize installation status.".utf8
                    )
                )
                return
            }

            writeRSDDebug("INSTALL_STATUS_PUBLISH_PASSED")

            writeRSDDebug(
                "INSTALL_IDENTITY_VALIDATED selectionID=\(installationIdentity.installationID) bundleID=\(installationIdentity.bundleID)"
            )

            writeRSDDebug(
                "INSTALL_COMMAND_RECEIVED address=\(address) port=\(port)"
            )


            // KI_INSTALL_IDENTITY_CAPTURE
            // Pass the validated identity into this installation attempt.
            writeRSDDebug("INSTALL_RSD_PROBE_BEGIN")

            startRSDProbe(
                address: address,
                port: port,
                installationIdentity: installationIdentity
            )

            writeRSDDebug("INSTALL_RSD_PROBE_RETURNED")

            // KI_INSTALL_ATTEMPT_ACK_RESPONSE
            // Return the unique installation-attempt identifier.
            writeRSDDebug("INSTALL_ACK_SENDING")

            completionHandler(
                Data(
                    (
                        "INSTALL_STARTED:" +
                        installationIdentity.installationID
                    ).utf8
                )
            )

            writeRSDDebug("INSTALL_ACK_SENT")

        } else {

            completionHandler(messageData)
        }

    }

    override func sleep(
        completionHandler: @escaping () -> Void
    ) {

        completionHandler()
    }

    override func wake() {
    }
}
