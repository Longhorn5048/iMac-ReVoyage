import XCTest
@testable import TargetBridge

final class TBReceiverIdentityTests: XCTestCase {
    func testDevelopmentConnectionNeedsNoSavedPairingCode() {
        XCTAssertFalse(TBReceiverPairingCredential.pairingRequired)
        XCTAssertEqual(TBReceiverPairingCredential.load(forReceiver: "unpaired-imac.local"),
                       String(repeating: "0", count: 64))
        XCTAssertEqual(TBReceiverPairingCredential.candidateCode(forReceiver: "unpaired-imac.local", identityHint: nil),
                       TBReceiverPairingCredential.localConnectionCode)
        XCTAssertNil(TBReceiverPairingCredential.expectedIdentity(forReceiver: "unpaired-imac.local"))
        XCTAssertNil(TBReceiverPairingCredential.load(forReceiver: ""))
    }
    func testDirectConnectionNeverTurnsAddressFormatsIntoPairingRequirements() {
        for host in ["", "雲風的iMac.local", "[fe80::1%en0]", "192.168.1.2:54321", "http://192.168.1.2", "192.168.1.2 (Ethernet)"] {
            // The connection layer reports invalid addresses. Credential
            // lookup must not block dialing with a misleading pairing error.
            XCTAssertEqual(TBReceiverPairingCredential.candidateCode(forReceiver: host, identityHint: nil),
                           TBReceiverPairingCredential.localConnectionCode)
            if !host.isEmpty {
                XCTAssertEqual(TBReceiverPairingCredential.load(forReceiver: host),
                               TBReceiverPairingCredential.localConnectionCode)
            }
        }
    }
    let identity = "12345678-1234-4234-8234-123456789abc"
    let key = String(repeating: "a", count: 64)
    let nonce = Data(0..<32)

    func testIdentityProofMatchesReceiverGoldenVector() throws {
        let digest = try XCTUnwrap(TBMonitorProtocol.receiverIdentityDigest(nonce: nonce, pairingCode: key, identity: identity))
        XCTAssertEqual(digest.map { String(format: "%02x", $0) }.joined(), "16e985febd4b5a711d97875351819ac85ce6a7dc09e5d8d28be9c9befb290d35")
        let challenge = TBMonitorSettingsChallenge(schemaVersion: 1, nonce: nonce.map { String(format: "%02x", $0) }.joined(), receiverID: identity, identityProof: digest.map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: challenge, nonce: nonce, pairingCode: key, expectedIdentity: identity), identity)
        XCTAssertThrowsError(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: challenge, nonce: Data(repeating: 0, count: 32), pairingCode: key, expectedIdentity: identity))
        XCTAssertThrowsError(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: challenge, nonce: nonce, pairingCode: String(repeating: "b", count: 64), expectedIdentity: identity))
        XCTAssertThrowsError(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: challenge, nonce: nonce, pairingCode: key, expectedIdentity: "87654321-1234-4234-8234-123456789abc"))
    }

    func testFreshSenderNonceRejectsCapturedAckAndReflection() throws {
        let senderNonce = Data(32..<64)
        let response = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key,
            receiverProof: true, senderNonce: senderNonce, receiverIdentity: identity))
        XCTAssertEqual(response.map { String(format: "%02x", $0) }.joined(), "1e2288aca170d203dffc410e92b0a3860215289080feac272922b17ad84a5ed9")
        XCTAssertTrue(TBMonitorProtocol.verifySessionAuthenticationResponse(response, nonce: nonce, pairingCode: key,
            senderNonce: senderNonce, receiverIdentity: identity))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(response, nonce: nonce, pairingCode: key,
            senderNonce: Data(repeating: 0, count: 32), receiverIdentity: identity))
        let senderProof = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key,
            receiverProof: false, senderNonce: senderNonce, receiverIdentity: identity))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(senderProof, nonce: nonce, pairingCode: key,
            senderNonce: senderNonce, receiverIdentity: identity))
    }

    func testIdentityAwareCommandWaitsForFreshMutualAck() throws {
        let digest = try XCTUnwrap(TBMonitorProtocol.receiverIdentityDigest(nonce: nonce, pairingCode: key, identity: identity))
        let challenge = TBMonitorSettingsChallenge(schemaVersion: 1, supportedSchemaVersion: 2,
            nonce: nonce.map { String(format: "%02x", $0) }.joined(), requiresSessionAuthentication: true,
            receiverID: identity, identityProof: digest.map { String(format: "%02x", $0) }.joined())
        let command = Data([1, 2, 3])
        var handshake = try XCTUnwrap(TBReceiverCommandHandshake(pairingCode: key, command: command, expectedIdentity: identity))
        var output = try handshake.consume(type: .settingsChallenge, payload: JSONEncoder().encode(challenge))
        let (type, proof) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &output))
        XCTAssertEqual(type, .sessionAuth)
        XCTAssertEqual(proof.count, 64)
        let fresh = Data(proof.prefix(32))
        XCTAssertEqual(Data(proof.suffix(32)), TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce,
            pairingCode: key, receiverProof: false, senderNonce: fresh, receiverIdentity: identity))
        let oldAck = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: true))
        XCTAssertThrowsError(try handshake.consume(type: .sessionAuthAck, payload: oldAck))
        XCTAssertFalse(handshake.authenticated)
        let ack = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key,
            receiverProof: true, senderNonce: fresh, receiverIdentity: identity))
        XCTAssertEqual(try handshake.consume(type: .sessionAuthAck, payload: ack), command)
        XCTAssertTrue(handshake.authenticated)
    }

    func testKnownIdentityCannotDowngradeToLegacyChallenge() throws {
        let legacy = TBMonitorSettingsChallenge(schemaVersion: 1, nonce: "unused")
        XCTAssertNil(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: legacy, nonce: nonce, pairingCode: key, expectedIdentity: nil))
        XCTAssertThrowsError(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: legacy, nonce: nonce, pairingCode: key, expectedIdentity: identity))
    }

    func testPairingImportValidationAndNormalization() throws {
        let json = Data("{\"schemaVersion\":1,\"receiverID\":\"\(identity)\",\"host\":\"iMac.local\",\"pairingCode\":\"\(key)\"}".utf8)
        XCTAssertEqual(try TBReceiverPairingDocument.decode(json).receiverID, identity)
        XCTAssertEqual(TBReceiverPairingCredential.normalizedIdentity(identity.uppercased()), identity)
        XCTAssertNil(TBReceiverPairingCredential.normalizedIdentity("../../identity"))
        for invalid in [Data(repeating: 32, count: 4097), Data("{}".utf8), Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: "iMac.local", with: "http://iMac.local").utf8), Data(String(decoding: json, as: UTF8.self).replacingOccurrences(of: key, with: "123456").utf8)] {
            XCTAssertThrowsError(try TBReceiverPairingDocument.decode(invalid))
        }
    }

    func testDiscoveryIdentitySurvivesAddressChangeWithoutGrantingTrust() {
        var a = TBDiscoveredReceiver(serviceName: "iMac", receiverName: "iMac", preferredIP: "192.168.1.2", thunderboltIP: "", networkIP: "", panelSummary: "", version: "", supportsHEVCDecode: false, hostName: nil)
        a.receiverID = identity
        let b = TBDiscoveredReceiver(serviceName: "iMac", receiverName: "iMac", preferredIP: "192.168.1.3", thunderboltIP: "", networkIP: "", panelSummary: "", version: "", supportsHEVCDecode: false, hostName: nil, receiverID: identity)
        XCTAssertEqual(a.id, b.id)
        // Identity hints alone cannot verify the receiver's proof.
        let forged = TBMonitorSettingsChallenge(schemaVersion: 1, nonce: "unused", receiverID: identity, identityProof: String(repeating: "0", count: 64))
        XCTAssertThrowsError(try TBMonitorProtocol.verifiedReceiverIdentity(challenge: forged, nonce: nonce, pairingCode: key, expectedIdentity: identity))
    }
}
