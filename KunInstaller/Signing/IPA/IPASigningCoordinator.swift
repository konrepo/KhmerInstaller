import Foundation
import CryptoKit
import Zsign
import ZsignC

enum IPASigningError: LocalizedError {
    case certificateNotSelected
    case signingFailed
    case invalidCredentials
    case signatureVerificationFailed
    case unsupportedAppPlatform
    case unsupportedAppExtensions
    case duplicateProvisioningProfile
    case provisioningTeamMismatch

    var errorDescription: String? {
        switch self {
        case .certificateNotSelected:
            return "Select a signing certificate."
        case .signingFailed:
            return "Zsign failed to sign the application."
        case .invalidCredentials:
            return "Saved signing credentials are invalid."
        case .signatureVerificationFailed:
            return "The app or a nested code component failed signature or resource verification."
        case .unsupportedAppPlatform:
            return "The selected IPA is not a tvOS application."
        case .unsupportedAppExtensions:
            return "This tvOS IPA contains app extensions that require separate signing support."
        case .duplicateProvisioningProfile:
            return "Multiple provisioning profiles have the same application identifier."
        case .provisioningTeamMismatch:
            return "Provisioning profiles belong to different Apple Developer Teams."
        }
    }
}


// Verifies the primary CodeDirectory page hashes and detached CMS
// signature for a thin, little-endian 64-bit Mach-O executable.
// This is not a complete Apple code-signature policy verifier.
enum MachOSignatureVerifier {

    private static func be32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].reduce(UInt32(0)) {
            ($0 << 8) | UInt32($1)
        }
    }

    private static func le32(_ data: Data, _ offset: Int) -> UInt32? {
        guard offset >= 0, offset <= data.count - 4 else { return nil }
        return data[offset..<(offset + 4)].enumerated().reduce(UInt32(0)) {
            $0 | (UInt32($1.element) << (8 * $1.offset))
        }
    }

    private static func be64(_ data: Data, _ offset: Int) -> UInt64? {
        guard offset >= 0, offset <= data.count - 8 else { return nil }
        return data[offset..<(offset + 8)].reduce(UInt64(0)) {
            ($0 << 8) | UInt64($1)
        }
    }


    // Verify the resource hashes recorded in CodeResources.
    // Apple's resource-rule semantics and CodeDirectory special slots
    // are checked separately; this function validates the listed files.
    static func verifyResourceManifest(in appURL: URL) -> Bool {
        let fm = FileManager.default
        let sealURL = appURL
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources")

        guard
            let sealData = try? Data(contentsOf: sealURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: sealData,
                options: [],
                format: nil
            ),
            let seal = plist as? [String: Any],
            let files = seal["files"] as? [String: Any],
            let files2 = seal["files2"] as? [String: Any]
        else {
            return false
        }

        let root = appURL.standardizedFileURL
        let rootPath = root.path.hasSuffix("/")
            ? root.path
            : root.path + "/"

        func resourceURL(_ relativePath: String) -> URL? {
            guard !relativePath.isEmpty,
                  !relativePath.hasPrefix("/"),
                  !relativePath.contains("\\"),
                  !relativePath.split(separator: "/").contains("..")
            else {
                return nil
            }

            let url = root.appendingPathComponent(relativePath)
                .standardizedFileURL

            guard url.path.hasPrefix(rootPath) else {
                return nil
            }

            return url
        }

        func sha1(_ data: Data) -> Data {
            Data(Insecure.SHA1.hash(data: data))
        }

        func sha256(_ data: Data) -> Data {
            Data(SHA256.hash(data: data))
        }

        let names = Set(files.keys).union(files2.keys)

        for name in names {
            guard let url = resourceURL(name) else {
                return false
            }

            let entry1 = files[name]
            let entry2 = files2[name]

            let optional1 =
                (entry1 as? [String: Any])?["optional"] as? Bool ?? false
            let optional2 =
                (entry2 as? [String: Any])?["optional"] as? Bool ?? false

            var isDirectory: ObjCBool = false
            let exists = fm.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            )

            if !exists {
                if optional1 || optional2 {
                    continue
                }
                return false
            }

            guard !isDirectory.boolValue,
                  let data = try? Data(contentsOf: url)
            else {
                return false
            }

            if let entry1 {
                let expected: Data?

                if let value = entry1 as? Data {
                    expected = value
                } else if let dictionary = entry1 as? [String: Any] {
                    expected = dictionary["hash"] as? Data
                } else {
                    return false
                }

                guard let expected, sha1(data) == expected else {
                    return false
                }
            }

            if let entry2 {
                guard let dictionary = entry2 as? [String: Any] else {
                    return false
                }

                if let expectedSHA1 = dictionary["hash"] as? Data {
                    guard sha1(data) == expectedSHA1 else {
                        return false
                    }
                }

                if let expectedSHA256 = dictionary["hash2"] as? Data {
                    guard sha256(data) == expectedSHA256 else {
                        return false
                    }
                }

                guard dictionary["hash"] is Data,
                      dictionary["hash2"] is Data
                else {
                    return false
                }
            }
        }

        return true
    }

    static func verifyMainExecutable(in appURL: URL) -> Bool {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let sealURL = appURL
            .appendingPathComponent("_CodeSignature", isDirectory: true)
            .appendingPathComponent("CodeResources")

        guard
            let infoData = try? Data(contentsOf: infoURL),
            let sealData = try? Data(contentsOf: sealURL),
            let plist = try? PropertyListSerialization.propertyList(
                from: infoData,
                options: [],
                format: nil
            ),
            let info = plist as? [String: Any],
            let executable = info["CFBundleExecutable"] as? String,
            !executable.isEmpty
        else {
            return false
        }

        // Authenticate these files against the signed CodeDirectory
        // before trusting the resource hashes in CodeResources.
        guard verifyExecutable(
            at: appURL.appendingPathComponent(executable),
            specialSlotData: [
                1: infoData,
                3: sealData
            ]
        ) else {
            return false
        }

        return verifyResourceManifest(in: appURL)
    }

    // Verify each nested signed bundle independently.
    // This includes app extensions and embedded frameworks.
    static func verifyNestedCode(in appURL: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return false
        }

        let bundleExtensions: Set<String> = [
            "app", "appex", "framework", "xpc"
        ]

        let root = appURL.standardizedFileURL
        var nestedBundles: [URL] = []

        for case let candidate as URL in enumerator {
            guard bundleExtensions.contains(
                candidate.pathExtension.lowercased()
            ) else {
                continue
            }

            let standardized = candidate.standardizedFileURL

            // The supplied root is the main app; do not verify it twice.
            guard standardized != root else {
                continue
            }

            guard let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey]
            ), values.isDirectory == true else {
                continue
            }

            nestedBundles.append(candidate)
        }

        // Verify every discovered nested bundle. Fail closed on any error.
        for bundle in nestedBundles {
            guard verifyMainExecutable(in: bundle) else {
                return false
            }
        }

        return true
    }

    static func verifyExecutable(
        at url: URL,
        specialSlotData: [Int: Data] = [:]
    ) -> Bool {
        guard let data = try? Data(contentsOf: url), data.count >= 32 else {
            return false
        }

        let magic = data.prefix(4)

        // Thin little-endian 64-bit Mach-O.
        if magic.elementsEqual([0xCF, 0xFA, 0xED, 0xFE]) {
            return verifyThinExecutableData(
                data,
                specialSlotData: specialSlotData
            )
        }

        // Universal Mach-O containers: FAT32 and FAT64, both byte orders.
        let littleEndian: Bool
        let fat64: Bool

        if magic.elementsEqual([0xCA, 0xFE, 0xBA, 0xBE]) {
            littleEndian = false
            fat64 = false
        } else if magic.elementsEqual([0xBE, 0xBA, 0xFE, 0xCA]) {
            littleEndian = true
            fat64 = false
        } else if magic.elementsEqual([0xCA, 0xFE, 0xBA, 0xBF]) {
            littleEndian = false
            fat64 = true
        } else if magic.elementsEqual([0xBF, 0xBA, 0xFE, 0xCA]) {
            littleEndian = true
            fat64 = true
        } else {
            return false
        }

        func fatUInt32(_ offset: Int) -> UInt32? {
            guard offset >= 0, offset <= data.count - 4 else {
                return nil
            }

            let bytes = data[offset..<(offset + 4)]

            if littleEndian {
                return bytes.enumerated().reduce(UInt32(0)) {
                    $0 | (UInt32($1.element) << (8 * $1.offset))
                }
            }

            return bytes.reduce(UInt32(0)) {
                ($0 << 8) | UInt32($1)
            }
        }

        func fatUInt64(_ offset: Int) -> UInt64? {
            guard offset >= 0, offset <= data.count - 8 else {
                return nil
            }

            let bytes = data[offset..<(offset + 8)]

            if littleEndian {
                return bytes.enumerated().reduce(UInt64(0)) {
                    $0 | (UInt64($1.element) << (8 * $1.offset))
                }
            }

            return bytes.reduce(UInt64(0)) {
                ($0 << 8) | UInt64($1)
            }
        }

        guard let countRaw = fatUInt32(4), countRaw > 0 else {
            return false
        }

        let entrySize = fat64 ? 32 : 20

        guard UInt64(countRaw) <= UInt64((data.count - 8) / entrySize) else {
            return false
        }

        let count = Int(countRaw)
        let tableEnd = 8 + count * entrySize
        var slices: [Range<Int>] = []

        for index in 0..<count {
            let entry = 8 + index * entrySize

            let offsetValue: UInt64?
            let sizeValue: UInt64?

            if fat64 {
                offsetValue = fatUInt64(entry + 8)
                sizeValue = fatUInt64(entry + 16)
            } else {
                offsetValue = fatUInt32(entry + 8).map(UInt64.init)
                sizeValue = fatUInt32(entry + 12).map(UInt64.init)
            }

            guard let sliceOffset64 = offsetValue,
                  let sliceSize64 = sizeValue,
                  sliceOffset64 >= UInt64(tableEnd),
                  sliceOffset64 <= UInt64(data.count),
                  sliceSize64 >= 32,
                  sliceSize64 <= UInt64(data.count) - sliceOffset64,
                  sliceOffset64 <= UInt64(Int.max),
                  sliceSize64 <= UInt64(Int.max)
            else {
                return false
            }

            let sliceOffset = Int(sliceOffset64)
            let sliceSize = Int(sliceSize64)
            let sliceEnd = sliceOffset + sliceSize
            let sliceRange = sliceOffset..<sliceEnd

            // Architecture slices must not overlap one another.
            guard !slices.contains(where: {
                $0.lowerBound < sliceEnd && sliceOffset < $0.upperBound
            }) else {
                return false
            }

            slices.append(sliceRange)

            let slice = data.subdata(in: sliceRange)

            // This verifier intentionally supports thin little-endian
            // 64-bit Mach-O slices. Unsupported architectures fail closed.
            guard slice.prefix(4).elementsEqual(
                [0xCF, 0xFA, 0xED, 0xFE]
            ), verifyThinExecutableData(
                slice,
                specialSlotData: specialSlotData
            ) else {
                return false
            }
        }

        return true
    }

    private static func verifyThinExecutableData(
        _ data: Data,
        specialSlotData: [Int: Data]
    ) -> Bool {
        guard data.count >= 32 else {
            return false
        }

        // Verify a thin little-endian 64-bit Mach-O slice.
        guard data.prefix(4).elementsEqual([0xCF, 0xFA, 0xED, 0xFE]),
              let commandCount = le32(data, 16),
              let commandBytes = le32(data, 20)
        else {
            return false
        }

        let commandsEnd = 32 + Int(commandBytes)
        guard commandsEnd >= 32, commandsEnd <= data.count,
              commandCount <= commandBytes / 8
        else {
            return false
        }

        var position = 32
        var signatureRange: Range<Int>?

        for _ in 0..<commandCount {
            guard position <= commandsEnd - 8,
                  let command = le32(data, position),
                  let commandSize = le32(data, position + 4),
                  commandSize >= 8,
                  Int(commandSize) <= commandsEnd - position
            else {
                return false
            }

            if command == 0x1D {
                guard commandSize >= 16,
                      let offset = le32(data, position + 8),
                      let size = le32(data, position + 12),
                      size >= 12,
                      Int(offset) <= data.count,
                      Int(size) <= data.count - Int(offset)
                else {
                    return false
                }

                signatureRange = Int(offset)..<(Int(offset) + Int(size))
                break
            }

            position += Int(commandSize)
        }

        guard
            let signatureRange,
            let superMagic = be32(data, signatureRange.lowerBound),
            let superLength = be32(data, signatureRange.lowerBound + 4),
            let slotCount = be32(data, signatureRange.lowerBound + 8),
            superMagic == 0xFADE0CC0,
            superLength >= 12,
            Int(superLength) <= signatureRange.count,
            slotCount <= (superLength - 12) / 8
        else {
            return false
        }

        let blobEnd = signatureRange.lowerBound + Int(superLength)
        let blob = data.subdata(
            in: signatureRange.lowerBound..<blobEnd
        )

        var primaryDirectory: Data?
        var cmsWrapper: Data?

        for index in 0..<slotCount {
            let entry = 12 + Int(index) * 8

            guard let slotType = be32(blob, entry),
                  let slotOffset = be32(blob, entry + 4),
                  Int(slotOffset) <= blob.count - 8,
                  let magic = be32(blob, Int(slotOffset)),
                  let length = be32(blob, Int(slotOffset) + 4),
                  length >= 8,
                  Int(length) <= blob.count - Int(slotOffset)
            else {
                return false
            }

            let range = Int(slotOffset)..<(Int(slotOffset) + Int(length))
            let item = blob.subdata(in: range)

            if slotType == 0 {
                guard magic == 0xFADE0C02 else { return false }
                primaryDirectory = item
            } else if slotType == 0x10000 {
                guard magic == 0xFADE0B01 else { return false }
                cmsWrapper = item
            }
        }

        guard let directory = primaryDirectory,
              let wrapper = cmsWrapper,
              let version = be32(directory, 8),
              let hashOffsetRaw = be32(directory, 16),
              let specialSlotsRaw = be32(directory, 24),
              let codeSlotsRaw = be32(directory, 28),
              let codeLimitRaw = be32(directory, 32),
              directory.count >= 40
        else {
            return false
        }

        let hashOffset = Int(hashOffsetRaw)
        let specialSlots = Int(specialSlotsRaw)
        let codeSlots = Int(codeSlotsRaw)
        let hashSize = Int(directory[36])
        let hashType = directory[37]
        let pageExponent = Int(directory[39])

        guard hashSize > 0, pageExponent <= 30 else { return false }

        var codeLimit = UInt64(codeLimitRaw)
        if version >= 0x20300 && codeLimitRaw == UInt32.max {
            guard let extendedLimit = be64(directory, 56) else {
                return false
            }
            codeLimit = extendedLimit
        }

        guard codeLimit > 0,
              codeLimit <= UInt64(signatureRange.lowerBound),
              codeLimit <= UInt64(data.count),
              specialSlots <= hashOffset / hashSize,
              codeSlots <= (directory.count - min(hashOffset, directory.count)) / hashSize,
              hashOffset <= directory.count
        else {
            return false
        }

        let pageSize: UInt64
        if pageExponent == 0 {
            pageSize = codeLimit
        } else {
            pageSize = UInt64(1) << pageExponent
        }

        let expectedSlots = pageExponent == 0
            ? 1
            : (codeLimit + pageSize - 1) / pageSize

        guard expectedSlots == UInt64(codeSlots) else { return false }

        func digest(_ bytes: Data) -> Data? {
            switch hashType {
            case 1:
                guard hashSize == 20 else { return nil }
                return Data(Insecure.SHA1.hash(data: bytes))
            case 2:
                guard hashSize == 32 else { return nil }
                return Data(SHA256.hash(data: bytes))
            case 3:
                guard hashSize == 20 else { return nil }
                return Data(SHA256.hash(data: bytes).prefix(20))
            default:
                return nil
            }
        }

        // Verify supplied CodeDirectory special slots.
        // Slot 1 is Info.plist; slot 3 is CodeResources.
        for (slot, content) in specialSlotData {
            guard slot > 0,
                  slot <= specialSlots,
                  let actual = digest(content)
            else {
                return false
            }

            let storedOffset = hashOffset - slot * hashSize
            guard storedOffset <= directory.count - hashSize else {
                return false
            }

            let stored = directory.subdata(
                in: storedOffset..<(storedOffset + hashSize)
            )

            guard actual == stored else {
                return false
            }
        }

        for index in 0..<codeSlots {
            let start = UInt64(index) * pageSize
            let end = min(start + pageSize, codeLimit)

            guard start < end,
                  end <= UInt64(data.count),
                  let actual = digest(
                    data.subdata(in: Int(start)..<Int(end))
                  )
            else {
                return false
            }

            let storedOffset = hashOffset + index * hashSize
            guard storedOffset <= directory.count - hashSize else {
                return false
            }

            let stored = directory.subdata(
                in: storedOffset..<(storedOffset + hashSize)
            )

            guard actual == stored else { return false }
        }

        // CMS wrapper consists of its 8-byte blob header followed by DER.
        guard wrapper.count > 8,
              let wrapperLength = be32(wrapper, 4),
              Int(wrapperLength) == wrapper.count
        else {
            return false
        }

        let der = wrapper.subdata(in: 8..<wrapper.count)

        return KIVerifyDetachedCMS(directory, der)
    }
}

struct IPASigningCoordinator {

    // KI_TVOS_MULTIPROFILE_PREFLIGHT
    // Validate all saved profiles before invoking Zsign.
    private static func validatedProfiles(
        record: SigningCertificateRecord,
        certificate: SecCertificate
    ) throws -> [(url: URL, profile: SigningCredentialValidator.ProvisioningInfo)] {

        let vault = CertificateVault.shared

        let filenames = [
            record.profileFilename
        ] + record.additionalProfileFilenames

        guard !filenames.isEmpty else {
            throw IPASigningError.invalidCredentials
        }

        var validated: [(url: URL, profile: SigningCredentialValidator.ProvisioningInfo)] = []
        var applicationIDs = Set<String>()
        var expectedTeamID: String?

        for filename in filenames {
            let url = vault.fileURL(for: filename)
            let data = try Data(contentsOf: url)

            try SigningCredentialValidator.validateProfileSignerTrust(
                profileData: data
            )

            let profile = try SigningCredentialValidator.validateProfile(
                profileData: data,
                certificate: certificate
            )

            // KI_TVOS_UDID_OPTIONAL_SIGNING
            // Signing does not require a connected Apple TV.
            // Continue restricting unsupported enterprise profiles.
            guard !profile.provisionsAllDevices,
                  profile.provisionedDevices != nil else {
                throw SigningValidationError.invalidProfile
            }

            if let expectedTeamID {
                guard profile.teamID == expectedTeamID else {
                    throw IPASigningError.provisioningTeamMismatch
                }
            } else {
                expectedTeamID = profile.teamID
            }

            guard applicationIDs.insert(
                profile.applicationIdentifier
            ).inserted else {
                throw IPASigningError.duplicateProvisioningProfile
            }

            validated.append((url: url, profile: profile))
        }

        return validated
    }

    // KI_TVOS_COMPONENT_PROFILE_PREFLIGHT
    // Require exactly one profile for each app and extension.
    private static func validateComponentProfiles(
        appURL: URL,
        profiles: [(url: URL, profile: SigningCredentialValidator.ProvisioningInfo)]
    ) throws {
        let fm = FileManager.default
        var components = [appURL]

        guard let enumerator = fm.enumerator(
            at: appURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            throw IPAWorkspaceError.invalidIPA
        }

        for case let candidate as URL in enumerator {
            let ext = candidate.pathExtension.lowercased()

            guard ext == "appex" || ext == "app" else {
                continue
            }

            let values = try candidate.resourceValues(
                forKeys: [.isDirectoryKey]
            )

            guard values.isDirectory == true else {
                throw IPAWorkspaceError.invalidIPA
            }

            components.append(candidate)
        }

        var matchedIDs = Set<String>()

        for component in components {
            let infoURL = component.appendingPathComponent(
                "Info.plist"
            )

            let data = try Data(contentsOf: infoURL)

            guard let info = try PropertyListSerialization
                .propertyList(
                    from: data,
                    options: [],
                    format: nil
                ) as? [String: Any],
                let bundleID = info["CFBundleIdentifier"] as? String,
                !bundleID.isEmpty else {
                throw IPAWorkspaceError.invalidIPA
            }

            let matches = profiles.filter {
                $0.profile.applicationIdentifier ==
                    $0.profile.teamID + "." + bundleID
            }

            guard matches.count == 1 else {
                throw IPASigningError.invalidCredentials
            }

            guard matchedIDs.insert(
                matches[0].profile.applicationIdentifier
            ).inserted else {
                throw IPASigningError.duplicateProvisioningProfile
            }
        }

        guard matchedIDs.count == profiles.count else {
            throw IPASigningError.invalidCredentials
        }
    }

    static func sign(
        workspace: IPAWorkspace,
        record: SigningCertificateRecord
    ) throws -> URL {

        let vault = CertificateVault.shared

        let p12URL = vault.fileURL(
            for: record.p12Filename
        )

        let password = try vault.password(
            for: record
        )

        guard FileManager.default.fileExists(
            atPath: p12URL.path
        ) else {
            throw IPASigningError.invalidCredentials
        }

        // Validate the selected signing identity.
        let p12Data = try Data(contentsOf: p12URL)

        let identity = try SigningCredentialValidator.importIdentity(
            p12Data: p12Data,
            password: password
        )

        let certificate = try SigningCredentialValidator.certificate(
            from: identity
        )

        _ = try SigningCredentialValidator.validateCertificateDates(
            certificate
        )

        // KI_TVOS_MULTIPROFILE_INTEGRATION
        // Validate every profile before modifying the workspace.
        let profiles = try validatedProfiles(
            record: record,
            certificate: certificate
        )

        let appURL = try workspace.extractAndVerify()

        // Validate the extracted application's tvOS platform.
        let infoURL = appURL.appendingPathComponent("Info.plist")
        let infoData = try Data(contentsOf: infoURL)

        guard let info = try PropertyListSerialization
            .propertyList(
                from: infoData,
                options: [],
                format: nil
            ) as? [String: Any],
            let platforms = info[
                "CFBundleSupportedPlatforms"
            ] as? [String],
            platforms.contains("AppleTVOS") else {
            throw IPASigningError.unsupportedAppPlatform
        }

        // Require one matching profile for each app/extension.
        try validateComponentProfiles(
            appURL: appURL,
            profiles: profiles
        )

        // The native engine embeds each component's profile
        // before generating its resource seal.
        let success = Zsign.signMultipleProfiles(
            appPath: appURL.path,
            provisionPaths: profiles.map { $0.url.path },
            p12Path: p12URL.path,
            p12Password: password
        )

        guard success else {
            throw IPASigningError.signingFailed
        }

        guard MachOSignatureVerifier.verifyMainExecutable(in: appURL) else {
            throw IPASigningError.signatureVerificationFailed
        }

        guard MachOSignatureVerifier.verifyNestedCode(in: appURL) else {
            throw IPASigningError.signatureVerificationFailed
        }

        return appURL
    }
}
