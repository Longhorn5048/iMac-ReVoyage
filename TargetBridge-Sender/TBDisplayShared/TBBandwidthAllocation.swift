import Foundation

/// Capacity is usable application throughput per direction, after link overhead.
/// External SMB traffic is observable only; there is no SMB shaper in this app.
struct TBBandwidthAllocation: Codable, Equatable {
    var borrowUnused = false
    var video = 700.0
    var speaker = 10.0
    var camera = 25.0
    var microphone = 1.0
    var disk = 0.0
    var sd = 0.0
    static let controlMbps = 5.0
    var forward: Double { video + speaker + disk + sd + Self.controlMbps }
    var reverse: Double { camera + microphone + disk + sd + Self.controlMbps }
    func isValid(capacity: Double) -> Bool {
        TBVideoBandwidthBudget.validCapacity(capacity) &&
        [video, speaker, camera, microphone, disk, sd].allSatisfy { $0.isFinite && $0 >= 0 } &&
        video >= 2 && speaker >= 2 && camera >= 1 && camera <= 1000 && microphone >= 1 &&
        disk == 0 && sd == 0 && forward <= capacity && reverse <= capacity
    }
    func videoCeiling(capacity: Double) -> Double { borrowUnused ? capacity - speaker - Self.controlMbps : video }
    func cameraCeiling(capacity: Double) -> Double { borrowUnused ? min(1000, capacity - microphone - Self.controlMbps) : camera }
    static func preset(_ name: String) -> Self {
        switch name {
        case "display": return Self(video: 700, camera: 25)
        case "call": return Self(video: 100, camera: 100)
        case "files": return Self(video: 80, camera: 10)
        default: return Self()
        }
    }
}

/// Packet-level enforcement also works when the encoder rejects its rate hint.
/// One bounded burst permits a complete independently decodable frame.
struct TBPacketRateLimiter {
    let bytesPerSecond: Double
    let burstBytes: Double
    private var tokens: Double
    private var lastTime: Double
    init(mbps: Double, burstBytes: Int, now: Double) {
        bytesPerSecond = max(0, mbps) * 125_000
        self.burstBytes = Double(max(0, burstBytes))
        tokens = self.burstBytes
        lastTime = now
    }
    mutating func admit(bytes: Int, now: Double) -> Bool {
        guard bytes > 0, bytesPerSecond.isFinite, bytesPerSecond > 0,
              now.isFinite, now >= lastTime else { return false }
        tokens = min(burstBytes, tokens + (now - lastTime) * bytesPerSecond)
        lastTime = now
        guard Double(bytes) <= tokens else { return false }
        tokens -= Double(bytes)
        return true
    }
}
