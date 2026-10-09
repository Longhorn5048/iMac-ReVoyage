import XCTest
@testable import TargetBridge

final class TBMediaProtocolTests: XCTestCase {
    private let key = String(repeating: "0", count: 64)
    private let receiverNonce = Data(0..<32)
    private let senderNonce = Data(32..<64)
    private func hex(_ value: String) -> Data {
        var data = Data(); var index = value.startIndex
        while index < value.endIndex { let end = value.index(index, offsetBy: 2); data.append(UInt8(value[index..<end], radix:16)!); index=end }
        return data
    }
    private func sequenced(_ sequence: UInt64, bytes: Int) -> Data {
        var value = sequence.bigEndian; return Data(bytes:&value,count:8) + Data(repeating:0,count:bytes)
    }
    func testCrossLanguageSenderProofVector() throws {
        XCTAssertEqual(try TBMediaProtocol.authentication(receiverNonce: receiverNonce, senderNonce: senderNonce,key:key),
                       senderNonce + hex("951c94430204d7f442571ae2ebd0b152090b18b145ac63c14dfac9aa9da5f359"))
    }
    func testCrossLanguageReceiverProofVector() {
        XCTAssertTrue(TBMediaProtocol.verifyReceiver(hex("3516319ac020b8f83f1f9e2ce4379b57a902b92c17f9d73511fef4356422e240"),
            receiverNonce:receiverNonce,senderNonce:senderNonce,key:key))
    }
    func testReflectionAndNewSenderNonceCannotAuthenticateReceiver() throws {
        let senderProof = try TBMediaProtocol.authentication(receiverNonce:receiverNonce,senderNonce:senderNonce,key:key).suffix(32)
        XCTAssertFalse(TBMediaProtocol.verifyReceiver(senderProof,receiverNonce:receiverNonce,senderNonce:senderNonce,key:key))
        XCTAssertFalse(TBMediaProtocol.verifyReceiver(hex("3516319ac020b8f83f1f9e2ce4379b57a902b92c17f9d73511fef4356422e240"),
            receiverNonce:receiverNonce,senderNonce:Data(repeating:7,count:32),key:key))
    }
    func testAuthenticationRejectsInvalidKeyOrNonce() {
        XCTAssertThrowsError(try TBMediaHandshake(key:"invalid"))
        XCTAssertThrowsError(try TBMediaHandshake(key:key,senderNonce:Data(count:31)))
        XCTAssertThrowsError(try TBMediaProtocol.authentication(receiverNonce:Data(count:31),senderNonce:senderNonce,key:key))
    }
    func testHandshakeRejectsAllDataBeforeProof() throws {
        for type in [TBMediaPacket.registry,.status,.jpeg,.pcm,.heartbeat,.request] {
            var handshake=try TBMediaHandshake(key:key,senderNonce:senderNonce)
            XCTAssertThrowsError(try handshake.receive(type,Data()))
            _=try handshake.receive(.challenge,receiverNonce)
            XCTAssertThrowsError(try handshake.receive(type,Data()))
            XCTAssertFalse(handshake.authenticated)
        }
    }
    func testHandshakeRejectsRepeatedChallengeAndWrongProof() throws {
        var handshake=try TBMediaHandshake(key:key,senderNonce:senderNonce)
        _=try handshake.receive(.challenge,receiverNonce)
        XCTAssertThrowsError(try handshake.receive(.challenge,receiverNonce))
        XCTAssertThrowsError(try handshake.receive(.proof,Data(count:32)))
        XCTAssertFalse(handshake.authenticated)
    }
    func testHandshakeCompletesOnlyWithReceiverProof() throws {
        var handshake=try TBMediaHandshake(key:key,senderNonce:senderNonce)
        XCTAssertNotNil(try handshake.receive(.challenge,receiverNonce))
        XCTAssertNil(try handshake.receive(.proof,hex("3516319ac020b8f83f1f9e2ce4379b57a902b92c17f9d73511fef4356422e240")))
        XCTAssertTrue(handshake.authenticated)
        XCTAssertThrowsError(try handshake.receive(.proof,Data(count:32)))
    }
    func testFramingHandlesEverySplitAndCoalescedPackets() throws {
        let payload=Data(0..<32), packet=TBMediaProtocol.packet(.challenge,Data(0..<32))
        for split in 0..<packet.count {
            var buffer=Data(packet.prefix(split));XCTAssertNil(try TBMediaProtocol.drain(&buffer))
            buffer.append(packet.dropFirst(split));buffer.append(TBMediaProtocol.packet(.heartbeat))
            let first=try XCTUnwrap(TBMediaProtocol.drain(&buffer));XCTAssertEqual(first.0,.challenge);XCTAssertEqual(first.1,payload)
            XCTAssertEqual(try TBMediaProtocol.drain(&buffer)?.0,.heartbeat);XCTAssertTrue(buffer.isEmpty)
        }
    }
    func testFramingRejectsOversizedZeroAndUnknownPackets() {
        for bytes in [[UInt8](repeating:0,count:4),[255,255,255,255],[0,0,0,1,0x40]] {
            var data=Data(bytes);XCTAssertThrowsError(try TBMediaProtocol.drain(&data))
        }
        var buffer=Data(count:TBMediaProtocol.maxPacket+4+65_537)
        XCTAssertThrowsError(try TBMediaProtocol.drain(&buffer))
    }
    func testRegistryRejectsDuplicateDevicesControlCharactersAndInvalidPermissions() {
        let device=TBMediaDevice(id:"a",name:"FaceTime",kind:"camera")
        func registry(_ devices:[TBMediaDevice],_ permission:String="authorized")->TBMediaRegistry {
            TBMediaRegistry(schema:1,devices:devices,cameraPermission:permission,microphonePermission:"denied")
        }
        XCTAssertTrue(registry([device]).isValid)
        XCTAssertFalse(registry([device,device]).isValid)
        XCTAssertFalse(registry([TBMediaDevice(id:"a\n",name:"FaceTime",kind:"camera")]).isValid)
        XCTAssertFalse(registry([device],"trusted").isValid)
        XCTAssertFalse(registry([TBMediaDevice(id:"a",name:"FaceTime",kind:"speaker")]).isValid)
    }
    func testPCMContinuityOverflowAndReset() throws {
        var gate=TBMediaSequenceGate();try gate.acceptPCM(sequenced(0,bytes:960));try gate.acceptPCM(sequenced(480,bytes:960))
        XCTAssertThrowsError(try gate.acceptPCM(sequenced(480,bytes:960)))
        gate.reset();try gate.acceptPCM(sequenced(0,bytes:960))
        XCTAssertThrowsError(try gate.acceptPCM(sequenced(UInt64.max,bytes:2)))
        XCTAssertThrowsError(try gate.acceptPCM(sequenced(480,bytes:1)))
        XCTAssertThrowsError(try gate.acceptPCM(sequenced(480,bytes:1922)))
    }
    func testJPEGMaySkipButNeverReplayAndResetsAtCommandACK() throws {
        var gate=TBMediaSequenceGate();try gate.acceptJPEG(sequenced(2,bytes:100));try gate.acceptJPEG(sequenced(8,bytes:100))
        XCTAssertThrowsError(try gate.acceptJPEG(sequenced(8,bytes:100)))
        gate.reset();try gate.acceptJPEG(sequenced(0,bytes:100))
    }
    func testMicrophoneReconfigurationIgnoresOldSamplesUntilACK() throws {
        var gate = TBMediaSequenceGate()
        XCTAssertTrue(try gate.acceptPCM(sequenced(9600, bytes: 960)))
        gate.beginConfiguration() // Camera enabled while microphone remains on.
        XCTAssertFalse(try gate.acceptPCM(sequenced(10080, bytes: 960)))
        XCTAssertFalse(try gate.acceptJPEG(sequenced(42, bytes: 100)))
        XCTAssertFalse(try gate.acceptPCM(sequenced(0, bytes: 960)))
        XCTAssertTrue(gate.awaitingConfiguration) // permission_pending is not an ACK.
        gate.reset() // Final status ACK establishes the new sequence domain.
        XCTAssertTrue(try gate.acceptPCM(sequenced(0, bytes: 960)))
        XCTAssertTrue(try gate.acceptPCM(sequenced(480, bytes: 960)))
        XCTAssertTrue(try gate.acceptJPEG(sequenced(0, bytes: 100)))
        gate.beginConfiguration() // Camera disabled again, microphone stays on.
        XCTAssertFalse(try gate.acceptPCM(sequenced(960, bytes: 960)))
        gate.reset()
        XCTAssertTrue(try gate.acceptPCM(sequenced(0, bytes: 960)))
        XCTAssertThrowsError(try gate.acceptPCM(sequenced(0, bytes: 960)))
    }
    func testStatusRejectsUnknownErrorsAndActiveFailure() {
        XCTAssertTrue(TBMediaStatus(schema:1,cameraActive:false,microphoneActive:false,error:"permission_pending").isValid)
        XCTAssertFalse(TBMediaStatus(schema:1,cameraActive:true,microphoneActive:false,error:"permission_denied").isValid)
        XCTAssertFalse(TBMediaStatus(schema:2,cameraActive:false,microphoneActive:false,error:"").isValid)
    }
}
