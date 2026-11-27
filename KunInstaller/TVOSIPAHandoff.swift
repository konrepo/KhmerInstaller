import Foundation
import Combine

@MainActor
final class TVOSIPAHandoff: ObservableObject {

    @Published private(set) var pendingIPAURL: URL?
    @Published private(set) var requestID: UUID?

    private var consumedRequestID: UUID?

    func consumePendingRequest() -> Bool {
        guard let requestID,
              pendingIPAURL != nil,
              consumedRequestID != requestID else {
            return false
        }

        consumedRequestID = requestID
        return true
    }

    // Remove abandoned App Library downloads at app startup.
    // Never touch signed IPA storage or signing workspaces.
    static func cleanupAbandonedDownloads() {
        let fm = FileManager.default

        let root = fm.temporaryDirectory.appendingPathComponent(
            "KhmerInstaller-AppLibrary",
            isDirectory: true
        )

        guard let rootValues = try? root.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
        rootValues.isDirectory == true,
        rootValues.isSymbolicLink != true else {
            return
        }

        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            return
        }

        for entry in entries {
            let normalized = entry.standardizedFileURL

            guard normalized.deletingLastPathComponent() ==
                    root.standardizedFileURL,
                  normalized.pathExtension.lowercased() == "ipa",
                  UUID(
                    uuidString: normalized
                        .deletingPathExtension()
                        .lastPathComponent
                  ) != nil,
                  let values = try? entry.resourceValues(
                    forKeys: [
                        .isRegularFileKey,
                        .isSymbolicLinkKey
                    ]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }

            try? fm.removeItem(at: entry)
        }
    }

    private var downloadDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "KhmerInstaller-AppLibrary",
                isDirectory: true
            )
            .standardizedFileURL
    }

    private func isManagedDownload(_ url: URL) -> Bool {
        let normalized = url.standardizedFileURL

        return normalized.isFileURL &&
            normalized.pathExtension.lowercased() == "ipa" &&
            UUID(uuidString:
                normalized.deletingPathExtension()
                    .lastPathComponent) != nil &&
            normalized.deletingLastPathComponent() ==
                downloadDirectory
    }

    @discardableResult
    func prepare(_ url: URL) -> Bool {
        guard isManagedDownload(url),
              FileManager.default.fileExists(atPath: url.path)
        else {
            return false
        }

        if let previous = pendingIPAURL,
           previous.standardizedFileURL !=
                url.standardizedFileURL,
           isManagedDownload(previous) {
            try? FileManager.default.removeItem(at: previous)
        }

        pendingIPAURL = url
        requestID = UUID()
        return true
    }

    @discardableResult
    func completeImport(_ url: URL) -> Bool {
        guard let pendingIPAURL,
              pendingIPAURL.standardizedFileURL ==
                url.standardizedFileURL,
              isManagedDownload(url)
        else {
            return false
        }

        // Called only after successful signing workspace import.
        let fm = FileManager.default

        do {
            if fm.fileExists(atPath: url.path) {
                try fm.removeItem(at: url)
            }

            self.pendingIPAURL = nil
            requestID = nil
            return true

        } catch {
            NSLog(
                "App Library temporary IPA cleanup failed: %@",
                error.localizedDescription
            )
            return false
        }
    }

    func clear() {
        pendingIPAURL = nil
        requestID = nil
    }
}
