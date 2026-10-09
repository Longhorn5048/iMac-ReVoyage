import XCTest
@testable import TargetBridge

final class TBVideoBandwidthBudgetTests: XCTestCase {
    func testSharedLinkReservationsAndReplacementDoNotDoubleCount() {
        var budget = TBVideoBandwidthBudget(capacityMbps: 900)
        let first = UUID(), second = UUID(), third = UUID()
        XCTAssertTrue(budget.reserveVideo(for: first, megabitsPerSecond: 100))
        XCTAssertEqual(budget.backgroundCeilingMbps, 793, accuracy: 0.001)
        XCTAssertTrue(budget.reserveVideo(for: first, megabitsPerSecond: 250))
        XCTAssertEqual(budget.backgroundCeilingMbps, 643, accuracy: 0.001)
        XCTAssertTrue(budget.reserveVideo(for: second, megabitsPerSecond: 250))
        XCTAssertEqual(budget.backgroundCeilingMbps, 391, accuracy: 0.001)
        XCTAssertFalse(budget.reserveVideo(for: third, megabitsPerSecond: 400))
        XCTAssertEqual(budget.videoReservations.count, 2)
        budget.release(first)
        XCTAssertTrue(budget.reserveVideo(for: third, megabitsPerSecond: 400))
    }

    func testCableTestAndVideoExcludeEachOtherUntilReleased() {
        var budget = TBVideoBandwidthBudget(capacityMbps: 900)
        let video = UUID(), test = UUID()
        XCTAssertTrue(budget.reserveVideo(for: video, megabitsPerSecond: 100))
        XCTAssertFalse(budget.beginCableTest(for: test))
        budget.release(video)
        XCTAssertTrue(budget.beginCableTest(for: test))
        XCTAssertFalse(budget.beginCableTest(for: UUID()))
        XCTAssertFalse(budget.reserveVideo(for: video, megabitsPerSecond: 100))
        budget.release(test)
        XCTAssertTrue(budget.reserveVideo(for: video, megabitsPerSecond: 100))
    }

    func testCapacityChangesAreAtomicAndRetainSafetyMargin() {
        var budget = TBVideoBandwidthBudget(capacityMbps: 900)
        let id = UUID()
        XCTAssertTrue(budget.reserveVideo(for: id, megabitsPerSecond: 100))
        XCTAssertFalse(budget.setCapacity(100))
        XCTAssertEqual(budget.capacityMbps, 900)
        XCTAssertTrue(budget.setCapacity(200))
        XCTAssertEqual(budget.backgroundCeilingMbps, 93, accuracy: 0.001)
        for bad in [Double.nan, .infinity, 0, -1, 100_001] {
            XCTAssertFalse(budget.setCapacity(bad))
            XCTAssertFalse(budget.reserveVideo(for: UUID(), megabitsPerSecond: bad))
        }
        XCTAssertEqual(budget.videoReservations.count, 1)
    }

    func testSeparateLinksCanRunIndependently() {
        var first = TBVideoBandwidthBudget(capacityMbps: 900)
        var second = TBVideoBandwidthBudget(capacityMbps: 900)
        XCTAssertTrue(first.beginCableTest(for: UUID()))
        XCTAssertTrue(second.reserveVideo(for: UUID(), megabitsPerSecond: 100))
    }

    func testAllPresetBudgetsCoverTheirAverageBitrates() {
        for preset in TBDisplayCapturePreset.allCases {
            XCTAssertGreaterThan(preset.videoProtectionMbps * 1_000_000, Double(preset.averageBitRate))
        }
        XCTAssertEqual(TBDisplayCapturePreset.legacy1080p60.videoProtectionMbps, 100)
    }

    func testExperimentalOverridesCannotDisableOrUnboundCaptureQueues() {
        XCTAssertEqual(TBVideoSendGate.boundedQueueLimit(Int.min), 1)
        XCTAssertEqual(TBVideoSendGate.boundedQueueLimit(0), 1)
        XCTAssertEqual(TBVideoSendGate.boundedQueueLimit(3), 3)
        XCTAssertEqual(TBVideoSendGate.boundedQueueLimit(Int.max), 8)
    }

    func testDroppedReferenceSuppressesDependentFramesUntilNewKeyframe() throws {
        var gate = TBVideoSendGate(maxPackets: 1, maxBytes: 1000)
        XCTAssertNil(gate.admit(bytes: 100, keyframe: false))
        let key = try XCTUnwrap(gate.admit(bytes: 100, keyframe: true))
        XCTAssertFalse(gate.needsKeyframe)
        XCTAssertNil(gate.admit(bytes: 200, keyframe: false))
        XCTAssertTrue(gate.needsKeyframe)
        gate.complete(key)
        XCTAssertNil(gate.admit(bytes: 200, keyframe: false))
        XCTAssertNotNil(gate.admit(bytes: 200, keyframe: true))
        XCTAssertFalse(gate.needsKeyframe)
    }

    func testKeyframesCannotBypassByteOrPacketLimitsAndCompletionIsIdempotent() throws {
        var gate = TBVideoSendGate(maxPackets: 2, maxBytes: 1000)
        let first = try XCTUnwrap(gate.admit(bytes: 700, keyframe: true))
        XCTAssertNil(gate.admit(bytes: 400, keyframe: true))
        let second = try XCTUnwrap(gate.admit(bytes: 300, keyframe: true))
        XCTAssertEqual(gate.pendingBytes, 1000)
        XCTAssertNil(gate.admit(bytes: 1, keyframe: true))
        gate.complete(first)
        gate.complete(first)
        gate.complete(UUID())
        XCTAssertEqual(gate.pendingBytes, 300)
        XCTAssertEqual(gate.pendingPackets, 1)
        gate.complete(second)
        XCTAssertEqual(gate.pendingBytes, 0)
        XCTAssertNil(gate.admit(bytes: Int.max, keyframe: true))
        XCTAssertNil(gate.admit(bytes: -1, keyframe: true))
    }

    func testRawFramesDoNotDependOnIDRButRemainBounded() throws {
        var gate = TBVideoSendGate(maxPackets: 1, maxBytes: 1000)
        let raw = try XCTUnwrap(gate.admit(bytes: 900, keyframe: false, compressed: false))
        XCTAssertNil(gate.admit(bytes: 1, keyframe: false, compressed: false))
        gate.complete(raw)
        XCTAssertNotNil(gate.admit(bytes: 900, keyframe: false, compressed: false))
    }

    func testCongestionRequiresPersistenceAndRestorationIsSlow() {
        var control = TBVideoCongestionController(bitRate: 50_000_000, now: 0)
        XCTAssertNil(control.observe(congested: true, now: 0))
        XCTAssertNil(control.observe(congested: true, now: 0.5))
        XCTAssertEqual(control.observe(congested: true, now: 1), 37_500_000)
        XCTAssertNil(control.observe(congested: false, now: 1.1))
        XCTAssertNil(control.observe(congested: false, now: 10))
        XCTAssertEqual(control.observe(congested: false, now: 11.2), 42_500_000)
        XCTAssertNil(control.observe(congested: false, now: 11.3))
        XCTAssertNil(control.observe(congested: true, now: .nan))
        XCTAssertNil(control.observe(congested: true, now: -1))
    }

    func testCongestionNeverExceedsPresetOrFallsBelowMinimum() {
        var control = TBVideoCongestionController(bitRate: 50_000_000, now: 0)
        for time in 0...100 { _ = control.observe(congested: true, now: Double(time)) }
        XCTAssertEqual(control.targetBitRate, 10_000_000)
        for time in 101...250 { _ = control.observe(congested: false, now: Double(time)) }
        XCTAssertEqual(control.targetBitRate, 50_000_000)
    }

    func testRejectedEncoderChangeDoesNotBecomeReportedBitrate() {
        var control = TBVideoCongestionController(bitRate: 50_000_000, now: 0)
        _ = control.observe(congested: true, now: 0)
        XCTAssertEqual(control.observe(congested: true, now: 1), 37_500_000)
        control.restoreTarget(afterRejectedChange: 50_000_000)
        XCTAssertEqual(control.targetBitRate, 50_000_000)
        XCTAssertNil(control.observe(congested: true, now: 1.1))
        XCTAssertEqual(control.observe(congested: true, now: 2), 37_500_000)
    }
    func testAllocationSeparatesDirectionsAndRejectsSMBPromises() {
        var plan = TBBandwidthAllocation(video: 700, speaker: 10, camera: 800)
        XCTAssertTrue(plan.isValid(capacity: 900)) // opposite directions do not add
        XCTAssertEqual(plan.forward, 715)
        XCTAssertEqual(plan.reverse, 806)
        XCTAssertEqual(plan.videoCeiling(capacity: 900), 700)
        plan.borrowUnused = true
        XCTAssertEqual(plan.videoCeiling(capacity: 900), 885)
        XCTAssertEqual(plan.cameraCeiling(capacity: 900), 894)
        plan.disk = 1
        XCTAssertFalse(plan.isValid(capacity: 900))
        plan.disk = 0; plan.camera = 900
        XCTAssertFalse(plan.isValid(capacity: 900))
        plan.camera = .nan
        XCTAssertFalse(plan.isValid(capacity: 900))
    }
    func testPacketLimiterIncludesWireBytesAndBoundsBursts() {
        var gate = TBPacketRateLimiter(mbps: 1, burstBytes: 1000, now: 10)
        XCTAssertTrue(gate.admit(bytes: 1000, now: 10))
        XCTAssertFalse(gate.admit(bytes: 1, now: 10))
        XCTAssertTrue(gate.admit(bytes: 500, now: 10.00401))
        XCTAssertFalse(gate.admit(bytes: 501, now: 10.00401))
        XCTAssertFalse(gate.admit(bytes: 1, now: 9))
        XCTAssertFalse(gate.admit(bytes: 1, now: .nan))
        XCTAssertFalse(gate.admit(bytes: 1001, now: 20))
        XCTAssertTrue(gate.admit(bytes: 1000, now: 20))
    }

}
