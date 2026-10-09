import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import CryptoKit
import Darwin
import Foundation
import AVFoundation
import IOSurface
import Network
@preconcurrency import ScreenCaptureKit
import VideoToolbox

/// Coalesces producer updates while a serial consumer is busy. At most one
/// value is retained for the next drain, so capture callbacks cannot enqueue a
/// FIFO of stale frames behind encoder work.
final class TBCoalescingLatestValueSlot<Value> {
    private let lock = NSLock()
    private var latestValue: Value?
    private var drainScheduled = false

    /// Returns true only when the caller must schedule a consumer drain.
    func offer(_ value: Value) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        latestValue = value
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// Returns the newest value and permits a future producer to schedule the
    /// next drain. Offers made while the consumer works schedule one more drain.
    func takeLatest() -> Value? {
        lock.lock()
        defer { lock.unlock() }
        let value = latestValue
        latestValue = nil
        drainScheduled = false
        return value
    }
}

/// Reservations cover capture -> MainActor -> Network completion, including
/// the time spent waiting for either queue. Congestion pauses admission until
/// every older write drains; cancellation permanently closes this gate.
final class TBBoundedAudioSendGate: @unchecked Sendable {
    enum Admission { case accepted(UUID), overloaded, discarded, closed }
    private let lock = NSLock()
    private var pending: [UUID: (bytes: Int, time: Double)] = [:]
    private var bytes = 0
    private var closed = false
    private var cancelled = false
    private var enabled = true
    private var resumeAfter: Double?
    private var rate = TBPacketRateLimiter(mbps: 2, burstBytes: maxBytes + maxPackets * 5, now: 0)
    @discardableResult func setEnabled(_ value: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        enabled = value
        if value && closed && !cancelled && pending.isEmpty { closed = false; resumeAfter = nil }
        return !closed
    }
    func snapshot(now: Double) -> (bytes: Int, packets: Int, ageMS: Int) {
        lock.lock(); defer { lock.unlock() }
        let oldest = pending.values.map(\.time).min() ?? now
        return (bytes, pending.count, Int(max(0, now - oldest) * 1000))
    }
    static let maxBytes = 28_800 // 150ms of 48kHz stereo signed 16-bit PCM
    static let maxPackets = 32
    static let maxAge = 0.15
    static let recoveryDelay = 0.25
    static func capturePayload(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count % 4 == 0 else { return nil }
        // A resumed source may deliver a larger batch. Keep its newest PCM
        // within the existing latency budget rather than muting playback.
        return data.count > maxBytes ? Data(data.suffix(maxBytes)) : data
    }
    func reserve(bytes count: Int, now: Double) -> Admission {
        lock.lock(); defer { lock.unlock() }
        guard !closed, enabled else { return .closed }
        // Invalid payloads are not evidence of a stalled Network send queue.
        guard count > 0, count % 4 == 0, count <= Self.maxBytes else { return .discarded }
        guard count <= Self.maxBytes - bytes, pending.count < Self.maxPackets,
              !pending.values.contains(where: { now - $0.time >= Self.maxAge }),
              rate.admit(bytes: count + 5, now: now) else {
            closed = true; resumeAfter = now + Self.recoveryDelay; return .overloaded
        }
        let token = UUID(); pending[token] = (count, now); bytes += count
        return .accepted(token)
    }
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return !closed }
    func failOnce(now: Double = ProcessInfo.processInfo.systemUptime) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }; closed = true; resumeAfter = now + Self.recoveryDelay; return true
    }
    func release(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        if let entry = pending.removeValue(forKey: token) { bytes -= entry.bytes }
    }
    func expire(now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed, pending.values.contains(where: { now - $0.time >= Self.maxAge }) else { return false }
        closed = true; resumeAfter = now + Self.recoveryDelay; return true
    }
    func recoverWhenDrained(now: Double) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard closed, !cancelled, enabled, pending.isEmpty,
              let resumeAfter, now >= resumeAfter else { return false }
        closed = false; self.resumeAfter = nil
        return true
    }
    // Dispatch timers execute off MainActor. Construct the callback here with
    // an explicit Sendable type so it cannot inherit the session's isolation.
    func makeExpirationHandler(onExpiry: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        return { [self] in
            if expire(now: ProcessInfo.processInfo.systemUptime) { onExpiry() }
        }
    }
    func makeMaintenanceHandler(onExpiry: @escaping @Sendable () -> Void,
                                onRecovery: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        return { [self] in
            let now = ProcessInfo.processInfo.systemUptime
            if expire(now: now) { onExpiry() }
            else if recoverWhenDrained(now: now) { onRecovery() }
        }
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        cancelled = true; closed = true; resumeAfter = nil; pending.removeAll(); bytes = 0
    }
}

enum TBDisplayCapturePreset: String, CaseIterable, Identifiable {
    case compatible1080p30
    case legacy1080p60
    case standard1440p
    case smooth1440p60
    case smooth1800p60
    case crisp2160p60
    case native5k
    case native5k60Experimental

    var id: String { rawValue }

    var title: String {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return self == .compatible1080p30 ? "Compatibility" : "Low Latency"
        case .standard1440p:
            return "Standard"
        case .smooth1440p60:
            return "Smooth"
        case .smooth1800p60:
            return "Smooth+"
        case .crisp2160p60:
            return "Crisp"
        case .native5k:
            return "5K"
        case .native5k60Experimental:
            return "5K 60 Experimental"
        }
    }

    var description: String {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return self == .compatible1080p30 ? "1920 × 1080 @ 30" : "1920 × 1080 @ 60"
        case .standard1440p:
            return "2560 × 1440"
        case .smooth1440p60:
            return "2560 × 1440 @ 60"
        case .smooth1800p60:
            return "3200 × 1800 @ 60"
        case .crisp2160p60:
            return "3840 × 2160 @ 60"
        case .native5k:
            return "5120 × 2880 @ 48"
        case .native5k60Experimental:
            return "5120 × 2880 @ 60"
        }
    }

    var width: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 1920
        case .standard1440p, .smooth1440p60:
            return 2560
        case .smooth1800p60:
            return 3200
        case .crisp2160p60:
            return 3840
        case .native5k, .native5k60Experimental:
            return 5120
        }
    }

    var height: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 1080
        case .standard1440p, .smooth1440p60:
            return 1440
        case .smooth1800p60:
            return 1800
        case .crisp2160p60:
            return 2160
        case .native5k, .native5k60Experimental:
            return 2880
        }
    }

    var averageBitRate: Int {
        switch self {
        case .compatible1080p30:
            return 50_000_000
        case .legacy1080p60:
            return 80_000_000
        case .standard1440p:
            return 36_000_000
        case .smooth1440p60:
            return 52_000_000
        case .smooth1800p60:
            return 78_000_000
        case .crisp2160p60:
            return 105_000_000
        case .native5k:
            return 120_000_000
        case .native5k60Experimental:
            return 150_000_000
        }
    }

    var videoProtectionMbps: Double {
        switch self {
        case .compatible1080p30, .legacy1080p60: return 100
        case .standard1440p: return 80
        case .smooth1440p60: return 120
        case .smooth1800p60: return 160
        case .crisp2160p60: return 200
        case .native5k: return 250
        case .native5k60Experimental: return 300
        }
    }

    var codecName: String {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return "H.264"
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return "H.264"
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return "HEVC"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return kCMVideoCodecType_H264
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return kCMVideoCodecType_H264
        case .crisp2160p60, .native5k, .native5k60Experimental:
            return kCMVideoCodecType_HEVC
        }
    }

    var queueDepth: Int {
        if self != .legacy1080p60 && self != .compatible1080p30,
           let envVal = ProcessInfo.processInfo.environment["QD"], let parsed = Int(envVal) {
            return TBVideoSendGate.boundedQueueLimit(parsed)
        }
        return (self == .legacy1080p60 || self == .compatible1080p30) ? 1 : 2
    }

    var expectedFrameRate: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return self == .compatible1080p30 ? 30 : 60
        case .standard1440p:
            return 30
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameInterval: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 60
        case .standard1440p:
            return 60
        case .smooth1440p60:
            return 60
        case .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    var maxKeyFrameIntervalDuration: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 1
        case .standard1440p:
            return 2
        case .smooth1440p60:
            return 1
        case .smooth1800p60, .crisp2160p60:
            return 1
        case .native5k, .native5k60Experimental:
            return 1
        }
    }

    var prioritizeSpeed: Bool {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            // Desktop text needs quality at the existing bitrate; latency is
            // bounded separately by no reordering and the in-flight frame gate.
            return false
        case .standard1440p:
            return false
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5k60Experimental:
            return true
        }
    }

    var maxPendingVideoPackets: Int {
        if self != .legacy1080p60 && self != .compatible1080p30,
           let envVal = ProcessInfo.processInfo.environment["MPVP"], let parsed = Int(envVal) {
            return TBVideoSendGate.boundedQueueLimit(parsed)
        }
        return (self == .legacy1080p60 || self == .compatible1080p30) ? 1 : 3
    }

    var maxFrameDelayCount: Int {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 0
        case .standard1440p:
            return 1
        case .smooth1440p60, .smooth1800p60, .crisp2160p60, .native5k, .native5k60Experimental:
            return 0
        }
    }

    var dropsBeforeEncodeWhenBacklogged: Bool { true }

    var maxInFlightEncodeFrames: Int {
        if self != .legacy1080p60 && self != .compatible1080p30,
           let envVal = ProcessInfo.processInfo.environment["MIFEF"], let parsed = Int(envVal) {
            return TBVideoSendGate.boundedQueueLimit(parsed)
        }
        return (self == .legacy1080p60 || self == .compatible1080p30) ? 1 : 5
    }

    var captureResolution: SCCaptureResolutionType {
        switch self {
        case .standard1440p, .smooth1440p60, .smooth1800p60:
            return .nominal
        case .compatible1080p30, .legacy1080p60, .crisp2160p60, .native5k, .native5k60Experimental:
            // Capture backing pixels before scaling to the requested output.
            // A nominal 1 point = 1 pixel source loses Retina text detail first.
            return .best
        }
    }

    var virtualDisplayRefreshRate: Double {
        switch self {
        case .compatible1080p30, .legacy1080p60:
            return 60
        case .standard1440p:
            return 60
        case .smooth1440p60, .smooth1800p60:
            return 60
        case .crisp2160p60:
            return 60
        case .native5k:
            return 48
        case .native5k60Experimental:
            return 60
        }
    }

    /// Virtual display mode that makes the render resolution equal the stream
    /// resolution. macOS HiDPI is strictly 2x, so a (w/2, h/2) mode backs onto a
    /// (w, h) framebuffer, which ScreenCaptureKit then captures 1:1.
    ///
    /// Costs screen real estate: the desktop reports "looks like w/2 x h/2" rather
    /// than the receiver's default 2560 x 1440.
    func renderMatchedDisplayMode(hiDPI: Bool) -> TBVirtualDisplayModeSize {
        let scale = hiDPI ? 2 : 1
        return TBVirtualDisplayModeSize(width: width / scale, height: height / scale, hiDPI: hiDPI)
    }

    /// Logical desktop size the user ends up with under render matching.
    func renderMatchedDesktopDescription(hiDPI: Bool) -> String {
        let mode = renderMatchedDisplayMode(hiDPI: hiDPI)
        return "\(mode.width) × \(mode.height)"
    }
}

enum TBDisplayCaptureSource: String, CaseIterable, Identifiable {
    case desktopMirror
    case extendedDesktop

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch self {
        case .desktopMirror:
            return TBDisplaySenderL10n.text("sender.source.desktop_mirror", language)
        case .extendedDesktop:
            return TBDisplaySenderL10n.text("sender.source.extended_desktop", language)
        }
    }

    func virtualDisplayIdentity(receiverKey: String) -> TBVirtualDisplayIdentity {
        switch self {
        case .desktopMirror:
            return .desktopMirror
        case .extendedDesktop:
            return .extendedDesktop(receiverKey: receiverKey)
        }
    }
}

enum TBInputControlRole: String, CaseIterable, Identifiable {
    case off
    case senderMaster
    case receiverMaster

    var id: String { rawValue }
}

enum TBInputGestureMode: String, CaseIterable, Identifiable {
    case native
    case relayToSlave

    var id: String { rawValue }
}

private final class TBDirectDisplayStreamCapture {
    // Strong reference so the pipeline (and its delivery queue) outlives every
    // frame callback — a stray frame must never deref a freed pipeline.
    private let pipeline: TBVideoPipeline
    private let queue: DispatchQueue
    private var stream: CGDisplayStream?
    // CGDisplayStreamStop is asynchronous: frames already in flight keep arriving
    // until the stream delivers a final `.stopped` frame, and releasing the
    // CGDisplayStream before then crashes inside SkyLight's
    // `_CGYDisplayStreamFrameAvailable`. This self-reference keeps the capture
    // object (and the stream) alive from stop() until that `.stopped` frame.
    private var pendingStopRetain: TBDirectDisplayStreamCapture?

    init(pipeline: TBVideoPipeline, queue: DispatchQueue) {
        self.pipeline = pipeline
        self.queue = queue
    }

    func start(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset, showCursor: Bool) -> Bool {
        let properties: NSDictionary = [
            CGDisplayStream.colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            CGDisplayStream.showCursor: showCursor,
            CGDisplayStream.queueDepth: preset.queueDepth,
            CGDisplayStream.minimumFrameTime: 1.0 / Double(preset.expectedFrameRate)
        ]

        let displayStream = CGDisplayStream(
            dispatchQueueDisplay: displayID,
            outputWidth: preset.width,
            outputHeight: preset.height,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: properties,
            queue: queue
        ) { [weak self] status, displayTime, surface, _ in
            // Delivered on `queue` — the pipeline's own serial queue — so encode
            // runs here, off the main thread, with no extra hop.
            guard let self else { return }
            if status == .stopped {
                // The stream has fully drained; no further frames will arrive, so
                // it is now safe to release the stream and drop the self-retain.
                self.stream = nil
                self.pendingStopRetain = nil
                return
            }
            guard status == .frameComplete, let surface else { return }
            // After pipeline.stop(), encodeDisplaySurface() no-ops on its `running`
            // guard, so a late in-flight frame here is harmless.
            self.pipeline.encodeDisplaySurface(surface, displayTime: displayTime)
        }

        guard let displayStream, displayStream.start() == .success else {
            return false
        }

        stream = displayStream
        return true
    }

    func stop() {
        guard stream != nil else { return }
        // Stay alive until the `.stopped` frame arrives (see pendingStopRetain);
        // the stream is released in the handler, never here, so it is never freed
        // with frame events still queued on `queue`.
        pendingStopRetain = self
        stream?.stop()
    }

    deinit {
        stop()
    }
}

/// Owns the capture→encode→send video pipeline and runs it entirely on a
/// dedicated serial queue, off the main thread. SwiftUI layout (or any other
/// main-thread work) therefore cannot stall frame delivery. All mutable encode
/// state is confined to `queue`; the two values the main thread polls
/// (`sentFrames`, `lastCaptureFrameAt`) are guarded by a small lock instead of
/// a per-frame hop back to main.
private final class TBVideoPipeline: @unchecked Sendable {
    let queue = DispatchQueue(label: "fd.tbmonitor.sender.pipeline", qos: .userInteractive)

    private let preset: TBDisplayCapturePreset
    private let codecType: CMVideoCodecType
    private let connection: NWConnection
    private let displayName: String
    private let displayID: CGDirectDisplayID
    private let usesRawNV12: Bool
    private let onFirstFrame: @Sendable () -> Void
    private let onFailure: @Sendable () -> Void

    // Confined to `queue`.
    private var vtEncoder: VTCompressionSession?
    private var vtEncoderRef: Unmanaged<TBVideoPipeline>?
    private var sendGate: TBVideoSendGate
    private var packetRateLimiter: TBPacketRateLimiter
    private let maximumVideoMbps: Double
    private let encoderBitRate: Int
    private var congestion: TBVideoCongestionController
    private var pendingVideoPackets: Int { sendGate.pendingPackets }
    private var rateLimitSupported = false
    private var droppedFrames = 0
    private var submittedVideoBytes: UInt64 = 0
    private var inFlightEncodeFrames = 0
    private var displayStreamFrameSequence: CMTimeValue = 0
    private var lastEncodedDisplayPTS: CMTime?
    private var ackSent: Bool
    private var running = false
    private var suspended = false
    private var idleFrameRefresh = TBIdleFrameRefresh<CVPixelBuffer>()
    private var idleFrameTimer: DispatchSourceTimer?

    // Read from the main thread (fps timer / watchdog); guarded by `lock`.
    private let lock = NSLock()
    private let latestCapturedSample = TBCoalescingLatestValueSlot<CMSampleBuffer>()
    private var _sentFrames = 0
    private var _lastCaptureFrameAt = Date()
    private var _capturedFrames = 0
    private var _encodedFrames = 0
    private var _lastEncoderStatus: OSStatus = noErr

    init(preset: TBDisplayCapturePreset,
         maximumVideoMbps: Double,
         codecType: CMVideoCodecType,
         connection: NWConnection,
         displayName: String,
         displayID: CGDirectDisplayID,
         usesRawNV12: Bool,
         ackAlreadySent: Bool,
         onFirstFrame: @escaping @Sendable () -> Void,
         onFailure: @escaping @Sendable () -> Void) {
        self.preset = preset
        self.maximumVideoMbps = maximumVideoMbps
        self.encoderBitRate = min(preset.averageBitRate, max(1, Int(maximumVideoMbps * 800_000)))
        self.packetRateLimiter = TBPacketRateLimiter(mbps: maximumVideoMbps, burstBytes: usesRawNV12
            ? preset.width * preset.height * 2 + 1024 : 2 * 1024 * 1024,
            now: ProcessInfo.processInfo.systemUptime)
        self.codecType = codecType
        self.connection = connection
        self.displayName = displayName
        self.displayID = displayID
        self.usesRawNV12 = usesRawNV12
        self.ackSent = ackAlreadySent
        self.onFirstFrame = onFirstFrame
        self.onFailure = onFailure
        self.sendGate = TBVideoSendGate(maxPackets: max(1, preset.maxPendingVideoPackets),
            maxBytes: usesRawNV12
                ? (preset.width * preset.height * 2 + 1024) * max(1, preset.maxPendingVideoPackets)
                : max(2 * 1024 * 1024, Int(preset.videoProtectionMbps * 1_000_000 / 8 * 0.12)))
        self.congestion = TBVideoCongestionController(bitRate: encoderBitRate, now: ProcessInfo.processInfo.systemUptime)
    }

    // MARK: - Lifecycle (called from the main actor)

    /// Sets up the encoder on `queue`. Returns false if the hardware encoder
    /// could not be created.
    func start() -> Bool {
        queue.sync {
            if !usesRawNV12 { setupEncoder() }
            running = usesRawNV12 || vtEncoder != nil
            guard running else { return false }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.setEventHandler { [weak self] in self?.refreshIdleFrame() }
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            idleFrameTimer = timer
            timer.resume()
            return true
        }
    }

    /// Tears the encoder down on `queue`. Because the queue is serial, any
    /// in-flight `encode` completes before `VTCompressionSessionInvalidate`,
    /// so a frame can never encode into an invalidated session.
    func stop() {
        queue.sync {
            running = false
            idleFrameTimer?.cancel()
            idleFrameTimer = nil
            idleFrameRefresh.invalidate()
            if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
            vtEncoder = nil
            vtEncoderRef?.release()
            vtEncoderRef = nil
        }
    }

    // MARK: - Snapshots for the main thread

    var sentFramesSnapshot: Int {
        lock.lock(); defer { lock.unlock() }
        return _sentFrames
    }

    var lastCaptureFrameAtSnapshot: Date {
        lock.lock(); defer { lock.unlock() }
        return _lastCaptureFrameAt
    }

    func startupDiagnosticsSnapshot() -> (captured: Int, encoded: Int, encoderStatus: OSStatus) {
        lock.lock(); defer { lock.unlock() }
        return (_capturedFrames, _encodedFrames, _lastEncoderStatus)
    }

    func noteCaptureActivity() { markCaptureFrame() }

    var captureIsIdle: Bool { queue.sync { idleFrameRefresh.isIdle } }

    func setSuspended(_ value: Bool) {
        queue.sync {
            suspended = value
            idleFrameRefresh.invalidate()
            if !value { sendGate.requireKeyframe() }
        }
    }

    func diagnosticsSnapshot() -> (pending: Int, inFlight: Int, ptsSeq: CMTimeValue) {
        queue.sync { (pending: pendingVideoPackets, inFlight: inFlightEncodeFrames, ptsSeq: displayStreamFrameSequence) }
    }

    func protectionSnapshot() -> (pendingBytes: Int, submittedBytes: UInt64, dropped: Int, bitRate: Int, rateLimited: Bool) {
        queue.sync { (sendGate.pendingBytes, submittedVideoBytes, droppedFrames, congestion.targetBitRate, rateLimitSupported) }
    }

    private func observeCongestion(_ congested: Bool) {
        let previous = congestion.targetBitRate
        guard let encoder = vtEncoder,
              let bitRate = congestion.observe(congested: congested, now: ProcessInfo.processInfo.systemUptime) else { return }
        let status = VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: bitRate))
        if status != noErr {
            congestion.restoreTarget(afterRejectedChange: previous)
            TBLog.connection.warning("encoder rejected congestion bitrate \(bitRate, privacy: .public): \(status, privacy: .public)")
        }
    }

    private func canEncodeNextFrame() -> Bool {
        let congested = !sendGate.hasCapacity || inFlightEncodeFrames >= max(1, preset.maxInFlightEncodeFrames)
        observeCongestion(congested)
        if congested { droppedFrames += 1 }
        return !congested
    }

    private func markCaptureFrame() {
        lock.lock(); _lastCaptureFrameAt = Date(); lock.unlock()
    }

    /// ScreenCaptureKit invokes its callback on a separate queue. Coalesce
    /// callbacks before hopping to the encoder queue so slow encode/send work
    /// cannot turn DispatchQueue's FIFO into a queue of old desktop frames.
    func submitCapturedSample(_ sampleBuffer: CMSampleBuffer) {
        markCaptureFrame()
        lock.lock(); _capturedFrames += 1; lock.unlock()
        guard latestCapturedSample.offer(sampleBuffer) else { return }
        queue.async { [weak self] in
            guard let self, let sample = self.latestCapturedSample.takeLatest() else { return }
            self.encode(sample)
        }
    }

    func submitIdleFrame() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            if let image = self.idleFrameRefresh.idle(now: ProcessInfo.processInfo.systemUptime) { self.sendIdleImage(image) }
        }
    }

    private func refreshIdleFrame() {
        guard running, !suspended, let image = idleFrameRefresh.refresh(now: ProcessInfo.processInfo.systemUptime) else { return }
        sendIdleImage(image)
    }

    private func sendIdleImage(_ image: CVPixelBuffer) {
        guard !suspended else { return }
        if usesRawNV12 {
            sendRawFrame(image)
        } else if let encoder = vtEncoder, canEncodeNextFrame() {
            encode(pixelBuffer: image, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), using: encoder)
        }
    }

    func invalidateIdleFrame() {
        queue.async { [weak self] in self?.idleFrameRefresh.invalidate() }
    }

    // MARK: - Encoder setup (on `queue`)

    private func setupEncoder() {
        if let encoder = vtEncoder { VTCompressionSessionInvalidate(encoder) }
        vtEncoder = nil
        vtEncoderRef?.release()
        vtEncoderRef = nil

        let spec: NSDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true
        ]
        let retained = Unmanaged.passRetained(self)
        vtEncoderRef = retained

        let callback: VTCompressionOutputCallback = { ref, _, status, _, sampleBuffer in
            guard let ref else { return }
            let pipeline = Unmanaged<TBVideoPipeline>.fromOpaque(ref).takeUnretainedValue()
            pipeline.queue.async {
                pipeline.inFlightEncodeFrames = max(0, pipeline.inFlightEncodeFrames - 1)
                pipeline.lock.lock()
                pipeline._lastEncoderStatus = status
                if status == noErr, sampleBuffer != nil { pipeline._encodedFrames += 1 }
                pipeline.lock.unlock()
                guard status == noErr, let sampleBuffer else {
                    pipeline.sendGate.requireKeyframe()
                    return
                }
                pipeline.handleEncoded(sampleBuffer)
            }
        }

        var session: VTCompressionSession?
        guard VTCompressionSessionCreate(
            allocator: nil,
            width: Int32(preset.width),
            height: Int32(preset.height),
            codecType: codecType,
            encoderSpecification: spec,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: retained.toOpaque(),
            compressionSessionOut: &session
        ) == noErr, let session else {
            retained.release()
            vtEncoderRef = nil
            return
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // The receiver's NV12 shader uses limited-range BT.709. Both capture
        // paths produce sRGB, so label the encoded stream with that same contract.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ColorPrimaries,
                             value: kCVImageBufferColorPrimaries_ITU_R_709_2)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_TransferFunction,
                             value: kCVImageBufferTransferFunction_sRGB)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_YCbCrMatrix,
                             value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        if codecType == kCMVideoCodecType_HEVC {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel,
                                 value: TBVideoQualityPolicy.h264Profile(for: preset))
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: NSNumber(value: preset.expectedFrameRate))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: NSNumber(value: preset.maxKeyFrameInterval))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: NSNumber(value: preset.maxKeyFrameIntervalDuration))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: preset.maxFrameDelayCount))
        let averageStatus = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: NSNumber(value: encoderBitRate))
        guard averageStatus == noErr else {
            VTCompressionSessionInvalidate(session)
            retained.release()
            vtEncoderRef = nil
            return
        }
        // Leave headroom in the application reservation for packet overhead.
        // Two windows restrain both short bursts and sustained output.
        let bytesPerSecond = maximumVideoMbps * 1_000_000 / 8 * 0.9
        let rateLimits = [NSNumber(value: bytesPerSecond * 0.25), NSNumber(value: 0.25),
                          NSNumber(value: bytesPerSecond), NSNumber(value: 1)] as CFArray
        rateLimitSupported = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: rateLimits) == noErr
        if !rateLimitSupported {
            TBLog.connection.warning("encoder does not support DataRateLimits; bounded queues and congestion adaptation remain active")
        }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
                             value: preset.prioritizeSpeed ? kCFBooleanTrue : kCFBooleanFalse)
        if let maximumQP = TBVideoQualityPolicy.maximumFrameQP(for: preset) {
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP,
                                              value: NSNumber(value: maximumQP))
            if status != noErr {
                TBLog.connection.warning("encoder does not support desktop quality QP limit: \(status, privacy: .public)")
            }
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        vtEncoder = session
    }

    // MARK: - Encode paths (on `queue`)

    /// Opt-in raw passthrough: ScreenCaptureKit already captures NV12,
    /// so we can forward the planes uncompressed and skip the encoder entirely.
    /// This removes all decode cost on the receiver — useful when the receiver is
    /// an older Intel Mac whose HEVC decoder struggles at high resolutions — at
    /// the price of much higher bandwidth (~10.6 Gb/s for 5K@60 4:2:0), which a
    /// direct Thunderbolt Bridge link comfortably sustains.
    /// SCStream capture path. Must be dispatched onto `queue` by the caller.
    func encode(_ sampleBuffer: CMSampleBuffer) {
        guard running, !suspended, CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        idleFrameRefresh.capture(pixelBuffer, now: ProcessInfo.processInfo.systemUptime)
        if usesRawNV12 {
            sendRawFrame(pixelBuffer)
            return
        }
        guard let encoder = vtEncoder else { return }
        guard canEncodeNextFrame() else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    /// CGDisplayStream capture path. Delivered directly on `queue` by
    /// `TBDirectDisplayStreamCapture`.
    func encodeDisplaySurface(_ surface: IOSurfaceRef, displayTime: UInt64) {
        markCaptureFrame()
        lock.lock(); _capturedFrames += 1; lock.unlock()
        guard running, !suspended, let encoder = vtEncoder else { return }
        guard canEncodeNextFrame() else { return }

        let attrs: NSDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: preset.width,
            kCVPixelBufferHeightKey: preset.height,
            kCVPixelBufferIOSurfacePropertiesKey: NSDictionary()
        ]
        var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(
            kCFAllocatorDefault,
            surface,
            attrs,
            &unmanagedPixelBuffer
        ) == kCVReturnSuccess, let unmanagedPixelBuffer else {
            return
        }
        let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()

        displayStreamFrameSequence += 1
        // Derive PTS from the frame's actual capture time. CGDisplayStream
        // delivers frames irregularly (event-driven on screen changes), so a
        // frame-counter PTS would drift away from real wall-clock time over a
        // long session and pace the receiver progressively wrong. displayTime is
        // in mach-absolute units, the same host clock the SCStream path uses.
        let pts = displayTime != 0
            ? CMClockMakeHostTimeFromSystemUnits(displayTime)
            : CMClockGetTime(CMClockGetHostTimeClock())
        encode(pixelBuffer: pixelBuffer, presentationTimeStamp: pts, using: encoder)
    }

    private func encode(pixelBuffer: CVPixelBuffer, presentationTimeStamp pts: CMTime, using encoder: VTCompressionSession) {
        var pts = pts
        if let last = lastEncodedDisplayPTS, CMTimeCompare(pts, last) <= 0 {
            pts = CMTimeAdd(last, CMTime(value: 1, timescale: 600))
        }
        lastEncodedDisplayPTS = pts
        inFlightEncodeFrames += 1
        let status = VTCompressionSessionEncodeFrame(
            encoder,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: .invalid,
            frameProperties: sendGate.needsKeyframe
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        if status != noErr {
            lock.lock(); _lastEncoderStatus = status; lock.unlock()
            inFlightEncodeFrames = max(0, inFlightEncodeFrames - 1)
            sendGate.requireKeyframe()
        }
    }

    private func handleEncoded(_ sampleBuffer: CMSampleBuffer) {
        guard running, !suspended else { return }


        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        let isKeyframe = !notSync

        guard let frame = buildFramePacket(from: sampleBuffer) else { sendGate.requireKeyframe(); return }
        var packet = Data()
        if isKeyframe {
            guard let format = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let parameters = buildParamSetsPacket(from: format, codecType: codecType)
            else { sendGate.requireKeyframe(); return }
            // Count the parameter sets together with the dependent keyframe.
            packet.append(parameters)
        }
        packet.append(frame)
        submitVideo(packet, keyframe: isKeyframe, compressed: true)
    }

    private func submitVideo(_ media: Data, keyframe: Bool, compressed: Bool) {
        guard !suspended else { return }
        var packet = Data()
        if !ackSent {
            let ack = TBMonitorCreateSessionAck(accepted: true, displayName: displayName, displayID: displayID)
            guard let acknowledgement = TBMonitorProtocol.makeJSONPacket(type: .createSessionAck, value: ack)
            else { return }
            packet.append(acknowledgement)
        }
        packet.append(media)
        guard packetRateLimiter.admit(bytes: packet.count, now: ProcessInfo.processInfo.systemUptime) else {
            droppedFrames += 1
            if compressed { sendGate.requireKeyframe() }
            observeCongestion(true)
            return
        }
        guard let ticket = sendGate.admit(bytes: packet.count, keyframe: keyframe, compressed: compressed) else {
            droppedFrames += 1
            observeCongestion(true)
            return
        }
        if !ackSent {
            ackSent = true
            onFirstFrame()
        }
        let started = ProcessInfo.processInfo.systemUptime
        submittedVideoBytes &+= UInt64(packet.count)
        connection.send(content: packet, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.sendGate.complete(ticket)
                guard self.running else { return }
                if error != nil {
                    self.running = false
                    self.onFailure()
                } else {
                    self.observeCongestion(ProcessInfo.processInfo.systemUptime - started > 0.1)
                }
            }
        })
        lock.lock(); _sentFrames += 1; lock.unlock()
    }

    /// Raw passthrough: package the two NV12 planes of the captured pixel buffer
    /// and send them uncompressed. The receiver blits them directly (no decode).
    /// Payload: [1: format=1(NV12)][BE32 w][BE32 h][BE32 yStride][BE32 uvStride]
    ///          [Y plane: yStride*h][CbCr plane: uvStride*(h/2)]
    private func sendRawFrame(_ pixelBuffer: CVPixelBuffer) {
        guard running else { return }
        // Backpressure: never pile frames on top of a network that can't keep up.
        if pendingVideoPackets >= preset.maxPendingVideoPackets { return }
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2 else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
              let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1)
        else { return }
        let width = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)
        let ySize = yStride * height
        let uvSize = uvStride * uvHeight


        var payload = Data(capacity: 17 + ySize + uvSize)
        payload.append(1) // format: NV12
        TBMonitorProtocol.appendBE32(&payload, UInt32(width))
        TBMonitorProtocol.appendBE32(&payload, UInt32(height))
        TBMonitorProtocol.appendBE32(&payload, UInt32(yStride))
        TBMonitorProtocol.appendBE32(&payload, UInt32(uvStride))
        payload.append(UnsafeBufferPointer(start: yBase.assumingMemoryBound(to: UInt8.self), count: ySize))
        payload.append(UnsafeBufferPointer(start: uvBase.assumingMemoryBound(to: UInt8.self), count: uvSize))

        let packet = TBMonitorProtocol.makePacket(type: .rawFrame, payload: payload)
        submitVideo(packet, keyframe: true, compressed: false)
    }

    private func buildParamSetsPacket(from format: CMVideoFormatDescription, codecType: CMVideoCodecType) -> Data? {
        if codecType == kCMVideoCodecType_HEVC {
            var count = 0
            CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([2, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        } else {
            var count = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format,
                parameterSetIndex: 0,
                parameterSetPointerOut: nil,
                parameterSetSizeOut: nil,
                parameterSetCountOut: &count,
                nalUnitHeaderLengthOut: nil
            )
            guard count > 0 else { return nil }

            var payload = Data([1, UInt8(count)])
            for index in 0..<count {
                var pointer: UnsafePointer<UInt8>?
                var size = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format,
                    parameterSetIndex: index,
                    parameterSetPointerOut: &pointer,
                    parameterSetSizeOut: &size,
                    parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil
                )
                guard let pointer else { continue }
                TBMonitorProtocol.appendBE32(&payload, UInt32(size))
                payload.append(UnsafeBufferPointer(start: pointer, count: size))
            }
            return TBMonitorProtocol.makePacket(type: .paramSets, payload: payload)
        }
    }

    private func buildFramePacket(from sampleBuffer: CMSampleBuffer) -> Data? {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return nil }

        var payload = Data(count: totalLength)
        let status = payload.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else {
                return kCMBlockBufferBadCustomBlockSourceErr
            }
            return CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: totalLength,
                destination: baseAddress
            )
        }
        guard status == kCMBlockBufferNoErr else { return nil }
        return TBMonitorProtocol.makePacket(type: .frame, payload: payload)
    }
}

/// Live, frequently-updating session readouts (currently just the FPS counter),
/// split out of `TBDisplaySenderSession` so their ~1 Hz changes only invalidate
/// the small subview that displays them rather than the whole session card.
@MainActor
final class TBSessionLiveMetrics: ObservableObject {
    @Published var senderFPS = 0
}

@MainActor
final class TBDisplaySenderSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
    private static let receiverIPDefaultsKey = "fd.tbdisplaysender.receiverIP"
    private struct SavedExtendedDisplayArrangement {
        let x: Int32
        let y: Int32
        let isRelativeToMainDisplay: Bool
    }

    private static let extendedArrangementDefaultsPrefix = "com.targetbridge.sender.extended-arrangement"

    private static func normalizedPng(for image: NSImage) -> Data? {
        let targetSize = NSSize(width: 32, height: 32)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(targetSize.width),
            pixelsHigh: Int(targetSize.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }

        let context = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context

        // Clear canvas
        NSColor.clear.set()
        NSRect(origin: .zero, size: targetSize).fill()

        // Draw the image centered
        let x = (targetSize.width - image.size.width) / 2
        let y = (targetSize.height - image.size.height) / 2
        image.draw(in: NSRect(x: x, y: y, width: image.size.width, height: image.size.height))

        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    private static let standardCursorPngs: [Data: Int] = {
        let standardCursors: [(Int, NSCursor)] = [
            (0, NSCursor.arrow),
            (1, NSCursor.iBeam),
            (2, NSCursor.pointingHand),
            (3, NSCursor.resizeLeft),
            (3, NSCursor.resizeRight),
            (3, NSCursor.resizeLeftRight),
            (4, NSCursor.resizeUp),
            (4, NSCursor.resizeDown),
            (4, NSCursor.resizeUpDown),
            (5, NSCursor.closedHand),
            (5, NSCursor.openHand),
            (6, NSCursor.crosshair)
        ]
        var dict = [Data: Int]()
        for (type, cursor) in standardCursors {
            if let png = normalizedPng(for: cursor.image) {
                dict[png] = type
            }
        }

        // Dynamically load private system window resize cursors to support macOS window borders perfectly
        let privateCursors: [(Int, String)] = [
            (3, "_windowResizeEastWestCursor"),
            (4, "_windowResizeNorthSouthCursor"),
            (7, "_windowResizeNorthWestSouthEastCursor"),
            (8, "_windowResizeNorthEastSouthWestCursor"),
            (3, "_horizontalResizeCursor"),
            (4, "_verticalResizeCursor")
        ]
        for (type, selName) in privateCursors {
            let sel = NSSelectorFromString(selName)
            if NSCursor.responds(to: sel),
               let cursorObj = NSCursor.perform(sel)?.takeUnretainedValue() as? NSCursor,
               let png = normalizedPng(for: cursorObj.image) {
                dict[png] = type
            }
        }

        return dict
    }()

    let id = UUID()

    init(
        language: TBDisplaySenderLanguage,
        largeCursor: Bool,
        preventDisplaySleep: Bool,
        autoRestartOnWake: Bool,
        audioEnabled: Bool,
        verboseDisplayLogging: Bool = false
    ) {
        self.statusText = TBDisplaySenderStatusState.ready.text(language)
        self.receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        self.captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        self.displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        self.language = language
        self.largeCursor = largeCursor
        self.preventDisplaySleep = preventDisplaySleep
        self.autoRestartOnWake = autoRestartOnWake
        self.audioEnabled = audioEnabled
        self.verboseDisplayLogging = verboseDisplayLogging
        self.streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: .standard1440p,
            source: .desktopMirror,
            language: language
        )
        super.init()
        audioOutputRouteObserver.onChange = { [weak self] _ in self?.updateAudioRouting() }
        audioOutputRouteObserver.start()
        registerWakeObservers()
        registerDisplayReconfigurationCallback()
    }

    deinit {
        for token in wakeObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            DistributedNotificationCenter.default().removeObserver(token)
        }
        if displayReconfigurationCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                Self.displayReconfigurationCallback,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }

    @Published var isConnected = false
    @Published var isStreaming = false
    @Published var statusText: String
    @Published var transportKind: TBTransportKind = .networkLink
    @Published var localInterfaceIP = ""
    @Published var selectedReceiverID = "" {
        didSet {
            if selectedReceiverID.isEmpty {
                receiverIdentityHint = nil
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    @Published var isCableTesting = false
    @Published var cableTestResult: Double? = nil
    private var isCableTestConnection = false
    @Published var receiverIP: String = UserDefaults.standard.string(forKey: receiverIPDefaultsKey) ?? "" {
        didSet {
            UserDefaults.standard.set(receiverIP, forKey: Self.receiverIPDefaultsKey)
            if receiverIP != oldValue {
                receiverIdentityHint = nil
                receiverSupportsHEVCDecodeHint = nil
                receiverInputMonitoringTrustedHint = nil
                receiverAccessibilityTrustedHint = nil
            }
        }
    }
    var shortHostName: String? {
        if let receiver = TBDisplaySenderService.shared.discoveredReceivers.first(where: {
            $0.id == selectedReceiverID ||
            $0.preferredIP == receiverIP ||
            $0.thunderboltIP == receiverIP ||
            $0.networkIP == receiverIP
        }) {
            return receiver.shortHostName
        }
        return nil
    }

    var receiverDisplayName: String {
        if let host = shortHostName {
            return host
        }
        return receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var receiverSubtitle: String {
        var parts: [String] = []
        let ip = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ip.isEmpty {
            parts.append("\(TBDisplaySenderL10n.receiverIP(language)) \(ip)")
        }
        if !receiverPanelText.isEmpty {
            parts.append(receiverPanelText)
        }
        return parts.joined(separator: "\n")
    }

    @Published var audioEnabled: Bool {
        didSet {
            let open = audioSendGate?.setEnabled(shouldSendReceiverAudio) == true
            if !audioEnabled || open { audioIssueKey = "" }
        }
    }
    private let audioOutputRouteObserver = TBAudioOutputRouteObserver()
    private var shouldSendReceiverAudio: Bool {
        audioEnabled && !sleepState.isSleeping && audioOutputRouteObserver.allowsReceiverAudio
    }

    private func updateAudioRouting() {
        audioSendGate?.setEnabled(shouldSendReceiverAudio)
        speakerAudioSource?.select(audioOutputRouteObserver.allowsReceiverAudio ? audioOutputRouteObserver.deviceID : kAudioObjectUnknown)
        if !shouldSendReceiverAudio { audioIssueKey = "" }
    }

    @Published private(set) var receiverSupportsDisplayPower = false
    @Published private(set) var displayPowerPending = false
    @Published private(set) var displayPowerStatusKey = ""
    private var displayPowerRequestedOn: Bool?
    private var displayPowerRequestID: UInt64?
    private var displayPowerTimeout: Task<Void, Never>?
    private var senderPowerRequestID: UInt64?
    private var senderPowerRequestedAwake: Bool?
    private var senderPowerAwakeConfirmed = false
    private var senderPowerTimeout: Task<Void, Never>?
    private var allowSystemSleep: (@MainActor () -> Void)?
    private var sleepState = TBSenderSleepState()
    private var systemPowerObserver: TBSystemPowerObserver?
    private var wakeRecoveryTask: Task<Void, Never>?

    @Published private(set) var receiverSupportsBrightness: Bool? = nil
    @Published private(set) var actualBrightness: Double? = nil
    @Published private(set) var brightnessStatusKey = "sender.brightness.unconfirmed"
    private var applyingBrightnessState = false
    private var pendingBrightness: Double?
    private var brightnessTimeout: Task<Void, Never>?
    @Published var brightness: Double = 1.0 {
        didSet {
            guard !applyingBrightnessState else { return }
            sendBrightnessUpdate()
            scheduleSettingsSync()
        }
    }
    var receiverHiDPI: Bool { activeProfile?.hiDPI ?? true }
    @Published var volume: Double = 0.5 {
        didSet {
            sendVolumeUpdate()
            scheduleSettingsSync()
        }
    }
    var audioAddonAvailable = true
    var receiverSupportsHEVCDecodeHint: Bool?
    var receiverInputMonitoringTrustedHint: Bool?
    var receiverAccessibilityTrustedHint: Bool?
    @Published var senderFPS = 0
    // Live FPS readout. Kept on a dedicated observable so its once-per-second
    // update only re-renders the small FPS subview — not the whole session card
    // or (via the manager's objectWillChange bubble-up) the entire window.
    let liveMetrics = TBSessionLiveMetrics()
    @Published var receiverPanelText: String
    @Published private(set) var removableStorageVolumes: [TBMonitorRemovableVolume] = []
    @Published private(set) var receiverSettingsSyncReady = false
    @Published var virtualDisplayText: String
    @Published var captureDisplayText: String
    @Published var displayStateText: String
    @Published var language: TBDisplaySenderLanguage {
        didSet {
            refreshLocalizedText()
            scheduleSettingsSync()
        }
    }
    @Published var largeCursor: Bool
    @Published var preventDisplaySleep: Bool = true
    @Published var autoRestartOnWake: Bool = true
    @Published var verboseDisplayLogging: Bool = false {
        didSet {
            if verboseDisplayLogging {
                startVerboseLoggingTimer()
            } else {
                stopVerboseLoggingTimer()
            }
        }
    }
    /// When enabled, the virtual display's backing store is sized to the capture
    /// preset instead of the receiver-advertised 5120x2880. Removes the capture-side
    /// downsample and the GPU cost of rendering pixels that get thrown away.
    @Published var matchRenderToStream: Bool = false

    @Published var automaticQuality = true
    private var applyingAutomaticQuality = false
    private var qualityPolicy: TBVideoQualityPolicy?
    @Published var capturePreset: TBDisplayCapturePreset = .legacy1080p60 {
        didSet {
            if !applyingAutomaticQuality && capturePreset != oldValue { automaticQuality = false }
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var captureSource: TBDisplayCaptureSource = .desktopMirror {
        didSet {
            if !isStreaming {
                streamResolutionText = TBDisplaySenderL10n.streamSummary(preset: capturePreset, source: captureSource, language: language)
            }
        }
    }
    @Published var streamResolutionText: String
    var inputRelayActive = false {
        didSet {
            guard inputRelayActive != oldValue else { return }
            applyCursorOverlayMode()
        }
    }
    @Published var inputControlRole: TBInputControlRole = .off {
        didSet {
            inputRelayActive = (inputControlRole == .senderMaster)
            if inputControlRole != .receiverMaster {
                injectedRemoteMouseLocation = nil
                injectedLeftClickTracker.reset()
                releaseInjectedModifiersIfNeeded()
                remoteHeldModifierKeyCodes.removeAll()
                suppressedTriggerKeyCode = nil
            }
        }
    }
    @Published var inputGestureMode: TBInputGestureMode = .native
    /// User-defined receiver-master shortcuts for this session. See
    /// TBInputBinding.
    @Published var inputBindings: [TBInputBinding] = []

    private var connection: NWConnection?
    private let connectionQueue = DispatchQueue(label: "fd.tbmonitor.sender.connection", qos: .userInteractive)
    private var recvBuffer = Data()
    private var receiverSettingsNonce: Data?
    private var sessionAuthenticated = false
    var hasActiveConnection: Bool { connection != nil }
    private var pendingSessionPairingCode: String?
    private var activeSessionPairingCode: String?
    var receiverIdentityHint: String?
    private var sessionSenderNonce: Data?
    private var pendingReceiverIdentity: String?
    private var authenticatedReceiverIdentity: String?
    private var receiverSettingsSchemaVersion: UInt32 = 1
    private var lastSettingsRevisionSent: UInt64 = 0
    private var settingsSyncTask: Task<Void, Never>?

    private var session = ReceiverBackedVirtualDisplaySession()
    private var retainedSleepDisplayKey: String?
    private var speakerAudioSource: TBiMacSpeakerAudioSource?
    @Published private(set) var audioIssueKey = ""
    @Published private(set) var audioQueueSummary = ""
    @Published private(set) var receiverMetricsSummary = ""
    @Published private(set) var screenCaptureAccess = TBScreenCaptureAccess()
    private var audioSendGate: TBBoundedAudioSendGate?
    private var audioSendTimer: DispatchSourceTimer?
    private var activeProfile: TBMonitorDisplayProfile?
    private var activeCodecType: CMVideoCodecType?
    private var activeCodecName: String?

    private var captureDelegate: CaptureDelegate?
    private var scStream: SCStream?
    private var directDisplayStream: TBDirectDisplayStreamCapture?
    private var pipeline: TBVideoPipeline?
    private var captureGeneration = UUID()
    @Published private(set) var videoProtectionSummary = ""

    private var sentSnapshot = 0
    private var sessionAckSent = false
    private var firstFrameRecoveryAttempted = false
    private var fpsTimer: Timer?
    private var heartbeatTimer: Timer?
    private var firstFrameTimer: Timer?
    private var cursorTimer: Timer?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    /// Name of the local interface the current connect attempt is bound to
    /// (e.g. "bridge0"), resolved when dialing. Diagnostic context only.
    private var connectInterfaceName: String?
    /// Last state reported by NWConnection for the current attempt (e.g.
    /// "waiting(No route to host)") — surfaced when a connect fails or times
    /// out so the real reason is not lost.
    private var lastConnectionStateDetail: String?
    private var heartbeatSequence: UInt64 = 0
    private var statusState: TBDisplaySenderStatusState = .ready
    private var streamingActivity: NSObjectProtocol?
    private var lastCheckedCursor: NSCursor?
    private var lastCheckedCursorType: Int = 0
    private var baselineDisplayIDs = Set<CGDirectDisplayID>()
    private var cursorDisplayID: CGDirectDisplayID = kCGNullDirectDisplay
    private var lastCursorPacket: TBMonitorCursor?
    private var injectedRemoteMouseLocation: CGPoint?
    private var injectedLeftClickTracker = TBInjectedClickStateTracker()
    private var injectedCommandDown = false
    private var injectedShiftDown = false
    private var injectedOptionDown = false
    private var injectedControlDown = false
    private var injectedCapsDown = false
    // Tracks the actual modifier keys still held on the receiver while a
    // System Events shortcut is running, so released keys are never restored.
    private var remoteHeldModifierKeyCodes = Set<UInt16>()
    /// While a binding trigger key is held (matched), swallow its key-up so the
    /// raw trigger key never reaches the slave.
    private var suppressedTriggerKeyCode: UInt16?
    private static var cachedSupportsHEVCHardwareEncode: Bool?
    private var receivedInputEventCount: UInt64 = 0
    var onRemoteSwitchRequest: ((Int) -> Void)?
    var onRemoteDeactivateInputRequest: (() -> Void)?
    nonisolated(unsafe) private var wakeObservers: [NSObjectProtocol] = []
    private var isRestartingCaptureAfterWake = false
    nonisolated(unsafe) private var displayReconfigurationCallbackRegistered = false
    private var verboseLoggingTimer: Timer?
    private var captureHealthWatchdog: Timer?

    nonisolated(unsafe) private static let displayReconfigurationCallback: CGDisplayReconfigurationCallBack = { displayID, flags, userInfo in
        guard let userInfo else { return }
        let service = Unmanaged<TBDisplaySenderSession>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                service.handleDisplayReconfiguration(displayID: displayID, flags: flags)
            }
        }
    }

    private final class CaptureDelegate: NSObject, SCStreamOutput, SCStreamDelegate {
        var onFrame: (@Sendable (CMSampleBuffer) -> Void)?
        var onActivity: (@Sendable () -> Void)?
        var onIdle: (@Sendable () -> Void)?
        var onInvalidFrame: (@Sendable () -> Void)?
        var onAudio: (@Sendable (CMSampleBuffer) -> Void)?
        var onError: (@Sendable (Error) -> Void)?

        private static func frameStatus(_ sampleBuffer: CMSampleBuffer) -> SCFrameStatus? {
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
                  let rawStatus = attachments.first?[SCStreamFrameInfo.status] as? Int,
                  let status = SCFrameStatus(rawValue: rawStatus)
            else {
                return nil
            }
            return status
        }

        nonisolated func stream(_ stream: SCStream,
                                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                                of type: SCStreamOutputType) {
            if type == .audio {
                onAudio?(sampleBuffer)
                return
            }
            guard type == .screen else { return }
            onActivity?()
            switch Self.frameStatus(sampleBuffer) {
            case .idle:
                onIdle?()
            case .blank, .suspended, .stopped:
                onInvalidFrame?()
            default:
                onFrame?(sampleBuffer)
            }
        }

        nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
            onError?(error)
        }
    }

    private func setStatus(_ state: TBDisplaySenderStatusState) {
        statusState = state
        statusText = state.text(language)
    }

    private static func probeHEVCHardwareEncoderSupport() -> Bool {
        if let cachedSupportsHEVCHardwareEncode {
            return cachedSupportsHEVCHardwareEncode
        }

        let encoderSpecification: CFDictionary = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder as String: true
        ] as CFDictionary

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: 1920,
            height: 1080,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: encoderSpecification,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )
        if let session {
            VTCompressionSessionInvalidate(session)
        }

        let supported = status == noErr
        cachedSupportsHEVCHardwareEncode = supported
        return supported
    }

    private func resolvedCodecType(for preset: TBDisplayCapturePreset, profile: TBMonitorDisplayProfile?) -> CMVideoCodecType {
        TBVideoQualityPolicy.codec(for: preset,
            receiverHEVC: profile?.supportsHEVCDecode ?? receiverSupportsHEVCDecodeHint ?? false,
            senderHEVC: Self.probeHEVCHardwareEncoderSupport())
    }

    private func codecName(for codecType: CMVideoCodecType) -> String {
        codecType == kCMVideoCodecType_HEVC ? "HEVC" : "H.264"
    }

    private func refreshLocalizedText() {
        statusText = statusState.text(language)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: capturePreset,
            source: captureSource,
            language: language,
            codecName: activeCodecName
        )

        if let profile = activeProfile {
            receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        } else {
            receiverPanelText = TBDisplaySenderL10n.waitingReceiverProfile(language)
        }

        if session.displayID != kCGNullDirectDisplay, !session.displayName.isEmpty {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: session.displayName,
                id: session.displayID,
                language: language
            )
        } else {
            virtualDisplayText = TBDisplaySenderL10n.virtualDisplayNotCreated(language)
        }

        if captureDisplayText.isEmpty
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.italian)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.english)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.german)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.french)
            || captureDisplayText == TBDisplaySenderL10n.captureDisplayNotAvailable(.chinese) {
            captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        }

        if displayStateText.isEmpty
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.italian)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.english)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.german)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.french)
            || displayStateText == TBDisplaySenderL10n.displayStateNotAvailable(.chinese) {
            displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        }
    }

    private func formattedCaptureErrorMessage(for error: Error) -> String {
        let nsError = error as NSError
        let details = "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
        screenCaptureAccess.recordFailure(error)
        NSLog("TargetBridge: capture error %@", details)
        if TBScreenCaptureAccess.isPermissionDenied(error) {
            return TBDisplaySenderL10n.missingScreenRecordingPermission(language: language) + "\n" + details
        }
        return details
    }

    func connect() {
        guard connection == nil, !receiverIP.isEmpty, !localInterfaceIP.isEmpty else { return }
        TBDisplaySenderService.shared.cancelReceiverCommands(forReceiver: receiverIP)
        // This development build connects directly. Address parsing belongs to
        // the network layer, and must never become a request for credentials.
        let pairingCode = TBReceiverPairingCredential.localConnectionCode
        firstFrameRecoveryAttempted = false
        NSLog("TargetBridge: connect version=%@ app=%@ receiver=%@", TBDisplaySenderBuildInfo.versionDisplay, Bundle.main.bundlePath, receiverIP)
        guard TBDisplaySenderService.shared.reserveVideoLink(for: self, videoMbps: capturePreset.videoProtectionMbps,
                                                            cableTest: isCableTestConnection) else {
            setStatus(.connectionFailed(TBDisplaySenderL10n.text("sender.video_protection.budget_unavailable", language)))
            isCableTesting = false
            isCableTestConnection = false
            return
        }
        sessionAuthenticated = false
        resetDisplayPowerControls()
        pendingSessionPairingCode = nil
        activeSessionPairingCode = pairingCode
        sessionSenderNonce = nil
        pendingReceiverIdentity = nil
        authenticatedReceiverIdentity = nil
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        recvBuffer.removeAll(keepingCapacity: false)
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        receiverSettingsNonce = nil
        receiverSettingsSchemaVersion = 1
        removableStorageVolumes = []
        receiverSettingsSyncReady = false
        lastSettingsRevisionSent = 0
        activeProfile = nil
        activeCodecType = nil
        activeCodecName = nil
        lastConnectionStateDetail = nil
        setStatus(.connecting(receiverDisplayName))

        let dialHost: NWEndpoint.Host
        let params: NWParameters
        do {
            (dialHost, params) = try TBWiredConnection.dial(host: receiverIP, localIP: localInterfaceIP)
        } catch {
            let message = error as? TBWiredConnection.Failure == .linkTooSlow ? "sender.network.link_too_slow" : "sender.network.wired_required"
            stop(resetStatusTo: .connectionFailed(TBDisplaySenderL10n.text(message, language)))
            return
        }
        params.allowLocalEndpointReuse = true
        params.serviceClass = .interactiveVideo
        connectInterfaceName = TBConnectionDiagnostics.interfaceName(forLocalIP: localInterfaceIP,
            in: TBConnectionDiagnostics.currentIPv4Interfaces())
        let scopedHost = String(describing: dialHost)
        TBLog.connection.info("connect: dialing \(scopedHost, privacy: .public):\(TBMonitorProtocol.port) from \(self.localInterfaceIP, privacy: .public) (\(self.connectInterfaceName ?? "unknown interface", privacy: .public)) transport=\(self.transportKind.rawValue, privacy: .public)")
        let conn = NWConnection(
            host: dialHost,
            port: NWEndpoint.Port(integerLiteral: TBMonitorProtocol.port),
            using: params
        )
        connection = conn

        conn.stateUpdateHandler = { [weak self, weak conn] state in
            Task { @MainActor [weak self, weak conn] in
                guard let self, let conn, self.connection === conn else { return }
                switch state {
                case .ready:
                    self.connectTimeoutWorkItem?.cancel()
                    self.connectTimeoutWorkItem = nil
                    TBLog.connection.info("connect: ready — \(self.receiverIP, privacy: .public) via \(self.connectInterfaceName ?? "?", privacy: .public)")
                    self.setStatus(.waitingDisplayProfile)
                    self.startHeartbeat()
                    self.startConnectWatchdog()
                    self.receiveLoop(on: conn)
                case .waiting(let error):
                    // The dial cannot proceed yet (no route, host down, cable
                    // unplugged, firewall drop, …). Record and log the real
                    // reason so a later timeout can report it instead of a
                    // bare "Connection timed out".
                    self.lastConnectionStateDetail = "waiting(\(error.localizedDescription))"
                    TBLog.connection.warning("connect: waiting — \(error.localizedDescription, privacy: .public)")
                case .failed(let error):
                    self.lastConnectionStateDetail = "failed(\(error.localizedDescription))"
                    let detail = TBConnectionDiagnostics.failureDetail(
                        receiverHost: self.receiverIP,
                        port: TBMonitorProtocol.port,
                        localIP: self.localInterfaceIP,
                        interfaceName: self.connectInterfaceName,
                        transport: self.transportKind.rawValue,
                        lastNetworkState: nil
                    )
                    TBLog.connection.error("connect: failed — \(error.localizedDescription, privacy: .public); \(detail, privacy: .public)")
                    self.setStatus(.connectionFailed("\(error.localizedDescription) — \(detail)"))
                    self.stop(resetStatusTo: nil)
                case .cancelled:
                    self.isConnected = false
                default:
                    break
                }
            }
        }

        startConnectWatchdog()
        conn.start(queue: connectionQueue)
    }

    func startCableTest() {
        guard !isCableTesting, connection == nil, !isConnected, !receiverIP.isEmpty else { return }
        isCableTesting = true
        cableTestResult = nil
        isCableTestConnection = true
        connect()
    }

    private func performCableTest() async throws -> Double {
        guard let conn = connection else {
            throw NSError(domain: "TBDisplaySenderService", code: -1, userInfo: [NSLocalizedDescriptionKey: "No connection"])
        }

        let totalBytes: Int64 = 20 * 1000 * 1000 * 1000
        let chunkSize = 4 * 1000 * 1000
        let totalChunks = Int(totalBytes / Int64(chunkSize))

        // Pre-allocate the single test packet to avoid memory overhead
        var packet = Data()
        TBMonitorProtocol.appendBE32(&packet, UInt32(1 + chunkSize))
        packet.append(TBMonitorPacketType.testData.rawValue)
        packet.append(Data(repeating: 0, count: chunkSize))
        let testPacket = packet

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let startTime = DispatchTime.now()
                let condition = NSCondition()

                let lock = NSLock()
                var sendError: Error?
                var resumed = false
                var inFlightCount = 0

                func finish(with error: Error?) {
                    lock.lock()
                    defer { lock.unlock() }
                    guard !resumed else { return }
                    resumed = true
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else {
                        let endTime = DispatchTime.now()
                        let nanoTime = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
                        let timeInSeconds = Double(nanoTime) / 1_000_000_000.0

                        // 20 GB = 20,000,000,000 bytes = 160,000,000,000 bits
                        // Decimal Gigabits = bits / 1,000,000,000
                        let totalBits = Double(totalBytes) * 8.0
                        let rate = totalBits / 1_000_000_000.0 / timeInSeconds
                        continuation.resume(returning: rate)
                    }
                }

                for _ in 0..<totalChunks {
                    lock.lock()
                    let err = sendError
                    lock.unlock()
                    if err != nil {
                        break
                    }

                    condition.lock()
                    while inFlightCount >= 8 {
                        lock.lock()
                        let errCheck = sendError
                        lock.unlock()
                        if errCheck != nil {
                            break
                        }
                        if !condition.wait(until: Date().addingTimeInterval(30)) {
                            lock.lock()
                            if sendError == nil {
                                sendError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
                            }
                            lock.unlock()
                            break
                        }
                    }

                    lock.lock()
                    let errCheck2 = sendError
                    lock.unlock()
                    if errCheck2 != nil {
                        condition.unlock()
                        break
                    }

                    inFlightCount += 1
                    condition.unlock()

                    conn.send(content: testPacket, completion: .contentProcessed({ error in
                        if let error = error {
                            lock.lock()
                            if sendError == nil {
                                sendError = error
                            }
                            lock.unlock()
                        }

                        condition.lock()
                        inFlightCount -= 1
                        condition.broadcast()
                        condition.unlock()
                    }))
                }

                // Wait for all outstanding packets to complete (up to 3 seconds)
                let limitDate = Date().addingTimeInterval(3.0)
                condition.lock()
                while inFlightCount > 0 {
                    if !condition.wait(until: limitDate) {
                        lock.lock()
                        if sendError == nil {
                            sendError = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
                        }
                        lock.unlock()
                        break
                    }
                }
                condition.unlock()

                lock.lock()
                let err = sendError
                lock.unlock()

                finish(with: err)
            }
        }
    }

    func stop(persistArrangement: Bool = true) {
        sleepState.cancelResume()
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        stop(resetStatusTo: .stopped, persistArrangement: persistArrangement)
    }

    func persistExtendedDisplayArrangementSnapshot() {
        persistExtendedDisplayArrangementIfNeeded()
    }

    private func stop(resetStatusTo status: TBDisplaySenderStatusState?, persistArrangement: Bool = true) {
        if sleepState.needsResume, let profile = activeProfile, session.displayID != kCGNullDirectDisplay {
            retainedSleepDisplayKey = sleepDisplayKey(for: profile)
        }
        TBDisplaySenderService.shared.releaseVideoLink(for: self)
        captureGeneration = UUID()
        videoProtectionSummary = ""
        sessionAuthenticated = false
        resetDisplayPowerControls()
        pendingSessionPairingCode = nil
        qualityPolicy = nil
        activeSessionPairingCode = nil
        sessionSenderNonce = nil
        pendingReceiverIdentity = nil
        authenticatedReceiverIdentity = nil
        if persistArrangement {
            persistExtendedDisplayArrangementIfNeeded()
        }
        sendTeardown(reason: "sender_stop")
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        receiverSettingsNonce = nil
        receiverSettingsSchemaVersion = 1
        heartbeatTimer?.invalidate()
        heartbeatTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        stopCaptureWatchdog()
        stopVerboseLoggingTimer()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            stream.stopCapture(completionHandler: nil)
            scStream = nil
        }
        speakerAudioSource?.stop(); speakerAudioSource = nil
        audioSendTimer?.cancel(); audioSendTimer = nil
        audioSendGate?.close(); audioSendGate = nil
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        pipeline?.stop()
        pipeline = nil
        releaseInjectedModifiersIfNeeded()
        remoteHeldModifierKeyCodes.removeAll()
        injectedLeftClickTracker.reset()
        suppressedTriggerKeyCode = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        if !sleepState.needsResume {
            retainedSleepDisplayKey = nil
            let currentSession = session
            session = ReceiverBackedVirtualDisplaySession()
            Task { @MainActor in currentSession.destroy() }
        }
        activeProfile = nil
        activeCodecType = nil
        activeCodecName = nil
        isConnected = false
        isStreaming = false
        isCableTesting = false
        isCableTestConnection = false
        isRestartingCaptureAfterWake = false
        if let status {
            setStatus(status)
        }
        refreshLocalizedText()
        liveMetrics.senderFPS = 0
        receiverMetricsSummary = ""
        audioQueueSummary = ""
        sentSnapshot = 0
        sessionAckSent = false
        baselineDisplayIDs = []
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil
        captureDisplayText = TBDisplaySenderL10n.captureDisplayNotAvailable(language)
        displayStateText = TBDisplaySenderL10n.displayStateNotAvailable(language)
        if sleepState.needsResume && !sleepState.isSleeping { startWakeRecovery() }
    }

    /// Stable per-receiver discriminator: the connection address when known
    /// (distinct per machine even when two identical iMacs report the same SDL
    /// display name), falling back to the receiver-reported name.
    private func receiverIdentityDiscriminator(for profile: TBMonitorDisplayProfile) -> String {
        if let identity = authenticatedReceiverIdentity { return identity }
        let trimmedIP = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedIP.isEmpty ? profile.receiverName : trimmedIP
    }

    /// Key used to derive the extended-desktop virtual display identity. Shares
    /// the same receiver discriminator as the saved-arrangement key so a given
    /// receiver maps to one stable virtual display identity across reconnects.
    private func extendedDisplayIdentityKey(for profile: TBMonitorDisplayProfile) -> String {
        "\(receiverIdentityDiscriminator(for: profile))|\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func sleepDisplayKey(for profile: TBMonitorDisplayProfile) -> String {
        "\(extendedDisplayIdentityKey(for: profile))|\(captureSource.rawValue)|\(profile.modeWidth)x\(profile.modeHeight)|\(profile.hiDPI)|\(capturePreset.virtualDisplayRefreshRate)"
    }

    private func extendedArrangementDefaultsKey(for profile: TBMonitorDisplayProfile) -> String {
        let normalizedIdentity = receiverIdentityDiscriminator(for: profile).replacingOccurrences(
            of: #"[^A-Za-z0-9._-]+"#,
            with: "-",
            options: .regularExpression
        )
        return "\(Self.extendedArrangementDefaultsPrefix).\(normalizedIdentity).\(profile.panelWidth)x\(profile.panelHeight)"
    }

    private func loadSavedExtendedDisplayArrangement(for profile: TBMonitorDisplayProfile) -> SavedExtendedDisplayArrangement? {
        let key = extendedArrangementDefaultsKey(for: profile)
        var storedValue = UserDefaults.standard.dictionary(forKey: key)
        if storedValue == nil, authenticatedReceiverIdentity != nil {
            let address = receiverIP.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#, with: "-", options: .regularExpression)
            let oldKey = "\(Self.extendedArrangementDefaultsPrefix).\(address).\(profile.panelWidth)x\(profile.panelHeight)"
            storedValue = UserDefaults.standard.dictionary(forKey: oldKey)
            if let storedValue { UserDefaults.standard.set(storedValue, forKey: key) }
        }
        guard let stored = storedValue else { return nil }

        if let dx = stored["dx"] as? Int,
           let dy = stored["dy"] as? Int {
            return SavedExtendedDisplayArrangement(
                x: Int32(dx),
                y: Int32(dy),
                isRelativeToMainDisplay: true
            )
        }

        guard let x = stored["x"] as? Int,
              let y = stored["y"] as? Int
        else {
            return nil
        }
        return SavedExtendedDisplayArrangement(
            x: Int32(x),
            y: Int32(y),
            isRelativeToMainDisplay: false
        )
    }

    private func persistExtendedDisplayArrangementIfNeeded() {
        guard captureSource == .extendedDesktop,
              let profile = activeProfile,
              session.displayID != kCGNullDirectDisplay,
              CGDisplayIsInMirrorSet(session.displayID) == 0
        else { return }

        let bounds = CGDisplayBounds(session.displayID)
        let mainBounds = CGDisplayBounds(CGMainDisplayID())
        let key = extendedArrangementDefaultsKey(for: profile)
        let payload: [String: Int] = [
            "dx": Int((bounds.origin.x - mainBounds.origin.x).rounded()),
            "dy": Int((bounds.origin.y - mainBounds.origin.y).rounded()),
            "x": Int(bounds.origin.x.rounded()),
            "y": Int(bounds.origin.y.rounded())
        ]
        UserDefaults.standard.set(payload, forKey: key)
    }

    private func sendHello() {
        let name = Host.current().localizedName ?? "MacBook"
        let preset = capturePreset
        let helloCodecType = resolvedCodecType(for: preset, profile: activeProfile)
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .helloReceiver,
            value: TBMonitorHelloReceiver(
                senderName: name,
                uiLanguage: language.fileStem,
                capturePreset: preset.title,
                captureSource: captureSource.title(language),
                captureWidth: preset.width,
                captureHeight: preset.height,
                codec: codecName(for: helloCodecType)
            )
        ) else { return }
        send(packet)
    }

    private func sendInputControlModeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .inputControlMode,
            value: TBMonitorInputControlMode(mode: inputControlRole.rawValue)
        ) else { return }
        TBInputDebugLog.log("sender send control mode update \(inputControlRole.rawValue) to \(receiverIP)")
        send(packet)
    }

    private func resetDisplayPowerControls() {
        finishSenderPowerRequest()
        senderPowerAwakeConfirmed = false
        displayPowerTimeout?.cancel()
        displayPowerTimeout = nil
        displayPowerRequestedOn = nil
        displayPowerRequestID = nil
        displayPowerPending = false
        receiverSupportsDisplayPower = false
        receiverSupportsBrightness = nil; actualBrightness = nil; pendingBrightness = nil
        brightnessTimeout?.cancel(); brightnessTimeout = nil
        brightnessStatusKey = "sender.brightness.unconfirmed"
        displayPowerStatusKey = ""
    }

    func requestReceiverDisplayPower(displayOn: Bool) {
        guard sessionAuthenticated, receiverSupportsDisplayPower, !displayPowerPending,
              connection != nil else { return }
        let requestID = UInt64.random(in: 1...UInt64.max)
        displayPowerRequestID = requestID
        displayPowerRequestedOn = displayOn
        displayPowerPending = true
        displayPowerStatusKey = "sender.display_power.pending"
        send(TBMonitorDisplayPower.command(displayOn: displayOn, requestID: requestID))
        displayPowerTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard let self, self.displayPowerPending else { return }
            self.displayPowerPending = false
            self.displayPowerRequestedOn = nil
            self.displayPowerRequestID = nil
            self.displayPowerStatusKey = "sender.display_power.failed"
            self.displayPowerTimeout = nil
        }
    }

    private func finishSenderPowerRequest() {
        senderPowerTimeout?.cancel()
        senderPowerTimeout = nil
        senderPowerRequestID = nil
        senderPowerRequestedAwake = nil
        allowSystemSleep?()
        allowSystemSleep = nil
    }

    private func sendSenderPowerState(awake: Bool, allowSleep: (@MainActor () -> Void)? = nil) {
        finishSenderPowerRequest()
        guard sessionAuthenticated, activeProfile?.supportsSenderPower == true, let connection else {
            allowSleep?()
            return
        }
        let requestID = UInt64.random(in: 1...UInt64.max)
        senderPowerRequestID = requestID
        senderPowerRequestedAwake = awake
        senderPowerAwakeConfirmed = false
        allowSystemSleep = allowSleep
        connection.send(content: TBMonitorDisplayPower.command(displayOn: awake, requestID: requestID, senderState: true),
            completion: .contentProcessed { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.senderPowerRequestID == requestID else { return }
                    self.displayPowerStatusKey = "sender.display_power.failed"
                    self.finishSenderPowerRequest()
                }
            })
        senderPowerTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard let self, self.senderPowerRequestID == requestID else { return }
            self.displayPowerStatusKey = "sender.display_power.failed"
            self.finishSenderPowerRequest()
        }
    }

    private func sendBrightnessUpdate() {
        guard sessionAuthenticated, receiverSupportsBrightness != false, brightness.isFinite, (0...1).contains(brightness) else { return }
        pendingBrightness = brightness
        brightnessStatusKey = "sender.brightness.pending"
        brightnessTimeout?.cancel()
        brightnessTimeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
            self?.pendingBrightness = nil
            self?.brightnessStatusKey = "sender.brightness.unconfirmed"
        }
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .brightness,
            value: TBMonitorBrightness(level: brightness)
        ) else { return }
        send(packet)
    }

    private func sendVolumeUpdate() {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .volume,
            value: TBMonitorVolume(level: volume)
        ) else { return }
        send(packet)
    }

    /// Re-sends this session's settings after the user saves a pairing code.
    func syncReceiverSettingsNow() {
        settingsSyncTask?.cancel()
        settingsSyncTask = nil
        sendSettingsSync()
    }

    private func scheduleSettingsSync() {
        guard receiverSettingsNonce != nil else { return }
        settingsSyncTask?.cancel()
        settingsSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.sendSettingsSync()
        }
    }

    private func sendSettingsSync() {
        let schemaVersion = receiverSettingsSchemaVersion
        let sleepAfterNoSignalSeconds = schemaVersion >= 2
            ? UInt32(TBDisplaySenderService.shared.receiverNoSignalSleepSeconds)
            : nil
        guard isConnected,
              let nonce = receiverSettingsNonce,
              let pairingCode = activeSessionPairingCode,
              let message = TBMonitorProtocol.settingsAuthenticationMessage(
                nonce: nonce,
                schemaVersion: schemaVersion,
                revision: nextSettingsRevision(),
                brightness: brightness,
                volume: volume,
                language: language.fileStem,
                sleepAfterNoSignalSeconds: sleepAfterNoSignalSeconds
              ) else { return }

        let revision = lastSettingsRevisionSent
        let key = SymmetricKey(data: Data(pairingCode.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: message, using: key)
        let hmac = digest.map { String(format: "%02x", $0) }.joined()
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .settingsSync,
            value: TBMonitorSettingsSync(
                schemaVersion: Int(schemaVersion),
                revision: revision,
                brightness: brightness,
                volume: volume,
                language: language.fileStem,
                sleepAfterNoSignalSeconds: sleepAfterNoSignalSeconds,
                hmac: hmac
            )
        ) else { return }
        send(packet)
    }

    private func nextSettingsRevision() -> UInt64 {
        let key = "com.revoyage.sender.receiver-settings-revision.v1"
        let persisted = UserDefaults.standard.object(forKey: key) as? UInt64 ?? 0
        lastSettingsRevisionSent = max(lastSettingsRevisionSent, persisted) &+ 1
        UserDefaults.standard.set(lastSettingsRevisionSent, forKey: key)
        return lastSettingsRevisionSent
    }

    private func dataFromHex(_ value: String) -> Data? {
        guard value.count.isMultiple(of: 2) else { return nil }
        var result = Data(capacity: value.count / 2)
        var index = value.startIndex
        while index < value.endIndex {
            let next = value.index(index, offsetBy: 2)
            guard let byte = UInt8(value[index..<next], radix: 16) else { return nil }
            result.append(byte)
            index = next
        }
        return result
    }

    func sendClipboardText(_ text: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .clipboard,
            value: TBMonitorClipboard(text: text)
        ) else { return }
        send(packet)
    }

    private func sendHeartbeat() {
        heartbeatSequence += 1
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .heartbeat,
            value: TBMonitorHeartbeat(sequence: heartbeatSequence)
        ) else { return }
        send(packet)
    }

    private func sendTeardown(reason: String) {
        guard let packet = TBMonitorProtocol.makeJSONPacket(
            type: .teardown,
            value: TBMonitorTeardown(reason: reason)
        ) else { return }
        send(packet)
    }

    private func receiveLoop(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, error in
            Task { @MainActor [weak self] in
                guard let self, self.connection === connection else { return }
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.drainPackets()
                }
                if error != nil || isDone {
                    if let error {
                        self.setStatus(.connectionClosed(error.localizedDescription))
                    } else if case .startingCapture = self.statusState {
                        self.setStatus(.receiverClosedDuringCapture)
                    } else if case .captureActive = self.statusState {
                        self.setStatus(.receiverClosedConnection)
                    }
                    self.stop(resetStatusTo: nil)
                    return
                }
                self.receiveLoop(on: connection)
            }
        }
    }

    private func drainPackets() {
        do {
            try drainPacketsOrThrow()
        } catch {
            // Corrupt length prefix: the framing is unrecoverable, so tear the
            // connection down instead of buffering inbound data forever.
            TBLog.connection.error("corrupt inbound stream (\(String(describing: error), privacy: .public)); closing connection")
            recvBuffer.removeAll(keepingCapacity: false)
            setStatus(.connectionClosed(String(describing: error)))
            stop(resetStatusTo: nil)
        }
    }

    private func drainPacketsOrThrow() throws {
        while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &recvBuffer) {
            guard sessionAuthenticated || type == .settingsChallenge || type == .sessionAuthAck else {
                setStatus(.connectionFailed("Receiver does not support required session authentication."))
                stop(resetStatusTo: nil)
                return
            }
            switch type {
            case .settingsChallenge:
                guard let challenge = TBMonitorProtocol.decodeJSON(TBMonitorSettingsChallenge.self, from: payload),
                      !sessionAuthenticated,
                      pendingSessionPairingCode == nil,
                      challenge.requiresSessionAuthentication == true,
                      challenge.schemaVersion == 1,
                      (1...2).contains(challenge.supportedSchemaVersion ?? challenge.schemaVersion),
                      let nonce = dataFromHex(challenge.nonce), nonce.count == 32,
                      let pairingCode = activeSessionPairingCode else {
                    setStatus(.connectionFailed("Receiver connection negotiation is invalid or unsupported."))
                    stop(resetStatusTo: nil)
                    return
                }
                do {
                    pendingReceiverIdentity = try TBMonitorProtocol.verifiedReceiverIdentity(
                        challenge: challenge, nonce: nonce, pairingCode: pairingCode,
                        expectedIdentity: TBReceiverPairingCredential.pairingRequired
                            ? (TBReceiverPairingCredential.expectedIdentity(forReceiver: receiverIP) ?? receiverIdentityHint) : nil)
                } catch {
                    setStatus(.connectionFailed("Receiver identity verification failed."))
                    stop(resetStatusTo: nil)
                    return
                }
                sessionSenderNonce = pendingReceiverIdentity == nil ? nil : TBMonitorProtocol.freshSenderNonce()
                guard let proof = TBMonitorProtocol.sessionAuthenticationDigest(nonce: nonce, pairingCode: pairingCode,
                    receiverProof: false, senderNonce: sessionSenderNonce, receiverIdentity: pendingReceiverIdentity) else {
                    stop(resetStatusTo: .connectionFailed("Receiver identity proof is invalid.")); return
                }
                receiverSettingsNonce = nonce
                pendingSessionPairingCode = pairingCode
                receiverSettingsSchemaVersion = UInt32(challenge.supportedSchemaVersion ?? challenge.schemaVersion)
                settingsSyncTask?.cancel()
                settingsSyncTask = nil
                send(TBMonitorProtocol.makePacket(type: .sessionAuth, payload: (sessionSenderNonce ?? Data()) + proof))
            case .sessionAuthAck:
                guard !sessionAuthenticated,
                      let nonce = receiverSettingsNonce,
                      let pairingCode = pendingSessionPairingCode,
                      TBMonitorProtocol.verifySessionAuthenticationResponse(payload, nonce: nonce, pairingCode: pairingCode, senderNonce: sessionSenderNonce, receiverIdentity: pendingReceiverIdentity)
                else {
                    setStatus(.connectionFailed("Receiver connection negotiation failed. Update both ends to the direct-connection build."))
                    stop(resetStatusTo: nil)
                    return
                }
                if let identity = pendingReceiverIdentity {
                    let identitySaved = TBReceiverPairingCredential.bindAuthenticatedIdentity(identity, code: pairingCode, host: receiverIP)
                    if TBReceiverPairingCredential.pairingRequired && !identitySaved {
                        setStatus(.connectionFailed("Could not save authenticated receiver identity."))
                        stop(resetStatusTo: nil)
                        return
                    }
                    TBDisplaySenderService.shared.migrateDisplayProfileAfterAuthentication(host: receiverIP, identity: identity)
                    authenticatedReceiverIdentity = identity
                }
                sessionAuthenticated = true
                pendingSessionPairingCode = nil
                isConnected = true
                connectTimeoutWorkItem?.cancel()
                connectTimeoutWorkItem = nil
                sendHello()
                sendInputControlModeUpdate()
                sendVolumeUpdate()
            case .receiverMetrics:
                guard let metrics = TBMonitorProtocol.decodeJSON(TBMonitorReceiverMetrics.self, from: payload), metrics.isValid else { continue }
                if automaticQuality, isStreaming, !metrics.raw, canRestartCapture,
                   let next = qualityPolicy?.consume(metrics, preset: capturePreset, now: ProcessInfo.processInfo.systemUptime) {
                    applyingAutomaticQuality = true
                    capturePreset = next
                    applyingAutomaticQuality = false
                    sendHello()
                    scheduleCaptureRestart(reason: "automatic receiver quality adjustment", delaySeconds: 0)
                }
                let decodeKey = metrics.raw ? "raw" : metrics.hardwareDecode == 1 ? "hardware" : metrics.hardwareDecode == 0 ? "software" : "unknown"
                receiverMetricsSummary = TBDisplaySenderL10n.text("sender.receiver_metrics", language, [
                    "decode": TBDisplaySenderL10n.text("sender.decode." + decodeKey, language),
                    "received": String(metrics.received), "decoded": String(metrics.uploaded),
                    "presented": String(metrics.submitted), "age": String(metrics.sinceSubmitMs),
                    "audio": String(metrics.audioBytes / 1024), "errors": String(metrics.decodeErrors)])
            case .brightnessState:
                guard let state = TBMonitorProtocol.decodeJSON(TBMonitorBrightnessState.self, from: payload), state.isValid else { continue }
                receiverSupportsBrightness = state.supported
                actualBrightness = state.actualLevel
                if let requested = state.requestedLevel, let pending = pendingBrightness,
                   abs(requested - pending) > 0.000001 { continue }
                if pendingBrightness != nil && state.accepted == nil { continue }
                if state.accepted != nil {
                    brightnessTimeout?.cancel(); brightnessTimeout = nil; pendingBrightness = nil
                }
                if state.accepted != nil || !state.supported || brightnessStatusKey != "sender.brightness.failed" {
                    brightnessStatusKey = !state.supported ? "sender.brightness.unsupported" :
                        state.accepted == false ? "sender.brightness.failed" : "sender.brightness.actual"
                }
                if let actual = state.actualLevel {
                    applyingBrightnessState = true; brightness = actual; applyingBrightnessState = false
                }
                if receiverSettingsSyncReady == false { scheduleSettingsSync() }
            case .displayPowerAck:
                guard let ack = TBMonitorDisplayPower.acknowledgement(payload),
                      displayPowerPending, displayPowerRequestedOn == ack.displayOn,
                      displayPowerRequestID == ack.requestID else { continue }
                displayPowerTimeout?.cancel()
                displayPowerTimeout = nil
                displayPowerRequestedOn = nil
                displayPowerRequestID = nil
                displayPowerPending = false
                displayPowerStatusKey = ack.accepted
                    ? (ack.displayOn ? "sender.display_power.wake_accepted" : "sender.display_power.off_accepted")
                    : "sender.display_power.failed"
            case .senderPowerAck:
                guard let ack = TBMonitorDisplayPower.acknowledgement(payload),
                      senderPowerRequestID == ack.requestID,
                      senderPowerRequestedAwake == ack.displayOn else { continue }
                senderPowerAwakeConfirmed = ack.accepted && ack.displayOn
                displayPowerStatusKey = ack.accepted
                    ? (ack.displayOn ? "sender.display_power.wake_accepted" : "sender.display_power.off_accepted")
                    : "sender.display_power.failed"
                finishSenderPowerRequest()
            case .settingsAck:
                if let ack = TBMonitorProtocol.decodeJSON(TBMonitorSettingsAck.self, from: payload) {
                    if ack.accepted {
                        receiverSettingsSyncReady = true
                        TBLog.connection.info("receiver settings synced at revision \(ack.revision, privacy: .public)")
                    } else {
                        TBLog.connection.warning("receiver rejected settings revision \(ack.revision, privacy: .public): \(ack.reason ?? "unknown", privacy: .public)")
                    }
                }
            case .removableVolumes:
                guard let snapshot = TBMonitorProtocol.decodeJSON(TBMonitorRemovableVolumeSnapshot.self, from: payload),
                      TBMonitorProtocol.isValidRemovableVolumeSnapshot(snapshot) else {
                    TBLog.connection.warning("receiver sent an invalid removable-volume snapshot")
                    continue
                }
                removableStorageVolumes = snapshot.volumes.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            case .displayProfile:
                handleDisplayProfile(payload)
            case .inputEvent:
                if inputControlRole == .receiverMaster,
                   let event = TBMonitorProtocol.decodeJSON(TBMonitorInputEvent.self, from: payload) {
                    receivedInputEventCount += 1
                    if receivedInputEventCount <= 20 || receivedInputEventCount.isMultiple(of: 100) {
                        TBInputDebugLog.log("sender received #\(receivedInputEventCount) kind=\(event.kind) dx=\(event.dx ?? 0) dy=\(event.dy ?? 0) sx=\(event.scrollX ?? 0) sy=\(event.scrollY ?? 0) key=\(event.keyCode ?? 0)")
                    }
                    if event.kind == "switchPrevTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(-1)
                    } else if event.kind == "switchNextTarget" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteSwitchRequest?(1)
                    } else if event.kind == "switchPrevSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: -1)
                    } else if event.kind == "switchNextSpace" {
                        releaseInjectedModifiersIfNeeded()
                        postLocalSpaceSwitch(direction: 1)
                    } else if event.kind == "deactivateInputControl" {
                        releaseInjectedModifiersIfNeeded()
                        onRemoteDeactivateInputRequest?()
                    } else {
                        applyIncomingInputEvent(event)
                    }
                }
            case .heartbeat:
                break
            case .teardown:
                setStatus(.receiverTerminatedSession)
                stop(resetStatusTo: nil)
                return
            case .clipboard:
                if let clipboard = TBMonitorProtocol.decodeJSON(TBMonitorClipboard.self, from: payload) {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(clipboard.text, forType: .string)
                }
            default:
                break
            }
        }
    }

    private func currentLocalMouseLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    // Bounds of every active display, in the Quartz global coordinate space
    // (top-left origin) — matching CGEvent locations and CGWarpMouseCursorPosition.
    // NSScreen.frame uses AppKit's bottom-left origin and must not be mixed in here.
    private func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    private func screenFrame(containing point: CGPoint) -> CGRect? {
        activeDisplayBounds().first(where: { $0.contains(point) })
    }

    private func clampedMouseTarget(from current: CGPoint, dx: Int, dy: Int) -> CGPoint {
        let rawTarget = CGPoint(x: current.x + CGFloat(dx), y: current.y + CGFloat(dy))
        let displays = activeDisplayBounds()
        guard !displays.isEmpty else { return rawTarget }

        // If the target lands on any display, allow it unchanged. This lets the
        // relayed cursor cross from one screen onto an adjacent one (e.g. the
        // receiver-backed virtual extended display), matching how the pointer
        // behaves with the local touchpad. Clamping to a single screen's bounds
        // previously trapped the pointer on the sender's main display (issue #97).
        if displays.contains(where: { $0.contains(rawTarget) }) {
            return rawTarget
        }

        // Off every display: keep the pointer on the display it is currently on so
        // the injected cursor can never get lost in a gap between displays.
        let frame = displays.first(where: { $0.contains(current) }) ?? displays[0]
        let minX = frame.minX
        let maxX = frame.maxX - 1
        let minY = frame.minY
        let maxY = frame.maxY - 1

        return CGPoint(
            x: min(max(rawTarget.x, minX), maxX),
            y: min(max(rawTarget.y, minY), maxY)
        )
    }

    private func localInputEventSource() -> CGEventSource? {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.localEventsSuppressionInterval = 0
        return source
    }

    private func logLocalInputInjectionStateIfNeeded(context: String) {
        let trusted = AXIsProcessTrusted()
        TBInputDebugLog.log("sender input injection state trusted=\(trusted) context=\(context)")
    }

    private func postLocalMouseMove(dx: Int, dy: Int, type: CGEventType = .mouseMoved, button: CGMouseButton = .left) {
        logLocalInputInjectionStateIfNeeded(context: "mouseMove")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        let target = clampedMouseTarget(from: current, dx: dx, dy: dy)
        injectedRemoteMouseLocation = target
        let shouldWarp = (type == .mouseMoved)
        if shouldWarp {
            CGWarpMouseCursorPosition(target)
        }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: target, mouseButton: button) else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        event.post(tap: .cghidEventTap)

        // Auto-hidden menu bar / Dock reveal on macOS depends on the pointer
        // really landing on a screen edge. A second edge-pinned move helps the
        // system treat relayed motion like a native "push against the border".
        if type == .mouseMoved,
           let frame = screenFrame(containing: target),
           target.x <= frame.minX || target.x >= frame.maxX - 1 ||
           target.y <= frame.minY || target.y >= frame.maxY - 1,
           let edgeEvent = CGEvent(mouseEventSource: localInputEventSource(), mouseType: .mouseMoved, mouseCursorPosition: target, mouseButton: button) {
            edgeEvent.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
            edgeEvent.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
            edgeEvent.post(tap: .cghidEventTap)
        }
    }

    private func postLocalMouseButton(type: CGEventType, button: CGMouseButton) {
        logLocalInputInjectionStateIfNeeded(context: "mouseButton")
        guard let current = injectedRemoteMouseLocation ?? currentLocalMouseLocation() else { return }
        guard let event = CGEvent(mouseEventSource: localInputEventSource(), mouseType: type, mouseCursorPosition: current, mouseButton: button) else { return }
        if button == .left {
            let clickState: Int
            if type == .leftMouseDown {
                clickState = injectedLeftClickTracker.registerClick(
                    at: current,
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    doubleClickInterval: NSEvent.doubleClickInterval
                )
            } else {
                clickState = max(injectedLeftClickTracker.currentClickState, 1)
            }
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickState))
        }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalScroll(scrollX: Int, scrollY: Int) {
        guard let wheelX = Int32(exactly: scrollX), let wheelY = Int32(exactly: scrollY) else { return }
        logLocalInputInjectionStateIfNeeded(context: "scroll")
        guard let event = CGEvent(
            scrollWheelEvent2Source: localInputEventSource(),
            units: .line,
            wheelCount: 2,
            wheel1: wheelY,
            wheel2: wheelX,
            wheel3: 0
        ) else { return }
        event.post(tap: .cghidEventTap)
    }

    private func postLocalKey(keyCode: UInt16, isDown: Bool) {
        logLocalInputInjectionStateIfNeeded(context: "key")
        switch keyCode {
        case 54, 55: injectedCommandDown = isDown
        case 56, 60: injectedShiftDown = isDown
        case 58, 61: injectedOptionDown = isDown
        case 59, 62: injectedControlDown = isDown
        case 57: injectedCapsDown = isDown
        default: break
        }
        guard let event = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(keyCode), keyDown: isDown) else { return }
        event.flags = currentInjectedModifierFlags()
        event.post(tap: .cghidEventTap)
    }

    private func currentInjectedModifierFlags() -> CGEventFlags {
        var flags: CGEventFlags = []
        if injectedCommandDown {
            flags.insert(.maskCommand)
        }
        if injectedShiftDown {
            flags.insert(.maskShift)
        }
        if injectedOptionDown {
            flags.insert(.maskAlternate)
        }
        if injectedControlDown {
            flags.insert(.maskControl)
        }
        if injectedCapsDown {
            flags.insert(.maskAlphaShift)
        }
        return flags
    }

    private func releaseInjectedModifiersIfNeeded() {
        if injectedCommandDown {
            postLocalKey(keyCode: 55, isDown: false)
            injectedCommandDown = false
        }
        if injectedShiftDown {
            postLocalKey(keyCode: 56, isDown: false)
            injectedShiftDown = false
        }
        if injectedOptionDown {
            postLocalKey(keyCode: 58, isDown: false)
            injectedOptionDown = false
        }
        if injectedControlDown {
            postLocalKey(keyCode: 59, isDown: false)
            injectedControlDown = false
        }
        if injectedCapsDown {
            postLocalKey(keyCode: 57, isDown: false)
            injectedCapsDown = false
        }
    }

    private func postLocalSpaceSwitch(direction: Int) {
        logLocalInputInjectionStateIfNeeded(context: "spaceSwitch")

        let controlKeyCode: UInt16 = 59
        let arrowKeyCode: UInt16 = direction < 0 ? 123 : 124

        guard let controlDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: true),
              let arrowDown = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: true),
              let arrowUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(arrowKeyCode), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: localInputEventSource(), virtualKey: CGKeyCode(controlKeyCode), keyDown: false)
        else {
            return
        }

        controlDown.flags = .maskControl
        arrowDown.flags = .maskControl
        arrowUp.flags = .maskControl
        controlUp.flags = []

        controlDown.post(tap: .cghidEventTap)
        arrowDown.post(tap: .cghidEventTap)
        arrowUp.post(tap: .cghidEventTap)
        controlUp.post(tap: .cghidEventTap)
    }

    private func applyIncomingInputEvent(_ event: TBMonitorInputEvent) {
        TBInputDebugLog.log("sender applying incoming event kind=\(event.kind)")
        switch event.kind {
        case "move":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0)
        case "leftDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .leftMouseDragged, button: .left)
        case "rightDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .rightMouseDragged, button: .right)
        case "otherDrag":
            postLocalMouseMove(dx: event.dx ?? 0, dy: event.dy ?? 0, type: .otherMouseDragged, button: .center)
        case "leftDown":
            postLocalMouseButton(type: .leftMouseDown, button: .left)
        case "leftUp":
            postLocalMouseButton(type: .leftMouseUp, button: .left)
        case "rightDown":
            postLocalMouseButton(type: .rightMouseDown, button: .right)
        case "rightUp":
            postLocalMouseButton(type: .rightMouseUp, button: .right)
        case "otherDown":
            postLocalMouseButton(type: .otherMouseDown, button: .center)
        case "otherUp":
            postLocalMouseButton(type: .otherMouseUp, button: .center)
        case "scroll":
            postLocalScroll(scrollX: event.scrollX ?? 0, scrollY: event.scrollY ?? 0)
        case "keyDown":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: true)
                if handleIncomingTriggerKeyDown(keyCode) { return }
                postLocalKey(keyCode: keyCode, isDown: true)
            }
        case "keyUp":
            if let keyCode = event.keyCode {
                updateRemoteModifierState(keyCode: keyCode, isDown: false)
                if keyCode == suppressedTriggerKeyCode {
                    suppressedTriggerKeyCode = nil
                    return
                }
                postLocalKey(keyCode: keyCode, isDown: false)
            }
        default:
            break
        }
    }

    /// receiverMaster: if the incoming key-down completes a binding trigger,
    /// inject the action locally and swallow the trigger. Returns true if handled.
    private func handleIncomingTriggerKeyDown(_ keyCode: UInt16) -> Bool {
        guard !TBInputBindingEngine.isModifierKeyCode(keyCode), !inputBindings.isEmpty else { return false }
        // Debounce key-repeat: ignore repeats while the trigger is still held.
        if keyCode == suppressedTriggerKeyCode { return true }
        let held = currentHeldModifierBits()
        guard let binding = TBInputBindingEngine.match(keyCode: keyCode, modifiers: held, in: inputBindings) else {
            return false
        }
        suppressedTriggerKeyCode = keyCode
        TBInputDebugLog.log("binding MATCH: trigger=\(binding.trigger.displayString) -> inject \(binding.action.displayString)")
        injectActionViaSystemEvents(binding.action)
        return true
    }

    /// Inject a binding action through System Events (AppleScript) rather than a
    /// raw CGEvent. The WindowServer ignores synthetic CGEvent presses for
    /// protected symbolic hotkeys (e.g. ⌃← to switch Spaces), but honors the same
    /// shortcut when it comes from the trusted System Events process.
    ///
    /// The user may be holding the trigger's modifiers, which we inject as held
    /// CGEvent state — that would contaminate the action (e.g. a stray ⌥). So we
    /// release the held modifiers first so System Events sees a clean combo. On
    /// completion, restore only modifiers that the receiver still holds.
    private func injectActionViaSystemEvents(_ action: TBInputShortcut) {
        let heldKeyCodes = currentlyHeldRemoteModifierKeyCodes()
        for keyCode in heldKeyCodes { postLocalKey(keyCode: keyCode, isDown: false) }

        // Run the AppleScript in-process (NSAppleScript), NOT via /usr/bin/osascript:
        // when spawned, osascript is the keystroke-sending client and lacks
        // Accessibility (error 1002). In-process, this app is the client and it
        // already holds Accessibility + Automation, so System Events is allowed
        // to post the shortcut.
        let source = "tell application \"System Events\" to key code \(action.keyCode)\(Self.appleScriptModifierClause(action.modifiers))"
        DispatchQueue.global(qos: .userInitiated).async {
            var errorInfo: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
            let failure: String? = errorInfo.map { "\($0)" }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let failure { TBInputDebugLog.log("system-events inject error: \(failure)") }
                guard self.inputControlRole == .receiverMaster else { return }
                for keyCode in self.currentlyHeldRemoteModifierKeyCodes() {
                    self.postLocalKey(keyCode: keyCode, isDown: true)
                }
            }
        }
    }

    private func updateRemoteModifierState(keyCode: UInt16, isDown: Bool) {
        guard TBInputBindingEngine.modifierBit(for: keyCode) != nil else { return }
        if isDown {
            remoteHeldModifierKeyCodes.insert(keyCode)
        } else {
            remoteHeldModifierKeyCodes.remove(keyCode)
        }
    }

    private func currentlyHeldRemoteModifierKeyCodes() -> [UInt16] {
        TBInputShortcut.modifierTable.compactMap { modifier in
            remoteHeldModifierKeyCodes.first {
                TBInputBindingEngine.modifierBit(for: $0) == modifier.bit
            }
        }
    }

    private static func appleScriptModifierClause(_ modifiers: UInt32) -> String {
        var parts: [String] = []
        if modifiers & TBInputShortcut.control != 0 { parts.append("control down") }
        if modifiers & TBInputShortcut.option  != 0 { parts.append("option down") }
        if modifiers & TBInputShortcut.shift   != 0 { parts.append("shift down") }
        if modifiers & TBInputShortcut.command != 0 { parts.append("command down") }
        guard !parts.isEmpty else { return "" }
        return " using {" + parts.joined(separator: ", ") + "}"
    }

    /// Current held modifier state (our bitmask) reconstructed from injected keys.
    private func currentHeldModifierBits() -> UInt32 {
        var m: UInt32 = 0
        if injectedControlDown { m |= TBInputShortcut.control }
        if injectedOptionDown  { m |= TBInputShortcut.option }
        if injectedShiftDown   { m |= TBInputShortcut.shift }
        if injectedCommandDown { m |= TBInputShortcut.command }
        return m
    }

    private func handleDisplayProfile(_ payload: Data) {
        guard activeProfile == nil,
              let expectedConnection = connection,
              let profile = TBMonitorProtocol.decodeJSON(TBMonitorDisplayProfile.self, from: payload),
              profile.isValid
        else { return }

        if automaticQuality && !isCableTestConnection {
            let policy = TBVideoQualityPolicy(panelWidth: profile.panelWidth, panelHeight: profile.panelHeight,
                receiverHEVC: profile.supportsHEVCDecode == true, senderHEVC: Self.probeHEVCHardwareEncoderSupport(),
                now: ProcessInfo.processInfo.systemUptime)
            qualityPolicy = policy
            applyingAutomaticQuality = true
            capturePreset = policy.recommended
            applyingAutomaticQuality = false
        }
        activeProfile = profile
        if sleepState.isSleeping && !isCableTestConnection {
            sleepState.sleep(system: sleepState.systemSleeping, activeSession: true)
        }
        if !isCableTestConnection { sendSenderPowerState(awake: !sleepState.isSleeping) }
        receiverSupportsBrightness = profile.supportsBrightness
        if profile.supportsBrightnessState != true { scheduleSettingsSync() }
        receiverSupportsDisplayPower = profile.supportsDisplayPower == true
        if let supportsHEVCDecode = profile.supportsHEVCDecode {
            receiverSupportsHEVCDecodeHint = supportsHEVCDecode
        }
        if let inputMonitoringTrusted = profile.inputMonitoringTrusted {
            receiverInputMonitoringTrustedHint = inputMonitoringTrusted
        }
        if let accessibilityTrusted = profile.accessibilityTrusted {
            receiverAccessibilityTrustedHint = accessibilityTrusted
        }
        receiverPanelText = TBDisplaySenderL10n.receiverSummary(profile, language: language)
        sendHello()
        sendInputControlModeUpdate()
        sendVolumeUpdate()

        Task { @MainActor in
            guard self.connection === expectedConnection else { return }
            if self.isCableTestConnection {
                self.setStatus(.testingCable)
                do {
                    let rate = try await self.performCableTest()
                    guard self.connection === expectedConnection else { return }
                    self.cableTestResult = rate
                } catch {
                    guard self.connection === expectedConnection else { return }
                    NSLog("TargetBridge: cable test failed: \(error)")
                    self.stop(resetStatusTo: .connectionFailed(error.localizedDescription))
                    return
                }
                self.isCableTestConnection = false
                self.isCableTesting = false
                self.stop(resetStatusTo: .stopped)
                return
            }

            self.setStatus(.creatingVirtualDisplay)
            let displayIDs = await self.fetchShareableDisplayIDs()
            guard self.connection === expectedConnection else { return }
            self.baselineDisplayIDs = displayIDs
            let receiverKey = self.extendedDisplayIdentityKey(for: profile)
            let modeOverride: TBVirtualDisplayModeSize? = (self.matchRenderToStream && self.captureSource == .extendedDesktop)
                ? self.capturePreset.renderMatchedDisplayMode(hiDPI: profile.hiDPI)
                : nil
            if let modeOverride {
                NSLog(
                    "TargetBridge: render matching on, virtual display mode %dx%d (backing %dx%d) for %dx%d stream",
                    modeOverride.width, modeOverride.height,
                    modeOverride.backingWidth, modeOverride.backingHeight,
                    self.capturePreset.width, self.capturePreset.height
                )
            }
            let reuseDisplay = self.sleepState.needsResume && modeOverride == nil &&
                self.retainedSleepDisplayKey == self.sleepDisplayKey(for: profile) &&
                self.onlineDisplayIDs().contains(self.session.displayID)
            guard reuseDisplay || self.session.create(
                from: profile,
                refreshRate: self.capturePreset.virtualDisplayRefreshRate,
                modeOverride: modeOverride,
                identity: self.captureSource.virtualDisplayIdentity(receiverKey: receiverKey),
                receiverKey: receiverKey
            ) else {
                guard self.connection === expectedConnection else { return }
                self.setStatus(.virtualDisplayCreationFailed)
                self.stop(resetStatusTo: nil)
                return
            }
            self.retainedSleepDisplayKey = nil
            guard self.connection === expectedConnection else { return }
            if self.captureSource == .desktopMirror {
                let displayReady = await self.waitForOnlineDisplay(self.session.displayID)
                guard self.connection === expectedConnection else { return }
                let mirrorConfigured = displayReady && self.configureDesktopMirror(for: self.session.displayID)
                if !mirrorConfigured {
                    NSLog(
                        "TargetBridge: unable to enable mirror mode for virtual display %u on first attempt; scheduling retry",
                        self.session.displayID
                    )
                }
            }
            guard self.connection === expectedConnection else { return }
            self.virtualDisplayText = TBDisplaySenderL10n.virtualDisplaySummary(
                name: self.session.displayName,
                id: self.session.displayID,
                language: self.language
            )
            self.displayStateText = self.describeDisplayState(for: self.session.displayID)

            // Reset the first-frame flag BEFORE capture starts. startCapture() is
            // async and frames can begin flowing (firing handleFirstEncodedFrame,
            // which sets sessionAckSent = true) during its suspension. Resetting
            // afterward would clobber that true back to false, leaving the watchdog
            // armed against a session that has already delivered frames — it then
            // tears down a healthy stream ~4s in. See onFirstFrame wiring below.
            self.sessionAckSent = false
            self.setStatus(.startingCapture(self.capturePreset.description, self.captureSource))
            let started = await self.startCapture(for: profile)
            guard self.connection === expectedConnection else { return }
            guard started else {
                self.stop(resetStatusTo: nil)
                return
            }

            if self.captureSource == .extendedDesktop {
                self.scheduleExtendedDesktopRecovery(for: self.session.displayID)
            } else if self.captureSource == .desktopMirror {
                self.scheduleDesktopMirrorRecovery(for: self.session.displayID)
            }

            if !self.sessionAckSent { self.setStatus(.captureStartedWaitingFirstFrame) }
            self.startFirstFrameWatchdog()
        }
    }

    private func startCapture(for profile: TBMonitorDisplayProfile) async -> Bool {
        guard let connection else { return false }
        do {
            let preset = capturePreset
            let usesRawNV12 = rawNV12Enabled(for: profile)
            let videoCeiling = TBDisplaySenderService.shared.videoBandwidthCeiling(for: self)
            let requiredMbps = usesRawNV12
                ? Double(preset.width) * Double(preset.height) * 12 * Double(preset.expectedFrameRate) / 1_000_000 * 1.2
                : min(preset.videoProtectionMbps, videoCeiling)
            guard requiredMbps <= videoCeiling, TBDisplaySenderService.shared.reserveVideoLink(for: self, videoMbps: requiredMbps) else {
                setStatus(.connectionFailed(TBDisplaySenderL10n.text("sender.video_protection.configuration_too_large", language)))
                return false
            }
            let codecType = resolvedCodecType(for: preset, profile: profile)
            let codecName = usesRawNV12 ? "NV12 RAW" : codecName(for: codecType)
            activeCodecType = usesRawNV12 ? nil : codecType
            activeCodecName = codecName

            // The encode/send pipeline runs entirely on its own serial queue,
            // off the main thread, so SwiftUI layout can never stall frame
            // delivery. Preset/dimensions/codec are immutable for a session
            // (the pickers are disabled while streaming), so we capture them once.
            let generation = UUID()
            captureGeneration = generation
            let pipeline = TBVideoPipeline(
                preset: preset,
                maximumVideoMbps: requiredMbps,
                codecType: codecType,
                connection: connection,
                displayName: session.displayName,
                displayID: session.displayID,
                usesRawNV12: usesRawNV12,
                ackAlreadySent: sessionAckSent,
                onFirstFrame: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.connection === connection, self.captureGeneration == generation else { return }
                        self.handleFirstEncodedFrame()
                    }
                },
                onFailure: { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.connection === connection, self.captureGeneration == generation else { return }
                        self.stop(resetStatusTo: .connectionFailed(TBDisplaySenderL10n.text("sender.video_protection.send_failed", self.language)))
                    }
                }
            )
            guard pipeline.start() else { return false }
            pipeline.setSuspended(sleepState.isSleeping)
            self.pipeline = pipeline
            TBLog.connection.info("capture: pipeline started preset=\(preset.rawValue, privacy: .public) source=\(String(describing: self.captureSource), privacy: .public) codec=\(codecName, privacy: .public) rawNV12=\(usesRawNV12, privacy: .public)")

            let display: SCDisplay
            if captureSource == .desktopMirror {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                screenCaptureAccess.recordSuccess()
                guard self.connection === connection, self.pipeline === pipeline else { return false }
                guard let mainDisplay = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) else {
                    return false
                }
                display = mainDisplay
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                screenCaptureAccess.recordSuccess()
                guard self.connection === connection, self.pipeline === pipeline else { return false }
                if session.displayID != kCGNullDirectDisplay,
                   let targetDisplay = content.displays.first(where: { $0.displayID == session.displayID }) {
                    display = targetDisplay
                } else {
                    display = try await waitForCaptureDisplay()
                }
            }
            guard self.connection === connection, self.pipeline === pipeline else { return false }

            if let sourceMode = CGDisplayCopyDisplayMode(display.displayID) {
                TBLog.connection.info("capture geometry: display=\(display.displayID, privacy: .public) desktop=\(sourceMode.width, privacy: .public)x\(sourceMode.height, privacy: .public) backing=\(sourceMode.pixelWidth, privacy: .public)x\(sourceMode.pixelHeight, privacy: .public) stream=\(preset.width, privacy: .public)x\(preset.height, privacy: .public)")
            }

            let configuration = SCStreamConfiguration()
            configuration.width = preset.width
            configuration.height = preset.height
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: Int32(preset.expectedFrameRate))
            // One image is retained for idle refresh, with free surfaces left
            // for capture and the in-flight encoder. Coalescing still prevents
            // a FIFO of old frames from increasing display latency.
            configuration.queueDepth = max(3, preset.queueDepth)
            configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            // Avoid inheriting a wide-gamut display profile or an implicit YUV
            // matrix while the receiver renders with a fixed BT.709 conversion.
            configuration.colorSpaceName = CGColorSpace.sRGB
            configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            configuration.showsCursor = !largeCursor
            configuration.scalesToFit = true
            configuration.captureResolution = preset.captureResolution
            configuration.capturesAudio = false
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48000
            configuration.channelCount = 2

            streamResolutionText = TBDisplaySenderL10n.streamSummary(
                preset: preset,
                source: captureSource,
                language: language,
                codecName: codecName
            )

            let delegate = CaptureDelegate()
            delegate.onActivity = { pipeline.noteCaptureActivity() }
            delegate.onIdle = { pipeline.submitIdleFrame() }
            delegate.onInvalidFrame = { pipeline.invalidateIdleFrame() }
            delegate.onFrame = { sampleBuffer in
                pipeline.submitCapturedSample(sampleBuffer)
            }
            let audioGate = TBBoundedAudioSendGate()
            audioGate.setEnabled(shouldSendReceiverAudio)
            audioSendGate = audioGate
            audioIssueKey = ""
            let audioTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .userInitiated))
            let failAudio: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection, self.pipeline === pipeline else { return }
                    guard self.shouldSendReceiverAudio, !audioGate.isOpen else { return }
                    self.audioIssueKey = "sender.audio.paused_congestion"
                    // Keep the user's sound preference. The gate stays bounded
                    // while older writes drain, then resumes automatically.
                }
            }
            audioTimer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
            let recoverAudio: @Sendable () -> Void = { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection, self.pipeline === pipeline,
                          self.shouldSendReceiverAudio, audioGate.isOpen else { return }
                    self.audioIssueKey = ""
                }
            }
            audioTimer.setEventHandler(handler: audioGate.makeMaintenanceHandler(onExpiry: failAudio, onRecovery: recoverAudio))
            audioSendTimer = audioTimer; audioTimer.resume()
            let speakerSource = TBiMacSpeakerAudioSource(onStatus: { [weak self] status in
                if status != noErr { TBLog.connection.error("iMac speaker PCM read failed: \(status, privacy: .public)") }
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection, self.pipeline === pipeline,
                          self.shouldSendReceiverAudio else { return }
                    if status != noErr { self.audioIssueKey = "sender.audio.driver_unavailable" }
                    else if self.audioIssueKey == "sender.audio.driver_unavailable" { self.audioIssueKey = "" }
                }
            }) { [weak self] pcm in
                guard let data = TBBoundedAudioSendGate.capturePayload(pcm) else { return }
                // Reserve before scheduling: a busy MainActor cannot accumulate
                // an unbounded number of sample tasks or retained audio bytes.
                switch audioGate.reserve(bytes: data.count, now: ProcessInfo.processInfo.systemUptime) {
                case .closed, .discarded: return
                case .overloaded: failAudio()
                case .accepted(let token):
                    Task { @MainActor [weak self] in
                        guard let self, self.connection === connection, self.pipeline === pipeline,
                              self.shouldSendReceiverAudio, self.sessionAuthenticated else { audioGate.release(token); return }
                        if audioGate.expire(now: ProcessInfo.processInfo.systemUptime) { audioGate.release(token); failAudio(); return }
                        guard audioGate.isOpen else { audioGate.release(token); return }
                        let packet = TBMonitorProtocol.makePacket(type: .audioFrame, payload: data)
                        connection.send(content: packet, completion: .contentProcessed { @Sendable error in
                            audioGate.release(token)
                            if error != nil && audioGate.failOnce() { failAudio() }
                        })
                    }
                }
            }
            speakerAudioSource = speakerSource
            updateAudioRouting()
            delegate.onError = { [weak self] error in
                Task { @MainActor [weak self] in
                    guard let self, self.connection === connection, self.pipeline === pipeline else { return }
                    if self.sleepState.isSleeping { return }
                    self.setStatus(.captureError(self.formattedCaptureErrorMessage(for: error)))
                    self.stop(resetStatusTo: nil)
                }
            }
            captureDelegate = delegate

            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
            captureDisplayText = TBDisplaySenderL10n.captureDisplaySCDisplay(language, id: display.displayID)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
            try stream.addStreamOutput(
                delegate,
                type: .screen,
                sampleHandlerQueue: DispatchQueue(label: "fd.tbmonitor.sender.capture", qos: .userInteractive)
            )
            scStream = stream
            try await stream.startCapture()
            guard self.connection === connection, self.pipeline === pipeline else {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
                stream.stopCapture(completionHandler: nil)
                return false
            }
            screenCaptureAccess.recordSuccess()
            isStreaming = true
            if largeCursor { startCursorUpdates(displayID: display.displayID) }
            if !sleepState.isSleeping {
                streamingActivity = ProcessInfo.processInfo.beginActivity(
                    options: activityOptions(), reason: "TargetBridge streaming active")
            }
            startFPSTimer()
            startCaptureWatchdog()
            return true
        } catch {
            guard self.connection === connection else { return false }
            if error.localizedDescription.hasPrefix("no virtual SCDisplay available") {
                setStatus(.noShareableDisplay(error.localizedDescription))
            } else {
                setStatus(.captureDesktopError(formattedCaptureErrorMessage(for: error)))
            }
            return false
        }
    }

    private func startDirectDisplayStream(displayID: CGDirectDisplayID, preset: TBDisplayCapturePreset) -> Bool {
        guard let pipeline else { return false }
        let codecName = activeCodecName ?? codecName(for: activeCodecType ?? preset.codecType)
        streamResolutionText = TBDisplaySenderL10n.streamSummary(
            preset: preset,
            source: captureSource,
            language: language,
            codecName: codecName
        )

        // Deliver frames straight onto the pipeline's own queue — the handler
        // runs there, so encode happens off the main thread with no extra hop.
        let directCapture = TBDirectDisplayStreamCapture(pipeline: pipeline, queue: pipeline.queue)
        guard directCapture.start(displayID: displayID, preset: preset, showCursor: !largeCursor) else {
            return false
        }

        directDisplayStream = directCapture
        captureDisplayText = TBDisplaySenderL10n.captureDisplayCGDisplayStream(language, id: displayID)
        isStreaming = true
        if largeCursor { startCursorUpdates(displayID: displayID) }
        if !sleepState.isSleeping {
            streamingActivity = ProcessInfo.processInfo.beginActivity(
                options: activityOptions(), reason: "TargetBridge streaming active")
        }
        startFPSTimer()
        startCaptureWatchdog()
        return true
    }

    private func activityOptions() -> ProcessInfo.ActivityOptions {
        var options: ProcessInfo.ActivityOptions = [.userInitiatedAllowingIdleSystemSleep]
        if preventDisplaySleep {
            options.insert(.idleDisplaySleepDisabled)
        }
        return options
    }

    private func waitForCaptureDisplay() async throws -> SCDisplay {
        let targetDisplayID = (captureSource == .desktopMirror) ? CGMainDisplayID() : session.displayID
        return try await waitForVirtualDisplay(
            matching: targetDisplayID,
            baselineDisplayIDs: baselineDisplayIDs
        )
    }

    private func waitForVirtualDisplay(
        matching targetDisplayID: CGDirectDisplayID,
        baselineDisplayIDs: Set<CGDirectDisplayID>
    ) async throws -> SCDisplay {
        enum DisplayLookupError: LocalizedError {
            case notFound(details: String)

            var errorDescription: String? {
                switch self {
                case .notFound(let details):
                    return details
                }
            }
        }

        var lastContent: SCShareableContent?
        for _ in 0..<80 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            lastContent = content
            if let display = content.displays.first(where: { $0.displayID == targetDisplayID }) {
                return display
            }
            if let display = content.displays.first(where: { !baselineDisplayIDs.contains($0.displayID) }) {
                return display
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }

        let content: SCShareableContent
        if let lastContent {
            content = lastContent
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }
        let availableIDs = content.displays.map { String($0.displayID) }.sorted().joined(separator: ", ")
        let baselineIDs = baselineDisplayIDs.map(String.init).sorted().joined(separator: ", ")
        let onlineIDs = onlineDisplayIDs().map(String.init).sorted().joined(separator: ", ")
        throw DisplayLookupError.notFound(
            details: "no virtual SCDisplay available (target=\(targetDisplayID), baseline=[\(baselineIDs)], available=[\(availableIDs)], online=[\(onlineIDs)])"
        )
    }

    private func fetchShareableDisplayIDs() async -> Set<CGDirectDisplayID> {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenCaptureAccess.recordSuccess()
            return Set(content.displays.map(\.displayID))
        } catch {
            screenCaptureAccess.recordFailure(error)
            return []
        }
    }

    /// A freshly created virtual display can be reported by CoreGraphics before
    /// it is usable in a display configuration. Waiting briefly avoids racing
    /// `CGConfigureDisplayMirrorOfDisplay` on first connect.
    private func waitForOnlineDisplay(_ displayID: CGDirectDisplayID) async -> Bool {
        for _ in 0..<20 {
            if onlineDisplayIDs().contains(displayID) {
                return true
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return onlineDisplayIDs().contains(displayID)
    }

    /// RAW remains an explicit diagnostic-only transport until a selectable
    /// profile and sustained hardware tests prove it safe for normal sessions.
    /// A Receiver must explicitly advertise support before the environment
    /// override can enable it, so older builds never receive unknown frames.
    private func rawNV12Enabled(for profile: TBMonitorDisplayProfile) -> Bool {
        guard profile.supportsRawNV12 == true else { return false }
        guard let value = ProcessInfo.processInfo.environment["RAW"]?.lowercased() else { return false }
        return value == "1" || value == "true"
    }

    private func configureDesktopMirror(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let result = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, CGMainDisplayID())
            if result == .success {
                let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
                if complete == .success {
                    completed = true
                    return true
                }
            }

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return false
    }

    private func scheduleExtendedDesktopRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            var hasAppliedArrangement = false

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .extendedDesktop,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                // A newly recreated virtual display can already be outside a mirror set
                // while still sitting at macOS's default placement on the right.
                // Force at least one explicit extended-desktop configuration pass so
                // we can reapply the saved arrangement for this receiver.
                if CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureExtendedDesktop(for: virtualDisplayID)
                if configured {
                    hasAppliedArrangement = true
                }
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: extended desktop recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || (CGDisplayIsInMirrorSet(virtualDisplayID) == 0 && hasAppliedArrangement) {
                    return
                }
            }
        }
    }

    private func scheduleDesktopMirrorRecovery(for virtualDisplayID: CGDirectDisplayID) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            for attempt in 1...12 {
                try? await Task.sleep(nanoseconds: 500_000_000)

                guard self.captureSource == .desktopMirror,
                      self.session.displayID == virtualDisplayID,
                      self.activeProfile != nil
                else { return }

                if CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                    return
                }

                let configured = self.configureDesktopMirror(for: virtualDisplayID)
                self.displayStateText = self.describeDisplayState(for: virtualDisplayID)
                NSLog(
                    "TargetBridge: desktop mirror recovery attempt %d for %u configured=%d state=%@",
                    attempt,
                    virtualDisplayID,
                    configured,
                    self.displayStateText
                )

                if configured || CGDisplayIsInMirrorSet(virtualDisplayID) != 0 {
                    return
                }
            }
        }
    }

    private func configureExtendedDesktop(for virtualDisplayID: CGDirectDisplayID) -> Bool {
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            var displayConfig: CGDisplayConfigRef?
            guard CGBeginDisplayConfiguration(&displayConfig) == .success, let cfg = displayConfig else {
                return false
            }

            var completed = false
            defer {
                if !completed {
                    CGCancelDisplayConfiguration(cfg)
                }
            }

            let mainDisplayID = CGMainDisplayID()
            let mainBounds = CGDisplayBounds(mainDisplayID)
            let mainMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, mainDisplayID, kCGNullDirectDisplay)
            let virtualMirrorResult = CGConfigureDisplayMirrorOfDisplay(cfg, virtualDisplayID, kCGNullDirectDisplay)
            if mainMirrorResult != .success || virtualMirrorResult != .success {
                NSLog(
                    "TargetBridge: failed to detach mirror set for extended desktop (main=%d virtual=%d)",
                    mainMirrorResult.rawValue,
                    virtualMirrorResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let mainOriginResult = CGConfigureDisplayOrigin(cfg, mainDisplayID, 0, 0)
            let savedArrangement = activeProfile.flatMap { loadSavedExtendedDisplayArrangement(for: $0) }
            let defaultTargetX = Int32((mainBounds.maxX - mainBounds.origin.x).rounded())
            let targetX: Int32
            let targetY: Int32
            if let savedArrangement {
                if savedArrangement.isRelativeToMainDisplay {
                    targetX = Int32(mainBounds.origin.x.rounded()) + savedArrangement.x
                    targetY = Int32(mainBounds.origin.y.rounded()) + savedArrangement.y
                } else {
                    targetX = savedArrangement.x
                    targetY = savedArrangement.y
                }
            } else {
                targetX = defaultTargetX
                targetY = 0
            }
            let originResult = CGConfigureDisplayOrigin(cfg, virtualDisplayID, targetX, targetY)
            if mainOriginResult != .success || originResult != .success {
                NSLog(
                    "TargetBridge: failed to position displays for extended desktop (main=%d virtual=%u targetX=%d targetY=%d result=%d)",
                    mainOriginResult.rawValue,
                    virtualDisplayID,
                    targetX,
                    targetY,
                    originResult.rawValue
                )
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
                continue
            }

            let complete = CGCompleteDisplayConfiguration(cfg, .forSession)
            if complete == .success {
                completed = true
                return true
            }
            NSLog(
                "TargetBridge: CGCompleteDisplayConfiguration failed while forcing extended desktop for %u (result=%d)",
                virtualDisplayID,
                complete.rawValue
            )

            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }

        return CGDisplayIsInMirrorSet(virtualDisplayID) == 0
    }

    private func describeDisplayState(for virtualDisplayID: CGDirectDisplayID) -> String {
        let mainDisplayID = CGMainDisplayID()
        let virtualMirror = CGDisplayIsInMirrorSet(virtualDisplayID) != 0
        let mainMirror = CGDisplayIsInMirrorSet(mainDisplayID) != 0
        let virtualMirrors = CGDisplayMirrorsDisplay(virtualDisplayID)
        let mainMirrors = CGDisplayMirrorsDisplay(mainDisplayID)
        let identity = session.identityDescription.isEmpty ? "identity=n/a" : session.identityDescription
        return TBDisplaySenderL10n.displayStateSummary(
            language: language,
            identity: identity,
            virtual: virtualDisplayID,
            virtualMirror: virtualMirror,
            virtualMirrors: virtualMirrors,
            main: mainDisplayID,
            mainMirror: mainMirror,
            mainMirrors: mainMirrors
        )
    }

    private func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }
        return Array(displays.prefix(Int(count)))
    }
    private func startCursorUpdates(displayID: CGDirectDisplayID) {
        cursorTimer?.invalidate()
        cursorDisplayID = displayID
        lastCursorPacket = nil

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                sendCursorUpdateIfNeeded()
            }
        }
        cursorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        sendCursorUpdateIfNeeded(force: true)
    }

    private func sendHiddenCursorPacketIfNeeded() {
        guard isConnected else { return }

        let cursor = TBMonitorCursor(
            x: 0,
            y: 0,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: false,
            type: 0
        )
        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func applyCursorOverlayMode() {
        if inputRelayActive {
            cursorTimer?.invalidate()
            cursorTimer = nil
            sendHiddenCursorPacketIfNeeded()
            return
        }

        guard largeCursor, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        startCursorUpdates(displayID: cursorDisplayID)
    }

    private func getCurrentCursorType() -> Int {
        guard let current = NSCursor.currentSystem else { return 0 }
        if let last = lastCheckedCursor, last == current {
            return lastCheckedCursorType
        }

        lastCheckedCursor = current

        if let currentPng = Self.normalizedPng(for: current.image),
           let matchedType = Self.standardCursorPngs[currentPng] {
            lastCheckedCursorType = matchedType
            return matchedType
        }

        let size = current.image.size
        let hotSpot = current.hotSpot
        let type: Int
        if size.width > 0 && size.height > 0 {
            if hotSpot.x > 0 && hotSpot.x < 10 && hotSpot.y == 0 {
                type = 2 // Pointing Hand
            } else if size.width < size.height && abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                type = 1 // I-Beam
            } else if abs(hotSpot.x - size.width / 2) < 2 && abs(hotSpot.y - size.height / 2) < 2 {
                if size.width > size.height {
                    type = 3 // Resize Horizontal
                } else if size.height > size.width {
                    type = 4 // Resize Vertical
                } else {
                    type = 3 // Default fallback for square symmetric cursors: Resize Horizontal
                }
            } else {
                type = 0 // Arrow
            }
        } else {
            type = 0 // Arrow
        }

        lastCheckedCursorType = type
        return type
    }

    private func sendCursorUpdateIfNeeded(force: Bool = false) {
        guard !inputRelayActive else { return }
        guard isConnected, isStreaming, cursorDisplayID != kCGNullDirectDisplay else { return }
        guard let point = CGEvent(source: nil)?.location else { return }

        let bounds = CGDisplayBounds(cursorDisplayID)
        guard bounds.width > 0, bounds.height > 0 else { return }

        let localX = point.x - bounds.origin.x
        let localY = point.y - bounds.origin.y
        let visible = localX >= 0 && localY >= 0 && localX <= bounds.width && localY <= bounds.height

        let scaledX = Int((max(0, min(bounds.width, localX)) / bounds.width) * Double(capturePreset.width))
        let scaledY = Int((max(0, min(bounds.height, localY)) / bounds.height) * Double(capturePreset.height))
        let cursor = TBMonitorCursor(
            x: scaledX,
            y: scaledY,
            width: capturePreset.width,
            height: capturePreset.height,
            visible: visible,
            type: getCurrentCursorType()
        )

        if !force, let previous = lastCursorPacket {
            let movement = abs(previous.x - cursor.x) + abs(previous.y - cursor.y)
            if movement < 2,
               previous.visible == cursor.visible,
               previous.width == cursor.width,
               previous.height == cursor.height,
               previous.type == cursor.type {
                return
            }
        }

        lastCursorPacket = cursor
        if let packet = TBMonitorProtocol.makeJSONPacket(type: .cursor, value: cursor) {
            send(packet)
        }
    }

    private func registerWakeObservers() {
        let powerObserver = TBSystemPowerObserver()
        powerObserver.onWillSleep = { [weak self] allow in
            guard let self else { allow(); return }
            self.handleSenderSleep(system: true, allowSleep: allow)
        }
        powerObserver.onDidWake = { [weak self] in self?.handleSenderWake(system: true) }
        systemPowerObserver = powerObserver
        let registered = powerObserver.start()
        let workspace = NSWorkspace.shared.notificationCenter
        if !registered {
            // Best-effort fallback when IOKit registration is unavailable.
            wakeObservers.append(workspace.addObserver(forName: NSWorkspace.willSleepNotification,
                object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleSenderSleep(system: true) }
            })
        }
        wakeObservers.append(workspace.addObserver(forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSenderWake(system: true) }
        })
        wakeObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSenderSleep(system: false) }
        })
        wakeObservers.append(workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification,
            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSenderWake(system: false) }
        })
        let handler: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSystemWake()
            }
        }

        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screenIsUnlocked"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
        wakeObservers.append(
            DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name("com.apple.screensaver.didstop"),
                object: nil,
                queue: nil,
                using: handler
            )
        )
    }

    private func registerDisplayReconfigurationCallback() {
        guard !displayReconfigurationCallbackRegistered else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = CGDisplayRegisterReconfigurationCallback(Self.displayReconfigurationCallback, context)
        displayReconfigurationCallbackRegistered = (result == .success)
        if verboseDisplayLogging {
            startVerboseLoggingTimer()
        }
    }

    private func handleDisplayReconfiguration(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let isOurs = session.displayID != kCGNullDirectDisplay && displayID == session.displayID
        guard verboseDisplayLogging || isOurs else { return }
        var parts: [String] = []
        if flags.contains(.addFlag) { parts.append("add") }
        if flags.contains(.removeFlag) { parts.append("remove") }
        if flags.contains(.enabledFlag) { parts.append("enabled") }
        if flags.contains(.disabledFlag) { parts.append("disabled") }
        if flags.contains(.mirrorFlag) { parts.append("mirror") }
        if flags.contains(.unMirrorFlag) { parts.append("unMirror") }
        if flags.contains(.movedFlag) { parts.append("moved") }
        if flags.contains(.setMainFlag) { parts.append("setMain") }
        if flags.contains(.setModeFlag) { parts.append("setMode") }
        if flags.contains(.beginConfigurationFlag) { parts.append("beginConfiguration") }
        if flags.contains(.desktopShapeChangedFlag) { parts.append("desktopShapeChanged") }
        let flagText = parts.isEmpty ? "none" : parts.joined(separator: "|")
        NSLog(
            "TargetBridge: display reconfiguration displayID=%u ours=%@ flags=%@ online=[%@]",
            displayID,
            isOurs ? "yes" : "no",
            flagText,
            onlineDisplayIDs().map(String.init).joined(separator: ",")
        )
        if isOurs, session.displayID != kCGNullDirectDisplay {
            displayStateText = describeDisplayState(for: session.displayID)
        }
    }

    private func startVerboseLoggingTimer() {
        stopVerboseLoggingTimer()
        guard verboseDisplayLogging else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.logStreamSnapshot()
            }
        }
        verboseLoggingTimer = timer
        logStreamSnapshot()
    }

    private func stopVerboseLoggingTimer() {
        verboseLoggingTimer?.invalidate()
        verboseLoggingTimer = nil
    }

    private func startCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkCaptureHealth()
            }
        }
    }

    private func stopCaptureWatchdog() {
        captureHealthWatchdog?.invalidate()
        captureHealthWatchdog = nil
    }

    private func checkCaptureHealth() {
        guard !sleepState.isSleeping, isStreaming, sessionAckSent, activeProfile != nil, !isRestartingCaptureAfterWake, let pipeline else { return }
        guard !pipeline.captureIsIdle else { return }
        let elapsed = Date().timeIntervalSince(pipeline.lastCaptureFrameAtSnapshot)
        guard elapsed >= 8.0 else { return }
        NSLog("TargetBridge: capture watchdog tripped — %.1fs since last frame, soft restart", elapsed)
        scheduleCaptureRestart(reason: "watchdog (\(Int(elapsed))s without frames)", delaySeconds: 0.5)
    }

    private func logStreamSnapshot() {
        guard verboseDisplayLogging else { return }
        let online = onlineDisplayIDs()
        let virtualOnline = online.contains(session.displayID)
        let diag = pipeline?.diagnosticsSnapshot() ?? (pending: 0, inFlight: 0, ptsSeq: 0)
        NSLog(
            "TargetBridge: stream snapshot streaming=%@ fps=%d virtualID=%u online=%@ pendingPackets=%d inFlightEncode=%d ptsSeq=%lld",
            isStreaming ? "yes" : "no",
            liveMetrics.senderFPS,
            session.displayID,
            virtualOnline ? "yes" : "no",
            diag.pending,
            diag.inFlight,
            diag.ptsSeq
        )
    }

    private func handleSystemWake() {
        guard !sleepState.isSleeping, !sleepState.needsResume, autoRestartOnWake else { return }
        scheduleCaptureRestart(reason: "system wake", delaySeconds: 1.0)
    }

    private func handleSenderSleep(system: Bool, allowSleep: (@MainActor () -> Void)? = nil) {
        sleepState.sleep(system: system, activeSession: !isCableTestConnection && (isStreaming || activeProfile != nil))
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        guard sleepState.needsResume else { allowSleep?(); return }
        pipeline?.setSuspended(true)
        audioSendGate?.setEnabled(false)
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        sendSenderPowerState(awake: false, allowSleep: allowSleep)
    }

    private func handleSenderWake(system: Bool) {
        guard sleepState.wake(system: system) else { return }
        guard sleepState.needsResume else { return }
        pipeline?.setSuspended(false)
        audioOutputRouteObserver.refresh()
        updateAudioRouting()
        sendSenderPowerState(awake: true)
        // Recovery of a sleep-paused session is mandatory. The older preference
        // controls opportunistic restarts on unlock/screensaver notifications.
        if isStreaming { scheduleCaptureRestart(reason: "Sender resumed", delaySeconds: 1) }
        startWakeRecovery()
    }

    private func startWakeRecovery() {
        guard wakeRecoveryTask == nil, sleepState.needsResume, !sleepState.isSleeping else { return }
        wakeRecoveryTask = Task { @MainActor [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 60
            var observedConnection = self?.connection
            var connectionStartedAt = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                guard let self, self.sleepState.needsResume, !self.sleepState.isSleeping else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if self.connection !== observedConnection {
                    observedConnection = self.connection
                    connectionStartedAt = now
                }
                let captureReady = self.isStreaming && !self.isRestartingCaptureAfterWake &&
                    (self.pipeline?.sentFramesSnapshot ?? 0) > 0 &&
                    self.pipeline.map { Date().timeIntervalSince($0.lastCaptureFrameAtSnapshot) < 3 } == true
                if captureReady,
                   (self.activeProfile?.supportsSenderPower != true || self.senderPowerAwakeConfirmed) {
                    self.sleepState.resumed()
                    self.wakeRecoveryTask = nil
                    return
                }
                if ProcessInfo.processInfo.systemUptime >= deadline {
                    self.sleepState.cancelResume()
                    self.wakeRecoveryTask = nil
                    if !self.isStreaming { self.stop(resetStatusTo: nil) }
                    TBLog.connection.warning("Sender wake recovery timed out; manual connect remains available")
                    return
                }
                if self.connection != nil && TBSenderWakeRecovery.shouldReconnect(
                    elapsed: now - connectionStartedAt,
                    requiresPowerAck: self.activeProfile?.supportsSenderPower == true,
                    powerConfirmed: self.senderPowerAwakeConfirmed, captureReady: captureReady) {
                    TBLog.connection.warning("Sender wake: transport/capture recovery stalled; reconnecting")
                    self.stop(resetStatusTo: nil)
                }
                if self.activeProfile?.supportsSenderPower == true,
                   !self.senderPowerAwakeConfirmed, self.senderPowerRequestID == nil {
                    self.sendSenderPowerState(awake: true)
                }
                if self.connection == nil { self.connect() }
            }
        }
    }

    func restartCaptureNow() {
        scheduleCaptureRestart(reason: "manual restart", delaySeconds: 0.0)
    }

    var canRestartCapture: Bool {
        !sleepState.isSleeping && isStreaming && activeProfile != nil && !isRestartingCaptureAfterWake
    }

    private func scheduleCaptureRestart(reason: String, delaySeconds: Double) {
        guard !sleepState.isSleeping, isStreaming, !isRestartingCaptureAfterWake, let profile = activeProfile,
              let expectedConnection = connection else { return }
        isRestartingCaptureAfterWake = true
        NSLog("TargetBridge: \(reason) — soft restart of capture pipeline")
        Task { @MainActor [weak self] in
            if delaySeconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            guard let self else { return }
            guard self.connection === expectedConnection else { return }
            guard !self.sleepState.isSleeping, self.isStreaming, self.activeProfile?.receiverName == profile.receiverName else {
                self.isRestartingCaptureAfterWake = false
                return
            }
            await self.softRestartCapture(for: profile)
            guard self.connection === expectedConnection else { return }
            self.isRestartingCaptureAfterWake = false
        }
    }

    private func softRestartCapture(for profile: TBMonitorDisplayProfile) async {
        guard let expectedConnection = connection else { return }
        // Tear down only the capture pipeline — keep the network connection and virtual display.
        cursorTimer?.invalidate()
        cursorTimer = nil
        fpsTimer?.invalidate()
        fpsTimer = nil
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        stopCaptureWatchdog()
        if let directDisplayStream {
            directDisplayStream.stop()
            self.directDisplayStream = nil
        }
        if let stream = scStream {
            if let delegate = captureDelegate {
                try? stream.removeStreamOutput(delegate, type: .screen)
                try? stream.removeStreamOutput(delegate, type: .audio)
            }
            try? await stream.stopCapture()
            // A reconnect may have installed a new stream while stopping the old one.
            guard connection === expectedConnection else { return }
            scStream = nil
        }
        guard connection === expectedConnection else { return }
        speakerAudioSource?.stop(); speakerAudioSource = nil
        audioSendTimer?.cancel(); audioSendTimer = nil
        audioSendGate?.close(); audioSendGate = nil
        captureDelegate = nil
        if let activity = streamingActivity {
            ProcessInfo.processInfo.endActivity(activity)
            streamingActivity = nil
        }
        pipeline?.stop()
        pipeline = nil
        isStreaming = false
        liveMetrics.senderFPS = 0
        senderFPS = 0
        sentSnapshot = 0
        cursorDisplayID = kCGNullDirectDisplay
        lastCursorPacket = nil

        let started = await startCapture(for: profile)
        guard connection === expectedConnection else { return }
        if !started {
            NSLog("TargetBridge: capture restart failed; preserving the capture error")
            stop(resetStatusTo: nil)
        }
    }

    private func handleFirstEncodedFrame() {
        guard !sessionAckSent else { return }
        sessionAckSent = true
        firstFrameTimer?.invalidate()
        firstFrameTimer = nil
        TBLog.connection.info("capture: first encoded frame received")
        setStatus(.captureActive(capturePreset.description, activeCodecName ?? capturePreset.codecName, captureSource))
    }

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        sentSnapshot = pipeline?.sentFramesSnapshot ?? 0
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                let total = pipeline?.sentFramesSnapshot ?? 0
                let fps = total - sentSnapshot
                liveMetrics.senderFPS = fps
                senderFPS = fps
                sentSnapshot = total
                if let audio = audioSendGate?.snapshot(now: ProcessInfo.processInfo.systemUptime) {
                    audioQueueSummary = TBDisplaySenderL10n.text("sender.audio.queue", language, [
                        "bytes": String(audio.bytes / 1024), "packets": String(audio.packets), "age": String(audio.ageMS)])
                }
                if let protection = pipeline?.protectionSnapshot() {
                    videoProtectionSummary = TBDisplaySenderL10n.text("sender.video_protection.metrics", language, [
                        "rate": String(protection.bitRate / 1_000_000),
                        "pending": String(protection.pendingBytes / 1024),
                        "dropped": String(protection.dropped),
                        "limit": TBDisplaySenderL10n.text(protection.rateLimited
                            ? "sender.video_protection.limit_active" : "sender.video_protection.limit_unavailable", language)
                    ])
                }
            }
        }
    }

    private func startHeartbeat() {
        heartbeatTimer?.invalidate()
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.sendHeartbeat()
            }
        }
    }

    private func startFirstFrameWatchdog() {
        // If the first encoded frame already arrived (handleFirstEncodedFrame ran
        // while startCapture was still suspended), there is nothing to watch for —
        // arming would only leave a no-op timer dangling.
        guard !sessionAckSent, let expectedConnection = connection else { return }
        let expectedGeneration = captureGeneration
        firstFrameTimer?.invalidate()
        firstFrameTimer = Timer.scheduledTimer(withTimeInterval: 8, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.connection === expectedConnection,
                      self.captureGeneration == expectedGeneration,
                      !self.sleepState.isSleeping, self.isStreaming, !self.sessionAckSent, !self.isRestartingCaptureAfterWake else { return }
                let diagnostic = self.pipeline?.startupDiagnosticsSnapshot() ?? (captured: 0, encoded: 0, encoderStatus: 0)
                NSLog("TargetBridge: first frame timeout captured=%d encoded=%d encoderStatus=%d sent=%d", diagnostic.captured, diagnostic.encoded, diagnostic.encoderStatus, self.pipeline?.sentFramesSnapshot ?? 0)
                if !self.firstFrameRecoveryAttempted, let profile = self.activeProfile {
                    self.firstFrameRecoveryAttempted = true
                    self.isRestartingCaptureAfterWake = true
                    await self.softRestartCapture(for: profile)
                    guard self.connection === expectedConnection else { return }
                    self.isRestartingCaptureAfterWake = false
                    guard self.isStreaming else { return }
                    if !self.sessionAckSent { self.setStatus(.captureStartedWaitingFirstFrame) }
                    self.startFirstFrameWatchdog()
                } else {
                    self.setStatus(self.capturePreset == .native5k || self.capturePreset == .native5k60Experimental ? .hevcNoFrames : .noFirstFrame)
                    self.stop(resetStatusTo: nil)
                }
            }
        }
    }

    private func startConnectWatchdog() {
        connectTimeoutWorkItem?.cancel()
        
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard !self.isConnected else { return }

                let timeoutMessage: String
                switch self.language {
                case .italian: timeoutMessage = "Connessione scaduta"
                case .english: timeoutMessage = "Connection timed out"
                case .german: timeoutMessage = "Verbindungs-Zeitüberschreitung"
                case .french: timeoutMessage = "Délai de connexion dépassé"
                case .chinese: timeoutMessage = "连接超时"
                }

                // Attach where we dialed, from which interface, and the last
                // state the network stack reported — previously all of this
                // was discarded and the user saw only the bare timeout.
                let detail = TBConnectionDiagnostics.failureDetail(
                    receiverHost: self.receiverIP,
                    port: TBMonitorProtocol.port,
                    localIP: self.localInterfaceIP,
                    interfaceName: self.connectInterfaceName,
                    transport: self.transportKind.rawValue,
                    lastNetworkState: self.lastConnectionStateDetail
                )
                TBLog.connection.error("connect: timed out — \(detail, privacy: .public)")
                self.setStatus(.connectionFailed("\(timeoutMessage) — \(detail)"))
                self.stop(resetStatusTo: nil)
            }
        }
        
        connectTimeoutWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0, execute: workItem)
    }

    private func send(_ packet: Data) {
        guard sessionAuthenticated || (packet.count >= 5 &&
            [TBMonitorPacketType.sessionAuth.rawValue, TBMonitorPacketType.heartbeat.rawValue,
             TBMonitorPacketType.teardown.rawValue].contains(packet[4])) else { return }
        connection?.send(content: packet, completion: .contentProcessed({ _ in }))
    }

    func sendInputEvent(_ event: TBMonitorInputEvent) {
        guard isConnected else { return }
        send(TBMonitorProtocol.makeInputEventPacket(event))
    }

    func updateInputControlMode() {
        guard isConnected else { return }
        sendInputControlModeUpdate()
    }

}
