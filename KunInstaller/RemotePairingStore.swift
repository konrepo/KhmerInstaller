import Foundation
import Security

struct RemotePairingRecord: Codable {

    let hostIdentifier: String

    let publicKey: Data
    let privateKey: Data

    let peerAltIRK: Data

    let remoteName: String
    let remoteModel: String
}

final class RemotePairingStore {

    static let shared = RemotePairingStore()

    private let service =
        "com.kun.installer.remote-pairing"

    private init() {}

    // MARK: - Save

    func save(
        _ record: RemotePairingRecord,
        for deviceKey: String
    ) throws {

        let data =
            try JSONEncoder().encode(record)

        let account =
            accountName(for: deviceKey)

        let query: [String: Any] = [
            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String:
                data,

            kSecAttrAccessible as String:
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus =
            SecItemUpdate(
                query as CFDictionary,
                attributes as CFDictionary
            )

        if updateStatus == errSecItemNotFound {

            var addQuery = query

            addQuery[kSecValueData as String] =
                data

            addQuery[
                kSecAttrAccessible as String
            ] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

            let status =
                SecItemAdd(
                    addQuery as CFDictionary,
                    nil
                )

            guard status == errSecSuccess else {
                throw StoreError.keychain(status)
            }

        } else if updateStatus != errSecSuccess {

            throw StoreError.keychain(
                updateStatus
            )
        }
    }

    // MARK: - Load

    func load(
        for deviceKey: String
    ) throws -> RemotePairingRecord? {

        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                accountName(for: deviceKey),

            kSecReturnData as String:
                true,

            kSecMatchLimit as String:
                kSecMatchLimitOne
        ]

        var result:
            CFTypeRef?

        let status =
            SecItemCopyMatching(
                query as CFDictionary,
                &result
            )

        if status == errSecItemNotFound {
            return nil
        }

        guard status == errSecSuccess else {
            throw StoreError.keychain(status)
        }

        guard let data =
            result as? Data
        else {
            throw StoreError.invalidData
        }

        return try JSONDecoder()
            .decode(
                RemotePairingRecord.self,
                from: data
            )
    }

    // MARK: - Shared App Group Export

    func exportToAppGroup(
        _ record: RemotePairingRecord
    ) throws {

        let groupID = KhmerInstallerConfig.appGroupID

        guard
            let containerURL =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        groupID
                )
        else {
            throw StoreError.appGroupUnavailable
        }

        let fileURL =
            containerURL.appendingPathComponent(
                "remote-pairing-record.json"
            )

        let data =
            try JSONEncoder().encode(record)

        try data.write(
            to: fileURL,
            options: .atomic
        )

        print(
            "Exported pairing record to App Group:",
            fileURL.path
        )
    }

    func loadFromAppGroup()
        throws -> RemotePairingRecord?
    {

        let groupID = KhmerInstallerConfig.appGroupID

        guard
            let containerURL =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        groupID
                )
        else {
            throw StoreError.appGroupUnavailable
        }

        let fileURL =
            containerURL.appendingPathComponent(
                "remote-pairing-record.json"
            )

        guard
            FileManager.default.fileExists(
                atPath: fileURL.path
            )
        else {
            return nil
        }

        let data =
            try Data(contentsOf: fileURL)

        return try JSONDecoder().decode(
            RemotePairingRecord.self,
            from: data
        )
    }

    // MARK: - Delete

    func delete(
        for deviceKey: String
    ) throws {

        let query: [String: Any] = [

            kSecClass as String:
                kSecClassGenericPassword,

            kSecAttrService as String:
                service,

            kSecAttrAccount as String:
                accountName(for: deviceKey)
        ]

        let status =
            SecItemDelete(
                query as CFDictionary
            )

        guard status == errSecSuccess ||
              status == errSecItemNotFound
        else {
            throw StoreError.keychain(status)
        }
    }

    // MARK: - Helpers

    private func accountName(
        for deviceKey: String
    ) -> String {

        deviceKey
    }

    enum StoreError: LocalizedError {
        case keychain(OSStatus)
        case invalidData
        case appGroupUnavailable

        var errorDescription: String? {

            switch self {

            case .keychain(let status):
                return """
                Keychain error: \(status)
                """

            case .invalidData:
                return """
                Saved pairing record is invalid.
                """

            case .appGroupUnavailable:
                return """
                KunInstaller App Group is unavailable.
                """
            }
        }
    }
}
