import Foundation

enum PairingDataComponentType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case retryDelay = 0x08
    case certificate = 0x09
    case signature = 0x0A
    case permissions = 0x0B
    case fragmentData = 0x0C
    case fragmentLast = 0x0D
    case sessionID = 0x0E
    case ttl = 0x0F
    case extraData = 0x10
    case info = 0x11
    case acl = 0x12
    case flags = 0x13
    case validationData = 0x14
    case mfiAuthToken = 0x15
    case mfiProductType = 0x16
    case serialNumber = 0x17
    case mfiAuthTokenUUID = 0x18
    case appFlags = 0x19
    case ownershipProof = 0x1A
    case setupCodeType = 0x1B
    case productionData = 0x1C
    case appInfo = 0x1D
    case separator = 0xFF
}

struct PairingTLV {
    let type: PairingDataComponentType
    let data: Data
}

enum PairingTLVError: LocalizedError {
    case truncated
    case invalidType(UInt8)

    var errorDescription: String? {
        switch self {
        case .truncated:
            return "Truncated pairing TLV data."
        case .invalidType(let raw):
            return "Unknown pairing TLV type: 0x\(String(raw, radix: 16))"
        }
    }
}

enum PairingTLVCodec {

    static func encode(_ entries: [PairingTLV]) -> Data {
        var output = Data()

        for entry in entries {
            let bytes = [UInt8](entry.data)

            if bytes.isEmpty {
                output.append(entry.type.rawValue)
                output.append(0)
                continue
            }

            var offset = 0

            while offset < bytes.count {
                let chunkLength = min(
                    bytes.count - offset,
                    255
                )

                output.append(entry.type.rawValue)
                output.append(UInt8(chunkLength))

                output.append(
                    contentsOf: bytes[
                        offset ..< offset + chunkLength
                    ]
                )

                offset += chunkLength
            }
        }

        return output
    }

    static func decode(
        _ data: Data
    ) throws -> [PairingTLV] {

        var result: [PairingTLV] = []
        var index = 0

        while index < data.count {

            guard index + 2 <= data.count else {
                throw PairingTLVError.truncated
            }

            let rawType = data[index]
            let length = Int(data[index + 1])

            index += 2

            guard index + length <= data.count else {
                throw PairingTLVError.truncated
            }

            guard let type = PairingDataComponentType(
                rawValue: rawType
            ) else {
                throw PairingTLVError.invalidType(rawType)
            }

            let value = Data(
                data[index ..< index + length]
            )

            if let existingIndex = result.firstIndex(
                where: { $0.type == type }
            ) {
                let combined = result[existingIndex].data + value

                result[existingIndex] = PairingTLV(
                    type: type,
                    data: combined
                )
            } else {
                result.append(
                    PairingTLV(
                        type: type,
                        data: value
                    )
                )
            }

            index += length
        }

        return result
    }

    static func values(
        for type: PairingDataComponentType,
        in entries: [PairingTLV]
    ) -> [Data] {
        entries
            .filter { $0.type == type }
            .map(\.data)
    }

    static func firstValue(
        for type: PairingDataComponentType,
        in entries: [PairingTLV]
    ) -> Data? {
        values(for: type, in: entries).first
    }
}
