import Foundation

/// One egress link, one direction. This accounts for application traffic;
/// it does not claim to shape Finder SMB or other processes.
struct TBVideoBandwidthBudget {
    private(set) var capacityMbps: Double
    private(set) var videoReservations: [UUID: Double] = [:]
    private(set) var cableTester: UUID?

    init(capacityMbps: Double) {
        self.capacityMbps = Self.validCapacity(capacityMbps) ? capacityMbps : 900
    }

    static func validCapacity(_ value: Double) -> Bool {
        value.isFinite && (1...100_000).contains(value)
    }

    var backgroundCeilingMbps: Double {
        max(0, capacityMbps - videoReservations.values.reduce(0, +) - Double(videoReservations.count) * 2 - TBBandwidthAllocation.controlMbps)
    }

    mutating func reserveVideo(for id: UUID, megabitsPerSecond: Double) -> Bool {
        guard cableTester == nil, megabitsPerSecond.isFinite, megabitsPerSecond > 0 else { return false }
        var proposed = videoReservations
        proposed[id] = megabitsPerSecond
        let required = proposed.values.reduce(0, +) + Double(proposed.count) * 2 + TBBandwidthAllocation.controlMbps
        guard required <= capacityMbps else { return false }
        videoReservations = proposed
        return true
    }

    mutating func beginCableTest(for id: UUID) -> Bool {
        guard videoReservations.isEmpty, cableTester == nil || cableTester == id else { return false }
        cableTester = id
        return true
    }

    mutating func setCapacity(_ capacity: Double) -> Bool {
        guard Self.validCapacity(capacity),
              videoReservations.values.reduce(0, +) + Double(videoReservations.count) * 2 + TBBandwidthAllocation.controlMbps <= capacity
        else { return false }
        capacityMbps = capacity
        return true
    }

    mutating func release(_ id: UUID) {
        videoReservations.removeValue(forKey: id)
        if cableTester == id { cableTester = nil }
    }
}

/// Counts bytes retained by network submissions as well as packets. If an
/// encoded frame is omitted, all dependent frames wait for a fresh IDR.
struct TBVideoSendGate {
    static func boundedQueueLimit(_ requested: Int) -> Int { min(8, max(1, requested)) }
    let maxPackets: Int
    let maxBytes: Int
    private(set) var pendingBytes = 0
    private(set) var needsKeyframe = true
    private var submissions: [UUID: Int] = [:]

    var pendingPackets: Int { submissions.count }
    var hasCapacity: Bool { pendingPackets < maxPackets && pendingBytes < maxBytes }

    mutating func admit(bytes: Int, keyframe: Bool, compressed: Bool = true) -> UUID? {
        guard bytes > 0, bytes <= maxBytes,
              pendingPackets < maxPackets, pendingBytes <= maxBytes - bytes,
              !compressed || keyframe || !needsKeyframe else {
            if compressed { needsKeyframe = true }
            return nil
        }
        let id = UUID()
        submissions[id] = bytes
        pendingBytes += bytes
        if compressed && keyframe { needsKeyframe = false }
        return id
    }

    mutating func requireKeyframe() { needsKeyframe = true }

    mutating func complete(_ id: UUID) {
        guard let bytes = submissions.removeValue(forKey: id) else { return }
        pendingBytes -= bytes
    }
}

/// Slow recovery avoids oscillation. Network completion is only a local
/// congestion signal, not proof of remote decoding or presentation.
struct TBVideoCongestionController {
    let maximumBitRate: Int
    private(set) var targetBitRate: Int
    private var lastChange: TimeInterval
    private var congestedSince: TimeInterval?
    private var stableSince: TimeInterval?

    init(bitRate: Int, now: TimeInterval) {
        maximumBitRate = bitRate
        targetBitRate = bitRate
        lastChange = now
    }

    mutating func restoreTarget(afterRejectedChange previous: Int) {
        targetBitRate = min(maximumBitRate, max(maximumBitRate / 5, previous))
    }

    mutating func observe(congested: Bool, now: TimeInterval) -> Int? {
        guard now.isFinite, now >= lastChange else { return nil }
        if congested {
            stableSince = nil
            if congestedSince == nil { congestedSince = now }
            guard now - (congestedSince ?? now) >= 1, now - lastChange >= 1 else { return nil }
            let next = max(maximumBitRate / 5, targetBitRate * 3 / 4)
            guard next < targetBitRate else { return nil }
            targetBitRate = next
            lastChange = now
            congestedSince = now
            return next
        }
        congestedSince = nil
        if stableSince == nil { stableSince = now }
        guard now - (stableSince ?? now) >= 10, now - lastChange >= 10,
              targetBitRate < maximumBitRate else { return nil }
        targetBitRate = min(maximumBitRate, targetBitRate + max(1, maximumBitRate / 10))
        lastChange = now
        stableSince = now
        return targetBitRate
    }
}
