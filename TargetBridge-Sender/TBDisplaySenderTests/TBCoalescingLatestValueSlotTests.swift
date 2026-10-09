import XCTest
@testable import TargetBridge

final class TBCoalescingLatestValueSlotTests: XCTestCase {
    func testOffersReplacePendingValueAndScheduleOnlyOneDrain() {
        let slot = TBCoalescingLatestValueSlot<Int>()

        XCTAssertTrue(slot.offer(100))
        XCTAssertFalse(slot.offer(101))
        XCTAssertFalse(slot.offer(102))
        XCTAssertEqual(slot.takeLatest(), 102)

        XCTAssertTrue(slot.offer(103))
        XCTAssertEqual(slot.takeLatest(), 103)
    }
}

final class TBBoundedAudioSendGateTests: XCTestCase {
    @MainActor
    func testExpirationTimerCreatedOnMainActorRunsOnBackgroundQueue() async {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted = gate.reserve(bytes: 1920, now: 0) else { return XCTFail() }
        let expired = expectation(description: "background audio deadline")
        expired.assertForOverFulfill = true
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.setEventHandler(handler: gate.makeExpirationHandler {
            XCTAssertFalse(Thread.isMainThread)
            expired.fulfill()
        })
        timer.schedule(deadline: .now(), repeating: .milliseconds(5))
        timer.resume()
        await fulfillment(of: [expired], timeout: 2)
        timer.cancel()
        XCTAssertFalse(gate.isOpen)
    }

    @MainActor
    func testBackgroundExpirationHandlerDoesNotFailAnIdleStream() async {
        let gate = TBBoundedAudioSendGate()
        let finished = expectation(description: "idle background callback")
        let handler = gate.makeExpirationHandler { XCTFail("Idle audio must not expire") }
        DispatchQueue.global(qos: .userInitiated).async {
            handler()
            handler()
            finished.fulfill()
        }
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(gate.isOpen)
    }

    func testQueuedActorTasksAndNetworkWritesShareOneByteLimit() {
        let gate = TBBoundedAudioSendGate()
        var tokens: [UUID] = []
        for _ in 0..<15 {
            guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 10) else { return XCTFail() }
            tokens.append(token)
        }
        guard case .overloaded = gate.reserve(bytes: 1920, now: 10.01) else { return XCTFail() }
        XCTAssertFalse(gate.isOpen)
        guard case .closed = gate.reserve(bytes: 1920, now: 10.02) else { return XCTFail() }
        for token in tokens { gate.release(token) }
        XCTAssertFalse(gate.failOnce())
    }
    func testCompletionReleasesCapacityAndDeadlineFiresOnce() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 20) else { return XCTFail() }
        gate.release(token); gate.release(token) // A duplicated completion cannot subtract twice.
        guard case .accepted = gate.reserve(bytes: 1920, now: 20.01) else { return XCTFail() }
        XCTAssertFalse(gate.expire(now: 20.1))
        XCTAssertTrue(gate.expire(now: 20.2))
        XCTAssertFalse(gate.expire(now: 20.3))
        XCTAssertFalse(gate.isOpen)
    }
    func testPacketLimitAndCancellationStopFurtherAdmission() {
        let gate = TBBoundedAudioSendGate()
        for _ in 0..<32 {
            guard case .accepted = gate.reserve(bytes: 4, now: 30) else { return XCTFail() }
        }
        guard case .overloaded = gate.reserve(bytes: 4, now: 30) else { return XCTFail() }
        let cancelled = TBBoundedAudioSendGate(); cancelled.close()
        guard case .closed = cancelled.reserve(bytes: 4, now: 30) else { return XCTFail() }
    }
    func testMutedCaptureCannotQueueActorTasksAndCanResume() {
        let gate = TBBoundedAudioSendGate(); gate.setEnabled(false)
        for _ in 0..<100 {
            guard case .closed = gate.reserve(bytes: 1920, now: 10) else { return XCTFail() }
        }
        XCTAssertTrue(gate.isOpen)
        gate.setEnabled(true)
        guard case .accepted = gate.reserve(bytes: 1920, now: 11) else { return XCTFail() }
    }
    func testStalledNetworkCompletionRejectsNewCaptureWithoutAccumulatingTasks() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted = gate.reserve(bytes: 1920, now: 40) else { return XCTFail() }
        guard case .overloaded = gate.reserve(bytes: 1920, now: 40.2) else { return XCTFail() }
    }
    func testFailedAudioOnlyReopensAfterEveryEarlierWriteDrains() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 10) else { return XCTFail() }
        XCTAssertTrue(gate.expire(now: 10.2))
        XCTAssertFalse(gate.setEnabled(true))
        XCTAssertEqual(gate.snapshot(now: 10.2).bytes, 1920)
        gate.release(token)
        XCTAssertTrue(gate.setEnabled(true))
        guard case .accepted = gate.reserve(bytes: 1920, now: 11) else { return XCTFail() }
    }

    func testImmediateCompletionsCannotBypassPCMWireRate() {
        let gate = TBBoundedAudioSendGate()
        for _ in 0..<15 {
            guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 50) else { return XCTFail() }
            gate.release(token)
        }
        XCTAssertEqual(gate.snapshot(now: 50).bytes, 0)
        guard case .overloaded = gate.reserve(bytes: 1920, now: 50) else { return XCTFail() }
        XCTAssertFalse(gate.isOpen)
    }

    func testEmptyPartialAndOversizedCaptureBatchesDoNotMuteLaterPlayback() {
        let gate = TBBoundedAudioSendGate()
        for count in [0, 3, TBBoundedAudioSendGate.maxBytes + 4] {
            guard case .discarded = gate.reserve(bytes: count, now: 10) else { return XCTFail() }
            XCTAssertTrue(gate.isOpen)
            XCTAssertEqual(gate.snapshot(now: 10).bytes, 0)
        }
        guard case .accepted = gate.reserve(bytes: 1920, now: 10.01) else { return XCTFail("Playback must still work after an empty conversion") }
    }

    func testResumedLargeCaptureBatchKeepsNewestWholePCMFramesWithinBudget() throws {
        let newest = Data(repeating: 7, count: TBBoundedAudioSendGate.maxBytes)
        let batch = Data(repeating: 1, count: 4096) + newest
        XCTAssertEqual(TBBoundedAudioSendGate.capturePayload(batch), newest)
        XCTAssertNil(TBBoundedAudioSendGate.capturePayload(Data()))
        XCTAssertNil(TBBoundedAudioSendGate.capturePayload(Data(count: 3)))
        let normal = Data(repeating: 2, count: 1920)
        XCTAssertEqual(TBBoundedAudioSendGate.capturePayload(normal), normal)
        let gate = TBBoundedAudioSendGate()
        let payload = try XCTUnwrap(TBBoundedAudioSendGate.capturePayload(batch))
        guard case .accepted = gate.reserve(bytes: payload.count, now: 10) else { return XCTFail() }
        XCTAssertEqual(gate.snapshot(now: 10).bytes, TBBoundedAudioSendGate.maxBytes)
    }

    func testTransientStallAutomaticallyRecoversOnlyAfterAllWritesDrain() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let first) = gate.reserve(bytes: 1920, now: 10),
              case .accepted(let second) = gate.reserve(bytes: 1920, now: 10) else { return XCTFail() }
        XCTAssertTrue(gate.expire(now: 10.2))
        XCTAssertFalse(gate.recoverWhenDrained(now: 12))
        gate.release(first)
        XCTAssertFalse(gate.recoverWhenDrained(now: 12))
        XCTAssertEqual(gate.snapshot(now: 12).bytes, 1920)
        gate.release(second)
        XCTAssertFalse(gate.recoverWhenDrained(now: 10.3), "A brief cooldown avoids repeated burst retries")
        XCTAssertTrue(gate.recoverWhenDrained(now: 12))
        XCTAssertFalse(gate.recoverWhenDrained(now: 12))
        guard case .accepted = gate.reserve(bytes: 1920, now: 12) else { return XCTFail("Recovery must not require toggling the sound preference") }
    }

    func testExplicitMuteSleepAndCancellationCannotBeOverriddenByRecovery() {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 20) else { return XCTFail() }
        XCTAssertTrue(gate.expire(now: 20.2))
        gate.setEnabled(false) // Used by both explicit mute and Sender sleep.
        gate.release(token)
        XCTAssertFalse(gate.recoverWhenDrained(now: 30))
        guard case .closed = gate.reserve(bytes: 1920, now: 30) else { return XCTFail() }
        XCTAssertTrue(gate.setEnabled(true))
        guard case .accepted = gate.reserve(bytes: 1920, now: 30) else { return XCTFail() }
        gate.close()
        XCTAssertFalse(gate.setEnabled(true))
        XCTAssertFalse(gate.recoverWhenDrained(now: 40))
        guard case .closed = gate.reserve(bytes: 1920, now: 40) else { return XCTFail() }
    }

    func testRepeatedPlaybackBurstsRecoverWithoutRelaxingByteAndRateLimits() {
        let gate = TBBoundedAudioSendGate()
        for cycle in 0..<20 {
            let now = Double(cycle) + 50
            for _ in 0..<15 {
                guard case .accepted(let token) = gate.reserve(bytes: 1920, now: now) else { return XCTFail() }
                gate.release(token)
            }
            guard case .overloaded = gate.reserve(bytes: 1920, now: now) else { return XCTFail("Burst rate limit must remain active") }
            XCTAssertEqual(gate.snapshot(now: now).bytes, 0)
            XCTAssertFalse(gate.recoverWhenDrained(now: now + 0.1))
            XCTAssertTrue(gate.recoverWhenDrained(now: now + 0.3))
        }
    }

    @MainActor
    func testMaintenanceTimerReportsDrainRecoveryOffMainActorExactlyOnce() async {
        let gate = TBBoundedAudioSendGate()
        guard case .accepted(let token) = gate.reserve(bytes: 1920, now: 0) else { return XCTFail() }
        XCTAssertTrue(gate.expire(now: 0.2))
        gate.release(token)
        let recovered = expectation(description: "automatic recovery on timer queue")
        recovered.assertForOverFulfill = true
        let handler = gate.makeMaintenanceHandler(onExpiry: { XCTFail("Already paused") }, onRecovery: {
            XCTAssertFalse(Thread.isMainThread)
            recovered.fulfill()
        })
        DispatchQueue.global(qos: .userInitiated).async { handler(); handler() }
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertTrue(gate.isOpen)
    }

}
