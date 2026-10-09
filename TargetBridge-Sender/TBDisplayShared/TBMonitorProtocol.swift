import Foundation
import CryptoKit

enum TBMonitorPacketType: UInt8 {
    case helloReceiver = 0x10
    case displayProfile = 0x11
    case createSessionAck = 0x12
    case uiLanguage = 0x13
    case settingsChallenge = 0x14
    case settingsSync = 0x15
    case settingsAck = 0x16
    case sessionAuth = 0x17
    case sessionAuthAck = 0x18
    case paramSets = 0x20
    case frame = 0x21
    case rawFrame = 0x22   // Uncompressed NV12 planes (raw passthrough mode)
    case audioFrame = 0x23
    case heartbeat = 0x30
    case teardown = 0x31
    case cursor = 0x32
    case inputEvent = 0x33
    case inputControlMode = 0x34
    case brightness = 0x35
    case clipboard = 0x36
    case volume = 0x37
    case removableVolumes = 0x38
    case displayPower = 0x39
    case displayPowerAck = 0x3a
    case receiverMetrics = 0x3c
    case brightnessState = 0x3b
    case senderPower = 0x3d
    case senderPowerAck = 0x3e
    case storageMonitorChallenge = 0x41
    case storageMonitorAuth = 0x42
    case storageMonitorSnapshot = 0x43
    case testData = 0x40
}

enum TBMonitorDisplayPower {
    static func command(displayOn: Bool, requestID: UInt64, senderState: Bool = false) -> Data {
        var id = requestID.bigEndian
        return TBMonitorProtocol.makePacket(type: senderState ? .senderPower : .displayPower,
            payload: Data([displayOn ? 1 : 0]) + Data(bytes: &id, count: 8))
    }
    static func acknowledgement(_ payload: Data) -> (displayOn: Bool, accepted: Bool, requestID: UInt64)? {
        guard payload.count == 10, payload[payload.startIndex] <= 1,
              payload[payload.startIndex + 1] <= 1 else { return nil }
        let id = payload.dropFirst(2).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard id != 0 else { return nil }
        return (payload[payload.startIndex] == 1, payload[payload.startIndex + 1] == 1, id)
    }
}

struct TBMonitorHelloReceiver: Codable {
    var brightnessCommandsOnly: Bool? = true
    var senderName: String
    var uiLanguage: String?
    var capturePreset: String?
    var captureSource: String?
    var captureWidth: Int?
    var captureHeight: Int?
    var codec: String?
}

struct TBMonitorDisplayProfile: Codable {
    var receiverName: String
    var panelWidth: Int
    var panelHeight: Int
    var modeWidth: Int
    var modeHeight: Int
    var refreshRate: Double
    var hiDPI: Bool
    var captureWidth: Int
    var captureHeight: Int
    var supportsHEVCDecode: Bool?
    var supportsRawNV12: Bool?
    var inputMonitoringTrusted: Bool?
    var accessibilityTrusted: Bool?
    var supportsDisplayPower: Bool? = nil
    var supportsSenderPower: Bool? = nil
    var supportsBrightness: Bool? = nil
    var supportsBrightnessState: Bool? = nil
    var supportsAutomaticBrightnessControl: Bool? = nil
    var widthMillimeters: Double? = nil
    var heightMillimeters: Double? = nil
    var displayIdentity: String? = nil
    var nativeModeKnown: Bool? = nil

    /// Validate peer-controlled sizes before multiplication or unsigned conversion.
    var isValid: Bool {
        let sizes = [panelWidth, panelHeight, modeWidth, modeHeight, captureWidth, captureHeight]
        guard sizes.allSatisfy({ (1...16384).contains($0) }),
              refreshRate.isFinite, (1...240).contains(refreshRate) else { return false }
        let scale = hiDPI ? 2 : 1
        let dimensions = [widthMillimeters, heightMillimeters].compactMap { $0 }
        guard dimensions.allSatisfy({ $0.isFinite && (0...5000).contains($0) }) else { return false }
        return modeWidth * scale <= panelWidth && modeHeight * scale <= panelHeight
    }
}

struct TBMonitorCreateSessionAck: Codable {
    var accepted: Bool
    var displayName: String
    var displayID: UInt32
}

struct TBMonitorUILanguageUpdate: Codable {
    var uiLanguage: String
}

struct TBMonitorSettingsChallenge: Codable {
    var schemaVersion: Int
    var supportedSchemaVersion: Int?
    var nonce: String
    var requiresSessionAuthentication: Bool?
    var receiverID: String? = nil
    var identityProof: String? = nil
}

struct TBMonitorSettingsSync: Codable {
    var schemaVersion: Int
    var revision: UInt64
    var brightness: Double
    var volume: Double
    var language: String
    var sleepAfterNoSignalSeconds: UInt32?
    var hmac: String
}

struct TBMonitorSettingsAck: Codable {
    var accepted: Bool
    var revision: UInt64
    var reason: String?
}

struct TBMonitorHeartbeat: Codable {
    var sequence: UInt64
}

struct TBMonitorTeardown: Codable {
    var reason: String
}

struct TBMonitorCursor: Codable {
    var x: Int
    var y: Int
    var width: Int
    var height: Int
    var visible: Bool
    var type: Int
}

struct TBMonitorInputEvent: Codable {
    var kind: String
    var dx: Int?
    var dy: Int?
    var scrollX: Int?
    var scrollY: Int?
    var keyCode: UInt16?
}

struct TBMonitorInputControlMode: Codable {
    var mode: String
}

struct TBMonitorBrightness: Codable {
    var level: Double
}

struct TBMonitorBrightnessState: Codable {
    var supported: Bool
    var actualLevel: Double?
    var requestedLevel: Double?
    var accepted: Bool?
    var reason: String
    var isValid: Bool {
        [actualLevel, requestedLevel].compactMap { $0 }.allSatisfy { $0.isFinite && (0...1).contains($0) }
            && (!supported || actualLevel != nil) && (accepted != true || supported)
            && reason.count <= 128
    }
}

struct TBMonitorVolume: Codable {
    var level: Double
}

struct TBMonitorClipboard: Codable {
    var text: String
}

struct TBMonitorRemovableVolume: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct TBMonitorRemovableVolumeSnapshot: Decodable, Sendable {
    let schemaVersion: Int
    let volumes: [TBMonitorRemovableVolume]
}

/// Framing-level corruption that cannot be recovered by waiting for more
/// bytes. The connection carrying the stream should be torn down.
enum TBMonitorProtocolError: Error, Equatable, CustomStringConvertible {
    case invalidPacketLength(UInt32)

    var description: String {
        switch self {
        case .invalidPacketLength(let length):
            return "invalid packet length \(length)"
        }
    }
}

enum TBMonitorProtocol {
    static let port: UInt16 = 54321

    /// Upper bound for a single packet's declared length. Mirrors the
    /// receiver's parser sanity check (net.c) so both ends agree on what a
    /// corrupt length prefix is. Without this cap, a corrupted 4-byte length
    /// (e.g. 0xFFFFFFFF) would make the drain loop buffer inbound data
    /// forever, waiting for a packet that can never complete.
    static let maxPacketLength: UInt32 = 64 * 1024 * 1024

    static func isValidRemovableVolumeSnapshot(_ snapshot: TBMonitorRemovableVolumeSnapshot) -> Bool {
        guard snapshot.schemaVersion == 1, snapshot.volumes.count <= 32 else { return false }
        let identifiers = snapshot.volumes.map(\.id)
        guard Set(identifiers).count == identifiers.count else { return false }
        return snapshot.volumes.allSatisfy { volume in
            !volume.id.isEmpty && volume.id.utf8.count <= 128 &&
            !volume.name.isEmpty && volume.name.utf8.count <= 255 &&
            volume.name != "." && volume.name != ".." &&
            !volume.name.contains("/") &&
            !volume.id.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) &&
            !volume.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    static func removableVolumeSMBURL(receiverHost: String, shareName: String) -> URL? {
        guard receiverHost.range(of: "^[A-Za-z0-9.-]{1,253}$", options: .regularExpression) != nil,
              !shareName.isEmpty, shareName.utf8.count <= 255,
              shareName != ".", shareName != "..", !shareName.contains("/"),
              !shareName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let encodedName = shareName.addingPercentEncoding(
                withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
              ) else { return nil }
        var components = URLComponents()
        components.scheme = "smb"
        components.host = receiverHost
        components.percentEncodedPath = "/\(encodedName)"
        return components.url
    }

    static func makePacket(type: TBMonitorPacketType, payload: Data) -> Data {
        var packet = Data()
        appendBE32(&packet, UInt32(1 + payload.count))
        packet.append(type.rawValue)
        packet.append(payload)
        return packet
    }

    static func makeJSONPacket<T: Encodable>(type: TBMonitorPacketType, value: T) -> Data? {
        let encoder = JSONEncoder()
        guard let payload = try? encoder.encode(value) else { return nil }
        return makePacket(type: type, payload: payload)
    }

    /// Authenticates a separate, read-only storage-monitor connection. This
    /// endpoint has its own challenge and connection so volume discovery does
    /// not depend on a running display stream.
    static func makeStorageMonitorAuthPacket(nonce: Data, pairingCode: String) -> Data? {
        let keyText = pairingCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard nonce.count == 32, keyText.count == 64,
              keyText.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else { return nil }
        var message = nonce
        message.append(contentsOf: "ReVoyageStorageMonitorV1".utf8)
        let key = SymmetricKey(data: Data(keyText.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return makePacket(type: .storageMonitorAuth, payload: Data(digest))
    }

    static func freshSenderNonce() -> Data {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func sessionAuthenticationDigest(nonce: Data, pairingCode: String, receiverProof: Bool,
                                            senderNonce: Data? = nil, receiverIdentity: String? = nil) -> Data? {
        guard nonce.count == 32, let code = TBReceiverPairingCredential.normalizedCode(pairingCode) else { return nil }
        var message = nonce
        if let senderNonce {
            guard senderNonce.count == 32, let identity = TBReceiverPairingCredential.normalizedIdentity(receiverIdentity) else { return nil }
            message.append(senderNonce)
            message.append(contentsOf: identity.utf8)
            message.append(contentsOf: (receiverProof ? "ReVoyageSessionReceiverV2" : "ReVoyageSessionSenderV2").utf8)
        } else {
            message.append(contentsOf: (receiverProof ? "ReVoyageSessionReceiverV1" : "ReVoyageSessionSenderV1").utf8)
        }
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(code.utf8))))
    }

    static func receiverIdentityDigest(nonce: Data, pairingCode: String, identity: String) -> Data? {
        guard nonce.count == 32, let code = TBReceiverPairingCredential.normalizedCode(pairingCode),
              let identity = TBReceiverPairingCredential.normalizedIdentity(identity) else { return nil }
        var message = nonce
        message.append(contentsOf: identity.utf8)
        message.append(contentsOf: "ReVoyageReceiverIdentityV1".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(code.utf8))))
    }

    static func verifiedReceiverIdentity(challenge: TBMonitorSettingsChallenge, nonce: Data,
                                        pairingCode: String, expectedIdentity: String?) throws -> String? {
        // Older address-paired receivers remain usable until an identity has
        // been authenticated. A known identity may never silently downgrade.
        if challenge.receiverID == nil && challenge.identityProof == nil && expectedIdentity == nil { return nil }
        guard let id = TBReceiverPairingCredential.normalizedIdentity(challenge.receiverID),
              expectedIdentity == nil || id == TBReceiverPairingCredential.normalizedIdentity(expectedIdentity),
              let proof = challenge.identityProof, proof.utf8.count == 64,
              let digest = receiverIdentityDigest(nonce: nonce, pairingCode: pairingCode, identity: id) else {
            throw TBReceiverCommandHandshake.Failure.invalidProof
        }
        let expected = digest.map { String(format: "%02x", $0) }.joined()
        var difference: UInt8 = 0
        for (left, right) in zip(proof.utf8, expected.utf8) { difference |= left ^ right }
        guard difference == 0 else { throw TBReceiverCommandHandshake.Failure.invalidProof }
        return id
    }

    static func verifySessionAuthenticationResponse(_ proof: Data, nonce: Data, pairingCode: String, senderNonce: Data? = nil, receiverIdentity: String? = nil) -> Bool {
        guard let expected = sessionAuthenticationDigest(nonce: nonce, pairingCode: pairingCode, receiverProof: true, senderNonce: senderNonce, receiverIdentity: receiverIdentity),
              proof.count == expected.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(proof, expected) { difference |= left ^ right }
        return difference == 0
    }

    /// Hand-rolled encoder for the input-event hot path. Mouse move/drag events
    /// fire at display refresh rate (or faster with high-poll-rate mice), and a
    /// fresh `JSONEncoder` per event is the busiest allocator in that path. This
    /// emits the same JSON shape `JSONDecoder` reconstructs into a
    /// `TBMonitorInputEvent` (omitted fields decode as nil), mirroring the
    /// receiver's `snprintf`-based emitter. `kind` is always a fixed literal from
    /// the event converter, so no string escaping is required.
    static func makeInputEventPacket(_ event: TBMonitorInputEvent) -> Data {
        var json = "{\"kind\":\"\(event.kind)\""
        if let dx = event.dx { json += ",\"dx\":\(dx)" }
        if let dy = event.dy { json += ",\"dy\":\(dy)" }
        if let scrollX = event.scrollX { json += ",\"scrollX\":\(scrollX)" }
        if let scrollY = event.scrollY { json += ",\"scrollY\":\(scrollY)" }
        if let keyCode = event.keyCode { json += ",\"keyCode\":\(keyCode)" }
        json += "}"
        return makePacket(type: .inputEvent, payload: Data(json.utf8))
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, from payload: Data) -> T? {
        let decoder = JSONDecoder()
        return try? decoder.decode(type, from: payload)
    }

    /// Drains the next complete packet from `buffer`.
    ///
    /// - Returns: the packet, or `nil` when the buffer does not yet hold a
    ///   complete packet (more bytes are needed).
    /// - Throws: `TBMonitorProtocolError.invalidPacketLength` when the length
    ///   prefix is corrupt (zero or above `maxPacketLength`); the stream is
    ///   unrecoverable and the caller should close the connection.
    ///
    /// Packets with an unrecognized type byte (e.g. from a newer peer) are
    /// skipped and draining continues with the next packet, so one unknown
    /// packet cannot stall the packets queued behind it.
    static func drainPacket(from buffer: inout Data) throws -> (TBMonitorPacketType, Data)? {
        while buffer.count >= 5 {
            let packetLength = readBE32(buffer, offset: 0)
            guard packetLength >= 1, packetLength <= maxPacketLength else {
                throw TBMonitorProtocolError.invalidPacketLength(packetLength)
            }
            let packetEnd = 4 + Int(packetLength)
            guard buffer.count >= packetEnd else { return nil }
            let typeByte = buffer[4]
            let payload = buffer.subdata(in: 5..<packetEnd)
            buffer.removeSubrange(0..<packetEnd)
            if let packetType = TBMonitorPacketType(rawValue: typeByte) {
                return (packetType, payload)
            }
        }
        return nil
    }

    static func appendBE32(_ data: inout Data, _ value: UInt32) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    /// Canonical settings payload authenticated by the Receiver. Version 1
    /// retains its 56-byte layout; version 2 appends a 32-bit sleep timeout.
    static func settingsAuthenticationMessage(
        nonce: Data,
        schemaVersion: UInt32,
        revision: UInt64,
        brightness: Double,
        volume: Double,
        language: String,
        sleepAfterNoSignalSeconds: UInt32? = nil
    ) -> Data? {
        let supportedLanguages: Set<String> = ["auto", "en", "it", "de", "fr", "zh"]
        guard nonce.count == 32,
              supportedLanguages.contains(language),
              language.utf8.count <= 7 else { return nil }

        var message = nonce
        appendBE32(&message, schemaVersion)
        appendBE64(&message, revision)
        appendBE16(&message, quantizedLevel(brightness))
        appendBE16(&message, quantizedLevel(volume))
        message.append(contentsOf: language.utf8)
        message.append(contentsOf: repeatElement(UInt8(0), count: 8 - language.utf8.count))
        if schemaVersion == 2 {
            guard let sleepAfterNoSignalSeconds,
                  (15...3600).contains(sleepAfterNoSignalSeconds) else { return nil }
            appendBE32(&message, sleepAfterNoSignalSeconds)
        } else if schemaVersion != 1 {
            return nil
        }
        return message
    }

    private static func quantizedLevel(_ value: Double) -> UInt16 {
        let bounded = min(max(value.isFinite ? value : 0, 0), 1)
        return UInt16((bounded * 1000).rounded())
    }

    private static func appendBE16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8(value & 0xFF))
    }

    private static func appendBE64(_ data: inout Data, _ value: UInt64) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    static func readBE32(_ data: Data, offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes {
            $0.loadUnaligned(as: UInt32.self).bigEndian
        }
    }
}

struct TBMonitorReceiverMetrics: Codable {
    let hardwareDecode: Int
    let raw: Bool
    let received: UInt64, uploaded: UInt64, submitted: UInt64, sinceSubmitMs: UInt64
    let audioBytes: Int
    let decodeErrors: UInt64
    var isValid: Bool { (-1...1).contains(hardwareDecode) && (0...28_800).contains(audioBytes) }
}
