import Foundation
import CoreMedia
import VideoToolbox

/// Conservative quality changes use elapsed time and counter deltas. Static
/// desktops and a single delayed sample do not count as receiver overload.
struct TBVideoQualityPolicy {
    static let ladder: [TBDisplayCapturePreset] = [.compatible1080p30, .legacy1080p60, .standard1440p]
    private var previous: (time: Double, metrics: TBMonitorReceiverMetrics)?
    private var badSince: Double?
    private var goodSince: Double?
    private var changedAt: Double
    private var recoveryUsed = false
    let recommended: TBDisplayCapturePreset

    init(panelWidth: Int, panelHeight: Int, receiverHEVC: Bool, senderHEVC: Bool, now: Double) {
        recommended = panelWidth >= 2560 && panelHeight >= 1440 && receiverHEVC && senderHEVC
            ? .standard1440p : .legacy1080p60
        changedAt = now
    }

    static func codec(for preset: TBDisplayCapturePreset, receiverHEVC: Bool, senderHEVC: Bool) -> CMVideoCodecType {
        if preset == .legacy1080p60 || preset == .compatible1080p30 { return kCMVideoCodecType_H264 }
        return receiverHEVC && senderHEVC ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
    }

    // H.264 High is supported by the Catalina decoder. Its desktop-detail
    // tools do not require frame reordering, which stays disabled separately.
    static func h264Profile(for preset: TBDisplayCapturePreset) -> CFString {
        preset == .legacy1080p60 || preset == .compatible1080p30
            ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_H264_Main_AutoLevel
    }

    static func maximumFrameQP(for preset: TBDisplayCapturePreset) -> Int? {
        // Maintain fine UI edges under rate control. Hardware may drop frames
        // when a busy scene cannot satisfy both this cap and the link budget.
        preset == .legacy1080p60 || preset == .compatible1080p30 ? 18 : nil
    }

    mutating func consume(_ metrics: TBMonitorReceiverMetrics, preset: TBDisplayCapturePreset,
                          now: Double) -> TBDisplayCapturePreset? {
        guard metrics.isValid, now.isFinite else { return nil }
        defer { previous = (now, metrics) }
        guard let previous, let index = Self.ladder.firstIndex(of: preset), now > previous.time,
              now - previous.time <= 5, metrics.received >= previous.metrics.received,
              metrics.submitted >= previous.metrics.submitted, metrics.decodeErrors >= previous.metrics.decodeErrors else {
            badSince = nil; goodSince = nil; return nil
        }
        let received = metrics.received - previous.metrics.received
        let submitted = metrics.submitted - previous.metrics.submitted
        let errors = metrics.decodeErrors - previous.metrics.decodeErrors
        // Counter freshness alone is not latency. Require real arriving frames
        // and sustained poor presentation or decode failures before reducing.
        guard received >= 5 else { badSince = nil; goodSince = nil; return nil }
        let softwareAtHighResolution = metrics.hardwareDecode == 0 && preset.width > 1920
        let struggling = errors > 0 || Double(submitted) / Double(received) < 0.65 || softwareAtHighResolution
        if struggling {
            goodSince = nil
            if badSince == nil { badSince = now }
            if index > 0, now - changedAt >= 30, now - (badSince ?? now) >= 10 {
                changedAt = now; badSince = nil
                return Self.ladder[index - 1]
            }
        } else {
            badSince = nil
            if goodSince == nil { goodSince = now }
            // At most one recovery probe per connection prevents oscillation.
            if !recoveryUsed, index < (Self.ladder.firstIndex(of: recommended) ?? 0),
               now - changedAt >= 120, now - (goodSince ?? now) >= 120 {
                recoveryUsed = true; changedAt = now; goodSince = nil
                return Self.ladder[index + 1]
            }
        }
        return nil
    }
}
