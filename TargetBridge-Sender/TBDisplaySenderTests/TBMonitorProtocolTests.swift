import XCTest
@testable import TargetBridge

final class TBStorageVolumeMonitorStartupTests: XCTestCase {
    @MainActor
    private final class StartupOwner {
        static let shared = StartupOwner()
        private(set) var resolvedHosts: [String] = []
        private lazy var monitor = TBStorageVolumeMonitor(localIPForReceiver: { [weak self] host in
            self?.resolvedHosts.append(host)
            // Loopback is never a wired route, so this test opens no connection.
            return "127.0.0.1"
        })

        private init() {
            // Match startup with a persisted storage host while shared is initializing.
            monitor.configure(host: "192.0.2.1", pairingCode: nil)
        }

        var status: TBStorageMonitorStatus { monitor.status }
    }

    @MainActor
    func testStorageMonitorCanConnectDuringOwnerSingletonInitialization() async {
        let owner = StartupOwner.shared
        XCTAssertEqual(owner.resolvedHosts, ["192.0.2.1"])
        XCTAssertEqual(owner.status, .unavailable)
    }

    @MainActor
    func testEmptyHostDoesNotResolveOrConnect() async {
        var resolvedHosts: [String] = []
        let monitor = TBStorageVolumeMonitor(localIPForReceiver: { host in
            resolvedHosts.append(host)
            return "127.0.0.1"
        })
        monitor.configure(host: " \n ", pairingCode: nil)
        XCTAssertTrue(resolvedHosts.isEmpty)
        XCTAssertEqual(monitor.status, .needsHost)
        XCTAssertTrue(monitor.volumes.isEmpty)
    }
}

/// Wire-protocol unit tests. These run with no network, no Thunderbolt hardware,
/// and no receiver — they pin down the framing invariants both apps rely on:
/// `[4B BE length][1B type][payload]` where length counts type + payload.
final class TBMonitorProtocolTests: XCTestCase {

    func testDisplayPowerCommandsAndAcknowledgementValidation() throws {
        for on in [false, true] {
            var bytes = TBMonitorDisplayPower.command(displayOn: on, requestID: 0x0102030405060708)
            let (type, payload) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &bytes))
            XCTAssertEqual(type, .displayPower)
            XCTAssertEqual(payload, Data([on ? 1 : 0, 1, 2, 3, 4, 5, 6, 7, 8]))
            XCTAssertTrue(bytes.isEmpty)
            for accepted in [false, true] {
                let ack = try XCTUnwrap(TBMonitorDisplayPower.acknowledgement(Data([on ? 1 : 0, accepted ? 1 : 0, 1, 2, 3, 4, 5, 6, 7, 8])))
                XCTAssertEqual(ack.displayOn, on)
                XCTAssertEqual(ack.accepted, accepted)
                XCTAssertEqual(ack.requestID, 0x0102030405060708)
            }
        }
        for bytes: [UInt8] in [[], [0], [2, 1], [1, 2], [0, 1, 0], Array(repeating: 0, count: 10), [2, 1, 1, 2, 3, 4, 5, 6, 7, 8], [1, 2, 1, 2, 3, 4, 5, 6, 7, 8]] {
            XCTAssertNil(TBMonitorDisplayPower.acknowledgement(Data(bytes)))
        }
    }

    func testDisplayPowerCapabilityDefaultsToUnsupportedForOlderReceiver() throws {
        let json = Data("{\"receiverName\":\"iMac\",\"panelWidth\":5120,\"panelHeight\":2880,\"modeWidth\":2560,\"modeHeight\":1440,\"refreshRate\":60,\"hiDPI\":true,\"captureWidth\":2560,\"captureHeight\":1440}".utf8)
        let profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: json)
        XCTAssertNil(profile.supportsDisplayPower)
        XCTAssertNil(profile.supportsSenderPower)
        XCTAssertTrue(profile.isValid)
    }

    func testSenderSleepPacketsHaveSeparateTypesAndCorrelatedAcknowledgements() throws {
        for awake in [false, true] {
            var command = TBMonitorDisplayPower.command(displayOn: awake, requestID: 0x0102030405060708, senderState: true)
            let (type, payload) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &command))
            XCTAssertEqual(type, .senderPower)
            XCTAssertEqual(payload, Data([awake ? 1 : 0, 1, 2, 3, 4, 5, 6, 7, 8]))
            var reply = TBMonitorProtocol.makePacket(type: .senderPowerAck,
                payload: Data([awake ? 1 : 0, 1]) + payload.dropFirst())
            let (replyType, replyPayload) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &reply))
            XCTAssertEqual(replyType, .senderPowerAck)
            let ack = try XCTUnwrap(TBMonitorDisplayPower.acknowledgement(replyPayload))
            XCTAssertEqual(ack.requestID, 0x0102030405060708)
            XCTAssertEqual(ack.displayOn, awake)
            XCTAssertTrue(ack.accepted)
        }
    }

    func testPairingAccountsAreScopedAndHostNormalizationIsStable() {
        XCTAssertEqual(TBReceiverPairingCredential.account(forReceiver: " iMac.LOCAL.\n"),
                       TBReceiverPairingCredential.account(forReceiver: "imac.local"))
        XCTAssertNotEqual(TBReceiverPairingCredential.account(forReceiver: "192.168.1.2"),
                          TBReceiverPairingCredential.account(forReceiver: "192.168.1.3"))
        for host in ["", ".", "../key", "smb://imac.local", "host name", "host\nname", String(repeating: "x", count: 254)] {
            XCTAssertNil(TBReceiverPairingCredential.account(forReceiver: host), host)
        }
        XCTAssertEqual(TBReceiverPairingCredential.normalizedCode(" \(String(repeating: "A", count: 64))\n"),
                       String(repeating: "a", count: 64))
        XCTAssertNil(TBReceiverPairingCredential.normalizedCode(String(repeating: "g", count: 64)))
    }

    func testOfflineCommandRequiresMutualProofBeforeLanguagePacket() throws {
        let key = String(repeating: "a", count: 64)
        let nonce = Data(0..<32)
        let language = try XCTUnwrap(TBMonitorProtocol.makeJSONPacket(type: .uiLanguage,
            value: TBMonitorUILanguageUpdate(uiLanguage: "zh")))
        var handshake = try XCTUnwrap(TBReceiverCommandHandshake(pairingCode: key, command: language))
        let challenge = Data("{\"schemaVersion\":1,\"supportedSchemaVersion\":2,\"requiresSessionAuthentication\":true,\"nonce\":\"\(nonce.map { String(format: "%02x", $0) }.joined())\"}".utf8)
        var outbound = try handshake.consume(type: .settingsChallenge, payload: challenge)
        let (type, proof) = try XCTUnwrap(TBMonitorProtocol.drainPacket(from: &outbound))
        XCTAssertEqual(type, .sessionAuth)
        XCTAssertEqual(proof, TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: false))
        XCTAssertFalse(handshake.authenticated)
        let response = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: true))
        XCTAssertEqual(try handshake.consume(type: .sessionAuthAck, payload: response), language)
        XCTAssertTrue(handshake.authenticated)
        XCTAssertThrowsError(try handshake.consume(type: .sessionAuthAck, payload: response))
    }

    func testOfflineCommandRejectsLegacyChallengeAndUnsolicitedPackets() throws {
        let command = TBMonitorProtocol.makePacket(type: .uiLanguage, payload: Data())
        for type in [TBMonitorPacketType.displayProfile, .inputEvent, .sessionAuthAck] {
            var handshake = try XCTUnwrap(TBReceiverCommandHandshake(pairingCode: String(repeating: "a", count: 64), command: command))
            XCTAssertThrowsError(try handshake.consume(type: type, payload: Data()))
        }
        var handshake = try XCTUnwrap(TBReceiverCommandHandshake(pairingCode: String(repeating: "a", count: 64), command: command))
        let legacy = Data("{\"schemaVersion\":1,\"nonce\":\"\(String(repeating: "0", count: 64))\"}".utf8)
        XCTAssertThrowsError(try handshake.consume(type: .settingsChallenge, payload: legacy))
    }

    func testOfflineCommandRejectsReflectedWrongAndReplayProofs() throws {
        let key = String(repeating: "a", count: 64)
        let nonce = Data(repeating: 0, count: 32)
        let challenge = Data("{\"schemaVersion\":1,\"requiresSessionAuthentication\":true,\"nonce\":\"\(String(repeating: "0", count: 64))\"}".utf8)
        let reflected = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: false))
        let wrong = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: String(repeating: "b", count: 64), receiverProof: true))
        let replay = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: Data(repeating: 1, count: 32), pairingCode: key, receiverProof: true))
        for proof in [reflected, wrong, replay, Data()] {
            var handshake = try XCTUnwrap(TBReceiverCommandHandshake(pairingCode: key, command: Data([1])))
            _ = try handshake.consume(type: .settingsChallenge, payload: challenge)
            XCTAssertThrowsError(try handshake.consume(type: .sessionAuthAck, payload: proof))
            XCTAssertFalse(handshake.authenticated)
        }
    }

    func testDisplayProfileRejectsUnsafePeerDimensions() {
        var profile = TBMonitorDisplayProfile(
            receiverName: "Test", panelWidth: 5120, panelHeight: 2880,
            modeWidth: 2560, modeHeight: 1440, refreshRate: 60, hiDPI: true,
            captureWidth: 2560, captureHeight: 1440
        )
        XCTAssertTrue(profile.isValid)
        for width in [-1, 0, Int.max] {
            profile.panelWidth = width
            XCTAssertFalse(profile.isValid)
        }
        profile.panelWidth = 5120
        profile.modeWidth = 5120
        XCTAssertFalse(profile.isValid)
        profile.hiDPI = false
        XCTAssertTrue(profile.isValid)
        for rate in [Double.nan, .infinity, 0, -1, 1000] {
            profile.refreshRate = rate
            XCTAssertFalse(profile.isValid)
        }
    }

    func testSessionAuthenticationMatchesReceiverVectorsAndRejectsReplay() throws {
        let nonce = Data(0..<32)
        let key = String(repeating: "a", count: 64)
        let sender = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: false))
        let receiver = try XCTUnwrap(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: key, receiverProof: true))
        XCTAssertEqual(sender.map { String(format: "%02x", $0) }.joined(), "a2e616e50866f35a1d6db603c4cb655438ce91993e801e914fc07b5e008c28b7")
        XCTAssertEqual(receiver.map { String(format: "%02x", $0) }.joined(), "6ec57636a59c68c6f917e0f1bc7199c99d23d3d95934b66e405a9112c05a2985")
        XCTAssertTrue(TBMonitorProtocol.verifySessionAuthenticationResponse(receiver, nonce: nonce, pairingCode: key))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(sender, nonce: nonce, pairingCode: key))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(receiver, nonce: Data(repeating: 1, count: 32), pairingCode: key))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(receiver, nonce: nonce, pairingCode: String(repeating: "b", count: 64)))
        XCTAssertFalse(TBMonitorProtocol.verifySessionAuthenticationResponse(receiver.dropLast(), nonce: nonce, pairingCode: key))
        XCTAssertNil(TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: "bad", receiverProof: false))
    }

    func testAddonIDsCannotEscapeTheImportDirectory() {
        for id in ["", ".", "..", "../settings", "a/b", "a\\b", "a\n", String(repeating: "x", count: 129)] {
            XCTAssertFalse(TBAddonManifest.isSafeID(id), id)
        }
        for id in ["com.targetbridge.input", "addon-1", "custom_addon"] {
            XCTAssertTrue(TBAddonManifest.isSafeID(id), id)
        }
    }

    // MARK: - BE32 primitives

    func testBE32RoundTrip() {
        let values: [UInt32] = [0, 1, 0xFF, 0x1234_5678, 0x7FFF_FFFF, 0xFFFF_FFFF]
        for value in values {
            var data = Data()
            TBMonitorProtocol.appendBE32(&data, value)
            XCTAssertEqual(data.count, 4)
            XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 0), value, "round trip failed for \(value)")
        }
    }

    func testAppendBE32IsBigEndian() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0x0102_0304)
        XCTAssertEqual([UInt8](data), [0x01, 0x02, 0x03, 0x04])
    }

    func testVersionOneSettingsAuthenticationMessageHasCanonicalLayout() throws {
        let nonce = Data(0..<32)
        let message = try XCTUnwrap(TBMonitorProtocol.settingsAuthenticationMessage(
            nonce: nonce,
            schemaVersion: 1,
            revision: 0x0102_0304_0506_0708,
            brightness: 0.5,
            volume: 1.0,
            language: "zh"
        ))

        XCTAssertEqual(message.count, 56)
        XCTAssertEqual(Array(message.prefix(32)), Array(0..<32))
        XCTAssertEqual(Array(message[32..<48]), [0, 0, 0, 1, 1, 2, 3, 4, 5, 6, 7, 8, 1, 244, 3, 232])
        XCTAssertEqual(Array(message[48..<56]), [122, 104, 0, 0, 0, 0, 0, 0])
    }

    func testVersionTwoSettingsAuthenticationAddsSleepTimeout() throws {
        let message = try XCTUnwrap(TBMonitorProtocol.settingsAuthenticationMessage(
            nonce: Data(repeating: 0x11, count: 32),
            schemaVersion: 2,
            revision: 9,
            brightness: 1,
            volume: 0,
            language: "en",
            sleepAfterNoSignalSeconds: 300
        ))
        XCTAssertEqual(message.count, 60)
        XCTAssertEqual(Array(message.suffix(4)), [0, 0, 1, 44])
        XCTAssertNil(TBMonitorProtocol.settingsAuthenticationMessage(
            nonce: Data(repeating: 0x11, count: 32),
            schemaVersion: 2,
            revision: 9,
            brightness: 1,
            volume: 0,
            language: "en",
            sleepAfterNoSignalSeconds: 14
        ))
    }

    func testLegacySettingsChallengeStillDecodes() throws {
        let nonce = String(repeating: "0", count: 64)
        let payload = Data("{\"schemaVersion\":1,\"nonce\":\"\(nonce)\"}".utf8)
        let challenge = try XCTUnwrap(TBMonitorProtocol.decodeJSON(TBMonitorSettingsChallenge.self, from: payload))
        XCTAssertEqual(challenge.schemaVersion, 1)
        XCTAssertNil(challenge.supportedSchemaVersion)
    }

    func testChallengeNegotiatesSchemaTwoWithoutBreakingBaseVersion() throws {
        let nonce = String(repeating: "a", count: 64)
        let payload = Data("{\"schemaVersion\":1,\"supportedSchemaVersion\":2,\"nonce\":\"\(nonce)\"}".utf8)
        let challenge = try XCTUnwrap(TBMonitorProtocol.decodeJSON(TBMonitorSettingsChallenge.self, from: payload))
        XCTAssertEqual(challenge.schemaVersion, 1)
        XCTAssertEqual(challenge.supportedSchemaVersion, 2)
    }

    func testRemovableVolumeSnapshotDecodesAndBuildsSafeSMBURL() throws {
        let payload = Data("""
        {"schemaVersion":1,"volumes":[{"id":"A1B2-C3D4","name":"Camera Card #1"}]}
        """.utf8)
        let snapshot = try XCTUnwrap(TBMonitorProtocol.decodeJSON(TBMonitorRemovableVolumeSnapshot.self, from: payload))
        XCTAssertTrue(TBMonitorProtocol.isValidRemovableVolumeSnapshot(snapshot))
        XCTAssertEqual(snapshot.volumes.first?.id, "A1B2-C3D4")
        let url = try XCTUnwrap(TBMonitorProtocol.removableVolumeSMBURL(
            receiverHost: "imac.local",
            shareName: snapshot.volumes[0].name
        ))
        XCTAssertEqual(url.absoluteString, "smb://imac.local/Camera%20Card%20%231")
        XCTAssertEqual(url.path, "/Camera Card #1")
    }

    func testStorageMonitorAuthenticationPacketHasSeparateDomainAndFrame() throws {
        let nonce = Data(0..<32)
        let key = String(repeating: "0123456789abcdef", count: 4)
        let packet = try XCTUnwrap(TBMonitorProtocol.makeStorageMonitorAuthPacket(
            nonce: nonce,
            pairingCode: key
        ))
        XCTAssertEqual(Array(packet.prefix(5)), [0, 0, 0, 33, TBMonitorPacketType.storageMonitorAuth.rawValue])
        XCTAssertEqual(
            packet.dropFirst(5).map { String(format: "%02x", $0) }.joined(),
            "09d4a43e6a4f88825dd53aec2216b64bc89eb81332792d4a1df12b9384633612"
        )
        XCTAssertNil(TBMonitorProtocol.makeStorageMonitorAuthPacket(
            nonce: Data(repeating: 0, count: 31),
            pairingCode: key
        ))
        XCTAssertNil(TBMonitorProtocol.makeStorageMonitorAuthPacket(
            nonce: nonce,
            pairingCode: "not-a-pairing-code"
        ))
    }

    func testRemovableVolumeSnapshotRejectsUnsupportedAndAmbiguousData() throws {
        let unsupported = try XCTUnwrap(TBMonitorProtocol.decodeJSON(
            TBMonitorRemovableVolumeSnapshot.self,
            from: Data("{\"schemaVersion\":2,\"volumes\":[]}".utf8)
        ))
        XCTAssertFalse(TBMonitorProtocol.isValidRemovableVolumeSnapshot(unsupported))

        let duplicateIDs = try XCTUnwrap(TBMonitorProtocol.decodeJSON(
            TBMonitorRemovableVolumeSnapshot.self,
            from: Data("{\"schemaVersion\":1,\"volumes\":[{\"id\":\"same\",\"name\":\"Card A\"},{\"id\":\"same\",\"name\":\"Card B\"}]}".utf8)
        ))
        XCTAssertFalse(TBMonitorProtocol.isValidRemovableVolumeSnapshot(duplicateIDs))
        XCTAssertNil(TBMonitorProtocol.removableVolumeSMBURL(receiverHost: "bad/host", shareName: "Card"))
        XCTAssertNil(TBMonitorProtocol.removableVolumeSMBURL(receiverHost: "imac.local", shareName: "../private"))
    }

    func testSettingsAuthenticationMessageRejectsUnsupportedInputs() {
        XCTAssertNil(TBMonitorProtocol.settingsAuthenticationMessage(
            nonce: Data(repeating: 0, count: 31), schemaVersion: 1,
            revision: 1, brightness: 0.5, volume: 0.5, language: "en"
        ))
        XCTAssertNil(TBMonitorProtocol.settingsAuthenticationMessage(
            nonce: Data(repeating: 0, count: 32), schemaVersion: 1,
            revision: 1, brightness: 0.5, volume: 0.5, language: "xx"
        ))
    }

    func testReadBE32HonorsOffset() {
        var data = Data()
        TBMonitorProtocol.appendBE32(&data, 0xAAAA_AAAA)
        TBMonitorProtocol.appendBE32(&data, 0x0000_BEEF)
        XCTAssertEqual(TBMonitorProtocol.readBE32(data, offset: 4), 0x0000_BEEF)
    }

    // MARK: - Packet framing

    func testMakePacketLayout() {
        let packet = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0xAA, 0xBB, 0xCC]))
        // length = 1 (type byte) + 3 (payload) = 4
        XCTAssertEqual([UInt8](packet), [0x00, 0x00, 0x00, 0x04, 0x30, 0xAA, 0xBB, 0xCC])
    }

    func testRawNV12PacketTypeAndOlderDisplayProfilesRemainCompatible() throws {
        XCTAssertEqual(TBMonitorPacketType.rawFrame.rawValue, 0x22)

        let olderProfile = Data("""
        {
          "receiverName": "Older Receiver",
          "panelWidth": 5120,
          "panelHeight": 2880,
          "modeWidth": 2560,
          "modeHeight": 1440,
          "refreshRate": 60,
          "hiDPI": true,
          "captureWidth": 5120,
          "captureHeight": 2880
        }
        """.utf8)
        let profile = try JSONDecoder().decode(TBMonitorDisplayProfile.self, from: olderProfile)
        XCTAssertNil(profile.supportsRawNV12)
    }

    func testDrainPacketRoundTrip() throws {
        let payload = Data("hello receiver".utf8)
        var buffer = TBMonitorProtocol.makePacket(type: .helloReceiver, payload: payload)

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertNotNil(drained)
        XCTAssertEqual(drained?.0, .helloReceiver)
        XCTAssertEqual(drained?.1, payload)
        XCTAssertTrue(buffer.isEmpty, "drain must consume the packet")
    }

    func testDrainPacketEmptyPayload() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .teardown, payload: Data())
        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .teardown)
        XCTAssertEqual(drained?.1, Data())
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketWaitsForCompleteHeader() {
        var buffer = Data([0x00, 0x00, 0x00, 0x04]) // header missing its 5th byte
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 4, "incomplete data must not be consumed")
    }

    func testDrainPacketWaitsForCompletePayload() {
        let full = TBMonitorProtocol.makePacket(type: .frame, payload: Data(repeating: 0x42, count: 100))
        var buffer = full.prefix(50) as Data
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 50, "incomplete data must not be consumed")
    }

    func testDrainTwoContiguousPackets() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .cursor, payload: Data([0x01]))
        buffer.append(TBMonitorProtocol.makePacket(type: .brightness, payload: Data([0x02, 0x03])))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .cursor)
        XCTAssertEqual(first?.1, Data([0x01]))

        let second = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(second?.0, .brightness)
        XCTAssertEqual(second?.1, Data([0x02, 0x03]))

        XCTAssertTrue(buffer.isEmpty)
    }

    /// Simulates TCP fragmentation: the packet arrives one byte at a time and
    /// must only drain once the final byte lands.
    func testDrainPacketAcrossSplitFeeds() throws {
        let packet = TBMonitorProtocol.makePacket(type: .clipboard, payload: Data("copy me".utf8))
        var buffer = Data()

        for (index, byte) in packet.enumerated() {
            buffer.append(byte)
            let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
            if index < packet.count - 1 {
                XCTAssertNil(drained, "must not drain before byte \(packet.count - 1), drained at \(index)")
            } else {
                XCTAssertEqual(drained?.0, .clipboard)
                XCTAssertEqual(drained?.1, Data("copy me".utf8))
            }
        }
    }

    // MARK: - Corrupt and unknown framing

    func testDrainPacketThrowsOnZeroLength() {
        var buffer = Data([0x00, 0x00, 0x00, 0x00, 0x30])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0))
        }
    }

    func testDrainPacketThrowsOnOversizedLength() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength + 1)
        buffer.append(0x21)
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(TBMonitorProtocol.maxPacketLength + 1))
        }
    }

    /// A corrupted length like 0xFFFFFFFF must fail fast instead of making the
    /// drain loop buffer inbound data forever for a packet that never completes.
    func testDrainPacketThrowsOnAllOnesLength() {
        var buffer = Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21, 0x00])
        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer)) { error in
            XCTAssertEqual(error as? TBMonitorProtocolError, .invalidPacketLength(0xFFFF_FFFF))
        }
    }

    func testDrainPacketAcceptsLengthAtCapWhileWaitingForPayload() {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, TBMonitorProtocol.maxPacketLength)
        buffer.append(0x21)
        // Length is legal but the payload has not arrived: need more data, no throw.
        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertEqual(buffer.count, 5)
    }

    func testDrainPacketThrowsOnCorruptLengthBehindValidPacket() throws {
        var buffer = TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x01]))
        buffer.append(Data([0xFF, 0xFF, 0xFF, 0xFF, 0x21]))

        let first = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(first?.0, .heartbeat)

        XCTAssertThrowsError(try TBMonitorProtocol.drainPacket(from: &buffer))
    }

    /// An unrecognized type byte (e.g. a packet from a newer peer) must be
    /// skipped so it cannot stall valid packets queued behind it.
    func testDrainPacketSkipsUnknownTypeAndReturnsNextPacket() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 3)
        buffer.append(contentsOf: [0xEE, 0x00, 0x00]) // unknown type 0xEE + 2 payload bytes
        buffer.append(TBMonitorProtocol.makePacket(type: .heartbeat, payload: Data([0x07])))

        let drained = try TBMonitorProtocol.drainPacket(from: &buffer)
        XCTAssertEqual(drained?.0, .heartbeat)
        XCTAssertEqual(drained?.1, Data([0x07]))
        XCTAssertTrue(buffer.isEmpty)
    }

    func testDrainPacketConsumesLoneUnknownType() throws {
        var buffer = Data()
        TBMonitorProtocol.appendBE32(&buffer, 1)
        buffer.append(0xEE)

        XCTAssertNil(try TBMonitorProtocol.drainPacket(from: &buffer))
        XCTAssertTrue(buffer.isEmpty, "unknown packet must be consumed, not left to stall the stream")
    }

    // MARK: - JSON payloads

    func testJSONPacketRoundTrip() throws {
        let heartbeat = TBMonitorHeartbeat(sequence: 42)
        guard var buffer = TBMonitorProtocol.makeJSONPacket(type: .heartbeat, value: heartbeat) else {
            XCTFail("encode failed"); return
        }
        guard let (type, payload) = try TBMonitorProtocol.drainPacket(from: &buffer) else {
            XCTFail("drain failed"); return
        }
        XCTAssertEqual(type, .heartbeat)
        XCTAssertEqual(TBMonitorProtocol.decodeJSON(TBMonitorHeartbeat.self, from: payload)?.sequence, 42)
    }

    // MARK: - Hand-rolled input-event encoder parity
    //
    // `makeInputEventPacket` documents this invariant: "emits the same JSON shape
    // `JSONDecoder` reconstructs into a `TBMonitorInputEvent` (omitted fields
    // decode as nil)". These tests guard it, since the receiver's snprintf-based
    // emitter mirrors the same shape.

    private func makeEvent(
        kind: String,
        dx: Int? = nil,
        dy: Int? = nil,
        scrollX: Int? = nil,
        scrollY: Int? = nil,
        keyCode: UInt16? = nil
    ) -> TBMonitorInputEvent {
        TBMonitorInputEvent(kind: kind, dx: dx, dy: dy, scrollX: scrollX, scrollY: scrollY, keyCode: keyCode)
    }

    private func assertEncoderParity(
        _ event: TBMonitorInputEvent,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var buffer = TBMonitorProtocol.makeInputEventPacket(event)
        guard let (type, payload) = try? TBMonitorProtocol.drainPacket(from: &buffer) ?? nil else {
            XCTFail("packet did not drain", file: file, line: line)
            return
        }
        XCTAssertEqual(type, .inputEvent, file: file, line: line)
        guard let decoded = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) else {
            XCTFail("payload did not decode as TBMonitorInputEvent: \(String(decoding: payload, as: UTF8.self))",
                    file: file, line: line)
            return
        }
        XCTAssertEqual(decoded.kind, event.kind, file: file, line: line)
        XCTAssertEqual(decoded.dx, event.dx, file: file, line: line)
        XCTAssertEqual(decoded.dy, event.dy, file: file, line: line)
        XCTAssertEqual(decoded.scrollX, event.scrollX, file: file, line: line)
        XCTAssertEqual(decoded.scrollY, event.scrollY, file: file, line: line)
        XCTAssertEqual(decoded.keyCode, event.keyCode, file: file, line: line)
    }

    func testInputEventEncoderParityMouseMove() {
        assertEncoderParity(makeEvent(kind: "move", dx: 5, dy: -3))
    }

    func testInputEventEncoderParityScroll() {
        assertEncoderParity(makeEvent(kind: "scroll", scrollX: -120, scrollY: 42))
    }

    func testInputEventEncoderParityKeyDown() {
        assertEncoderParity(makeEvent(kind: "keyDown", keyCode: 0x24))
    }

    func testInputEventEncoderParityAllFields() {
        assertEncoderParity(makeEvent(kind: "drag", dx: 1, dy: 2, scrollX: 3, scrollY: 4, keyCode: UInt16.max))
    }

    func testInputEventEncoderParityNoOptionalFields() {
        assertEncoderParity(makeEvent(kind: "leftUp"))
    }

    func testInputEventEncoderParityExtremeValues() {
        assertEncoderParity(makeEvent(kind: "move", dx: Int.min, dy: Int.max))
    }
    func testBrightnessReadbackCannotTurnInvalidValuesIntoSuccess() throws {
        let valid = Data(#"{"supported":true,"actualLevel":0.4,"requestedLevel":0.5,"accepted":true,"reason":""}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(TBMonitorBrightnessState.self, from: valid).isValid)
        for json in [#"{"supported":true,"accepted":true,"reason":""}"#,
                     #"{"supported":false,"actualLevel":0.4,"accepted":true,"reason":""}"#,
                     #"{"supported":true,"actualLevel":1.1,"reason":""}"#] {
            XCTAssertFalse(try JSONDecoder().decode(TBMonitorBrightnessState.self, from: Data(json.utf8)).isValid)
        }
    }

    func testReceiverMetricsDescribeObservedOutputAndBoundAudioBytes() throws {
        let raw = Data(#"{"hardwareDecode":-1,"raw":true,"received":12,"uploaded":10,"submitted":4,"sinceSubmitMs":20,"audioBytes":28800,"decodeErrors":0}"#.utf8)
        XCTAssertTrue(try JSONDecoder().decode(TBMonitorReceiverMetrics.self, from: raw).isValid)
        let invalid = Data(#"{"hardwareDecode":2,"raw":false,"received":0,"uploaded":0,"submitted":0,"sinceSubmitMs":0,"audioBytes":28801,"decodeErrors":0}"#.utf8)
        XCTAssertFalse(try JSONDecoder().decode(TBMonitorReceiverMetrics.self, from: invalid).isValid)
    }

    func testNewSenderMarksSettingsSyncAsBrightnessSaveOnly() throws {
        let hello = TBMonitorHelloReceiver(senderName: "Mac", uiLanguage: "en", capturePreset: nil,
            captureSource: nil, captureWidth: nil, captureHeight: nil, codec: nil)
        let data = try JSONEncoder().encode(hello)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fields["brightnessCommandsOnly"] as? Bool, true)
    }

}
