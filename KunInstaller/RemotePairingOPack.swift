import Foundation

enum RemotePairingOPackError: LocalizedError {
    case unsupportedType
    case truncated
    case invalidObject
    case integerOutOfBounds

    var errorDescription: String? {
        switch self {
        case .unsupportedType:
            return "Unsupported OPACK type."
        case .truncated:
            return "Truncated OPACK data."
        case .invalidObject:
            return "Invalid OPACK object."
        case .integerOutOfBounds:
            return "Integer is outside the supported OPACK range."
        }
    }
}

enum RemotePairingOPack {

    // MARK: - Public

    static func encode(_ object: Any) throws -> Data {
        var output = Data()
        try encodeObject(object, into: &output)
        return output
    }

    static func decode(_ data: Data) throws -> Any {
        var offset = 0
        let value = try decodeObject(data, offset: &offset)

        guard offset == data.count else {
            throw RemotePairingOPackError.invalidObject
        }

        return value
    }

    // MARK: - Encoding

    private static func encodeObject(
        _ object: Any,
        into output: inout Data
    ) throws {

        if let value = object as? Bool {
            output.append(value ? 0x01 : 0x02)
            return
        }

        if let value = object as? Int {
            try encodeInteger(value, into: &output)
            return
        }

        if let value = object as? UInt64 {
            guard value <= UInt64.max else {
                throw RemotePairingOPackError.integerOutOfBounds
            }

            try encodeUnsignedInteger(value, into: &output)
            return
        }

        if let value = object as? String {
            try encodeString(value, into: &output)
            return
        }

        if let value = object as? Data {
            try encodeBytes(value, into: &output)
            return
        }

        if let value = object as? [Any] {
            try encodeArray(value, into: &output)
            return
        }

        if let value = object as? [String: Any] {
            try encodeDictionary(value, into: &output)
            return
        }

        throw RemotePairingOPackError.unsupportedType
    }

    // MARK: - Integer

    private static func encodeInteger(
        _ value: Int,
        into output: inout Data
    ) throws {

        guard value >= 0 else {
            throw RemotePairingOPackError.unsupportedType
        }

        try encodeUnsignedInteger(
            UInt64(value),
            into: &output
        )
    }

    private static func encodeUnsignedInteger(
        _ value: UInt64,
        into output: inout Data
    ) throws {

        // 0x08 ... 0x2F represent integer values 0 ... 0x27.
        if value <= 0x27 {
            output.append(UInt8(value + 8))
            return
        }

        // UInt8
        if value <= 0xFF {
            output.append(0x30)
            output.append(UInt8(value))
            return
        }

        // UInt32 little-endian
        if value <= UInt64(UInt32.max) {
            output.append(0x32)

            let v = UInt32(value)

            output.append(UInt8(v & 0xFF))
            output.append(UInt8((v >> 8) & 0xFF))
            output.append(UInt8((v >> 16) & 0xFF))
            output.append(UInt8((v >> 24) & 0xFF))

            return
        }

        // UInt64 little-endian
        output.append(0x33)

        for shift in stride(
            from: 0,
            through: 56,
            by: 8
        ) {
            output.append(
                UInt8(
                    (value >> UInt64(shift)) & 0xFF
                )
            )
        }
    }

    // MARK: - Strings

    private static func encodeString(
        _ value: String,
        into output: inout Data
    ) throws {

        let bytes = Array(value.utf8)

        // Short string:
        // type = 0x40 + byte count
        if bytes.count <= 0x20 {
            output.append(
                UInt8(0x40 + bytes.count)
            )
            output.append(contentsOf: bytes)
            return
        }

        if bytes.count <= 0xFF {
            output.append(0x61)
            output.append(UInt8(bytes.count))
            output.append(contentsOf: bytes)
            return
        }

        if bytes.count <= Int(UInt16.max) {
            output.append(0x62)

            let count = UInt16(bytes.count)

            output.append(
                UInt8((count >> 8) & 0xFF)
            )

            output.append(
                UInt8(count & 0xFF)
            )

            output.append(contentsOf: bytes)
            return
        }

        throw RemotePairingOPackError.unsupportedType
    }

    // MARK: - Bytes

    private static func encodeBytes(
        _ value: Data,
        into output: inout Data
    ) throws {

        // Short byte string:
        // type = 0x70 + byte count
        if value.count <= 0x20 {
            output.append(
                UInt8(0x70 + value.count)
            )
            output.append(value)
            return
        }

        if value.count <= 0xFF {
            output.append(0x91)
            output.append(UInt8(value.count))
            output.append(value)
            return
        }

        if value.count <= Int(UInt16.max) {
            output.append(0x92)

            let count = UInt16(value.count)

            output.append(
                UInt8((count >> 8) & 0xFF)
            )

            output.append(
                UInt8(count & 0xFF)
            )

            output.append(value)
            return
        }

        throw RemotePairingOPackError.unsupportedType
    }

    // MARK: - Arrays

    private static func encodeArray(
        _ values: [Any],
        into output: inout Data
    ) throws {

        // opack2 uses 0xD0...0xDE for arrays
        // with fewer than 15 items.
        if values.count < 15 {
            output.append(
                UInt8(0xD0 + values.count)
            )

            for value in values {
                try encodeObject(
                    value,
                    into: &output
                )
            }

            return
        }

        // Terminated array:
        // 0xDF + elements + 0x03
        output.append(0xDF)

        for value in values {
            try encodeObject(
                value,
                into: &output
            )
        }

        output.append(0x03)
    }

    // MARK: - Dictionaries

    private static func encodeDictionary(
        _ dictionary: [String: Any],
        into output: inout Data
    ) throws {

        // IMPORTANT:
        // opack2 uses insertion order from the Mapping.
        // Swift Dictionary preserves insertion order.
        //
        // Do NOT sort these keys.

        if dictionary.count < 15 {
            output.append(
                UInt8(0xE0 + dictionary.count)
            )

            for (key, value) in dictionary {
                try encodeObject(
                    key,
                    into: &output
                )

                try encodeObject(
                    value,
                    into: &output
                )
            }

            return
        }

        // Terminated dictionary:
        // 0xEF + key/value pairs + terminator key/value.
        output.append(0xEF)

        for (key, value) in dictionary {
            try encodeObject(
                key,
                into: &output
            )

            try encodeObject(
                value,
                into: &output
            )
        }

        // Terminator object.
        output.append(0x03)
        output.append(0x03)
    }

    // MARK: - Decoding

    private static func decodeObject(
        _ data: Data,
        offset: inout Int
    ) throws -> Any {

        guard offset < data.count else {
            throw RemotePairingOPackError.truncated
        }

        let type = data[offset]
        offset += 1

        switch type {

        case 0x01:
            return true

        case 0x02:
            return false

        case 0x03:
            return NSNull()

        // Small integers: 0x08...0x2F
        case 0x08...0x2F:
            return Int(type - 8)

        case 0x30:
            return Int(
                try readUInt8(
                    data,
                    offset: &offset
                )
            )

        case 0x32:
            return Int(
                try readUInt32LE(
                    data,
                    offset: &offset
                )
            )

        case 0x33:
            let value = try readUInt64LE(
                data,
                offset: &offset
            )

            guard value <= UInt64(Int.max) else {
                return value
            }

            return Int(value)

        // Short strings: 0x40...0x60
        case 0x40...0x60:
            let count = Int(type - 0x40)

            return try readString(
                data,
                count: count,
                offset: &offset
            )

        case 0x61:
            let count = Int(
                try readUInt8(
                    data,
                    offset: &offset
                )
            )

            return try readString(
                data,
                count: count,
                offset: &offset
            )

        case 0x62:
            let count = Int(
                try readUInt16BE(
                    data,
                    offset: &offset
                )
            )

            return try readString(
                data,
                count: count,
                offset: &offset
            )

        // Short bytes: 0x70...0x90
        case 0x70...0x90:
            let count = Int(type - 0x70)

            return try readBytes(
                data,
                count: count,
                offset: &offset
            )

        case 0x91:
            let count = Int(
                try readUInt8(
                    data,
                    offset: &offset
                )
            )

            return try readBytes(
                data,
                count: count,
                offset: &offset
            )

        case 0x92:
            let count = Int(
                try readUInt16BE(
                    data,
                    offset: &offset
                )
            )

            return try readBytes(
                data,
                count: count,
                offset: &offset
            )

        // Short arrays
        case 0xD0...0xDE:
            let count = Int(type - 0xD0)

            var values: [Any] = []
            values.reserveCapacity(count)

            for _ in 0..<count {
                values.append(
                    try decodeObject(
                        data,
                        offset: &offset
                    )
                )
            }

            return values

        // Terminated array
        case 0xDF:
            var values: [Any] = []

            while true {
                let value = try decodeObject(
                    data,
                    offset: &offset
                )

                if value is NSNull {
                    break
                }

                values.append(value)
            }

            return values

        // Short dictionaries
        case 0xE0...0xEE:
            let count = Int(type - 0xE0)

            var result: [String: Any] = [:]

            for _ in 0..<count {
                let keyObject = try decodeObject(
                    data,
                    offset: &offset
                )

                guard let key = keyObject as? String else {
                    throw RemotePairingOPackError.invalidObject
                }

                result[key] = try decodeObject(
                    data,
                    offset: &offset
                )
            }

            return result

        // Terminated dictionary
        case 0xEF:
            var result: [String: Any] = [:]

            while true {
                let key = try decodeObject(
                    data,
                    offset: &offset
                )

                if key is NSNull {
                    _ = try decodeObject(
                        data,
                        offset: &offset
                    )
                    break
                }

                guard let stringKey = key as? String else {
                    throw RemotePairingOPackError.invalidObject
                }

                result[stringKey] = try decodeObject(
                    data,
                    offset: &offset
                )
            }

            return result

        default:
            throw RemotePairingOPackError.unsupportedType
        }
    }

    // MARK: - Readers

    private static func readUInt8(
        _ data: Data,
        offset: inout Int
    ) throws -> UInt8 {

        guard offset < data.count else {
            throw RemotePairingOPackError.truncated
        }

        let value = data[offset]
        offset += 1

        return value
    }

    private static func readUInt16BE(
        _ data: Data,
        offset: inout Int
    ) throws -> UInt16 {

        guard offset + 2 <= data.count else {
            throw RemotePairingOPackError.truncated
        }

        let value =
            (UInt16(data[offset]) << 8)
            | UInt16(data[offset + 1])

        offset += 2

        return value
    }

    private static func readUInt32LE(
        _ data: Data,
        offset: inout Int
    ) throws -> UInt32 {

        guard offset + 4 <= data.count else {
            throw RemotePairingOPackError.truncated
        }

        let value =
            UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)

        offset += 4

        return value
    }

    private static func readUInt64LE(
        _ data: Data,
        offset: inout Int
    ) throws -> UInt64 {

        guard offset + 8 <= data.count else {
            throw RemotePairingOPackError.truncated
        }

        var value: UInt64 = 0

        for index in 0..<8 {
            value |=
                UInt64(data[offset + index])
                << UInt64(index * 8)
        }

        offset += 8

        return value
    }

    private static func readString(
        _ data: Data,
        count: Int,
        offset: inout Int
    ) throws -> String {

        guard offset + count <= data.count else {
            throw RemotePairingOPackError.truncated
        }

        let value = Data(
            data[offset ..< offset + count]
        )

        offset += count

        guard let string = String(
            data: value,
            encoding: .utf8
        ) else {
            throw RemotePairingOPackError.invalidObject
        }

        return string
    }

    private static func readBytes(
        _ data: Data,
        count: Int,
        offset: inout Int
    ) throws -> Data {

        guard offset + count <= data.count else {
            throw RemotePairingOPackError.truncated
        }

        let value = Data(
            data[offset ..< offset + count]
        )

        offset += count

        return value
    }

    // MARK: - Ordered Dictionary

    static func encodeDictionary(
        _ entries: [(String, Any)]
    ) throws -> Data {

        guard entries.count < 15 else {
            throw RemotePairingOPackError.unsupportedType
        }

        var output = Data()

        output.append(
            UInt8(0xE0 + entries.count)
        )

        for (key, value) in entries {

            try encodeObject(
                key,
                into: &output
            )

            try encodeObject(
                value,
                into: &output
            )
        }

        return output
    }

    }   // <-- THIS closes RemotePairingOPack


    #if DEBUG

    enum RemotePairingOPackTest {

        static func run() {

            let entries: [(String, Any)] = [
                (
                    "altIRK",
                    Data("1234567890123456".utf8)
                ),
                (
                    "btAddr",
                    "11:22:33:44:55:66"
                ),
                (
                    "mac",
                    Data("123456".utf8)
                ),
                (
                    "accountID",
                    "TEST"
                ),
                (
                    "model",
                    "computer-model"
                ),
                (
                    "name",
                    "TEST"
                )
            ]

            do {

                let encoded =
                    try RemotePairingOPack.encodeDictionary(
                        entries
                    )

                let hex = encoded
                    .map {
                        String(
                            format: "%02x",
                            $0
                        )
                    }
                    .joined()

                print("SWIFT OPACK:")
                print(hex)

            } catch {

                print("OPACK TEST FAILED:")
                print(
                    error.localizedDescription
                )
            }
        }
    }

    #endif
