import Foundation
import CryptoKit
import Crypto
import SRP

enum RemotePairingCryptoError: LocalizedError {
    case invalidKey
    case invalidNonce
    case invalidData

    var errorDescription: String? {
        switch self {
        case .invalidKey:
            return "Invalid cryptographic key."
        case .invalidNonce:
            return "Invalid cryptographic nonce."
        case .invalidData:
            return "Invalid cryptographic data."
        }
    }
}

struct RemotePairingCrypto {

    // MARK: - SRP-6a / SHA-512 / 3072-bit

    static func makeSRPClient(
        pin: String
    ) -> Client<SHA512> {
        Client<SHA512>(
            username: "Pair-Setup",
            password: pin,
            group: .N3072
        )
    }

    // MARK: - X25519

    static func generateX25519KeyPair()
        -> Curve25519.KeyAgreement.PrivateKey
    {
        Curve25519.KeyAgreement.PrivateKey()
    }

    static func x25519PublicKey(
        privateKey: Curve25519.KeyAgreement.PrivateKey
    ) -> Data {
        privateKey.publicKey.rawRepresentation
    }

    static func x25519SharedSecret(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        publicKey: Data
    ) throws -> Data {

        let peerKey =
            try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: publicKey
            )

        let sharedSecret =
            try privateKey.sharedSecretFromKeyAgreement(
                with: peerKey
            )

        return sharedSecret.withUnsafeBytes {
            Data($0)
        }
    }

    // MARK: - HKDF-SHA512

    static func hkdfSHA512(
        keyMaterial: Data,
        salt: Data?,
        info: Data,
        outputByteCount: Int
    ) -> Data {

        let key = SymmetricKey(data: keyMaterial)

        let derived =
            HKDF<SHA512>.deriveKey(
                inputKeyMaterial: key,
                salt: salt ?? Data(),
                info: info,
                outputByteCount: outputByteCount
            )

        return derived.withUnsafeBytes {
            Data($0)
        }
    }

    // MARK: - ChaCha20-Poly1305

    static func encrypt(
        key: Data,
        nonce: Data,
        plaintext: Data,
        authenticatedData: Data = Data()
    ) throws -> Data {

        guard key.count == 32 else {
            throw RemotePairingCryptoError.invalidKey
        }

        guard nonce.count == 12 else {
            throw RemotePairingCryptoError.invalidNonce
        }

        let symmetricKey = SymmetricKey(data: key)

        let nonceValue =
            try ChaChaPoly.Nonce(data: nonce)

        let sealedBox =
            try ChaChaPoly.seal(
                plaintext,
                using: symmetricKey,
                nonce: nonceValue,
                authenticating: authenticatedData
            )

        var result = Data()
        result.append(sealedBox.ciphertext)
        result.append(sealedBox.tag)

        return result
    }

    static func decrypt(
        key: Data,
        nonce: Data,
        ciphertextAndTag: Data,
        authenticatedData: Data = Data()
    ) throws -> Data {

        guard key.count == 32 else {
            throw RemotePairingCryptoError.invalidKey
        }

        guard nonce.count == 12 else {
            throw RemotePairingCryptoError.invalidNonce
        }

        guard ciphertextAndTag.count >= 16 else {
            throw RemotePairingCryptoError.invalidData
        }

        let symmetricKey = SymmetricKey(data: key)

        let nonceValue =
            try ChaChaPoly.Nonce(data: nonce)

        let tagStart =
            ciphertextAndTag.count - 16

        let ciphertext =
            ciphertextAndTag[..<tagStart]

        let tag =
            ciphertextAndTag[tagStart...]

        let sealedBox =
            try ChaChaPoly.SealedBox(
                nonce: nonceValue,
                ciphertext: ciphertext,
                tag: tag
            )

        return try ChaChaPoly.open(
            sealedBox,
            using: symmetricKey,
            authenticating: authenticatedData
        )
    }

    // MARK: - Ed25519

    static func generateSigningKey()
        -> Curve25519.Signing.PrivateKey
    {
        Curve25519.Signing.PrivateKey()
    }

    static func sign(
        privateKey: Curve25519.Signing.PrivateKey,
        data: Data
    ) throws -> Data {
        try privateKey.signature(for: data)
    }

    static func publicSigningKey(
        privateKey: Curve25519.Signing.PrivateKey
    ) -> Data {
        privateKey.publicKey.rawRepresentation
    }

    // MARK: - Pair-Setup M5/M6

    static func makePairSetupEncryptionKey(
        sessionKey: Data
    ) -> Data {

        hkdfSHA512(
            keyMaterial: sessionKey,
            salt: Data("Pair-Setup-Encrypt-Salt".utf8),
            info: Data("Pair-Setup-Encrypt-Info".utf8),
            outputByteCount: 32
        )
    }

    static func makePairSetupSignBufferKey(
        sessionKey: Data
    ) -> Data {

        hkdfSHA512(
            keyMaterial: sessionKey,
            salt: Data("Pair-Setup-Controller-Sign-Salt".utf8),
            info: Data("Pair-Setup-Controller-Sign-Info".utf8),
            outputByteCount: 32
        )
    }

    static func makePairSetupSignature(
        sessionKey: Data,
        hostIdentifier: String,
        signingPrivateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {

        var signBuffer = makePairSetupSignBufferKey(
            sessionKey: sessionKey
        )

        signBuffer.append(
            contentsOf: Data(hostIdentifier.utf8)
        )

        signBuffer.append(
            contentsOf: signingPrivateKey
                .publicKey
                .rawRepresentation
        )

        return try sign(
            privateKey: signingPrivateKey,
            data: signBuffer
        )
    }

    static func encryptPairSetupMessage05(
        encryptionKey: Data,
        plaintext: Data
    ) throws -> Data {

        let nonce = Data(
            [
                0x00, 0x00, 0x00, 0x00,
                0x50, 0x53, 0x2d, 0x4d,
                0x73, 0x67, 0x30, 0x35
            ]
        )

        return try encrypt(
            key: encryptionKey,
            nonce: nonce,
            plaintext: plaintext,
            authenticatedData: Data()
        )
    }

    static func decryptPairSetupMessage06(
        encryptionKey: Data,
        ciphertext: Data
    ) throws -> Data {

        let nonce = Data(
            [
                0x00, 0x00, 0x00, 0x00,
                0x50, 0x53, 0x2d, 0x4d,
                0x73, 0x67, 0x30, 0x36
            ]
        )

        return try decrypt(
            key: encryptionKey,
            nonce: nonce,
            ciphertextAndTag: ciphertext,
            authenticatedData: Data()
        )
    }

    static func makeMainEncryptionKey(
        sessionKey: Data,
        label: String
    ) -> SymmetricKey {

        let zeroSalt = Data(
            repeating: 0,
            count: 64
        )

        return HKDF<SHA512>.deriveKey(
            inputKeyMaterial: SymmetricKey(
                data: sessionKey
            ),
            salt: zeroSalt,
            info: Data(label.utf8),
            outputByteCount: 32
        )
    }

    static func computeAuthTag(
        altIRK: Data,
        serviceIdentifier: String
    ) -> Data {

        precondition(
            altIRK.count == 16,
            "altIRK must be 16 bytes"
        )

        let hash =
            sipHash24(
                key: altIRK,
                message: Data(serviceIdentifier.utf8)
            )

        var littleEndian = hash.littleEndian

        let hashData = withUnsafeBytes(
            of: &littleEndian
        ) {
            Data($0)
        }

        return Data(
            hashData
                .prefix(6)
                .reversed()
        )
    }

    private static func sipHash24(
        key: Data,
        message: Data
    ) -> UInt64 {

        precondition(
            key.count == 16,
            "SipHash key must be 16 bytes"
        )

        let k0 = readUInt64LE(
            key,
            offset: 0
        )

        let k1 = readUInt64LE(
            key,
            offset: 8
        )

        var v0 =
            k0 ^ 0x736F6D6570736575

        var v1 =
            k1 ^ 0x646F72616E646F6D

        var v2 =
            k0 ^ 0x6C7967656E657261

        var v3 =
            k1 ^ 0x7465646279746573

        @inline(__always)
        func rotl(
            _ value: UInt64,
            _ amount: UInt64
        ) -> UInt64 {

            (value << amount)
                | (value >> (64 - amount))
        }

        @inline(__always)
        func sipRound() {

            v0 &+= v1
            v1 = rotl(v1, 13)
            v1 ^= v0
            v0 = rotl(v0, 32)

            v2 &+= v3
            v3 = rotl(v3, 16)
            v3 ^= v2

            v0 &+= v3
            v3 = rotl(v3, 21)
            v3 ^= v0

            v2 &+= v1
            v1 = rotl(v1, 17)
            v1 ^= v2
            v2 = rotl(v2, 32)
        }

        let length = message.count
        let end = length - (length % 8)

        for offset in stride(
            from: 0,
            to: end,
            by: 8
        ) {

            let m =
                readUInt64LE(
                    message,
                    offset: offset
                )

            v3 ^= m

            sipRound()
            sipRound()

            v0 ^= m
        }

        var last =
            UInt64(length & 0xff) << 56

        let remainder =
            length - end

        if remainder > 0 {

            for i in 0..<remainder {

                last |=
                    UInt64(
                        message[end + i]
                    ) << UInt64(8 * i)
            }
        }

        v3 ^= last

        sipRound()
        sipRound()

        v0 ^= last

        v2 ^= 0xff

        sipRound()
        sipRound()
        sipRound()
        sipRound()

        return v0 ^ v1 ^ v2 ^ v3
    }

    private static func readUInt64LE(
        _ data: Data,
        offset: Int
    ) -> UInt64 {

        var value: UInt64 = 0

        for i in 0..<8 {

            value |=
                UInt64(data[offset + i])
                << UInt64(8 * i)
        }

        return value
    }

    static func testAuthTag() {
        let altIRK = Data(
            [
                0xe9, 0xe8, 0x2d, 0xc0,
                0x6a, 0x49, 0x79, 0x6b,
                0x56, 0x6f, 0x54, 0x00,
                0x19, 0xb1, 0xc7, 0x7b
            ]
        )

        let tag = computeAuthTag(
            altIRK: altIRK,
            serviceIdentifier: "TEST"
        )

        print(
            "SWIFT AUTH TAG:",
            tag.map {
                String(format: "%02x", $0)
            }.joined()
        )
    }
}
