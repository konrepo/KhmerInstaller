import Foundation

struct RemotePairingDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let identifier: String
    let hostname: String
    let port: Int
}

struct PairConsentResult {
    let publicKey: Data
    let salt: Data
    let pin: String?
}

struct RemotePairingSession {
    var sequenceNumber: UInt64 = 0
    var encryptedSequenceNumber: UInt64 = 0

    var remoteIdentifier: String?
    var remoteModel: String?

    var x25519PrivateKey: Data?
    var encryptionKey: Data?

    var peerAltIRK: Data?
    var sessionIdentifier: Data?

    var hostIdentifier: String?
}

enum RemotePairingState: Equatable {
    case disconnected
    case connecting
    case connected
    case handshaking
    case validatingPairing
    case requestingPairing
    case waitingForPIN
    case verifyingProof
    case savingPairRecord
    case paired
    case failed(String)
}
