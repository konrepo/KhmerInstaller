
import Foundation
import Network

final class RemoteXPC {

    enum Error: Swift.Error, LocalizedError {
        case notReady
        case connectionFailed(String)
        case connectionClosed
        case invalidResponse
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notReady:
                return "RSD connection is not ready."
            case .connectionFailed(let message):
                return "RSD connection failed: \(message)"
            case .connectionClosed:
                return "RSD connection closed."
            case .invalidResponse:
                return "Invalid RemoteXPC response."
            case .writeFailed(let message):
                return "RSD write failed: \(message)"
            }
        }
    }

    static let rootChannel: UInt32 = 1
    static let replyChannel: UInt32 = 3

    static let messagingProtocolVersion: UInt64 = 7

    static let remoteXPCVersionFlags: UInt64 =
        0x0100000000000006

    private let connection: NWConnection

    private var receiveBuffer =
        Data()

    private var discoveredUniqueDeviceID: String?

    private var rawReceiveBuffer =
        Data()

    init(
        address: String,
        port: Int,
        interface: NWInterface
    ) throws {

        guard
            let nwPort = NWEndpoint.Port(
                rawValue: UInt16(port)
            )
        else {
            throw Error.connectionFailed(
                "Invalid RSD port \(port)"
            )
        }

        let parameters = NWParameters.tcp

        parameters.requiredInterface = interface

        connection = NWConnection(
            host: NWEndpoint.Host(address),
            port: nwPort,
            using: parameters
        )
    }

    func connect() async throws {

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Void, Swift.Error>
            ) in

            var finished = false

            connection.stateUpdateHandler = { state in

                switch state {

                case .ready:
                    guard !finished else {
                        return
                    }

                    finished = true

                    print(
                        "RemoteXPC RSD TCP ready"
                    )

                    continuation.resume()

                case .failed(let error):
                    guard !finished else {
                        return
                    }

                    finished = true

                    continuation.resume(
                        throwing:
                            Error.connectionFailed(
                                error.localizedDescription
                            )
                    )

                case .cancelled:
                    guard !finished else {
                        return
                    }

                    finished = true

                    continuation.resume(
                        throwing:
                            Error.connectionClosed
                    )

                default:
                    break
                }
            }

            connection.start(
                queue: .global(
                    qos: .userInitiated
                )
            )
        }
    }

    func debugTCPConnectionDescription() -> String {

        return "TCP connection ready"
    }

    func debugTCPConnectionState() -> String {

        switch connection.state {

        case .setup:
            return "setup"

        case .waiting(let error):
            return "waiting: \(error.localizedDescription)"

        case .preparing:
            return "preparing"

        case .ready:
            return "ready"

        case .failed(let error):
            return "failed: \(error.localizedDescription)"

        case .cancelled:
            return "cancelled"

        @unknown default:
            return "unknown"
        }
    }

    func sendRaw(
        _ data: Data
    ) async throws {

        try await send(
            data
        )
    }

    func receiveRaw(
        minimumIncompleteLength: Int = 1,
        maximumLength: Int = 65536
    ) async throws -> Data {

        return try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Data, Swift.Error>
            ) in

            connection.receive(
                minimumIncompleteLength:
                    minimumIncompleteLength,
                maximumLength:
                    maximumLength
            ) {
                content,
                _,
                isComplete,
                error in

                if let error {

                    continuation.resume(
                        throwing:
                            Error.connectionFailed(
                                error.localizedDescription
                            )
                    )

                    return
                }

                if let content,
                   !content.isEmpty {

                    continuation.resume(
                        returning:
                            content
                    )

                    return
                }

                if isComplete {

                    continuation.resume(
                        throwing:
                            Error.connectionClosed
                    )

                    return
                }

                continuation.resume(
                    throwing:
                        Error.invalidResponse
                )
            }
        }
    }

    func receiveExact(
        _ size: Int
    ) async throws -> Data {

        guard size >= 0 else {
            throw Error.invalidResponse
        }

        while rawReceiveBuffer.count < size {

            let chunk =
                try await receiveRaw(
                    maximumLength: 65536
                )

            guard !chunk.isEmpty else {
                throw Error.connectionClosed
            }

            rawReceiveBuffer.append(
                chunk
            )
        }

        let result =
            Data(
                rawReceiveBuffer.prefix(
                    size
                )
            )

        rawReceiveBuffer.removeFirst(
            size
        )

        return result
    }

    func sendInitialHandshake(
        hostUUID: UUID
    ) async throws {

        let stream =
            try buildInitialStream(
                hostUUID: hostUUID
            )

        print(
            "RemoteXPC initial stream bytes:",
            stream.count
        )

        print(
            "RemoteXPC initial stream hex:",
            stream.map {
                String(
                    format: "%02x",
                    $0
                )
            }.joined()
        )

        try await send(
            stream
        )
    }

    func fetchUniqueDeviceID(
        hostUUID: UUID
    ) async throws -> String {

        discoveredUniqueDeviceID = nil

        try await connect()

        try await sendInitialHandshake(
            hostUUID: hostUUID
        )

        let response =
            try await receiveFirstResponse()

        _ = debugResponseSummary(
            response
        )

        guard
            let discoveredUniqueDeviceID,
            !discoveredUniqueDeviceID.isEmpty
        else {
            throw Error.invalidResponse
        }

        return discoveredUniqueDeviceID
    }

    func receiveFirstResponse() async throws -> Data {

        var messageBuffer = Data()
        var expectedMessageBytes: Int?

        while true {

            let frame =
                try await receiveNextHTTP2Frame()

            guard frame.count >= 9 else {
                throw Error.invalidResponse
            }

            let type =
                frame[3]

            let flags =
                frame[4]

            let streamID =
                (UInt32(frame[5]) << 24) |
                (UInt32(frame[6]) << 16) |
                (UInt32(frame[7]) << 8) |
                UInt32(frame[8])

            print(
                "RemoteXPC received HTTP2 frame:",
                "type=0x\(String(format: "%02x", type))",
                "flags=0x\(String(format: "%02x", flags))",
                "stream=\(streamID)",
                "bytes=\(frame.count)"
            )

            // SETTINGS
            if type == 0x04 {

                if flags & 0x01 == 0 {

                    try await send(
                        http2SettingsAckFrame()
                    )

                    print(
                        "RemoteXPC sent SETTINGS ACK"
                    )
                }

                continue
            }

            // WINDOW_UPDATE
            if type == 0x08 {
                continue
            }

            // HEADERS
            if type == 0x01 {
                continue
            }

            // Only RemoteXPC DATA on the root channel.
            guard type == 0x00,
                  streamID == Self.rootChannel else {

                continue
            }

            let fragment =
                Data(
                    frame.dropFirst(9)
                )

            print(
                "RemoteXPC DATA fragment bytes:",
                fragment.count
            )

            messageBuffer.append(
                fragment
            )

            print(
                "RemoteXPC message buffer bytes:",
                messageBuffer.count
            )

            // Once we have the 16-byte RemoteXPC wrapper header,
            // determine the complete message size.
            if expectedMessageBytes == nil &&
                messageBuffer.count >= 16 {

                let bytes =
                    Array(
                        messageBuffer.prefix(16)
                    )

                let magic =
                    UInt32(bytes[0]) |
                    (UInt32(bytes[1]) << 8) |
                    (UInt32(bytes[2]) << 16) |
                    (UInt32(bytes[3]) << 24)

                guard magic == 0x29B00B92 else {
                    throw Error.invalidResponse
                }

                var size: UInt64 = 0

                for index in 0..<8 {

                    size |=
                        UInt64(
                            bytes[8 + index]
                        ) << UInt64(index * 8)
                }

                // RemoteXPC layout:
                //
                // 4  magic
                // 4  flags
                // 8  size
                // 8  message ID
                // N  XPC payload
                //
                // `size` counts everything after the 24-byte
                // fixed wrapper through the end of the XPC payload.
                //
                // Therefore:
                //
                // total = 24 + size
                //
                expectedMessageBytes =
                    24 + Int(size)

                print(
                    "RemoteXPC expected message bytes:",
                    expectedMessageBytes!
                )
            }

            guard let totalBytes =
                expectedMessageBytes else {

                continue
            }

            // More DATA fragments are still required.
            if messageBuffer.count < totalBytes {

                print(
                    "RemoteXPC waiting for continuation:",
                    "\(messageBuffer.count)/\(totalBytes)"
                )

                continue
            }

            let complete =
                Data(
                    messageBuffer.prefix(
                        totalBytes
                    )
                )

            print(
                "RemoteXPC complete message bytes:",
                complete.count
            )

            // Remove this complete message before processing the
            // next RemoteXPC message.
            messageBuffer.removeFirst(
                totalBytes
            )

            expectedMessageBytes = nil

            // Small control response. Ignore it and continue with
            // the next RemoteXPC message.
            if complete.count <= 44 {

                print(
                    "RemoteXPC complete control message; continuing"
                )

                continue
            }

            print(
                "===== REMOTEXPC COMPLETE SUBSTANTIVE MESSAGE ====="
            )

            return complete
        }
    }

    func debugBufferedHTTP2Frames() -> String {

        var lines: [String] = []

        lines.append(
            "BUFFERED_AFTER_FIRST_FRAME=\(receiveBuffer.count)"
        )

        var probeBuffer =
            receiveBuffer

        var bufferedFrameIndex = 0

        while probeBuffer.count >= 9 {

            let header =
                Array(
                    probeBuffer.prefix(9)
                )

            let length =
                (Int(header[0]) << 16) |
                (Int(header[1]) << 8) |
                Int(header[2])

            let frameSize =
                9 + length

            guard probeBuffer.count >= frameSize else {

                let partialType =
                    header[3]

                let partialFlags =
                    header[4]

                let partialStream =
                    (UInt32(header[5]) << 24) |
                    (UInt32(header[6]) << 16) |
                    (UInt32(header[7]) << 8) |
                    UInt32(header[8])

                lines.append(
                    "BUFFERED_INCOMPLETE_BYTES=\(probeBuffer.count)"
                )

                lines.append(
                    "PARTIAL_FRAME_LENGTH=\(length)"
                )

                lines.append(
                    "PARTIAL_FRAME_TYPE=0x\(String(format: "%02x", partialType))"
                )

                lines.append(
                    "PARTIAL_FRAME_FLAGS=0x\(String(format: "%02x", partialFlags))"
                )

                lines.append(
                    "PARTIAL_FRAME_STREAM=\(partialStream)"
                )

                lines.append(
                    "PARTIAL_FRAME_EXPECTED_BYTES=\(frameSize)"
                )

                lines.append(
                    "PARTIAL_FRAME_HAVE_BYTES=\(probeBuffer.count)"
                )

                break
            }

            let nextType =
                header[3]

            let nextFlags =
                header[4]

            let nextStream =
                (UInt32(header[5]) << 24) |
                (UInt32(header[6]) << 16) |
                (UInt32(header[7]) << 8) |
                UInt32(header[8])

            bufferedFrameIndex += 1

            lines.append(
                "BUFFERED_FRAME_\(bufferedFrameIndex)_TYPE=0x\(String(format: "%02x", nextType))"
            )

            lines.append(
                "BUFFERED_FRAME_\(bufferedFrameIndex)_FLAGS=0x\(String(format: "%02x", nextFlags))"
            )

            lines.append(
                "BUFFERED_FRAME_\(bufferedFrameIndex)_STREAM=\(nextStream)"
            )

            lines.append(
                "BUFFERED_FRAME_\(bufferedFrameIndex)_BYTES=\(frameSize)"
            )

            if nextType == 0x00 {
                lines.append(
                    "BUFFERED_FRAME_\(bufferedFrameIndex)_DATA_BYTES=\(length)"
                )
            }

            probeBuffer.removeFirst(
                frameSize
            )
        }

        if bufferedFrameIndex == 0 &&
            !probeBuffer.isEmpty {

            lines.append(
                "BUFFERED_NO_COMPLETE_FRAME"
            )
        }

        if receiveBuffer.isEmpty {

            lines.append(
                "BUFFERED_NO_BYTES"
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }

    private func receiveHTTP2Frame(
        wantedType: UInt8
    ) async throws -> Data {

        while true {

            let frame =
                try await receiveNextHTTP2Frame()

            guard frame.count >= 9 else {
                throw Error.invalidResponse
            }

            let type =
                frame[3]

            let flags =
                frame[4]

            let streamID =
                (UInt32(frame[5]) << 24) |
                (UInt32(frame[6]) << 16) |
                (UInt32(frame[7]) << 8) |
                UInt32(frame[8])

            print(
                "RemoteXPC handshake HTTP2 frame:",
                "type=0x\(String(format: "%02x", type))",
                "flags=0x\(String(format: "%02x", flags))",
                "stream=\(streamID)",
                "bytes=\(frame.count)"
            )

            if type == wantedType {
                return frame
            }
        }
    }

    private func receiveNextHTTP2Frame() async throws -> Data {

        while true {

            if receiveBuffer.count >= 9 {

                let header =
                    Array(
                        receiveBuffer.prefix(
                            9
                        )
                    )

                guard header.count == 9 else {
                    throw Error.invalidResponse
                }

                let length =
                    (Int(header[0]) << 16) |
                    (Int(header[1]) << 8) |
                    Int(header[2])

                let frameSize =
                    9 + length

                guard frameSize >= 9 else {
                    throw Error.invalidResponse
                }

                if receiveBuffer.count >= frameSize {

                    let frame =
                        Data(
                            receiveBuffer.prefix(
                                frameSize
                            )
                        )

                    receiveBuffer.removeFirst(
                        frameSize
                    )

                    return frame
                }
            }

            let chunk =
                try await receiveChunk()

            guard !chunk.isEmpty else {
                throw Error.invalidResponse
            }

            receiveBuffer.append(
                chunk
            )
        }
    }

    private func receiveChunk() async throws -> Data {

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Data, Swift.Error>
            ) in

            connection.receive(
                minimumIncompleteLength: 1,
                maximumLength: 65536
            ) {
                content,
                context,
                isComplete,
                error in

                if let error {

                    continuation.resume(
                        throwing:
                            Error.connectionFailed(
                                error.localizedDescription
                            )
                    )

                    return
                }

                if let content,
                   !content.isEmpty {

                    continuation.resume(
                        returning:
                            content
                    )

                    return
                }

                if isComplete {

                    continuation.resume(
                        throwing:
                            Error.connectionClosed
                    )

                    return
                }

                continuation.resume(
                    throwing:
                        Error.invalidResponse
                )
            }
        }
    }

    private func decodeXPCWrapper(
        _ data: Data
    ) {

        print(
            "===== REMOTEXPC XPC RESPONSE DECODE ====="
        )

        guard data.count >= 44 else {

            print(
                "XPC response too short:",
                data.count
            )

            return
        }

        func u32le(
            _ offset: Int
        ) -> UInt32 {

            UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
        }

        func u64le(
            _ offset: Int
        ) -> UInt64 {

            var value: UInt64 = 0

            for index in 0..<8 {

                value |=
                    UInt64(
                        data[offset + index]
                    ) << UInt64(index * 8)
            }

            return value
        }

        let magic =
            u32le(0)

        let flags =
            u32le(4)

        let wrapperSize =
            u64le(8)

        let messageID =
            u64le(16)

        let payloadMagic =
            u32le(24)

        let payloadVersion =
            u32le(28)

        let rootType =
            u32le(32)

        let rootBodyLength =
            u32le(36)

        let rootEntryCount =
            u32le(40)

        print(
            "XPC wrapper magic:",
            String(
                format: "0x%08x",
                magic
            )
        )

        print(
            "XPC wrapper flags:",
            String(
                format: "0x%08x",
                flags
            )
        )

        print(
            "XPC wrapper size:",
            wrapperSize
        )

        print(
            "XPC wrapper messageID:",
            messageID
        )

        print(
            "XPC payload magic:",
            String(
                format: "0x%08x",
                payloadMagic
            )
        )

        print(
            "XPC payload version:",
            payloadVersion
        )

        print(
            "XPC root object type:",
            String(
                format: "0x%08x",
                rootType
            )
        )

        print(
            "XPC root body length:",
            rootBodyLength
        )

        print(
            "XPC root entry count:",
            rootEntryCount
        )

        print(
            "===== REMOTEXPC XPC RESPONSE DECODE DONE ====="
        )
    }

    func debugResponseSummary(
        _ data: Data
    ) -> String {

        discoveredUniqueDeviceID = nil

        guard data.count >= 44 else {
            return "XPC_TOO_SHORT bytes=\(data.count)"
        }

        let bytes =
            Array(data)

        func u32le(
            _ offset: Int
        ) -> UInt32 {

            guard offset + 4 <= bytes.count else {
                return 0
            }

            return
                UInt32(bytes[offset]) |
                (UInt32(bytes[offset + 1]) << 8) |
                (UInt32(bytes[offset + 2]) << 16) |
                (UInt32(bytes[offset + 3]) << 24)
        }

        func u64le(
            _ offset: Int
        ) -> UInt64 {

            guard offset + 8 <= bytes.count else {
                return 0
            }

            var value: UInt64 = 0

            for index in 0..<8 {

                value |=
                    UInt64(
                        bytes[offset + index]
                    ) << UInt64(index * 8)
            }

            return value
        }

        func uuidString(
            _ offset: Int
        ) -> String? {

            guard offset + 16 <= bytes.count else {
                return nil
            }

            let b =
                Array(
                    bytes[
                        offset..<(offset + 16)
                    ]
                )

            return String(
                format:
                    "%02x%02x%02x%02x-%02x%02x-%02x%02x-%02x%02x-%02x%02x%02x%02x%02x%02x",
                b[0], b[1], b[2], b[3],
                b[4], b[5],
                b[6], b[7],
                b[8], b[9],
                b[10], b[11], b[12],
                b[13], b[14], b[15]
            )
        }

        var lines: [String] = []

        lines.append(
            "XPC_TOTAL_BYTES=\(data.count)"
        )

        lines.append(
            "XPC_WRAPPER_MAGIC=0x\(String(format: "%08x", u32le(0)))"
        )

        lines.append(
            "XPC_WRAPPER_FLAGS=0x\(String(format: "%08x", u32le(4)))"
        )

        lines.append(
            "XPC_WRAPPER_SIZE=\(u64le(8))"
        )

        lines.append(
            "XPC_MESSAGE_ID=\(u64le(16))"
        )

        lines.append(
            "XPC_PAYLOAD_MAGIC=0x\(String(format: "%08x", u32le(24)))"
        )

        lines.append(
            "XPC_PAYLOAD_VERSION=\(u32le(28))"
        )

        let rootType =
            u32le(32)

        let rootBodyLength =
            Int(u32le(36))

        let rootEntryCount =
            Int(u32le(40))

        lines.append(
            "XPC_ROOT_TYPE=0x\(String(format: "%08x", rootType))"
        )

        lines.append(
            "XPC_ROOT_BODY_LENGTH=\(rootBodyLength)"
        )

        lines.append(
            "XPC_ROOT_ENTRY_COUNT=\(rootEntryCount)"
        )

        // --------------------------------------------------------
        // Generic XPC object decoder.
        // --------------------------------------------------------

        func decodeObject(
            at offset: Int,
            depth: Int
        ) -> (
            summary: String,
            nextOffset: Int,
            type: UInt32
        ) {

            guard offset + 4 <= bytes.count else {

                return (
                    "<TRUNCATED>",
                    bytes.count,
                    0
                )
            }

            let type =
                u32le(offset)

            switch type {

            case 0x00009000:
                // XPC string:
                //
                // 4 bytes type
                // 4 bytes byte length
                // UTF-8 bytes including trailing NUL
                // padded to 4 bytes

                guard offset + 8 <= bytes.count else {

                    return (
                        "<TRUNCATED STRING HEADER>",
                        bytes.count,
                        type
                    )
                }

                let length =
                    Int(
                        u32le(
                            offset + 4
                        )
                    )

                let start =
                    offset + 8

                let end =
                    start + length

                guard end <= bytes.count else {

                    return (
                        "<TRUNCATED STRING>",
                        bytes.count,
                        type
                    )
                }

                var stringBytes =
                    Array(
                        bytes[start..<end]
                    )

                if stringBytes.last == 0 {
                    stringBytes.removeLast()
                }

                let value =
                    String(
                        bytes: stringBytes,
                        encoding: .utf8
                    ) ?? "<INVALID UTF8>"

                let paddedBody =
                    (4 + length + 3) & ~3

                let next =
                    offset +
                    4 +
                    paddedBody

                return (
                    "String(\"\(value)\")",
                    next,
                    type
                )

            case 0x00002000:
                // Bool:
                //
                // 4 bytes type
                // 4 bytes value

                guard offset + 8 <= bytes.count else {

                    return (
                        "<TRUNCATED BOOL>",
                        bytes.count,
                        type
                    )
                }

                let value =
                    u32le(
                        offset + 4
                    ) != 0

                return (
                    "Bool(\(value))",
                    offset + 8,
                    type
                )

            case 0x00004000:
                // UInt64:
                //
                // 4 bytes type
                // 8 bytes value

                guard offset + 12 <= bytes.count else {

                    return (
                        "<TRUNCATED UINT64>",
                        bytes.count,
                        type
                    )
                }

                let value =
                    u64le(
                        offset + 4
                    )

                return (
                    "UInt64(\(value))",
                    offset + 12,
                    type
                )

            case 0x0000A000:
                // UUID:
                //
                // 4 bytes type
                // 16 bytes UUID

                guard offset + 20 <= bytes.count else {

                    return (
                        "<TRUNCATED UUID>",
                        bytes.count,
                        type
                    )
                }

                let value =
                    uuidString(
                        offset + 4
                    ) ?? "<INVALID UUID>"

                return (
                    "UUID(\(value))",
                    offset + 20,
                    type
                )

            case 0x0000F000:
                // Dictionary:
                //
                // 4 bytes type
                // 4 bytes body length
                // 4 bytes entry count
                // key/value pairs

                guard offset + 12 <= bytes.count else {

                    return (
                        "<TRUNCATED DICTIONARY>",
                        bytes.count,
                        type
                    )
                }

                let bodyLength =
                    Int(
                        u32le(
                            offset + 4
                        )
                    )

                let entryCount =
                    Int(
                        u32le(
                            offset + 8
                        )
                    )

                let bodyStart =
                    offset + 8

                let bodyEnd =
                    bodyStart + bodyLength

                guard bodyEnd <= bytes.count else {

                    return (
                        "<TRUNCATED DICTIONARY BODY>",
                        bytes.count,
                        type
                    )
                }

                var cursor =
                    offset + 12

                var entries: [String] = []

                for index in 0..<entryCount {

                    guard cursor < bodyEnd else {
                        entries.append(
                            "entry\(index + 1)=<TRUNCATED>"
                        )
                        break
                    }

                    let keyStart =
                        cursor

                    var keyEnd =
                        keyStart

                    while keyEnd < bodyEnd &&
                        bytes[keyEnd] != 0 {

                        keyEnd += 1
                    }

                    guard keyEnd < bodyEnd else {

                        entries.append(
                            "entry\(index + 1)=<UNTERMINATED KEY>"
                        )
                        break
                    }

                    let key =
                        String(
                            bytes:
                                bytes[
                                    keyStart..<keyEnd
                                ],
                            encoding:
                                .utf8
                        ) ?? "<INVALID KEY>"

                    let keyByteCount =
                        (keyEnd - keyStart) + 1

                    let alignedKeyByteCount =
                        (keyByteCount + 3) & ~3

                    cursor =
                        keyStart +
                        alignedKeyByteCount

                    let value =
                        decodeObject(
                            at: cursor,
                            depth: depth + 1
                        )

                    entries.append(
                        "\(key)=\(value.summary)"
                    )

                    if key == "UniqueDeviceID",
                       value.summary.hasPrefix("String(\""),
                       value.summary.hasSuffix("\")")
                    {
                        let prefix = "String(\""
                        let suffix = "\")"

                        let start = value.summary.index(
                            value.summary.startIndex,
                            offsetBy: prefix.count
                        )

                        let end = value.summary.index(
                            value.summary.endIndex,
                            offsetBy: -suffix.count
                        )

                        let candidate =
                            String(
                                value.summary[start..<end]
                            )

                        if !candidate.isEmpty {
                            discoveredUniqueDeviceID = candidate
                        }
                    }

                    cursor =
                        value.nextOffset
                }

                let summary =
                    "Dictionary(\(entryCount)) {\n" +
                    entries.enumerated()
                        .map {
                            String(
                                repeating: "  ",
                                count: depth + 1
                            ) +
                            "\($0.offset + 1): " +
                            $0.element
                        }
                        .joined(
                            separator: "\n"
                        ) +
                    "\n" +
                    String(
                        repeating: "  ",
                        count: depth
                    ) +
                    "}"

                return (
                    summary,
                    bodyEnd,
                    type
                )

            default:

                return (
                    "<UNKNOWN XPC TYPE 0x\(String(format: "%08x", type))>",
                    min(
                        bytes.count,
                        offset + 4
                    ),
                    type
                )
            }
        }

        // --------------------------------------------------------
        // Decode root dictionary.
        // --------------------------------------------------------

        let root =
            decodeObject(
                at: 32,
                depth: 0
            )

        lines.append(
            "XPC_ROOT_DECODE=\(root.summary)"
        )

        if let discoveredUniqueDeviceID {
            lines.append(
                "XPC_UNIQUE_DEVICE_ID=\(discoveredUniqueDeviceID)"
            )
        } else {
            lines.append(
                "XPC_UNIQUE_DEVICE_ID=NOT_FOUND"
            )
        }

        return lines.joined(
            separator: "\n"
        )
    }

    func cancel() {
        connection.cancel()
    }

    #if DEBUG
    func debugPrintHandshakeVector() -> String {

        let uuid =
            UUID(
                uuidString:
                    "12345678-1234-5678-1234-567812345678"
            )!

        do {

            let actual =
                try buildInitialStream(
                    hostUUID: uuid
                )

            let expectedHex =
                """
                505249202a20485454502f322e300d0a0d0a534d0d0a0d0a
                00000c040000000000000300000064000401000000
                00000408000000000000ff0001
                000000010400000001
                00002c000000000001920bb0290100000014000000000000000000000000000000423713420500000000f000000400000000000000
                000000010400000003
                000018000000000001920bb0290102000000000000000000000000000000000000
                000018000000000003920bb0290100400000000000000000000000000000000000
                000108000000000001920bb02901010000f0000000000000000100000000000000423713420500000000f00000e0000000050000004d6573736167655479706500009000000a00000048616e647368616b650000004d6573736167696e6750726f746f636f6c56657273696f6e00000000004000000700000000000000555549440000000000a000001234567812345678123456781234567850726f70657274696573000000f000004c0000000200000052656d6f746558504356657273696f6e466c61677300000000400000060000000000000153656e73697469766550726f7065727469657356697369626c650000002000000100000053657276696365730000000000f000000400000000000000
                """

            let compactExpectedHex =
                expectedHex
                    .components(
                        separatedBy:
                            .whitespacesAndNewlines
                    )
                    .joined()

            guard
                let expected =
                    Self.dataFromHex(
                        compactExpectedHex
                    )
            else {

                let result =
                    "ERROR expected-hex-invalid"

                print(
                    "REMOTEXPC VECTOR:",
                    result
                )

                return result
            }

            print(
                "REMOTEXPC VECTOR actual length:",
                actual.count
            )

            print(
                "REMOTEXPC VECTOR expected length:",
                expected.count
            )

            let windowStart = 60
            let windowEnd = min(
                120,
                min(actual.count, expected.count)
            )

            print(
                "REMOTEXPC VECTOR ACTUAL[60..<120]:",
                actual[windowStart..<windowEnd]
                    .map {
                        String(
                            format: "%02x",
                            $0
                        )
                    }
                    .joined(separator: " ")
            )

            print(
                "REMOTEXPC VECTOR EXPECTED[60..<120]:",
                expected[windowStart..<windowEnd]
                    .map {
                        String(
                            format: "%02x",
                            $0
                        )
                    }
                    .joined(separator: " ")
            )

            if actual == expected {

                print(
                    "===== REMOTEXPC VECTOR PASS ====="
                )

                let result =
                    "PASS actual=\(actual.count) expected=\(expected.count)"

                print(
                    "REMOTEXPC VECTOR RESULT:",
                    result
                )

                Self.writeVectorResult(result)

                return result

            } else {

                print(
                    "===== REMOTEXPC VECTOR FAIL ====="
                )

                let limit =
                    min(
                        actual.count,
                        expected.count
                    )

                for index in 0..<limit {

                    if actual[index] != expected[index] {

                        let result =
                            "FAIL actual=\(actual.count) expected=\(expected.count) offset=\(index) actualByte=\(String(format: "%02x", actual[index])) expectedByte=\(String(format: "%02x", expected[index]))"

                        print(
                            "REMOTEXPC VECTOR RESULT:",
                            result
                        )

                        Self.writeVectorResult(result)

                        return result
                    }
                }

                let result =
                    "FAIL actual=\(actual.count) expected=\(expected.count) common-prefix-only"

                print(
                    "REMOTEXPC VECTOR RESULT:",
                    result
                )

                Self.writeVectorResult(result)

                return result
            }

        } catch {

            let result =
                "ERROR \(error.localizedDescription)"

            print(
                "REMOTEXPC VECTOR RESULT:",
                result
            )

            return result
        }
    }

    private static func writeVectorResult(
        _ result: String
    ) {

        guard
            let container =
                FileManager.default.containerURL(
                    forSecurityApplicationGroupIdentifier:
                        KhmerInstallerConfig.appGroupID
                )
        else {
            return
        }

        let url =
            container.appendingPathComponent(
                "remotexpc-vector-result.txt"
            )

        try? result.write(
            to: url,
            atomically: true,
            encoding: .utf8
        )
    }

    private static func dataFromHex(
        _ string: String
    ) -> Data? {

        guard string.count % 2 == 0 else {
            return nil
        }

        var result = Data()

        var index =
            string.startIndex

        while index < string.endIndex {

            let next =
                string.index(
                    index,
                    offsetBy: 2
                )

            guard
                let byte =
                    UInt8(
                        string[index..<next],
                        radix: 16
                    )
            else {
                return nil
            }

            result.append(byte)

            index = next
        }

        return result
    }
    #endif

    private func send(
        _ data: Data
    ) async throws {

        print(
            "REMOTEXPC SEND BEGIN bytes=",
            data.count
        )

        print(
            "REMOTEXPC SEND HEX:",
            data.map {
                String(format: "%02x", $0)
            }.joined()
        )

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Void, Swift.Error>
            ) in

            connection.send(
                content: data,
                completion: .contentProcessed {
                    error in

                    if let error {

                        print(
                            "REMOTEXPC SEND FAILED:",
                            error.localizedDescription
                        )

                        continuation.resume(
                            throwing:
                                Error.writeFailed(
                                    error.localizedDescription
                                )
                        )

                    } else {

                        print(
                            "REMOTEXPC SEND COMPLETE bytes=",
                            data.count
                        )

                        continuation.resume()
                    }
                }
            )
        }
    }

    private func buildInitialStream(
        hostUUID: UUID
    ) throws -> Data {

        var result = Data()

        // ----------------------------------------------------
        // HTTP/2 connection preface
        // ----------------------------------------------------

        result.append(
            Data(
                "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
                    .utf8
            )
        )

        // ----------------------------------------------------
        // SETTINGS
        // ----------------------------------------------------

        result.append(
            http2SettingsFrame(
                maxConcurrentStreams: 100,
                initialWindowSize: 16 * 1024 * 1024
            )
        )

        // ----------------------------------------------------
        // WINDOW_UPDATE stream 0
        // ----------------------------------------------------

        result.append(
            http2WindowUpdateFrame(
                streamID: 0,
                increment:
                    UInt32(
                        16 * 1024 * 1024 - 65535
                    )
            )
        )

        // ----------------------------------------------------
        // HEADERS stream 1
        // ----------------------------------------------------

        result.append(
            http2HeadersFrame(
                streamID: Self.rootChannel
            )
        )

        // ----------------------------------------------------
        // Empty XPC request on stream 1
        // ----------------------------------------------------

        result.append(
            http2DataFrame(
                streamID: Self.rootChannel,
                data:
                    xpcWrapper(
                        flags: 0x00000001,
                        messageID: 0,
                        payload:
                            xpcDictionary([])
                    )
            )
        )

        // ----------------------------------------------------
        // HEADERS stream 3
        // ----------------------------------------------------

        result.append(
            http2HeadersFrame(
                streamID: Self.replyChannel
            )
        )

        // ----------------------------------------------------
        // stream 1 termination/init state
        // ----------------------------------------------------

        result.append(
            http2DataFrame(
                streamID: Self.rootChannel,
                data:
                    xpcWrapper(
                        flags: 0x00000201,
                        messageID: 0,
                        payload: nil
                    )
            )
        )

        // ----------------------------------------------------
        // stream 3 init handshake state
        // ----------------------------------------------------

        result.append(
            http2DataFrame(
                streamID: Self.replyChannel,
                data:
                    xpcWrapper(
                        flags: 0x00400001,
                        messageID: 0,
                        payload: nil
                    )
            )
        )

        // ----------------------------------------------------
        // Device handshake request
        //
        // This is deliberately a separate DATA frame,
        // matching pymobiledevice3's send_request().
        // ----------------------------------------------------

        let handshake =
            xpcDictionary([
                (
                    "MessageType",
                    xpcString("Handshake")
                ),
                (
                    "MessagingProtocolVersion",
                    xpcUInt64(
                        Self.messagingProtocolVersion
                    )
                ),
                (
                    "UUID",
                    xpcUUID(hostUUID)
                ),
                (
                    "Properties",
                    xpcDictionary([
                        (
                            "RemoteXPCVersionFlags",
                            xpcUInt64(
                                Self.remoteXPCVersionFlags
                            )
                        ),
                        (
                            "SensitivePropertiesVisible",
                            xpcBool(true)
                        )
                    ])
                ),
                (
                    "Services",
                    xpcDictionary([])
                )
            ])

        let handshakeWrapper =
            xpcWrapper(
                flags:
                    0x00000101,
                messageID: 1,
                payload: handshake
            )

        result.append(
            http2DataFrame(
                streamID: Self.rootChannel,
                data: handshakeWrapper
            )
        )

        return result
    }

    // MARK: - HTTP/2

    private func http2SettingsAckFrame() -> Data {

        http2Frame(
            length: 0,
            type: 0x04,
            flags: 0x01,
            streamID: 0,
            payload: Data()
        )
    }

    private func http2SettingsFrame(
        maxConcurrentStreams: UInt32,
        initialWindowSize: UInt32
    ) -> Data {

        var payload = Data()

        appendUInt16BE(
            &payload,
            0x0003
        )

        appendUInt32BE(
            &payload,
            maxConcurrentStreams
        )

        appendUInt16BE(
            &payload,
            0x0004
        )

        appendUInt32BE(
            &payload,
            initialWindowSize
        )

        return http2Frame(
            length: payload.count,
            type: 0x04,
            flags: 0,
            streamID: 0,
            payload: payload
        )
    }

    private func http2WindowUpdateFrame(
        streamID: UInt32,
        increment: UInt32
    ) -> Data {

        var payload = Data()

        appendUInt32BE(
            &payload,
            increment & 0x7fffffff
        )

        return http2Frame(
            length: payload.count,
            type: 0x08,
            flags: 0,
            streamID: streamID,
            payload: payload
        )
    }

    private func http2HeadersFrame(
        streamID: UInt32
    ) -> Data {

        http2Frame(
            length: 0,
            type: 0x01,
            flags: 0x04,
            streamID: streamID,
            payload: Data()
        )
    }

    private func http2DataFrame(
        streamID: UInt32,
        data: Data
    ) -> Data {

        http2Frame(
            length: data.count,
            type: 0x00,
            flags: 0,
            streamID: streamID,
            payload: data
        )
    }

    private func http2Frame(
        length: Int,
        type: UInt8,
        flags: UInt8,
        streamID: UInt32,
        payload: Data
    ) -> Data {

        var result = Data()

        appendUInt24BE(
            &result,
            UInt32(length)
        )

        result.append(type)
        result.append(flags)

        appendUInt32BE(
            &result,
            streamID & 0x7fffffff
        )

        result.append(payload)

        return result
    }

    // MARK: - XPC

    private func xpcWrapper(
        flags: UInt32,
        messageID: UInt64,
        payload: Data?
    ) -> Data {

        var message = Data()

        // XPC message ID.
        appendUInt64LE(
            &message,
            messageID
        )

        // Normal create_xpc_wrapper() payloads carry the
        // XPC payload magic and version before the object.
        //
        // 0x42133742 = XPC payload magic
        // 5          = payload encoding version
        if let payload {

            appendUInt32LE(
                &message,
                0x42133742
            )

            appendUInt32LE(
                &message,
                5
            )

            message.append(payload)

        } else {

            // Raw control/termination wrappers have no
            // XPC object payload.
        }

        var result = Data()

        // RemoteXPC wrapper magic.
        appendUInt32LE(
            &result,
            0x29B00B92
        )

        appendUInt32LE(
            &result,
            flags
        )

        // The size field includes:
        //   messageID (8)
        //   plus payload bytes.
        let size: UInt64 =
            if payload != nil {
                UInt64(message.count - 8)
            } else {
                0
            }

        appendUInt64LE(
            &result,
            size
        )

        result.append(message)

        return result
    }

    private func xpcDictionary(
        _ entries: [(String, Data)]
    ) -> Data {

        var body = Data()

        appendUInt32LE(
            &body,
            UInt32(entries.count)
        )

        for (key, value) in entries {

            body.append(
                xpcAlignedString(key)
            )

            body.append(value)
        }

        var result = Data()

        appendUInt32LE(
            &result,
            0x0000F000
        )

        appendUInt32LE(
            &result,
            UInt32(body.count)
        )

        result.append(body)

        return result
    }

    private func xpcString(
        _ value: String
    ) -> Data {

        var encoded = Data(
            value.utf8
        )

        encoded.append(0)

        var body = Data()

        appendUInt32LE(
            &body,
            UInt32(encoded.count)
        )

        body.append(encoded)

        while body.count % 4 != 0 {
            body.append(0)
        }

        var result = Data()

        appendUInt32LE(
            &result,
            0x00009000
        )

        result.append(body)

        return result
    }

    private func xpcBool(
        _ value: Bool
    ) -> Data {

        var result = Data()

        appendUInt32LE(
            &result,
            0x00002000
        )

        appendUInt32LE(
            &result,
            value ? 1 : 0
        )

        return result
    }

    private func xpcUInt64(
        _ value: UInt64
    ) -> Data {

        var result = Data()

        appendUInt32LE(
            &result,
            0x00004000
        )

        appendUInt64LE(
            &result,
            value
        )

        return result
    }

    private func xpcUUID(
        _ value: UUID
    ) -> Data {

        var result = Data()

        appendUInt32LE(
            &result,
            0x0000A000
        )

        var uuid = value.uuid

        withUnsafeBytes(of: &uuid) {
            result.append(contentsOf: $0)
        }

        return result
    }

    private func xpcAlignedString(
        _ value: String
    ) -> Data {

        let bytes =
            Array(value.utf8)
            + [0]

        var result = Data()

        result.append(contentsOf: bytes)

        while result.count % 4 != 0 {
            result.append(0)
        }

        return result
    }

    // MARK: - Integer encoding

    private func appendUInt16BE(
        _ data: inout Data,
        _ value: UInt16
    ) {

        data.append(
            UInt8((value >> 8) & 0xff)
        )

        data.append(
            UInt8(value & 0xff)
        )
    }

    private func appendUInt24BE(
        _ data: inout Data,
        _ value: UInt32
    ) {

        data.append(
            UInt8((value >> 16) & 0xff)
        )

        data.append(
            UInt8((value >> 8) & 0xff)
        )

        data.append(
            UInt8(value & 0xff)
        )
    }

    private func appendUInt32BE(
        _ data: inout Data,
        _ value: UInt32
    ) {

        data.append(
            UInt8((value >> 24) & 0xff)
        )

        data.append(
            UInt8((value >> 16) & 0xff)
        )

        data.append(
            UInt8((value >> 8) & 0xff)
        )

        data.append(
            UInt8(value & 0xff)
        )
    }

    private func appendUInt32LE(
        _ data: inout Data,
        _ value: UInt32
    ) {

        data.append(
            UInt8(value & 0xff)
        )

        data.append(
            UInt8((value >> 8) & 0xff)
        )

        data.append(
            UInt8((value >> 16) & 0xff)
        )

        data.append(
            UInt8((value >> 24) & 0xff)
        )
    }

    private func appendUInt64LE(
        _ data: inout Data,
        _ value: UInt64
    ) {

        for shift in stride(
            from: 0,
            through: 56,
            by: 8
        ) {

            data.append(
                UInt8(
                    (value >> UInt64(shift))
                    & 0xff
                )
            )
        }
    }
}
