import Foundation

/// ScreenCaptureKit's idle events confirm that the latest image is still
/// current. Refresh it at 2 fps so the Receiver's video timeout stays valid.
/// Blank, suspended and stopped events must discard the cached image.
struct TBIdleFrameRefresh<Value> {
    private var latest: Value?
    private var lastFrameAt: TimeInterval = 0
    private(set) var isIdle = false

    mutating func capture(_ value: Value, now: TimeInterval) {
        latest = value
        lastFrameAt = now
        isIdle = false
    }

    mutating func idle(now: TimeInterval) -> Value? {
        isIdle = latest != nil
        return refresh(now: now)
    }

    mutating func refresh(now: TimeInterval) -> Value? {
        guard isIdle, let latest, now.isFinite, now - lastFrameAt >= 0.5 else { return nil }
        lastFrameAt = now
        return latest
    }

    mutating func invalidate() { latest = nil; isIdle = false }
}
