import Foundation

enum RemotePairingFramingError: Error {
    case frameTooLarge
    case invalidMagic
    case invalidLength
}

struct RemotePairingFraming {

    static let magic = Data("RPPairing".utf8)

    static func encode(_ body: Data) throws -> Data {
        guard body.count <= Int(UInt16.max) else {
            throw RemotePairingFramingError.frameTooLarge
        }

        let length = UInt16(body.count)

        var frame = Data()
        frame.append(magic)
        frame.append(UInt8(length >> 8))
        frame.append(UInt8(length & 0xff))
        frame.append(body)

        return frame
    }

    static func decodeHeader(_ header: Data) throws -> Int {
        guard header.count == magic.count + 2 else {
            throw RemotePairingFramingError.invalidLength
        }

        guard header.prefix(magic.count) == magic else {
            throw RemotePairingFramingError.invalidMagic
        }

        let offset = magic.count

        let length =
            (UInt16(header[offset]) << 8)
            | UInt16(header[offset + 1])

        return Int(length)
    }
}
