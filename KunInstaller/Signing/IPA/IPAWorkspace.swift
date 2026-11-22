// KI_RELEASE_LOG_CLEANUP: Removed console print diagnostics.
import Foundation
import ZsignC

enum IPAWorkspaceError: LocalizedError {
    case invalidIPA
    case workspaceCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidIPA:
            return "The selected file is not an IPA."
        case .workspaceCreationFailed:
            return "Unable to prepare the IPA workspace."
        }
    }
}

struct IPAWorkspace {
    let directory: URL
    let sourceIPA: URL

    // KI_ABANDONED_SIGNING_WORKSPACE_CLEANUP
    // Called once at application startup, before signing begins.
    static func cleanupAbandonedWorkspaces() {
        let fm = FileManager.default

        let root = fm.temporaryDirectory.appendingPathComponent(
            "KhmerInstaller-iOS-Signing",
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
                .isDirectoryKey,
                .isSymbolicLinkKey
            ],
            options: []
        ) else {
            return
        }

        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ),
                  values.isDirectory == true,
                  values.isSymbolicLink != true,
                  entry.deletingLastPathComponent().standardizedFileURL
                    == root.standardizedFileURL else {
                continue
            }

            try? fm.removeItem(at: entry)
        }
    }

    static func prepare(
        from selectedURL: URL
    ) throws -> IPAWorkspace {

        guard selectedURL.pathExtension.lowercased() == "ipa" else {
            throw IPAWorkspaceError.invalidIPA
        }

        let fileManager = FileManager.default

        let directory = fileManager.temporaryDirectory
            .appendingPathComponent(
                "KhmerInstaller-iOS-Signing",
                isDirectory: true
            )
            .appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )

        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )

            let destination = directory
                .appendingPathComponent("Original.ipa")

            try fileManager.copyItem(
                at: selectedURL,
                to: destination
            )

            return IPAWorkspace(
                directory: directory,
                sourceIPA: destination
            )
        } catch {
            try? fileManager.removeItem(at: directory)
            throw IPAWorkspaceError.workspaceCreationFailed
        }
    }


    func extractAndVerify() throws -> URL {
        let extracted = directory.appendingPathComponent(
            "Extracted",
            isDirectory: true
        )

        let fm = FileManager.default

        guard !fm.fileExists(atPath: extracted.path) else {
            throw IPAWorkspaceError.workspaceCreationFailed
        }

        guard KIExtractIPA(
            sourceIPA.path,
            extracted.path
        ) else {
            try? fm.removeItem(at: extracted)
            throw IPAWorkspaceError.invalidIPA
        }

        do {
            let payload = extracted.appendingPathComponent(
                "Payload",
                isDirectory: true
            )

            let entries = try fm.contentsOfDirectory(
                at: payload,
                includingPropertiesForKeys: nil
            )

            let apps = entries.filter {
                $0.pathExtension.lowercased() == "app"
            }

            guard apps.count == 1 else {
                throw IPAWorkspaceError.invalidIPA
            }

            let app = apps[0]

            let infoURL = app.appendingPathComponent(
                "Info.plist"
            )

            let infoData = try Data(contentsOf: infoURL)

            guard let info = try PropertyListSerialization
                .propertyList(
                    from: infoData,
                    format: nil
                ) as? [String: Any],
                let executable = info[
                    "CFBundleExecutable"
                ] as? String else {
                throw IPAWorkspaceError.invalidIPA
            }

            let executableURL = app.appendingPathComponent(
                executable
            )

            let attributes = try fm.attributesOfItem(
                atPath: executableURL.path
            )

            guard let fileType = attributes[.type] as? FileAttributeType,
                  fileType == .typeRegular,
                  let permissions = attributes[.posixPermissions] as? NSNumber,
                  permissions.intValue & 0o111 != 0 else {
                throw IPAWorkspaceError.invalidIPA
            }

            return app

        } catch {
            try? fm.removeItem(at: extracted)
            throw error
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(
            at: directory
        )
    }
}
