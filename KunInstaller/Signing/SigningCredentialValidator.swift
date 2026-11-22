
import Foundation
import Security
import ZsignC

enum SigningValidationError: LocalizedError {
    case invalidCertificate(OSStatus)
    case missingIdentity
    case missingCertificate
    case expiredCertificate
    case invalidProfile
    case expiredProfile
    case certificateMismatch
    case unsupportedPlatform
    case deviceNotProvisioned
    case missingDeviceUDID

    var errorDescription: String? {
        switch self {
        case .invalidCertificate(let status):
            return "Unable to unlock the .p12 certificate (status \(status))."
        case .missingIdentity:
            return "The .p12 file does not contain a signing identity."
        case .missingCertificate:
            return "The signing identity has no certificate."
        case .expiredCertificate:
            return "The signing certificate has expired."
        case .invalidProfile:
            return "The provisioning profile is invalid."
        case .expiredProfile:
            return "The provisioning profile has expired."
        case .certificateMismatch:
            return "The certificate does not match the provisioning profile."
        case .unsupportedPlatform:
            return "The provisioning profile does not support tvOS."
        case .deviceNotProvisioned:
            return "The selected Apple TV is not included in the provisioning profile."
        case .missingDeviceUDID:
            return "Retrieve the Apple TV UDID before signing."
        }
    }
}

struct SigningCredentialValidator {

    static func importIdentity(
        p12Data: Data,
        password: String
    ) throws -> SecIdentity {

        let options: [String: Any] = [
            kSecImportExportPassphrase as String: password
        ]

        var importedItems: CFArray?

        let status = SecPKCS12Import(
            p12Data as CFData,
            options as CFDictionary,
            &importedItems
        )

        guard status == errSecSuccess else {
            throw SigningValidationError.invalidCertificate(status)
        }

        guard let items = importedItems as? [[String: Any]],
              let first = items.first,
              let identityValue = first[
                kSecImportItemIdentity as String
              ] else {
            throw SigningValidationError.missingIdentity
        }

        return identityValue as! SecIdentity
    }

    static func certificate(
        from identity: SecIdentity
    ) throws -> SecCertificate {

        var certificate: SecCertificate?

        let status = SecIdentityCopyCertificate(
            identity,
            &certificate
        )

        guard status == errSecSuccess,
              let certificate else {
            throw SigningValidationError.missingCertificate
        }

        return certificate
    }


    static func validateCertificate(
        _ certificate: SecCertificate
    ) throws {

        let policy = SecPolicyCreateBasicX509()

        var trust: SecTrust?

        let status = SecTrustCreateWithCertificates(
            certificate,
            policy,
            &trust
        )

        guard status == errSecSuccess,
              let trust else {
            throw SigningValidationError.invalidCertificate(status)
        }

        // Evaluate the certificate against the basic X.509 policy.
        // This is not an Apple Developer signing-authorization check.
        var error: CFError?

        guard SecTrustEvaluateWithError(trust, &error) else {
            throw SigningValidationError.invalidCertificate(
                errSecNotTrusted
            )
        }
    }


    struct CertificateValidity {
        let validFrom: Date
        let validUntil: Date
    }


    static func validateCertificateDates(
        _ certificate: SecCertificate
    ) throws -> CertificateValidity {

        guard #available(iOS 18.0, *) else {
            throw SigningValidationError.invalidCertificate(
                errSecUnimplemented
            )
        }

        guard let fromCF =
            SecCertificateCopyNotValidBeforeDate(certificate),
              let untilCF =
            SecCertificateCopyNotValidAfterDate(certificate) else {
            throw SigningValidationError.invalidCertificate(
                errSecDecode
            )
        }

        let validFrom = fromCF as Date
        let validUntil = untilCF as Date

        let now = Date()

        guard validFrom <= now else {
            throw SigningValidationError.invalidCertificate(
                errSecNotTrusted
            )
        }

        guard validUntil > now else {
            throw SigningValidationError.expiredCertificate
        }

        return CertificateValidity(
            validFrom: validFrom,
            validUntil: validUntil
        )
    }


    static func validateProfileSignerTrust(
        profileData: Data
    ) throws {

        guard let certificateData =
            KIExtractProvisioningSignerCertificates(profileData),
            !certificateData.isEmpty else {
            throw SigningValidationError.invalidProfile
        }

        var certificates: [SecCertificate] = []

        for data in certificateData {
            guard let certificate =
                SecCertificateCreateWithData(
                    nil,
                    data as CFData
                ) else {
                throw SigningValidationError.invalidProfile
            }

            certificates.append(certificate)
        }

        let policy = SecPolicyCreateBasicX509()

        var trust: SecTrust?

        let status = SecTrustCreateWithCertificates(
            certificates as CFArray,
            policy,
            &trust
        )

        guard status == errSecSuccess,
              let trust else {
            throw SigningValidationError.invalidCertificate(status)
        }

        var trustError: CFError?

        guard SecTrustEvaluateWithError(
            trust,
            &trustError
        ) else {
            throw SigningValidationError.invalidCertificate(
                errSecNotTrusted
            )
        }
    }

    struct ProvisioningInfo {
        let name: String
        let teamID: String
        let applicationIdentifier: String
        let expirationDate: Date
        let certificateCount: Int
        let provisionedDevices: [String]?
        let provisionsAllDevices: Bool
    }

    static func validateAppleTV(
        udid: String?,
        profile: ProvisioningInfo
    ) throws {
        // Initial tvOS signing support is limited to
        // device-specific development and Ad Hoc profiles.
        // Enterprise profiles are not supported yet.
        guard !profile.provisionsAllDevices else {
            throw SigningValidationError.invalidProfile
        }

        guard let udid,
              !udid.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            throw SigningValidationError.missingDeviceUDID
        }

        guard let devices = profile.provisionedDevices,
              devices.contains(udid) else {
            throw SigningValidationError.deviceNotProvisioned
        }
    }

    static func validateProfile(
        profileData: Data,
        certificate: SecCertificate
    ) throws -> ProvisioningInfo {

        // Extracts CMS content without verifying its signature.
        guard let plistData =
            KIExtractProvisioningProfile(profileData) else {
            throw SigningValidationError.invalidProfile
        }

        guard let profile = try PropertyListSerialization
            .propertyList(
                from: plistData,
                options: [],
                format: nil
            ) as? [String: Any] else {
            throw SigningValidationError.invalidProfile
        }

        guard let platforms = profile["Platform"] as? [String],
              platforms.contains("tvOS") else {
            throw SigningValidationError.unsupportedPlatform
        }

        guard let expiration =
            profile["ExpirationDate"] as? Date,
            expiration > Date() else {
            throw SigningValidationError.expiredProfile
        }

        guard let teamIDs =
            profile["TeamIdentifier"] as? [String],
            let teamID = teamIDs.first,
            !teamID.isEmpty else {
            throw SigningValidationError.invalidProfile
        }

        guard let entitlements =
            profile["Entitlements"] as? [String: Any],
            let applicationIdentifier =
                entitlements["application-identifier"] as? String,
            !applicationIdentifier.isEmpty else {
            throw SigningValidationError.invalidProfile
        }

        guard let developerCertificates =
            profile["DeveloperCertificates"] as? [Data],
            !developerCertificates.isEmpty else {
            throw SigningValidationError.invalidProfile
        }

        let certificateData =
            SecCertificateCopyData(certificate) as Data

        guard developerCertificates.contains(
            where: { $0 == certificateData }
        ) else {
            throw SigningValidationError.certificateMismatch
        }

        return ProvisioningInfo(
            name: profile["Name"] as? String ?? "Unknown Profile",
            teamID: teamID,
            applicationIdentifier: applicationIdentifier,
            expirationDate: expiration,
            certificateCount: developerCertificates.count,
            provisionedDevices: profile["ProvisionedDevices"] as? [String],
            provisionsAllDevices: profile["ProvisionsAllDevices"] as? Bool ?? false
        )
    }

}
