import XCTest
@testable import TargetBridge

final class TBDisplayProfileTests: XCTestCase {
    func testWork5KUsesAnExtendedNative5KDisplay() {
        let settings = TBDisplayProfile.work5K.settings

        XCTAssertEqual(settings.captureSource, .extendedDesktop)
        XCTAssertEqual(settings.capturePreset, .native5k)
        XCTAssertTrue(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testLowLatencyUsesLegacy1080p60H264WithoutAudio() {
        let settings = TBDisplayProfile.lowLatency.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .legacy1080p60)
        XCTAssertFalse(settings.matchRenderToStream)
        XCTAssertFalse(settings.audioEnabled)
    }

    func testLegacyLowLatencyPresetBoundsTheFramePipeline() {
        let preset = TBDisplayCapturePreset.legacy1080p60

        XCTAssertEqual(preset.width, 1920)
        XCTAssertEqual(preset.height, 1080)
        XCTAssertEqual(preset.expectedFrameRate, 60)
        XCTAssertEqual(preset.virtualDisplayRefreshRate, 60)
        XCTAssertEqual(preset.codecName, "H.264")
        XCTAssertEqual(preset.averageBitRate, 80_000_000)
        XCTAssertEqual(preset.queueDepth, 1)
        XCTAssertEqual(preset.maxFrameDelayCount, 0)
        XCTAssertEqual(preset.maxPendingVideoPackets, 1)
        XCTAssertEqual(preset.maxInFlightEncodeFrames, 1)
        XCTAssertTrue(preset.dropsBeforeEncodeWhenBacklogged)
    }

    func testPresentationUsesACompatibleMirrorProfileWithAudio() {
        let settings = TBDisplayProfile.presentation.settings

        XCTAssertEqual(settings.captureSource, .desktopMirror)
        XCTAssertEqual(settings.capturePreset, .standard1440p)
        XCTAssertTrue(settings.audioEnabled)
    }
    func testRenderMatchingUsesReceiverScaleForAllPresets() {
        for preset in TBDisplayCapturePreset.allCases {
            let standard = preset.renderMatchedDisplayMode(hiDPI: false)
            XCTAssertEqual(standard.width, preset.width)
            XCTAssertEqual(standard.height, preset.height)
            XCTAssertEqual(standard.backingWidth, preset.width)
            XCTAssertEqual(standard.backingHeight, preset.height)
            let retina = preset.renderMatchedDisplayMode(hiDPI: true)
            XCTAssertEqual(retina.width * 2, preset.width)
            XCTAssertEqual(retina.height * 2, preset.height)
            XCTAssertEqual(retina.backingWidth, preset.width)
            XCTAssertEqual(retina.backingHeight, preset.height)
        }
    }

}
