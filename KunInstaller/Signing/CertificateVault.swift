import Foundation
import Security

struct SigningCertificateRecord: Codable, Identifiable {
    let id: UUID
    var nickname: String
    let p12Filename: String
    let profileFilename: String
    var additionalProfileFilenames: [String]
    let addedAt: Date
    let expirationDate: Date?

    init(
        id: UUID,
        nickname: String,
        p12Filename: String,
        profileFilename: String,
        additionalProfileFilenames: [String] = [],
        addedAt: Date,
        expirationDate: Date?
    ) {
        self.id = id
        self.nickname = nickname
        self.p12Filename = p12Filename
        self.profileFilename = profileFilename
        self.additionalProfileFilenames = additionalProfileFilenames
        self.addedAt = addedAt
        self.expirationDate = expirationDate
    }

    enum CodingKeys: String, CodingKey {
        case id
        case nickname
        case p12Filename
        case profileFilename
        case additionalProfileFilenames
        case addedAt
        case expirationDate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        id = try container.decode(UUID.self, forKey: .id)
        nickname = try container.decode(String.self, forKey: .nickname)
        p12Filename = try container.decode(String.self, forKey: .p12Filename)
        profileFilename = try container.decode(String.self, forKey: .profileFilename)
        additionalProfileFilenames = try container.decodeIfPresent(
            [String].self,
            forKey: .additionalProfileFilenames
        ) ?? []
        addedAt = try container.decode(Date.self, forKey: .addedAt)
        expirationDate = try container.decodeIfPresent(
            Date.self,
            forKey: .expirationDate
        )
    }
}

enum CertificateVaultError: LocalizedError {
    case invalidData
    case keychain(OSStatus)
    case passwordNotFound
    case recordNotFound
    case duplicateProfile
    case deletionRecoveryRequired

    var errorDescription: String? {
        switch self {
        case .invalidData:
            return "Saved certificate data is invalid."
        case .keychain(let status):
            return "Keychain operation failed (status \(status))."
        case .passwordNotFound:
            return "The certificate password could not be found."
        case .recordNotFound:
            return "The saved certificate record was not found."
        case .duplicateProfile:
            return "This provisioning profile or App ID is already saved."
        case .deletionRecoveryRequired:
            return "Certificate deletion was interrupted and automatic restoration failed. Keep app data intact and recover the quarantined files before retrying."
        }
    }
}

final class CertificateVault {
    static let shared = CertificateVault()

    private let keychainService =
        "com.konrepo.KhmerInstaller.signing-certificate-password"

    private let metadataFilename = "certificates.json"

    private init() {}

    private var directory: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]

        return base.appendingPathComponent(
            "KhmerInstaller/Certificates",
            isDirectory: true
        )
    }

    private var metadataURL: URL {
        directory.appendingPathComponent(metadataFilename)
    }

    func loadRecords() throws -> [SigningCertificateRecord] {
        guard FileManager.default.fileExists(
            atPath: metadataURL.path
        ) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)

        return try JSONDecoder().decode(
            [SigningCertificateRecord].self,
            from: data
        )
    }

    func fileURL(for filename: String) -> URL {
        directory.appendingPathComponent(filename)
    }

    func password(
        for record: SigningCertificateRecord
    ) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: record.id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?

        let status = SecItemCopyMatching(
            query as CFDictionary,
            &result
        )

        guard status == errSecSuccess else {
            if status == errSecItemNotFound {
                throw CertificateVaultError.passwordNotFound
            }

            throw CertificateVaultError.keychain(status)
        }

        guard let data = result as? Data,
              let password = String(
                data: data,
                encoding: .utf8
              ) else {
            throw CertificateVaultError.invalidData
        }

        return password
    }

    func add(
        p12Data: Data,
        profileData: Data,
        password: String,
        nickname: String,
        expirationDate: Date?
    ) throws -> SigningCertificateRecord {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let id = UUID()
        let p12Filename = "\(id.uuidString).p12"
        let profileFilename = "\(id.uuidString).mobileprovision"

        let p12URL = fileURL(for: p12Filename)
        let profileURL = fileURL(for: profileFilename)

        let cleanedNickname = nickname.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        let record = SigningCertificateRecord(
            id: id,
            nickname: cleanedNickname.isEmpty
                ? "Signing Certificate"
                : cleanedNickname,
            p12Filename: p12Filename,
            profileFilename: profileFilename,
            addedAt: Date(),
            expirationDate: expirationDate
        )

        do {
            try p12Data.write(
                to: p12URL,
                options: [.atomic, .completeFileProtection]
            )

            try profileData.write(
                to: profileURL,
                options: [.atomic, .completeFileProtection]
            )

            try savePassword(
                password,
                account: id.uuidString
            )

            var records = try loadRecords()
            records.insert(record, at: 0)

            let encoded = try JSONEncoder().encode(records)

            try encoded.write(
                to: metadataURL,
                options: [.atomic, .completeFileProtection]
            )

            return record
        } catch {
            try? FileManager.default.removeItem(at: p12URL)
            try? FileManager.default.removeItem(at: profileURL)
            deletePassword(account: id.uuidString)
            throw error
        }
    }

    func addAdditionalProfile(
        _ profileData: Data,
        to record: SigningCertificateRecord
    ) throws {
        var records = try loadRecords()

        guard let index = records.firstIndex(where: {
            $0.id == record.id
        }) else {
            throw CertificateVaultError.recordNotFound
        }

        let savedRecord = records[index]

        let p12Data = try Data(
            contentsOf: fileURL(for: savedRecord.p12Filename)
        )

        let identity = try SigningCredentialValidator.importIdentity(
            p12Data: p12Data,
            password: password(for: savedRecord)
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

        let newProfile = try SigningCredentialValidator.validateProfile(
            profileData: profileData,
            certificate: certificate
        )

        let existingNames = [
            savedRecord.profileFilename
        ] + savedRecord.additionalProfileFilenames

        for filename in existingNames {
            let existingData = try Data(
                contentsOf: fileURL(for: filename)
            )

            if existingData == profileData {
                throw CertificateVaultError.duplicateProfile
            }

            let existing = try SigningCredentialValidator.validateProfile(
                profileData: existingData,
                certificate: certificate
            )

            if existing.applicationIdentifier ==
                newProfile.applicationIdentifier {
                throw CertificateVaultError.duplicateProfile
            }
        }

        let filename = UUID().uuidString + ".mobileprovision"
        let destination = fileURL(for: filename)

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        try profileData.write(
            to: destination,
            options: [.atomic, .completeFileProtection]
        )

        do {
            records[index].additionalProfileFilenames.append(filename)

            let encoded = try JSONEncoder().encode(records)

            try encoded.write(
                to: metadataURL,
                options: [.atomic, .completeFileProtection]
            )
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // KI_RECOVERABLE_CERTIFICATE_DELETE_V1
    // Stage files before updating metadata; delete Keychain password last.
    // A failure attempts to restore metadata and staged files.
    // If restoration fails, the quarantine is deliberately retained.
    func delete(_ record: SigningCertificateRecord) throws {
        let fm = FileManager.default
        var records = try loadRecords()
        guard let index = records.firstIndex(where: { $0.id == record.id }) else {
            throw CertificateVaultError.recordNotFound
        }
        let saved = records[index]
        let filenames = [saved.p12Filename, saved.profileFilename]
            + saved.additionalProfileFilenames

        guard Set(filenames).count == filenames.count else {
            throw CertificateVaultError.invalidData
        }
        for filename in filenames {
            guard !filename.isEmpty,
                  filename == URL(fileURLWithPath: filename).lastPathComponent,
                  !filename.contains("/"), !filename.contains("\\"),
                  filename != ".", filename != ".." else {
                throw CertificateVaultError.invalidData
            }
            let url = fileURL(for: filename)
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ), values.isRegularFile == true,
               values.isSymbolicLink != true else {
                throw CertificateVaultError.invalidData
            }
        }

        // Keep the original bytes for an exact metadata rollback.
        let originalMetadata = try Data(contentsOf: metadataURL)
        let quarantine = directory.appendingPathComponent(
            ".deletion-pending-" + UUID().uuidString,
            isDirectory: true
        )
        try fm.createDirectory(
            at: quarantine,
            withIntermediateDirectories: false
        )
        var staged: [String] = []
        var metadataUpdated = false
        do {
            for filename in filenames {
                try fm.moveItem(
                    at: fileURL(for: filename),
                    to: quarantine.appendingPathComponent(filename)
                )
                staged.append(filename)
            }

            records.remove(at: index)
            let encoded = try JSONEncoder().encode(records)
            try encoded.write(
                to: metadataURL,
                options: [.atomic, .completeFileProtection]
            )
            metadataUpdated = true

            // Last fallible logical operation. Do not remove staged
            // credentials unless the Keychain deletion succeeded.
            try removePassword(account: saved.id.uuidString)
        } catch {
            let originalError = error
            var restorationFailed = false
            if metadataUpdated {
                do {
                    try originalMetadata.write(
                        to: metadataURL,
                        options: [.atomic, .completeFileProtection]
                    )
                } catch {
                    restorationFailed = true
                }
            }
            for filename in staged.reversed() {
                do {
                    try fm.moveItem(
                        at: quarantine.appendingPathComponent(filename),
                        to: fileURL(for: filename)
                    )
                } catch {
                    restorationFailed = true
                }
            }
            if restorationFailed {
                // Do not delete quarantine: it may contain the only
                // remaining copies of private signing credentials.
                throw CertificateVaultError.deletionRecoveryRequired
            }
            try? fm.removeItem(at: quarantine)
            throw originalError
        }

        // Keychain and metadata now agree. A failed quarantine cleanup
        // leaves a recoverable orphan rather than restoring a deleted key.
        try? fm.removeItem(at: quarantine)
    }

    private func removePassword(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CertificateVaultError.keychain(status)
        }
    }

    private func savePassword(
        _ password: String,
        account: String
    ) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        let deleteStatus = SecItemDelete(
            query as CFDictionary
        )

        guard deleteStatus == errSecSuccess ||
              deleteStatus == errSecItemNotFound else {
            throw CertificateVaultError.keychain(deleteStatus)
        }

        var attributes = query
        attributes[kSecValueData as String] = Data(password.utf8)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(
            attributes as CFDictionary,
            nil
        )

        guard status == errSecSuccess else {
            throw CertificateVaultError.keychain(status)
        }
    }

    private func deletePassword(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }
}
