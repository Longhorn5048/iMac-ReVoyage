import XCTest
@testable import TargetBridge

final class TBMediaStateTests: XCTestCase {
    func testStatusErrorMapsToState() {
        XCTAssertEqual(TBMediaBridgeState(statusError: ""), .connected)
        XCTAssertEqual(TBMediaBridgeState(statusError: "device_busy"), .deviceBusy)
        XCTAssertEqual(TBMediaBridgeState(statusError: "something_new"), .captureFailed)
    }

    func testEveryStateHasTextInEveryLanguage() {
        let keys = TBMediaBridgeState.allCases.map(\.localizationKey)
            + TBVirtualDeviceState.allCases.map(\.localizationKey)
            + TBMediaEndpointStatus.allCases.map(\.localizationKey)
        for language in TBDisplaySenderLanguage.allCases {
            for key in keys {
                XCTAssertFalse(TBDisplaySenderL10n.text(key, language).hasPrefix("[["), "\(key) missing for \(language)")
            }
        }
    }

    func testOnlyReceiverStatusErrorsKeepTheLink() {
        XCTAssertTrue(TBMediaBridgeState.permissionDenied.isLinked)
        XCTAssertTrue(TBMediaBridgeState.connected.isLinked)
        XCTAssertFalse(TBMediaBridgeState.connecting.isLinked)
        XCTAssertFalse(TBMediaBridgeState.cameraUnavailable.isLinked)
        XCTAssertFalse(TBMediaBridgeState.connectionTimeout.isLinked)
    }

    func testCaptureEndpointStatusOrder() {
        func status(installed: Bool = true, signed: Bool = true, linked: Bool = true, devices: Int = 1,
                    permission: TBMediaPermission = .authorized, active: Bool = false) -> TBMediaEndpointStatus {
            .capture(installed: installed, signingConfigured: signed, linked: linked, deviceCount: devices,
                     permission: permission, active: active)
        }
        XCTAssertEqual(status(installed: false, signed: false), .signingRequired)
        XCTAssertEqual(status(installed: false), .notInstalled)
        XCTAssertEqual(status(linked: false), .disconnected)
        XCTAssertEqual(status(devices: 0), .unavailable)
        XCTAssertEqual(status(devices: 0, permission: .denied), .permissionDenied)
        XCTAssertEqual(status(permission: .restricted), .permissionDenied)
        XCTAssertEqual(status(permission: .notDetermined), .permissionPending)
        XCTAssertEqual(status(), .inactive)
        XCTAssertEqual(status(active: true), .active)
        // An installed device works even when this build itself is unsigned.
        XCTAssertEqual(status(signed: false), .inactive)
    }

    func testSpeakerEndpointStatus() {
        XCTAssertEqual(TBMediaEndpointStatus.speaker(installed: false, sessionConnected: true, selectedAsOutput: true), .notInstalled)
        XCTAssertEqual(TBMediaEndpointStatus.speaker(installed: true, sessionConnected: false, selectedAsOutput: true), .disconnected)
        XCTAssertEqual(TBMediaEndpointStatus.speaker(installed: true, sessionConnected: true, selectedAsOutput: false), .inactive)
        XCTAssertEqual(TBMediaEndpointStatus.speaker(installed: true, sessionConnected: true, selectedAsOutput: true), .active)
    }
}
