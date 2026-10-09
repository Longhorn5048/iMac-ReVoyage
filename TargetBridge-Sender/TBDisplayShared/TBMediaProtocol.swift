import Foundation
import CryptoKit
import Security

enum TBMediaPacket: UInt8 {
    case challenge = 0x51, authentication = 0x52, proof = 0x53, registry = 0x54
    case request = 0x55, status = 0x56, jpeg = 0x57, pcm = 0x58, stop = 0x59, heartbeat = 0x5a
}
struct TBMediaDevice: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
}
struct TBMediaRegistry: Codable, Equatable, Sendable {
    let schema: Int
    let devices: [TBMediaDevice]
    let cameraPermission: String
    let microphonePermission: String
    var supportsBandwidthLimit: Bool? = nil
    var isValid: Bool {
        let permissions = ["authorized", "denied", "restricted", "notDetermined"]
        return schema == 1 && devices.count <= 32 &&
            Set(devices.map { "\($0.kind)|\($0.id)" }).count == devices.count &&
            permissions.contains(cameraPermission) && permissions.contains(microphonePermission) &&
            devices.allSatisfy { item in
                ["camera", "microphone"].contains(item.kind) && !item.id.isEmpty && !item.name.isEmpty &&
                item.id.utf8.count <= 512 && item.name.utf8.count <= 512 &&
                !item.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
                !item.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            }
    }
}
struct TBMediaStatus: Codable, Equatable, Sendable {
    let schema: Int
    let cameraActive: Bool
    let microphoneActive: Bool
    let error: String
    var isValid: Bool {
        schema == 1 && ["", "permission_pending", "permission_denied", "device_missing", "device_busy",
                       "format_unsupported", "capture_failed"].contains(error) &&
            (error.isEmpty || (!cameraActive && !microphoneActive))
    }
}
struct TBMediaRequest: Encodable {
    let schema = 1
    let cameraID: String?
    let microphoneID: String?
    var cameraMbps: Double? = nil
}
struct TBMediaHandshake {
    private let key: String
    private let senderNonce: Data
    private var receiverNonce: Data?
    private(set) var authenticated = false
    init(key: String, senderNonce: Data? = nil) throws {
        guard TBReceiverPairingCredential.normalizedCode(key) == key else { throw TBMediaProtocol.Failure.invalidProof }
        self.key = key
        if let senderNonce {
            guard senderNonce.count == 32 else { throw TBMediaProtocol.Failure.invalidProof }
            self.senderNonce = senderNonce
        } else {
            var nonce = Data(count: 32)
            guard nonce.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }) == errSecSuccess else {
                throw TBMediaProtocol.Failure.invalidProof
            }
            self.senderNonce = nonce
        }
    }
    mutating func receive(_ type: TBMediaPacket, _ payload: Data) throws -> Data? {
        guard !authenticated else { throw TBMediaProtocol.Failure.invalidProof }
        switch type {
        case .challenge:
            guard receiverNonce == nil, payload.count == 32 else { throw TBMediaProtocol.Failure.invalidProof }
            receiverNonce = payload
            return try TBMediaProtocol.authentication(receiverNonce: payload, senderNonce: senderNonce, key: key)
        case .proof:
            guard let receiverNonce,
                  TBMediaProtocol.verifyReceiver(payload, receiverNonce: receiverNonce, senderNonce: senderNonce, key: key) else {
                throw TBMediaProtocol.Failure.invalidProof
            }
            authenticated = true; return nil
        default: throw TBMediaProtocol.Failure.invalidProof
        }
    }
}
struct TBMediaSequenceGate {
    private var lastVideo: UInt64?
    private var nextAudio: UInt64?
    private(set) var awaitingConfiguration = false
    mutating func beginConfiguration() { awaitingConfiguration = true }
    mutating func reset() { lastVideo = nil; nextAudio = nil; awaitingConfiguration = false }
    @discardableResult mutating func acceptJPEG(_ payload: Data) throws -> Bool {
        guard payload.count > 8, payload.count <= 262_152 else { throw TBMediaProtocol.Failure.invalidPacket }
        guard !awaitingConfiguration else { return false }
        let sequence = try TBMediaProtocol.sequence(payload)
        if let lastVideo, sequence <= lastVideo { throw TBMediaProtocol.Failure.invalidPacket }
        lastVideo = sequence
        return true
    }
    @discardableResult mutating func acceptPCM(_ payload: Data) throws -> Bool {
        guard payload.count > 8, payload.count <= 1928, (payload.count - 8) % 2 == 0 else { throw TBMediaProtocol.Failure.invalidPacket }
        guard !awaitingConfiguration else { return false }
        let first = try TBMediaProtocol.sequence(payload), frames = UInt64((payload.count - 8) / 2)
        guard first <= UInt64.max - frames else { throw TBMediaProtocol.Failure.invalidPacket }
        if let nextAudio, first != nextAudio { throw TBMediaProtocol.Failure.invalidPacket }
        nextAudio = first + frames
        return true
    }
}
enum TBMediaProtocol {
    static let port: UInt16 = 54323
    static let maxPacket = 262_153
    enum Failure: Error { case invalidPacket, invalidProof }
    static func packet(_ type: TBMediaPacket, _ payload: Data = Data()) -> Data {
        var size = UInt32(payload.count + 1).bigEndian
        var result = Data(bytes: &size, count: 4)
        result.append(type.rawValue); result.append(payload); return result
    }
    static func drain(_ buffer: inout Data) throws -> (TBMediaPacket, Data)? {
        guard buffer.count <= maxPacket + 4 + 65_536 else { throw Failure.invalidPacket }
        guard buffer.count >= 4 else { return nil }
        let size = Int(buffer.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard (1...maxPacket).contains(size) else { throw Failure.invalidPacket }
        guard buffer.count >= size + 4 else { return nil }
        guard let type = TBMediaPacket(rawValue: buffer[buffer.startIndex + 4]) else { throw Failure.invalidPacket }
        let payload = buffer.subdata(in: (buffer.startIndex + 5)..<(buffer.startIndex + size + 4))
        buffer.removeFirst(size + 4)
        return (type, payload)
    }
    static func authentication(receiverNonce: Data, senderNonce: Data, key: String) throws -> Data {
        guard receiverNonce.count == 32, senderNonce.count == 32, TBReceiverPairingCredential.normalizedCode(key) == key else {
            throw Failure.invalidProof
        }
        let message = receiverNonce + senderNonce + Data("ReVoyageMediaSenderV1".utf8)
        return senderNonce + Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(key.utf8))))
    }
    static func verifyReceiver(_ proof: Data, receiverNonce: Data, senderNonce: Data, key: String) -> Bool {
        guard proof.count == 32, receiverNonce.count == 32, senderNonce.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(proof,
            authenticating: receiverNonce + senderNonce + Data("ReVoyageMediaReceiverV1".utf8),
            using: SymmetricKey(data: Data(key.utf8)))
    }
    static func sequence(_ payload: Data) throws -> UInt64 {
        guard payload.count >= 8 else { throw Failure.invalidPacket }
        return payload.withUnsafeBytes { UInt64(bigEndian: $0.loadUnaligned(as: UInt64.self)) }
    }
}
