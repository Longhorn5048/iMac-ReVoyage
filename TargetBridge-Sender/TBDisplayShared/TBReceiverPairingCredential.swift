import Foundation
import Security
import Network

enum TBReceiverPairingCredential {
    static var pairingRequired: Bool { rv_pairing_required() != 0 }
    static var localConnectionCode: String { String(cString: rv_local_wire_key()) }
    private static let aliasesKey = "com.revoyage.sender.receiver-identities.v1"
    private static let service = "com.revoyage.sender.receiver-pairing"

    static func load(forReceiver host: String) -> String? {
        if !pairingRequired {
            return host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : localConnectionCode
        }
        guard let account = account(forReceiver: host) else { return nil }
        if let direct = read(account: account).flatMap(normalizedCode) { return direct }
        return verifiedIdentity(forReceiver: host).flatMap(load(forIdentity:))
    }

    static func normalizedIdentity(_ candidate: String?) -> String? {
        guard let candidate, let uuid = UUID(uuidString: candidate), candidate.utf8.count == 36 else { return nil }
        return uuid.uuidString.lowercased()
    }

    static func expectedIdentity(forReceiver host: String) -> String? {
        if !pairingRequired { return nil }
        return verifiedIdentity(forReceiver: host) ?? normalizedHost(host).flatMap {
            normalizedIdentity(UserDefaults.standard.string(forKey: "com.revoyage.sender.expected-identity." + $0))
        }
    }

    static func rememberImportedIdentity(_ identity: String, host: String) {
        guard let host = normalizedHost(host), let identity = normalizedIdentity(identity) else { return }
        UserDefaults.standard.set(identity, forKey: "com.revoyage.sender.expected-identity." + host)
    }

    static func verifiedIdentity(forReceiver host: String) -> String? {
        guard let host = normalizedHost(host) else { return nil }
        let aliases = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
        return normalizedIdentity(aliases[host])
    }

    static func load(forIdentity identity: String) -> String? {
        guard let identity = normalizedIdentity(identity) else { return nil }
        if !pairingRequired { return localConnectionCode }
        return read(account: "receiver-identity-key-v1|\(identity)").flatMap(normalizedCode)
    }

    /// A Bonjour UUID is only a credential lookup hint. The caller must verify
    /// the signed identity and mutual nonce proof before using or saving it.
    static func candidateCode(forReceiver host: String, identityHint: String?) -> String? {
        if !pairingRequired { return localConnectionCode }
        return load(forReceiver: host) ?? identityHint.flatMap(normalizedIdentity).flatMap(load(forIdentity:))
    }

    @discardableResult
    static func bindAuthenticatedIdentity(_ identity: String, code: String, host: String) -> Bool {
        guard let identity = normalizedIdentity(identity), let host = normalizedHost(host),
              !pairingRequired || save(code, account: "receiver-identity-key-v1|\(identity)") else { return false }
        var aliases = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
        aliases[host] = identity
        UserDefaults.standard.set(aliases, forKey: aliasesKey)
        return true
    }

    /// Offered in the pairing editor only. Never used to authenticate an
    /// arbitrary discovered host: the user must bind it to a receiver first.
    static func legacyCodeForMigration() -> String? {
        read(account: "receiver-settings-key-v1").flatMap(normalizedCode)
    }

    static func normalizedHost(_ candidate: String) -> String? {
        var host = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, host.utf8.count <= 253,
              host.utf8.allSatisfy({
                  (48...57).contains($0) || (97...122).contains($0) ||
                  [UInt8(45), 46, 58, 37, 95].contains($0)
              }), host.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        return host
    }

    static func account(forReceiver host: String) -> String? {
        normalizedHost(host).map { "receiver-settings-key-v2|\($0)" }
    }

    static func normalizedCode(_ candidate: String) -> String? {
        let value = candidate.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == 64, value.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }) else { return nil }
        return value
    }

    private static func read(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    @discardableResult
    static func save(_ candidate: String, forReceiver host: String) -> Bool {
        guard let account = account(forReceiver: host), save(candidate, account: account),
              let host = normalizedHost(host) else { return false }
        // Explicit re-pairing permits a replaced installation to establish a
        // fresh authenticated identity; importing alone never grants trust.
        var aliases = UserDefaults.standard.dictionary(forKey: aliasesKey) as? [String: String] ?? [:]
        UserDefaults.standard.removeObject(forKey: "com.revoyage.sender.expected-identity." + host)
        aliases.removeValue(forKey: host)
        UserDefaults.standard.set(aliases, forKey: aliasesKey)
        return true
    }

    private static func save(_ candidate: String, account: String) -> Bool {
        guard let value = normalizedCode(candidate),
              let data = value.data(using: .utf8) else { return false }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }

        var insertion = query
        insertion.merge(updates) { _, new in new }
        return SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess
    }
}

/// A one-command connection follows the same mutual proof exchange as video.
/// Pure state transitions are also exercised without opening a socket.
struct TBReceiverCommandHandshake {
    enum Failure: Error { case invalidProof, unexpectedPacket }
    private let pairingCode: String
    private let command: Data
    private let expectedIdentity: String?
    private var nonce: Data?
    private var senderNonce: Data?
    private var receiverIdentity: String?
    private(set) var authenticated = false

    init?(pairingCode: String, command: Data, expectedIdentity: String? = nil) {
        guard let code = TBReceiverPairingCredential.normalizedCode(pairingCode) else { return nil }
        self.pairingCode = code
        self.command = command
        self.expectedIdentity = expectedIdentity
    }

    mutating func consume(type: TBMonitorPacketType, payload: Data) throws -> Data {
        guard !authenticated else { throw Failure.unexpectedPacket }
        if nonce == nil {
            guard type == .settingsChallenge,
                  let challenge = TBMonitorProtocol.decodeJSON(TBMonitorSettingsChallenge.self, from: payload),
                  challenge.requiresSessionAuthentication == true,
                  challenge.schemaVersion == 1,
                  (1...2).contains(challenge.supportedSchemaVersion ?? 1),
                  challenge.nonce.utf8.count == 64 else { throw Failure.unexpectedPacket }
            let bytes = Array(challenge.nonce.utf8)
            var decoded = Data()
            for index in stride(from: 0, to: 64, by: 2) {
                guard let byte = UInt8(String(decoding: bytes[index..<index + 2], as: UTF8.self), radix: 16)
                else { throw Failure.invalidProof }
                decoded.append(byte)
            }
            receiverIdentity = try TBMonitorProtocol.verifiedReceiverIdentity(challenge: challenge, nonce: decoded,
                pairingCode: pairingCode, expectedIdentity: expectedIdentity)
            senderNonce = receiverIdentity == nil ? nil : TBMonitorProtocol.freshSenderNonce()
            guard let proof = TBMonitorProtocol.sessionAuthenticationDigest(
                nonce: decoded, pairingCode: pairingCode, receiverProof: false,
                senderNonce: senderNonce, receiverIdentity: receiverIdentity
            ) else { throw Failure.invalidProof }
            nonce = decoded
            return TBMonitorProtocol.makePacket(type: .sessionAuth, payload: (senderNonce ?? Data()) + proof)
        }
        guard type == .sessionAuthAck, let nonce,
              TBMonitorProtocol.verifySessionAuthenticationResponse(payload, nonce: nonce, pairingCode: pairingCode, senderNonce: senderNonce, receiverIdentity: receiverIdentity)
        else { throw Failure.invalidProof }
        authenticated = true
        return command
    }
}

@MainActor
final class TBAuthenticatedReceiverCommand {
    private let connection: NWConnection
    private var handshake: TBReceiverCommandHandshake
    private var buffer = Data()
    private var timeout: Task<Void, Never>?
    private var completion: ((Bool) -> Void)?
    private var finished = false

    init?(host: String, pairingCode: String, command: Data, completion: @escaping (Bool) -> Void) {
        guard let host = TBReceiverPairingCredential.normalizedHost(host),
              let handshake = TBReceiverCommandHandshake(pairingCode: pairingCode, command: command, expectedIdentity: TBReceiverPairingCredential.expectedIdentity(forReceiver: host)),
              let port = NWEndpoint.Port(rawValue: TBMonitorProtocol.port) else { return nil }
        guard let (dialHost, parameters) = try? TBWiredConnection.dial(host: host,
            localIP: TBDisplaySenderService.shared.wiredLocalIP(forReceiver: host)) else { return nil }
        self.connection = NWConnection(host: dialHost, port: port, using: parameters)
        self.handshake = handshake
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                switch state {
                case .ready: self.receiveNext()
                case .failed, .cancelled: self.finish(success: false)
                default: break
                }
            }
        }
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.finish(success: false)
        }
        connection.start(queue: DispatchQueue(label: "com.revoyage.sender.receiver-command"))
    }

    func cancel() { finish(success: false) }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, end, error in
            Task { @MainActor [weak self] in
                guard let self, !self.finished else { return }
                if let data {
                    self.buffer.append(data)
                    guard self.buffer.count <= 16 * 1024 else { self.finish(success: false); return }
                    do {
                        while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &self.buffer) {
                            let packet = try self.handshake.consume(type: type, payload: payload)
                            let isCommand = self.handshake.authenticated
                            self.connection.send(content: packet, completion: .contentProcessed { [weak self] sendError in
                                Task { @MainActor [weak self] in
                                    if sendError != nil { self?.finish(success: false) }
                                    else if isCommand { self?.finish(success: true) }
                                }
                            })
                            if isCommand { return }
                        }
                    } catch { self.finish(success: false); return }
                }
                if end || error != nil { self.finish(success: false); return }
                self.receiveNext()
            }
        }
    }

    private func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        connection.stateUpdateHandler = nil
        connection.cancel()
        buffer.removeAll()
        let callback = completion
        completion = nil
        callback?(success)
    }
}

/// Imported identity remains a hint until the connection proves possession of
/// this key. Files are bounded and normalized before any Keychain write.
struct TBReceiverPairingDocument: Decodable {
    let schemaVersion: Int
    let receiverID: String
    let host: String
    let pairingCode: String

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 4096 else { throw TBReceiverCommandHandshake.Failure.invalidProof }
        let value = try JSONDecoder().decode(Self.self, from: data)
        guard value.schemaVersion == 1,
              TBReceiverPairingCredential.normalizedIdentity(value.receiverID) != nil,
              TBReceiverPairingCredential.normalizedHost(value.host) != nil,
              TBReceiverPairingCredential.normalizedCode(value.pairingCode) != nil else {
            throw TBReceiverCommandHandshake.Failure.invalidProof
        }
        return value
    }
}
