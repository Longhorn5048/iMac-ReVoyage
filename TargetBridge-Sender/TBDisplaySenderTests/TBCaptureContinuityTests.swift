import XCTest
import ScreenCaptureKit
import CoreAudio
@testable import TargetBridge

final class TBCaptureContinuityTests: XCTestCase {
    func testSpeakerPCMPropertyListRoundTripAndInvalidPayloads() throws {
        let bytes = Data((0..<1920).map { UInt8($0 % 256) })
        let encoded = try PropertyListSerialization.data(fromPropertyList: bytes, format: .binary, options: 0)
        let received = try PropertyListSerialization.propertyList(from: encoded, options: [], format: nil)
        let pointerSize = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        XCTAssertEqual(TBiMacSpeakerPCMTransport.decode(received as CFPropertyList, pointerSize: pointerSize), bytes)
        XCTAssertEqual(TBiMacSpeakerPCMTransport.decode(Data() as CFData, pointerSize: pointerSize), Data())
        XCTAssertNil(TBiMacSpeakerPCMTransport.decode(nil, pointerSize: pointerSize))
        XCTAssertNil(TBiMacSpeakerPCMTransport.decode("not PCM" as CFString, pointerSize: pointerSize))
        XCTAssertNil(TBiMacSpeakerPCMTransport.decode(bytes as CFData, pointerSize: 1920))
        XCTAssertNil(TBiMacSpeakerPCMTransport.decode(Data(repeating: 0, count: 1924) as CFData, pointerSize: pointerSize))
        XCTAssertNil(TBiMacSpeakerPCMTransport.decode(Data(repeating: 0, count: 3) as CFData, pointerSize: pointerSize))
        XCTAssertNotEqual(TBiMacSpeakerPCMTransport.pull, 0x72767370, "Legacy rvsp bytes must never be interpreted as a CF object")
    }

    func testWakeRecoveryReplacesStaleTransportAndStalledCapture() {
        XCTAssertFalse(TBSenderWakeRecovery.shouldReconnect(elapsed: 7.9, requiresPowerAck: true, powerConfirmed: false, captureReady: true))
        XCTAssertTrue(TBSenderWakeRecovery.shouldReconnect(elapsed: 8, requiresPowerAck: true, powerConfirmed: false, captureReady: true))
        XCTAssertFalse(TBSenderWakeRecovery.shouldReconnect(elapsed: 8, requiresPowerAck: true, powerConfirmed: true, captureReady: false))
        XCTAssertTrue(TBSenderWakeRecovery.shouldReconnect(elapsed: 12, requiresPowerAck: true, powerConfirmed: true, captureReady: false))
        XCTAssertFalse(TBSenderWakeRecovery.shouldReconnect(elapsed: 60, requiresPowerAck: false, powerConfirmed: false, captureReady: true))
        XCTAssertTrue(TBSenderWakeRecovery.shouldReconnect(elapsed: 12, requiresPowerAck: false, powerConfirmed: false, captureReady: false))
    }

    func testOnlyExplicitIMacOutputSelectionAllowsRemotePlayback() {
        XCTAssertTrue(TBAudioOutputRoute(deviceUID: TBAudioOutputRoute.speakerUID).allowsReceiverAudio)
        for uid in ["BuiltInSpeakerDevice", "BuiltInHeadphoneDevice", "USB-output", "Bluetooth-output", "HDMI-output", "AirPlay", "MultiOutputDevice"] {
            XCTAssertFalse(TBAudioOutputRoute(deviceUID: uid).allowsReceiverAudio)
        }
        XCTAssertFalse(TBAudioOutputRoute(deviceUID: nil).allowsReceiverAudio)
        XCTAssertFalse(TBAudioOutputRoute(deviceUID: "re.voyage.imac.speaker.spoof").allowsReceiverAudio)
    }

    func testOutputSwitchCannotBeUndoneByCongestionRecoveryOrSendPendingAudio() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 1) else { return XCTFail("initial audio") }
        XCTAssertTrue(gate.failOnce(now: 1.1))
        gate.setEnabled(false) // headphones selected while an older write is draining
        gate.release(token)
        XCTAssertFalse(gate.recoverWhenDrained(now: 2))
        if case .closed = gate.reserve(bytes: 1920, now: 2) {} else { XCTFail("external route must remain silent") }
        gate.setEnabled(true) // iMac speaker selected again
        guard case .accepted(let next) = gate.reserve(bytes: 1920, now: 3) else { return XCTFail("resume remote audio") }
        gate.release(next)
    }

    func testSystemSleepRetainsRecoveryIntentUntilCaptureResumes() {
        var state = TBSenderSleepState()
        state.sleep(system: true, activeSession: true)
        XCTAssertTrue(state.isSleeping)
        XCTAssertTrue(state.needsResume)
        XCTAssertTrue(state.wake(system: true))
        XCTAssertFalse(state.isSleeping)
        XCTAssertTrue(state.needsResume, "A lost TCP connection must not discard the session to resume")
        XCTAssertFalse(state.wake(system: true), "Repeated wake must not restart capture twice")
        state.resumed()
        XCTAssertFalse(state.needsResume)
    }

    func testScreenAndSystemSleepOverlapAndUserStopCancelsRecovery() {
        var state = TBSenderSleepState()
        state.sleep(system: false, activeSession: true)
        state.sleep(system: true, activeSession: false)
        XCTAssertFalse(state.wake(system: false), "A screen notification cannot resume a sleeping system")
        XCTAssertTrue(state.isSleeping)
        state.cancelResume()
        XCTAssertTrue(state.wake(system: true))
        XCTAssertFalse(state.needsResume, "Explicit Stop while asleep must stay stopped")
    }

    func testInactiveSleepDoesNotCreateAnAutomaticConnection() {
        var state = TBSenderSleepState()
        state.sleep(system: false, activeSession: false)
        XCTAssertTrue(state.wake(system: false))
        XCTAssertFalse(state.needsResume)
    }

    func testStaticDesktopIdleEventsRefreshBeforeReceiverVideoTimeoutForThirtySeconds() {
        var refresh = TBIdleFrameRefresh<Int>()
        refresh.capture(101, now: 0)
        XCTAssertNil(refresh.idle(now: 0.1))
        var lastPresentedAt = 0.0
        var refreshes = 0
        for tick in 1...1800 {
            let now = Double(tick) / 60
            if let image = refresh.refresh(now: now) {
                XCTAssertEqual(image, 101)
                XCTAssertLessThan(now - lastPresentedAt, 2, "Receiver must not mistake an unchanged desktop for signal loss")
                lastPresentedAt = now
                refreshes += 1
            }
        }
        XCTAssertGreaterThan(refreshes, 50)
        XCTAssertLessThanOrEqual(refreshes, 60, "Static refresh must stay within 2 fps")
        XCTAssertLessThan(30 - lastPresentedAt, 2)
    }

    func testChangedImageReplacesIdleImageAndSuspensionCannotResurrectOldContent() {
        var refresh = TBIdleFrameRefresh<String>()
        refresh.capture("first", now: 10)
        refresh.capture("changed", now: 10.2)
        XCTAssertNil(refresh.idle(now: 10.3))
        XCTAssertEqual(refresh.idle(now: 10.8), "changed")
        refresh.invalidate()
        XCTAssertNil(refresh.refresh(now: 11.8))
        XCTAssertNil(refresh.refresh(now: 50))
        refresh.capture("resumed", now: 51)
        XCTAssertNil(refresh.refresh(now: 52), "Live capture must not be replayed without a new idle confirmation")
        XCTAssertEqual(refresh.idle(now: 52), "resumed")
    }

    func testFailedPreflightDoesNotOverrideSuccessfulScreenCaptureKitAccess() {
        var access = TBScreenCaptureAccess()
        XCTAssertNil(access.diagnosticPermission(preflight: false))
        access.recordSuccess()
        XCTAssertEqual(access.diagnosticPermission(preflight: false), true)
        let encoderFailure = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.failedToStart.rawValue)
        access.recordFailure(encoderFailure)
        XCTAssertEqual(access.diagnosticPermission(preflight: false), true)
        XCTAssertFalse(TBScreenCaptureAccess.isPermissionDenied(encoderFailure))
    }

    func testOnlyExplicitScreenCaptureDenialReportsMissingPermission() {
        var access = TBScreenCaptureAccess()
        let failure = NSError(domain: SCStreamError.errorDomain, code: SCStreamError.Code.userDeclined.rawValue)
        access.recordFailure(failure)
        XCTAssertEqual(access.diagnosticPermission(preflight: false), false)
        XCTAssertTrue(TBScreenCaptureAccess.isPermissionDenied(failure))
        XCTAssertFalse(TBScreenCaptureAccess.isPermissionDenied(NSError(domain: "Network", code: failure.code)))
        XCTAssertEqual(access.diagnosticPermission(preflight: true), true, "A new grant must replace the earlier denial")
    }
}
