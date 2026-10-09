import XCTest
import CoreMedia
import CoreVideo
import VideoToolbox
@testable import TargetBridge

final class TBVideoQualityPolicyTests: XCTestCase {
    func metrics(_ time: Int, poor: Bool, hardware: Int = 1) -> TBMonitorReceiverMetrics {
        TBMonitorReceiverMetrics(hardwareDecode: hardware, raw: false, received: UInt64(time * 60), uploaded: UInt64(time * 60), submitted: UInt64(time * (poor ? 20 : 60)), sinceSubmitMs: 0, audioBytes: 0, decodeErrors: 0)
    }

    func testConservativeRecommendationAndCodecFallbackForAllPresets() {
        XCTAssertEqual(TBVideoQualityPolicy(panelWidth: 1920, panelHeight: 1080, receiverHEVC: false, senderHEVC: true, now: 0).recommended, .legacy1080p60)
        XCTAssertEqual(TBVideoQualityPolicy(panelWidth: 5120, panelHeight: 2880, receiverHEVC: true, senderHEVC: true, now: 0).recommended, .standard1440p)
        XCTAssertEqual(TBVideoQualityPolicy(panelWidth: 5120, panelHeight: 2880, receiverHEVC: false, senderHEVC: true, now: 0).recommended, .legacy1080p60)
        for preset in TBDisplayCapturePreset.allCases {
            XCTAssertEqual(TBVideoQualityPolicy.codec(for: preset, receiverHEVC: false, senderHEVC: true), kCMVideoCodecType_H264)
            XCTAssertEqual(TBVideoQualityPolicy.codec(for: preset, receiverHEVC: true, senderHEVC: false), kCMVideoCodecType_H264)
        }
        XCTAssertEqual(TBDisplayCapturePreset.compatible1080p30.expectedFrameRate, 30)
    }

    func testSustainedOverloadAndCooldown() {
        var policy = TBVideoQualityPolicy(panelWidth: 5120, panelHeight: 2880, receiverHEVC: true, senderHEVC: true, now: 0)
        for time in 0..<30 { XCTAssertNil(policy.consume(metrics(time, poor: true), preset: .standard1440p, now: Double(time))) }
        XCTAssertEqual(policy.consume(metrics(30, poor: true), preset: .standard1440p, now: 30), .legacy1080p60)
        for time in 31..<60 { XCTAssertNil(policy.consume(metrics(time, poor: true), preset: .legacy1080p60, now: Double(time))) }
        XCTAssertEqual(policy.consume(metrics(60, poor: true), preset: .legacy1080p60, now: 60), .compatible1080p30)
    }

    func testStaticDesktopAndStaleSamplesDoNotDegrade() {
        var policy = TBVideoQualityPolicy(panelWidth: 1920, panelHeight: 1080, receiverHEVC: false, senderHEVC: true, now: 0)
        for time in 0...150 { XCTAssertNil(policy.consume(metrics(0, poor: true), preset: .legacy1080p60, now: Double(time))) }
        XCTAssertNil(policy.consume(metrics(200, poor: true), preset: .legacy1080p60, now: 200))
    }

    func testRecoveryWaitsTwoStableMinutesAndOnlyProbesOnce() {
        var policy = TBVideoQualityPolicy(panelWidth: 5120, panelHeight: 2880, receiverHEVC: true, senderHEVC: true, now: 0)
        _ = policy.consume(metrics(0, poor: false), preset: .legacy1080p60, now: 0)
        for time in 1...120 { XCTAssertNil(policy.consume(metrics(time, poor: false), preset: .legacy1080p60, now: Double(time))) }
        XCTAssertEqual(policy.consume(metrics(121, poor: false), preset: .legacy1080p60, now: 121), .standard1440p)
        for time in 122...400 { XCTAssertNil(policy.consume(metrics(time, poor: false), preset: .legacy1080p60, now: Double(time))) }
    }

    // Synthetic pixels only: no screen capture, display changes or Receiver.
    // Compare real encode/decode output to the previous 1080p policy, so a
    // configuration that builds successfully but damages thin lines fails.
    func test1080pDesktopEncodingPreservesThinLinesWithinTheExistingBudget() throws {
        let previous = try encodeThinLines(updated: false)
        let current = try encodeThinLines(updated: true)
        XCTAssertGreaterThan(current.samples, 0)
        XCTAssertEqual(current.frames, 60)
        XCTAssertLessThanOrEqual(current.meanSquaredError, previous.meanSquaredError * 1.1 + 0.01)
        XCTAssertLessThan(current.bytes, 100_000_000 / 8)
        print("1080p synthetic thin lines: previous MSE=\(previous.meanSquaredError), current MSE=\(current.meanSquaredError); \(current.frames) frames, \(current.bytes) bytes")
    }

    private final class EncodedFrames {
        let lock = NSLock()
        var frames: [CMSampleBuffer] = []
        var status: OSStatus = noErr
    }

    private final class DecodedError {
        let lock = NSLock()
        let width: Int
        let height: Int
        var samples = 0
        var squaredError: Double = 0
        var status: OSStatus = noErr
        init(width: Int, height: Int) { self.width = width; self.height = height }
    }

    private struct EncodingResult {
        var samples: Int
        var frames: Int
        var bytes: Int
        var meanSquaredError: Double
    }

    private static func thinLineLuma(_ x: Int, _ y: Int) -> UInt8 {
        switch (x / 48 + y / 32) % 3 {
        case 0: return x % 48 < 2 || y % 32 < 2 ? 24 : 224
        case 1: return x % 16 == 0 || y % 8 == 0 ? 220 : 45
        default: return x % 13 < 2 || y % 11 < 2 ? 60 : 150
        }
    }

    private func encodeThinLines(updated: Bool) throws -> EncodingResult {
        let preset = TBDisplayCapturePreset.legacy1080p60
        let width = preset.width, height = preset.height
        var source: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &source), noErr)
        let pixels = try XCTUnwrap(source)
        CVPixelBufferLockBaseAddress(pixels, [])
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let luma = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width { luma[y * stride + x] = Self.thinLineLuma(x, y) } }
        memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) * height / 2)
        CVPixelBufferUnlockBaseAddress(pixels, [])

        let encoded = EncodedFrames()
        var encoder: VTCompressionSession?
        let createStatus = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary,
            imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: { ref, _, status, _, frame in
                guard let ref else { return }
                let state = Unmanaged<EncodedFrames>.fromOpaque(ref).takeUnretainedValue()
                state.lock.lock(); defer { state.lock.unlock() }
                if status != noErr { state.status = status }
                if let frame { state.frames.append(frame) }
            }, refcon: Unmanaged.passUnretained(encoded).toOpaque(), compressionSessionOut: &encoder)
        guard createStatus == noErr else { throw XCTSkip("No synthetic H.264 hardware encoder: \(createStatus)") }
        let session = try XCTUnwrap(encoder)
        defer { VTCompressionSessionInvalidate(session) }
        func set(_ key: CFString, _ value: Any) {
            XCTAssertEqual(VTSessionSetProperty(session, key: key, value: value as CFTypeRef), noErr, "\(key)")
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_ProfileLevel, updated ? TBVideoQualityPolicy.h264Profile(for: preset) : kVTProfileLevel_H264_Main_AutoLevel)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, preset.expectedFrameRate)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, preset.maxKeyFrameInterval)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, preset.maxKeyFrameIntervalDuration)
        // Some hardware rejects zero delay; production also treats it as optional.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: NSNumber(value: preset.maxFrameDelayCount))
        set(kVTCompressionPropertyKey_AverageBitRate, updated ? preset.averageBitRate : 50_000_000)
        let bytesPerSecond = preset.videoProtectionMbps * 1_000_000 / 8 * 0.9
        set(kVTCompressionPropertyKey_DataRateLimits, [bytesPerSecond * 0.25, 0.25, bytesPerSecond, 1])
        set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, preset.prioritizeSpeed)
        if updated, let maximumQP = TBVideoQualityPolicy.maximumFrameQP(for: preset) {
            let status = VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxAllowedFrameQP, value: NSNumber(value: maximumQP))
            XCTAssertTrue(status == noErr || status == kVTPropertyNotSupportedErr)
        }
        XCTAssertEqual(VTCompressionSessionPrepareToEncodeFrames(session), noErr)
        for index in 0..<60 {
            XCTAssertEqual(VTCompressionSessionEncodeFrame(session, imageBuffer: pixels,
                presentationTimeStamp: CMTime(value: Int64(index), timescale: 60), duration: CMTime(value: 1, timescale: 60),
                frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid), noErr)
        XCTAssertEqual(encoded.status, noErr)
        let first = try XCTUnwrap(encoded.frames.first), last = try XCTUnwrap(encoded.frames.last)
        let stats = DecodedError(width: width, height: height)
        var decoder: VTDecompressionSession?
        var callback = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: { ref, _, status, _, image, _, _ in
            guard let ref else { return }
            let state = Unmanaged<DecodedError>.fromOpaque(ref).takeUnretainedValue()
            state.lock.lock(); defer { state.lock.unlock() }
            if status != noErr { state.status = status }
            guard let image else { return }
            CVPixelBufferLockBaseAddress(image, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return }
            let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<state.height { for x in 0..<state.width {
                let error = Int(bytes[y * rowBytes + x]) - Int(TBVideoQualityPolicyTests.thinLineLuma(x, y))
                state.squaredError += Double(error * error)
            } }
            state.samples += state.width * state.height
        }, decompressionOutputRefCon: Unmanaged.passUnretained(stats).toOpaque())
        XCTAssertEqual(VTDecompressionSessionCreate(allocator: nil,
            formatDescription: try XCTUnwrap(CMSampleBufferGetFormatDescription(first)), decoderSpecification: nil,
            imageBufferAttributes: [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary,
            outputCallback: &callback, decompressionSessionOut: &decoder), noErr)
        let decompressor = try XCTUnwrap(decoder)
        defer { VTDecompressionSessionInvalidate(decompressor) }
        for frame in [first, last] {
            XCTAssertEqual(VTDecompressionSessionDecodeFrame(decompressor, sampleBuffer: frame, flags: [], frameRefcon: nil, infoFlagsOut: nil), noErr)
        }
        XCTAssertEqual(VTDecompressionSessionWaitForAsynchronousFrames(decompressor), noErr)
        XCTAssertEqual(stats.status, noErr)
        XCTAssertEqual(stats.samples, width * height * 2)
        return EncodingResult(samples: stats.samples, frames: encoded.frames.count,
            bytes: encoded.frames.reduce(0) { $0 + CMSampleBufferGetTotalSampleSize($1) },
            meanSquaredError: stats.squaredError / Double(max(1, stats.samples)))
    }
}
