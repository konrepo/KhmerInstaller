import Foundation
import Network
import SRP
import Crypto

final class RemotePairingClient {

    enum PairingError: LocalizedError {
        case connectionFailed(String)
        case connectionClosed
        case invalidFrame
        case invalidResponse(String)
        case pairingRejected(String)
        case missingPairingData
        case missingSalt
        case missingPublicKey
        case missingProof
        case invalidPIN

        var errorDescription: String? {
            switch self {
            case .connectionFailed(let message):
                return "Connection failed: \(message)"

            case .connectionClosed:
                return "Connection closed by Apple TV."

            case .invalidFrame:
                return "Invalid RPPairing frame."

            case .invalidResponse(let message):
                return "Invalid response: \(message)"

            case .pairingRejected(let message):
                return "Pairing rejected: \(message)"

            case .missingPairingData:
                return "Apple TV did not return pairing data."

            case .missingSalt:
                return "Apple TV did not return the SRP salt."

            case .missingPublicKey:
                return "Apple TV did not return the SRP public key."

            case .missingProof:
                return "Apple TV did not return the SRP proof."

            case .invalidPIN:
                return "Enter the 6-digit PIN shown on Apple TV."
            }
        }
    }

    private var connection: NWConnection?
    private var tlsConnection: NWConnection?
    private var rsdConnection: NWConnection?
    private var sequenceNumber: UInt64 = 0

    private var srpClient: Client<SHA512>?

    private var clientMainKey: SymmetricKey?
    private var serverMainKey: SymmetricKey?

    private var encryptedSequenceNumber: UInt64 = 0
    private var pairVerifySharedSecret: Data?

    private(set) var pairingPublicKey: Data?
    private(set) var pairingSalt: Data?

    private(set) var remoteName: String?
    private(set) var remoteModel: String?
    private(set) var remoteIdentifier: String?

    // MARK: - Connect + Handshake + Pair Setup

    func connect(
        serviceName: String,
        serviceType: String,
        domain: String
    ) async throws -> String {

        try await connectRemotePairingSession(
            serviceName: serviceName,
            serviceType: serviceType,
            domain: domain
        )

        let deviceKey =
            "\(remoteName ?? serviceName)|\(remoteModel ?? "")"

        if let record = try RemotePairingStore.shared.load(
            for: deviceKey
        ) {

            print(
                "Saved pair record found for \(serviceName)"
            )

            do {

                if try await performPairVerify(
                    record:
                        record
                ) {

                    return """
                    Trusted connection established
                    \(remoteName ?? serviceName)
                    Model: \(remoteModel ?? "Unknown")
                    Pair record verified
                    """
                }

            } catch {

                print(
                    "Saved pair verification failed: \(error.localizedDescription)"
                )
            }

            print(
                "Saved pair record rejected; starting fresh pairing session"
            )

            connection?.cancel()
            connection = nil

            // The previous connection may have been closed by
            // Apple TV during Pair Verify. Pair Setup must use
            // a completely new RemotePairing TCP session.

            try await connectRemotePairingSession(
                serviceName:
                    serviceName,
                serviceType:
                    serviceType,
                domain:
                    domain
            )
        }

        return try await performPairSetup()
    }

    private func connectRemotePairingSession(
        serviceName: String,
        serviceType: String,
        domain: String
    ) async throws {

        let endpoint = NWEndpoint.service(
            name:
                serviceName,
            type:
                serviceType,
            domain:
                domain,
            interface:
                nil
        )

        let connection =
            NWConnection(
                to:
                    endpoint,
                using:
                    NWParameters.tcp
            )

        self.connection =
            connection

        try await waitUntilReady(
            connection
        )

        print(
            "RemotePairing TCP connected to \(serviceName)"
        )

        try await performHandshake()
    }

    private func connectTLSPSK(
        host: String,
        port: Int
    ) async throws {

        guard let pairVerifySharedSecret else {
            throw PairingError.invalidResponse(
                "Pair Verify shared secret is unavailable."
            )
        }

        guard let nwPort = NWEndpoint.Port(
            rawValue: UInt16(port)
        ) else {
            throw PairingError.invalidResponse(
                "Invalid TLS listener port: \(port)"
            )
        }

        let tlsOptions =
            NWProtocolTLS.Options()

        let securityOptions =
            tlsOptions.securityProtocolOptions

        sec_protocol_options_set_min_tls_protocol_version(
            securityOptions,
            .TLSv12
        )

        sec_protocol_options_set_max_tls_protocol_version(
            securityOptions,
            .TLSv12
        )

        sec_protocol_options_set_peer_authentication_required(
            securityOptions,
            false
        )

        let psk =
            pairVerifySharedSecret.withUnsafeBytes {
                DispatchData(bytes: $0) as __DispatchData
            }

        let identity =
            DispatchData.empty as __DispatchData

        sec_protocol_options_add_pre_shared_key(
            securityOptions,
            psk,
            identity
        )

        let parameters =
            NWParameters(
                tls: tlsOptions,
                tcp: NWProtocolTCP.Options()
            )

        let endpoint =
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: nwPort
            )

        let connection =
            NWConnection(
                to: endpoint,
                using: parameters
            )

        try await waitUntilReady(connection)

        print(
            "TLS-PSK connection established to \(host):\(port)"
        )

        self.tlsConnection = connection
    }

    func connectTunnel(
        host: String,
        port: Int,
        record: RemotePairingRecord
    ) async throws
        -> (
            serviceName: String,
            port: Int,
            devicePublicKey: String,
            serverAddress: String,
            serverRSDPort: Int,
            clientAddress: String,
            clientMTU: Int
        ) {

        guard
            let nwPort = NWEndpoint.Port(
                rawValue: UInt16(port)
            )
        else {
            throw PairingError.invalidResponse(
                "Invalid tunnel port: \(port)"
            )
        }

        let endpoint =
            NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: nwPort
            )

        let connection =
            NWConnection(
                to: endpoint,
                using: NWParameters.tcp
            )

        self.connection = connection

        try await waitUntilReady(connection)

        print(
            "RemotePairing tunnel TCP connected to \(host):\(port)"
        )

        try await performHandshake()

        print(
            "Tunnel saved pair record found for \(record.remoteName)"
        )

        guard
            try await performPairVerify(
                record: record
            )
        else {
            throw PairingError.connectionClosed
        }

        print(
            "Tunnel Pair Verify successful"
        )

        let listener =
            try await createTCPListener()

        print(
            "Connecting to Apple TV TLS listener..."
        )

        try await connectTLSPSK(
            host: host,
            port: listener.port
        )

        let tunnelResponse =
            try await requestTunnelEstablish()

        guard
            let serverAddress =
                tunnelResponse["serverAddress"] as? String,

            let serverRSDPortNumber =
                tunnelResponse["serverRSDPort"] as? NSNumber,

            let clientParameters =
                tunnelResponse["clientParameters"]
                    as? [String: Any],

            let clientAddress =
                clientParameters["address"] as? String,

            let clientMTUNumber =
                clientParameters["mtu"] as? NSNumber
        else {
            throw PairingError.invalidResponse(
                "Tunnel response missing required address/port/clientParameters."
            )
        }

        let serverRSDPort =
            serverRSDPortNumber.intValue

        let clientMTU =
            clientMTUNumber.intValue

        print(
            "Apple TV serverAddress:",
            serverAddress
        )

        print(
            "Apple TV serverRSDPort:",
            serverRSDPort
        )

        print(
            "Client tunnel address:",
            clientAddress
        )

        print(
            "Client tunnel MTU:",
            clientMTU
        )

        print(
            "CDTunnel handshake returned to connectTunnel()"
        )

        return (
            serviceName: listener.serviceName,
            port: listener.port,
            devicePublicKey: listener.devicePublicKey,
            serverAddress: serverAddress,
            serverRSDPort: serverRSDPort,
            clientAddress: clientAddress,
            clientMTU: clientMTU
        )
    }

    func matchesTunnelService(
        identifier: String,
        authTag: Data
    ) throws -> Bool {

        let deviceKey =
            "\(remoteName ?? "")|\(remoteModel ?? "")"

        guard
            let record =
                try RemotePairingStore.shared.load(
                    for: deviceKey
                )
        else {
            print(
                "No saved pair record for \(deviceKey)"
            )
            return false
        }

        let expected =
            RemotePairingCrypto.computeAuthTag(
                altIRK: record.peerAltIRK,
                serviceIdentifier: identifier
            )

        let expectedHex =
            expected
                .map {
                    String(format: "%02x", $0)
                }
                .joined()

        let actualHex =
            authTag
                .map {
                    String(format: "%02x", $0)
                }
                .joined()

        print(
            "AUTH TAG EXPECTED:",
            expectedHex
        )

        print(
            "AUTH TAG ADVERTISED:",
            actualHex
        )

        let matches =
            expected == authTag

        print(
            matches
                ? "AUTH TAG MATCHED"
                : "AUTH TAG MISMATCH"
        )

        return matches
    }

    func savedPairRecord() throws -> RemotePairingRecord {

        let deviceKey =
            "\(remoteName ?? "")|\(remoteModel ?? "")"

        guard
            let record =
                try RemotePairingStore.shared.load(
                    for: deviceKey
                )
        else {
            throw PairingError.invalidResponse(
                "Saved pair record not found for \(deviceKey)"
            )
        }

        try RemotePairingStore.shared.exportToAppGroup(
            record
        )

        return record
    }

    private func connectRSD(
        host: String,
        port: Int
    ) async throws {

        guard let nwPort = NWEndpoint.Port(
            rawValue: UInt16(port)
        ) else {
            throw PairingError.invalidResponse(
                "Invalid RSD port: \(port)"
            )
        }

        let parameters =
            NWParameters.tcp

        let connection =
            NWConnection(
                to: NWEndpoint.hostPort(
                    host: NWEndpoint.Host(host),
                    port: nwPort
                ),
                using: parameters
            )

        self.rsdConnection = connection

        try await waitUntilReady(connection)

        print(
            "RSD TCP connection established to \(host):\(port)"
        )

        try await startRSDHTTP2()
    }

    private static let rsdHTTP2Magic = Data([
        0x50, 0x52, 0x49, 0x20,
        0x2A, 0x20,
        0x48, 0x54, 0x54, 0x50, 0x2F, 0x32, 0x2E, 0x30,
        0x0D, 0x0A,
        0x0D, 0x0A,
        0x53, 0x4D,
        0x0D, 0x0A,
        0x0D, 0x0A
    ])

    private func sendRSD(
        _ data: Data
    ) async throws {

        guard let rsdConnection else {
            throw PairingError.connectionClosed
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            rsdConnection.send(
                content: data,
                completion: .contentProcessed { error in

                    if let error {
                        continuation.resume(
                            throwing:
                                PairingError.connectionFailed(
                                    error.localizedDescription
                                )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func makeRSDFrame(
        length: Int,
        type: UInt8,
        flags: UInt8,
        streamID: UInt32,
        body: Data
    ) throws -> Data {

        guard length == body.count else {
            throw PairingError.invalidFrame
        }

        guard length <= 0xFFFFFF else {
            throw PairingError.invalidFrame
        }

        var frame = Data()

        // 24-bit big-endian length.
        frame.append(
            UInt8((length >> 16) & 0xFF)
        )
        frame.append(
            UInt8((length >> 8) & 0xFF)
        )
        frame.append(
            UInt8(length & 0xFF)
        )

        frame.append(type)
        frame.append(flags)

        let maskedStreamID =
            streamID & 0x7FFFFFFF

        frame.append(
            UInt8((maskedStreamID >> 24) & 0xFF)
        )
        frame.append(
            UInt8((maskedStreamID >> 16) & 0xFF)
        )
        frame.append(
            UInt8((maskedStreamID >> 8) & 0xFF)
        )
        frame.append(
            UInt8(maskedStreamID & 0xFF)
        )

        frame.append(body)

        return frame
    }

    private func startRSDHTTP2() async throws {

        print("Starting RemoteXPC HTTP/2 handshake")

        // HTTP/2 connection preamble.
        try await sendRSD(
            Self.rsdHTTP2Magic
        )

        // SETTINGS:
        // MAX_CONCURRENT_STREAMS = 100
        // INITIAL_WINDOW_SIZE = 16,777,216
        let settingsBody = Data([
            0x00, 0x03,
            0x00, 0x00, 0x00, 0x64,

            0x00, 0x04,
            0x01, 0x00, 0x00, 0x00
        ])

        try await sendRSD(
            try makeRSDFrame(
                length: settingsBody.count,
                type: 0x04,
                flags: 0x00,
                streamID: 0,
                body: settingsBody
            )
        )

        // WINDOW_UPDATE stream 0:
        // 16,711,681
        let increment: UInt32 = 16_711_681

        let windowBody = Data([
            UInt8((increment >> 24) & 0x7F),
            UInt8((increment >> 16) & 0xFF),
            UInt8((increment >> 8) & 0xFF),
            UInt8(increment & 0xFF)
        ])

        try await sendRSD(
            try makeRSDFrame(
                length: 4,
                type: 0x08,
                flags: 0x00,
                streamID: 0,
                body: windowBody
            )
        )

        // HEADERS stream 1, END_HEADERS.
        try await sendRSD(
            try makeRSDFrame(
                length: 0,
                type: 0x01,
                flags: 0x04,
                streamID: 1,
                body: Data()
            )
        )

        // XPC init on stream 1.
        let xpcInit =
            Data(hexString:
                "920bb0290102000000000000000000000000000000000000"
            )

        try await sendRSD(
            try makeRSDFrame(
                length: xpcInit.count,
                type: 0x00,
                flags: 0x00,
                streamID: 1,
                body: xpcInit
            )
        )

        // HEADERS stream 3, END_HEADERS.
        try await sendRSD(
            try makeRSDFrame(
                length: 0,
                type: 0x01,
                flags: 0x04,
                streamID: 3,
                body: Data()
            )
        )

        // XPC terminal/init-handshake frame on stream 1.
        try await sendRSD(
            try makeRSDFrame(
                length: 20,
                type: 0x00,
                flags: 0x00,
                streamID: 1,
                body: Data([
                    0x92, 0x0b, 0xb0, 0x29,
                    0x01, 0x00, 0x40, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00,
                    0x00, 0x00, 0x00, 0x00
                ])
            )
        )

        // XPC INIT_HANDSHAKE on stream 3.
        let xpcHandshake =
            Data(hexString:
                "920bb0290100400000000000000000000000000000000000"
            )

        try await sendRSD(
            try makeRSDFrame(
                length: xpcHandshake.count,
                type: 0x00,
                flags: 0x00,
                streamID: 3,
                body: xpcHandshake
            )
        )

        print("RemoteXPC HTTP/2 initialization sent")
    }

    // MARK: - Handshake

    private func performHandshake() async throws {

        let handshakeData: [String: Any] = [
            "hostOptions": [
                "attemptPairVerify": false
            ],
            "wireProtocolVersion": 19
        ]

        let plainRequest: [String: Any] = [
            "request": [
                "_0": [
                    "handshake": [
                        "_0": handshakeData
                    ]
                ]
            ]
        ]

        try await sendPlainRequest(plainRequest)

        let response = try await receivePlainResponse()

        print("REMOTE PAIRING HANDSHAKE RESPONSE:")

        parseHandshakeResponse(response)
    }

    private func parseHandshakeResponse(
        _ response: [String: Any]
    ) {

        guard
            let responseContainer =
                response["response"] as? [String: Any],
            let responseOne =
                responseContainer["_1"] as? [String: Any],
            let handshake =
                responseOne["handshake"] as? [String: Any],
            let handshakeZero =
                handshake["_0"] as? [String: Any]
        else {
            print("Could not parse handshake response.")
            return
        }

        let peerDeviceInfo =
            handshakeZero["peerDeviceInfo"] as? [String: Any]

        remoteIdentifier =
            peerDeviceInfo?["identifier"] as? String

        remoteModel =
            peerDeviceInfo?["model"] as? String

        remoteName =
            peerDeviceInfo?["name"] as? String

        print(
            "Remote model: \(remoteModel ?? "Unknown")"
        )

        if let deviceOptions =
            handshakeZero["deviceOptions"] as? [String: Any]
        {
            print(
                "allowsPairSetup:",
                deviceOptions["allowsPairSetup"] ?? "unknown"
            )

            print(
                "allowsPinlessPairing:",
                deviceOptions["allowsPinlessPairing"] ?? "unknown"
            )
        }

        print("RemotePairing handshake completed")
    }

    // MARK: - Pair Setup STATE 1

    private func performPairSetup() async throws -> String {

        let pairingTLV = PairingTLVCodec.encode([
            PairingTLV(
                type: .method,
                data: Data([0x00])
            ),
            PairingTLV(
                type: .state,
                data: Data([0x01])
            )
        ])

        let pairingData: [String: Any] = [
            "data": pairingTLV.base64EncodedString(),
            "kind": "setupManualPairing",
            "sendingHost": "KunInstaller",
            "startNewSession": true
        ]

        let plainRequest: [String: Any] = [
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": pairingData
                    ]
                ]
            ]
        ]

        print("Sending setupManualPairing STATE 1")

        try await sendPlainRequest(plainRequest)

        let response = try await receivePlainResponse()

        print("REMOTE PAIRING SETUP RESPONSE:")

        try parsePairSetupResponse(response)

        return """
        Connected to \(remoteName ?? "Apple TV")
        Model: \(remoteModel ?? "Unknown")
        RemotePairing handshake completed
        Apple TV ready for pairing
        Enter the 6-digit PIN shown on Apple TV
        """
    }

    private func parsePairSetupResponse(
        _ response: [String: Any]
    ) throws {

        guard
            let event = response["event"] as? [String: Any],
            let eventZero = event["_0"] as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Missing event._0."
            )
        }

        if
            let rejected =
                eventZero["pairingRejectedWithError"]
                as? [String: Any]
        {
            throw PairingError.pairingRejected(
                extractErrorMessage(from: rejected)
            )
        }

        guard
            let pairingData =
                eventZero["pairingData"] as? [String: Any],
            let pairingDataZero =
                pairingData["_0"] as? [String: Any],
            let encodedData =
                pairingDataZero["data"] as? String,
            let pairingBytes =
                Data(base64Encoded: encodedData)
        else {
            throw PairingError.missingPairingData
        }

        print(
            "Received pairing data: \(pairingBytes.count) bytes"
        )

        let tlvs = try PairingTLVCodec.decode(pairingBytes)

        guard
            let salt =
                PairingTLVCodec.firstValue(
                    for: .salt,
                    in: tlvs
                )
        else {
            throw PairingError.missingSalt
        }

        guard
            let publicKey =
                PairingTLVCodec.firstValue(
                    for: .publicKey,
                    in: tlvs
                )
        else {
            throw PairingError.missingPublicKey
        }

        pairingSalt = salt
        pairingPublicKey = publicKey

        print(
            "Apple TV SRP salt received: \(salt.count) bytes"
        )

        print(
            "Apple TV SRP public key received: \(publicKey.count) bytes"
        )
    }

    // MARK: - SRP / PIN

    func submitPIN(
        _ pin: String
    ) async throws -> String {

        guard pin.count == 6,
              pin.allSatisfy(\.isNumber) else {
            throw PairingError.invalidPIN
        }

        guard let salt = pairingSalt else {
            throw PairingError.missingSalt
        }

        guard let serverPublicKey = pairingPublicKey else {
            throw PairingError.missingPublicKey
        }

        let client = RemotePairingCrypto.makeSRPClient(
            pin: pin
        )

        srpClient = client

        print("Starting SRP-6a")
        print("Group: N3072")
        print("Hash: SHA-512")

        let challengeProof = try client.processChallenge(
            salt: salt,
            publicKey: serverPublicKey
        )

        let clientPublicKey = client.publicKey

        print(
            "Client SRP public key: \(clientPublicKey.count) bytes"
        )

        print(
            "Client SRP proof: \(challengeProof.count) bytes"
        )

        let firstPart = clientPublicKey.prefix(255)
        let remainingPart = clientPublicKey.dropFirst(255)

        let state3TLV = PairingTLVCodec.encode([
            PairingTLV(
                type: .state,
                data: Data([0x03])
            ),
            PairingTLV(
                type: .publicKey,
                data: Data(firstPart)
            ),
            PairingTLV(
                type: .publicKey,
                data: Data(remainingPart)
            ),
            PairingTLV(
                type: .proof,
                data: challengeProof
            )
        ])

        let pairingData: [String: Any] = [
            "data": state3TLV.base64EncodedString(),
            "kind": "setupManualPairing",
            "sendingHost": "KunInstaller",
            "startNewSession": false
        ]

        let plainRequest: [String: Any] = [
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": pairingData
                    ]
                ]
            ]
        ]

        print("Sending setupManualPairing STATE 3")

        try await sendPlainRequest(plainRequest)

        let response = try await receivePlainResponse()

        print("REMOTE PAIRING STATE 3 RESPONSE:")

        return try await verifySRPResponse(response)
    }

    private func verifySRPResponse(
        _ response: [String: Any]
    ) async throws -> String {

        guard
            let event = response["event"] as? [String: Any],
            let eventZero = event["_0"] as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Missing event._0 in SRP response."
            )
        }

        if
            let rejected =
                eventZero["pairingRejectedWithError"]
                as? [String: Any]
        {
            throw PairingError.pairingRejected(
                extractErrorMessage(from: rejected)
            )
        }

        guard
            let pairingData =
                eventZero["pairingData"] as? [String: Any],
            let pairingDataZero =
                pairingData["_0"] as? [String: Any],
            let encodedData =
                pairingDataZero["data"] as? String,
            let responseBytes =
                Data(base64Encoded: encodedData)
        else {
            throw PairingError.missingPairingData
        }

        let tlvs = try PairingTLVCodec.decode(
            responseBytes
        )

        guard
            let serverProof =
                PairingTLVCodec.firstValue(
                    for: .proof,
                    in: tlvs
                )
        else {
            throw PairingError.missingProof
        }

        guard let srpClient else {
            throw PairingError.invalidResponse(
                "SRP client session is missing."
            )
        }

        try srpClient.verifySession(
            keyProof: serverProof
        )

        print("SRP proof verified successfully")

        return try await savePairRecordOnAppleTV()
    }

    // MARK: - Plain Requests

    private func sendPlainRequest(
        _ plainRequest: [String: Any]
    ) async throws {

        let envelope: [String: Any] = [
            "message": [
                "plain": [
                    "_0": plainRequest
                ]
            ],
            "originatedBy": "host",
            "sequenceNumber": sequenceNumber
        ]

        sequenceNumber += 1

        let body = try JSONSerialization.data(
            withJSONObject: envelope,
            options: []
        )

        let frame =
            try RemotePairingFraming.encode(body)

        try await send(frame)
    }

    private func receivePlainResponse()
        async throws -> [String: Any]
    {
        let responseBody =
            try await receiveFrame()

        let object =
            try JSONSerialization.jsonObject(
                with: responseBody,
                options: []
            )

        guard let response =
            object as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Response was not a JSON object."
            )
        }

        guard
            let message =
                response["message"] as? [String: Any],
            let plain =
                message["plain"] as? [String: Any],
            let zero =
                plain["_0"] as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Missing message.plain._0."
            )
        }

        return zero
    }

    // MARK: - Connection

    private func waitUntilReady(
        _ connection: NWConnection
    ) async throws {

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Void, Error>
            ) in

            var completed = false

            connection.stateUpdateHandler = { state in

                switch state {

                case .ready:
                    guard !completed else {
                        return
                    }

                    completed = true
                    continuation.resume()

                case .failed(let error):
                    guard !completed else {
                        return
                    }

                    completed = true

                    continuation.resume(
                        throwing:
                            PairingError.connectionFailed(
                                error.localizedDescription
                            )
                    )

                case .cancelled:
                    guard !completed else {
                        return
                    }

                    completed = true

                    continuation.resume(
                        throwing:
                            PairingError.connectionClosed
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

    // MARK: - RPPairing

    private func send(
        _ data: Data
    ) async throws {

        guard let connection else {
            throw PairingError.connectionClosed
        }

        try await withCheckedThrowingContinuation {
            (
                continuation:
                    CheckedContinuation<Void, Error>
            ) in

            connection.send(
                content: data,
                completion: .contentProcessed {
                    error in

                    if let error {
                        continuation.resume(
                            throwing:
                                PairingError.connectionFailed(
                                    error.localizedDescription
                                )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func receiveFrame()
        async throws -> Data
    {
        let header =
            try await receiveExactly(11)

        let bodyLength: Int

        do {
            bodyLength =
                try RemotePairingFraming.decodeHeader(
                    header
                )
        } catch {
            throw PairingError.invalidFrame
        }

        guard bodyLength > 0 else {
            throw PairingError.invalidFrame
        }

        return try await receiveExactly(
            bodyLength
        )
    }

    private func receiveExactly(
        _ count: Int
    ) async throws -> Data {

        guard let connection else {
            throw PairingError.connectionClosed
        }

        var result = Data()

        while result.count < count {

            let remaining =
                count - result.count

            let chunk: Data =
                try await withCheckedThrowingContinuation {
                    (
                        continuation:
                            CheckedContinuation<Data, Error>
                    ) in

                    connection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: remaining
                    ) {
                        data,
                        _,
                        isComplete,
                        error in

                        if let error {
                            continuation.resume(
                                throwing:
                                    PairingError.connectionFailed(
                                        error.localizedDescription
                                    )
                            )

                            return
                        }

                        if isComplete &&
                            (data == nil || data!.isEmpty)
                        {
                            continuation.resume(
                                throwing:
                                    PairingError.connectionClosed
                            )

                            return
                        }

                        continuation.resume(
                            returning:
                                data ?? Data()
                        )
                    }
                }

            result.append(chunk)
        }

        return result
    }

    private static let cdTunnelMagic =
        Data("CDTunnel".utf8)

    private func sendTLS(
        _ data: Data
    ) async throws {

        guard let tlsConnection else {
            throw PairingError.connectionClosed
        }

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            tlsConnection.send(
                content: data,
                completion: .contentProcessed { error in

                    if let error {
                        continuation.resume(
                            throwing: PairingError.connectionFailed(
                                error.localizedDescription
                            )
                        )
                    } else {
                        continuation.resume()
                    }
                }
            )
        }
    }

    private func requestTunnelEstablish()
        async throws
        -> [String: Any] {

        let request: [String: Any] = [
            "type":
                "clientHandshakeRequest",

            "mtu":
                16000
        ]

        let body =
            try JSONSerialization.data(
                withJSONObject: request,
                options: []
            )

        let packet =
            try encodeCDTunnelPacket(body)

        print(
            "Sending Cumulative Tunnel handshake:"
        )


        print(
            "CDTunnel request bytes:",
            packet.count
        )

        try await sendTLS(packet)

        let responseBody =
            try await receiveCDTunnelPacket()

        print(
            "CDTunnel response bytes:",
            responseBody.count
        )

        guard
            let response =
                try JSONSerialization.jsonObject(
                    with: responseBody,
                    options: []
                ) as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "CDTunnel response was not a JSON object."
            )
        }

        print(
            "TUNNEL ESTABLISH RESPONSE:"
        )


        return response
    }

    private func receiveTLSExactly(
        _ count: Int
    ) async throws -> Data {

        guard let tlsConnection else {
            throw PairingError.connectionClosed
        }

        var result = Data()

        while result.count < count {

            let remaining =
                count - result.count

            let chunk: Data =
                try await withCheckedThrowingContinuation {
                    (continuation:
                        CheckedContinuation<Data, Error>) in

                    tlsConnection.receive(
                        minimumIncompleteLength: 1,
                        maximumLength: remaining
                    ) {
                        data,
                        _,
                        isComplete,
                        error in

                        if let error {
                            continuation.resume(
                                throwing:
                                    PairingError.connectionFailed(
                                        error.localizedDescription
                                    )
                            )
                            return
                        }

                        if isComplete &&
                            (data == nil || data!.isEmpty) {

                            continuation.resume(
                                throwing:
                                    PairingError.connectionClosed
                            )
                            return
                        }

                        continuation.resume(
                            returning: data ?? Data()
                        )
                    }
                }

            result.append(chunk)
        }

        return result
    }

    private func encodeCDTunnelPacket(
        _ body: Data
    ) throws -> Data {

        guard body.count <= Int(UInt16.max) else {
            throw PairingError.invalidFrame
        }

        var packet = Data()

        packet.append(Self.cdTunnelMagic)

        let length =
            UInt16(body.count)

        packet.append(
            UInt8((length >> 8) & 0xff)
        )

        packet.append(
            UInt8(length & 0xff)
        )

        packet.append(body)

        return packet
    }

    private func receiveCDTunnelPacket()
        async throws -> Data {

        let magic =
            try await receiveTLSExactly(
                Self.cdTunnelMagic.count
            )

        guard magic == Self.cdTunnelMagic else {
            throw PairingError.invalidFrame
        }

        let lengthBytes =
            try await receiveTLSExactly(2)

        let length =
            (UInt16(lengthBytes[0]) << 8)
            | UInt16(lengthBytes[1])

        guard length > 0 else {
            throw PairingError.invalidFrame
        }

        return try await receiveTLSExactly(
            Int(length)
        )
    }

    // MARK: - Error Helpers

    private func extractErrorMessage(
        from error: [String: Any]
    ) -> String {

        if
            let wrapped =
                error["wrappedError"] as? [String: Any],
            let userInfo =
                wrapped["userInfo"] as? [String: Any],
            let description =
                userInfo["NSLocalizedDescription"] as? String
        {
            return description
        }

        return "Unknown Apple TV pairing error."
    }

    // MARK: - Cancel

    func cancel() {
        connection?.cancel()
        connection = nil
        srpClient = nil
    }

    private func generateHostIdentifier() -> String {

        let hostname =
            ProcessInfo.processInfo.hostName

        let namespace =
            UUID(
                uuidString:
                    "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
            )!

        var namespaceBytes = namespace.uuid

        var input = Data(
            bytes: &namespaceBytes,
            count: MemoryLayout.size(
                ofValue: namespaceBytes
            )
        )

        input.append(
            contentsOf: Data(hostname.utf8)
        )

        let digest =
            Insecure.SHA1.hash(
                data: input
            )

        var bytes =
            Array(digest.prefix(16))

        // UUID version 3
        bytes[6] =
            (bytes[6] & 0x0F) | 0x30

        // RFC 4122 variant
        bytes[8] =
            (bytes[8] & 0x3F) | 0x80

        let uuid =
            UUID(
                uuid: (
                    bytes[0],  bytes[1],
                    bytes[2],  bytes[3],
                    bytes[4],  bytes[5],
                    bytes[6],  bytes[7],
                    bytes[8],  bytes[9],
                    bytes[10], bytes[11],
                    bytes[12], bytes[13],
                    bytes[14], bytes[15]
                )
            )

        return uuid.uuidString.uppercased()
    }

    private var hostSigningPrivateKey:
        Curve25519.Signing.PrivateKey?

    private var hostIdentifier: String?

    private var pairSetupEncryptionKey: Data?

    private func savePairRecordOnAppleTV() async throws -> String {

        guard let srpClient else {
            throw PairingError.invalidResponse(
                "SRP client session is missing."
            )
        }

        guard let sessionKey = srpClient.sessionKey else {
            throw PairingError.invalidResponse(
                "SRP session key is unavailable."
            )
        }

        let hostID = generateHostIdentifier()

        let signingKey =
            RemotePairingCrypto.generateSigningKey()

        let encryptionKey =
            RemotePairingCrypto.makePairSetupEncryptionKey(
                sessionKey: sessionKey
            )

        let signature =
            try RemotePairingCrypto.makePairSetupSignature(
                sessionKey: sessionKey,
                hostIdentifier: hostID,
                signingPrivateKey: signingKey
            )

        let publicKey =
            signingKey.publicKey.rawRepresentation

        // These values intentionally follow the current
        // pymobiledevice3 reference we inspected.
        let deviceInfoEntries: [(String, Any)] = [
            (
                "altIRK",
                Data([
                    0xe9, 0xe8, 0x2d, 0xc0,
                    0x6a, 0x49, 0x79, 0x6b,
                    0x56, 0x6f, 0x54, 0x00,
                    0x19, 0xb1, 0xc7, 0x7b
                ])
            ),
            (
                "btAddr",
                "11:22:33:44:55:66"
            ),
            (
                "mac",
                Data([
                    0x11, 0x22, 0x33,
                    0x44, 0x55, 0x66
                ])
            ),
            (
                "remotepairing_serial_number",
                "AAAAAAAAAAAA"
            ),
            (
                "accountID",
                hostID
            ),
            (
                "model",
                "computer-model"
            ),
            (
                "name",
                ProcessInfo.processInfo.hostName
            )
        ]

        let deviceInfo =
            try RemotePairingOPack.encodeDictionary(
                deviceInfoEntries
            )

        let innerTLV = PairingTLVCodec.encode([
            PairingTLV(
                type: .identifier,
                data: Data(hostID.utf8)
            ),
            PairingTLV(
                type: .publicKey,
                data: publicKey
            ),
            PairingTLV(
                type: .signature,
                data: signature
            ),
            PairingTLV(
                type: .info,
                data: deviceInfo
            )
        ])

        let encryptedData =
            try RemotePairingCrypto.encryptPairSetupMessage05(
                encryptionKey: encryptionKey,
                plaintext: innerTLV
            )

        let state5TLV =
            PairingTLVCodec.encode([
                PairingTLV(
                    type: .encryptedData,
                    data: encryptedData.prefix(255)
                ),
                PairingTLV(
                    type: .encryptedData,
                    data: encryptedData.dropFirst(255)
                ),
                PairingTLV(
                    type: .state,
                    data: Data([0x05])
                )
            ])

        let pairingData: [String: Any] = [
            "data": state5TLV.base64EncodedString(),
            "kind": "setupManualPairing",
            "sendingHost":
                ProcessInfo.processInfo.hostName,
            "startNewSession": false
        ]

        let request: [String: Any] = [
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": pairingData
                    ]
                ]
            ]
        ]

        print("Sending setupManualPairing STATE 5")

        try await sendPlainRequest(request)

        let response = try await receivePlainResponse()

        print("REMOTE PAIRING M6 RESPONSE:")

        let m6Data = try extractPairingData(
            from: response
        )

        let outerTLVs =
            try PairingTLVCodec.decode(m6Data)

        guard let encryptedM6 =
            PairingTLVCodec.firstValue(
                for: .encryptedData,
                in: outerTLVs
            )
        else {
            throw PairingError.missingPairingData
        }

        let decryptedM6 =
            try RemotePairingCrypto.decryptPairSetupMessage06(
                encryptionKey: encryptionKey,
                ciphertext: encryptedM6
            )

        let innerM6TLVs =
            try PairingTLVCodec.decode(
                decryptedM6
            )

        guard let info =
            PairingTLVCodec.firstValue(
                for: .info,
                in: innerM6TLVs
            )
        else {
            throw PairingError.invalidResponse(
                "Apple TV M6 did not contain INFO."
            )
        }

        let decodedInfo =
            try RemotePairingOPack.decode(info)

        guard let infoDictionary =
            decodedInfo as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Apple TV INFO was not an OPACK dictionary."
            )
        }

        guard let altIRK =
            infoDictionary["altIRK"] as? Data,
            altIRK.count == 16
        else {
            throw PairingError.invalidResponse(
                "Apple TV did not return a usable altIRK."
            )
        }

        hostSigningPrivateKey = signingKey
        hostIdentifier = hostID
        pairSetupEncryptionKey = encryptionKey

        let record = RemotePairingRecord(
            hostIdentifier: hostID,
            publicKey: publicKey,
            privateKey: signingKey.rawRepresentation,
            peerAltIRK: altIRK,
            remoteName: remoteName ?? "Apple TV",
            remoteModel: remoteModel ?? "Unknown"
        )

        let deviceKey =
            "\(remoteName ?? "Apple TV")|\(remoteModel ?? "")"

        try RemotePairingStore.shared.save(
            record,
            for: deviceKey
        )

        print(
            "Pair record saved for \(remoteName ?? "Apple TV")"
        )

        print(
            "Apple TV altIRK received: \(altIRK.count) bytes"
        )

        return """
        Encrypted pairing successful
        Apple TV altIRK received
        """
    }

    private func extractPairingData(
        from response: [String: Any]
    ) throws -> Data {

        guard
            let event = response["event"] as? [String: Any],
            let eventZero = event["_0"] as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Missing event._0."
            )
        }

        if
            let rejected =
                eventZero["pairingRejectedWithError"]
                as? [String: Any]
        {
            throw PairingError.pairingRejected(
                extractErrorMessage(from: rejected)
            )
        }

        guard
            let pairingData =
                eventZero["pairingData"] as? [String: Any],
            let pairingDataZero =
                pairingData["_0"] as? [String: Any],
            let encodedData =
                pairingDataZero["data"] as? String,
            let data =
                Data(base64Encoded: encodedData)
        else {
            throw PairingError.missingPairingData
        }

        return data
    }

    private var pairVerifyPrivateKey:
        Curve25519.KeyAgreement.PrivateKey?

    private func performPairVerify(
        record: RemotePairingRecord
    ) async throws -> Bool {

        let hostIdentifier =
            record.hostIdentifier

        let ed25519PrivateKey =
            try Curve25519.Signing.PrivateKey(
                rawRepresentation: record.privateKey
            )

        let x25519PrivateKey =
            Curve25519.KeyAgreement.PrivateKey()

        pairVerifyPrivateKey =
            x25519PrivateKey

        let state1TLV =
            PairingTLVCodec.encode([
                PairingTLV(
                    type: .state,
                    data: Data([0x01])
                ),
                PairingTLV(
                    type: .publicKey,
                    data: x25519PrivateKey
                        .publicKey
                        .rawRepresentation
                )
            ])

        let request: [String: Any] = [
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": [
                            "data":
                                state1TLV.base64EncodedString(),
                            "kind":
                                "verifyManualPairing",
                            "startNewSession":
                                true
                        ]
                    ]
                ]
            ]
        ]

        print("Sending verifyManualPairing STATE 1")

        try await sendPlainRequest(request)

        let response =
            try await receivePlainResponse()

        let peerData =
            try extractPairingData(from: response)

        let peerTLVs =
            try PairingTLVCodec.decode(peerData)

        guard let peerPublicKey =
            PairingTLVCodec.firstValue(
                for: .publicKey,
                in: peerTLVs
            )
        else {
            print("Pair Verify: Apple TV did not return public key")
            return false
        }

        guard peerPublicKey.count == 32 else {
            print("Pair Verify: invalid X25519 public key")
            return false
        }

        let peerKey =
            try Curve25519.KeyAgreement.PublicKey(
                rawRepresentation: peerPublicKey
            )

        let sharedSecret =
            try x25519PrivateKey.sharedSecretFromKeyAgreement(
                with: peerKey
            )

        let sharedSecretData =
            sharedSecret.withUnsafeBytes { Data($0) }

        pairVerifySharedSecret = sharedSecretData

        clientMainKey =
            RemotePairingCrypto.makeMainEncryptionKey(
                sessionKey: sharedSecretData,
                label: "ClientEncrypt-main"
            )

        serverMainKey =
            RemotePairingCrypto.makeMainEncryptionKey(
                sessionKey: sharedSecretData,
                label: "ServerEncrypt-main"
            )

        encryptedSequenceNumber = 0

        print("Main encrypted session keys initialized")

        let verifyKey =
            sharedSecret.hkdfDerivedSymmetricKey(
                using: SHA512.self,
                salt: Data(
                    "Pair-Verify-Encrypt-Salt".utf8
                ),
                sharedInfo: Data(
                    "Pair-Verify-Encrypt-Info".utf8
                ),
                outputByteCount: 32
            )

        var signBuffer = Data()

        signBuffer.append(
            x25519PrivateKey
                .publicKey
                .rawRepresentation
        )

        signBuffer.append(
            contentsOf: Data(
                hostIdentifier.utf8
            )
        )

        signBuffer.append(
            contentsOf: peerPublicKey
        )

        let signature =
            try ed25519PrivateKey.signature(
                for: signBuffer
            )

        let innerTLV =
            PairingTLVCodec.encode([
                PairingTLV(
                    type: .identifier,
                    data:
                        Data(hostIdentifier.utf8)
                ),
                PairingTLV(
                    type: .signature,
                    data: signature
                )
            ])

        let nonce = Data([
            0x00, 0x00, 0x00, 0x00,
            0x50, 0x56, 0x2D, 0x4D,
            0x73, 0x67, 0x30, 0x33
        ])

        let encrypted =
            try ChaChaPoly.seal(
                innerTLV,
                using: verifyKey,
                nonce: try ChaChaPoly.Nonce(
                    data: nonce
                ),
                authenticating: Data()
            )

        let encryptedBytes =
            encrypted.ciphertext +
            encrypted.tag

        let state3TLV =
            PairingTLVCodec.encode([
                PairingTLV(
                    type: .state,
                    data: Data([0x03])
                ),
                PairingTLV(
                    type: .encryptedData,
                    data: encryptedBytes
                )
            ])

        let request3: [String: Any] = [
            "event": [
                "_0": [
                    "pairingData": [
                        "_0": [
                            "data":
                                state3TLV.base64EncodedString(),
                            "kind":
                                "verifyManualPairing",
                            "startNewSession":
                                false
                        ]
                    ]
                ]
            ]
        ]

        print("Sending verifyManualPairing STATE 3")

        try await sendPlainRequest(request3)

        let response3 =
            try await receivePlainResponse()

        let responseData =
            try extractPairingData(
                from: response3
            )

        let responseTLVs =
            try PairingTLVCodec.decode(
                responseData
            )

        if PairingTLVCodec.firstValue(
            for: .error,
            in: responseTLVs
        ) != nil {
            print("Pair Verify rejected by Apple TV")
            return false
        }

        print("Saved pair record verified successfully")

        return true
    }

    private func sendEncryptedRequest(
        _ request: [String: Any]
    ) async throws -> [String: Any] {

        guard let clientMainKey else {
            throw PairingError.invalidResponse(
                "Client main encryption key is unavailable."
            )
        }

        guard let serverMainKey else {
            throw PairingError.invalidResponse(
                "Server main encryption key is unavailable."
            )
        }

        let nonce = makeEncryptedNonce(
            sequenceNumber: encryptedSequenceNumber
        )

        let plaintext =
            try JSONSerialization.data(
                withJSONObject: request,
                options: []
            )

        let sealed =
            try ChaChaPoly.seal(
                plaintext,
                using: clientMainKey,
                nonce: try ChaChaPoly.Nonce(
                    data: nonce
                ),
                authenticating: Data()
            )

        let encryptedData =
            sealed.ciphertext + sealed.tag

        let envelope: [String: Any] = [
            "message": [
                "streamEncrypted": [
                    "_0": encryptedData.base64EncodedString()
                ]
            ],
            "originatedBy": "host",
            "sequenceNumber": sequenceNumber
        ]

        sequenceNumber += 1
        encryptedSequenceNumber += 1

        let body =
            try JSONSerialization.data(
                withJSONObject: envelope,
                options: []
            )

        let frame =
            try RemotePairingFraming.encode(body)

        print("MAIN ENCRYPTED REQUEST")
        print(
            "Encrypted request bytes: \(encryptedData.count)"
        )

        try await send(frame)

        let responseBody =
            try await receiveFrame()

        guard
            let response =
                try JSONSerialization.jsonObject(
                    with: responseBody,
                    options: []
                ) as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Encrypted response was not a JSON object."
            )
        }

        guard
            let message =
                response["message"] as? [String: Any],
            let streamEncrypted =
                message["streamEncrypted"] as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Missing streamEncrypted response."
            )
        }

        let responseValue =
            streamEncrypted["_0"]

        let encryptedResponse: Data

        if let value = responseValue as? Data {
            encryptedResponse = value
        } else if let value = responseValue as? String {
            guard let decoded =
                Data(base64Encoded: value)
            else {
                throw PairingError.invalidResponse(
                    "Invalid encrypted response encoding."
                )
            }

            encryptedResponse = decoded
        } else {
            throw PairingError.invalidResponse(
                "Invalid encrypted response data."
            )
        }

        let responseSequenceNumber =
            encryptedSequenceNumber - 1

        let responseNonce =
            makeEncryptedNonce(
                sequenceNumber: responseSequenceNumber
            )

        guard encryptedResponse.count >= 16 else {
            throw PairingError.invalidResponse(
                "Encrypted response is too short."
            )
        }

        let responseCiphertext =
            encryptedResponse.dropLast(16)

        let responseTag =
            encryptedResponse.suffix(16)

        let sealedResponse =
            try ChaChaPoly.SealedBox(
                nonce: try ChaChaPoly.Nonce(
                    data: responseNonce
                ),
                ciphertext: responseCiphertext,
                tag: responseTag
            )

        let responsePlaintext: Data

        do {
            responsePlaintext =
                try ChaChaPoly.open(
                    sealedResponse,
                    using: serverMainKey,
                    authenticating: Data()
                )
        } catch {
            print("MAIN ENCRYPTED RESPONSE DECRYPT FAILED")
            print("Encrypted response bytes: \(encryptedResponse.count)")
            print(
                "Encrypted sequence number: \(encryptedSequenceNumber - 1)"
            )
            print(
                "Outer sequence number: \(sequenceNumber - 1)"
            )

            print(
                "Crypto error: \(error)"
            )

            throw error
        }

        guard
            let responseObject =
                try JSONSerialization.jsonObject(
                    with: responsePlaintext,
                    options: []
                ) as? [String: Any]
        else {
            throw PairingError.invalidResponse(
                "Encrypted response is not a JSON object."
            )
        }

        guard
            let responseContainer =
                responseObject["response"] as? [String: Any],
            let responseOne =
                responseContainer["_1"] as? [String: Any]
        else {
            return responseObject
        }

        if let errorExtended =
            responseOne["errorExtended"] {
            throw PairingError.invalidResponse(
                "Apple TV returned errorExtended: \(errorExtended)"
            )
        }

        return responseOne
    }

    private func makeEncryptedNonce(
        sequenceNumber: UInt64
    ) -> Data {

        var nonce = Data()

        var value = sequenceNumber

        for _ in 0..<8 {
            nonce.append(
                UInt8(value & 0xff)
            )
            value >>= 8
        }

        nonce.append(contentsOf: [0, 0, 0, 0])

        return nonce
    }

    private func createTCPListener()
        async throws
        -> (
            serviceName: String,
            port: Int,
            devicePublicKey: String
        ) {

        guard let pairVerifySharedSecret else {
            throw PairingError.invalidResponse(
                "Pair Verify shared secret is unavailable."
            )
        }

        let request: [String: Any] = [
            "request": [
                "_0": [
                    "createListener": [
                        "key":
                            pairVerifySharedSecret.base64EncodedString(),

                        "peerConnectionsInfo": [
                            [
                                "owningPID":
                                    ProcessInfo.processInfo
                                        .processIdentifier,

                                "owningProcessName":
                                    "CoreDeviceService"
                            ]
                        ],

                        "transportProtocolType":
                            "tcp"
                    ]
                ]
            ]
        ]

        print("Sending encrypted createListener")

        let response =
            try await sendEncryptedRequest(request)

        print("CREATE LISTENER RESPONSE:")

        guard
            let createListener =
                response["createListener"]
                as? [String: Any],

            let serviceName =
                createListener["serviceName"]
                as? String,

            let port =
                createListener["port"]
                as? Int,

            let devicePublicKey =
                createListener["devicePublicKey"]
                as? String

        else {
            throw PairingError.invalidResponse(
                "createListener response did not contain serviceName/port/devicePublicKey."
            )
        }

        print(
            "Apple TV listener service:",
            serviceName
        )

        print(
            "Apple TV listener port:",
            port
        )

        return (
            serviceName: serviceName,
            port: port,
            devicePublicKey: devicePublicKey
        )
    }
}

private extension Data {

    init(hexString: String) {

        self.init()

        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)

        var index = hexString.startIndex

        while index < hexString.endIndex {

            let next =
                hexString.index(
                    index,
                    offsetBy: 2
                )

            let byteString =
                String(
                    hexString[index..<next]
                )

            guard
                let byte =
                    UInt8(byteString, radix: 16)
            else {
                index = next
                continue
            }

            bytes.append(byte)
            index = next
        }

        self.append(contentsOf: bytes)
    }
}
