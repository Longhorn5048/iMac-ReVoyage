import Foundation

/// State of the Sender to iMac device-service link. The raw value is the
/// identifier used on the wire and in "sender.media.state.<raw>".
enum TBMediaBridgeState: String, CaseIterable, Sendable {
    case disconnected, connecting, connected
    case receiverRequired = "receiver_required"
    case wiredRequired = "wired_required"
    case linkTooSlow = "link_too_slow"
    case permissionPending = "permission_pending"
    case permissionDenied = "permission_denied"
    case deviceMissing = "device_missing"
    case deviceBusy = "device_busy"
    case formatUnsupported = "format_unsupported"
    case captureFailed = "capture_failed"
    case cameraUnavailable = "camera_unavailable"
    case microphoneUnavailable = "microphone_unavailable"
    case bandwidthUnsupported = "bandwidth_unsupported"
    case connectionFailed = "connection_failed"
    case connectionTimeout = "connection_timeout"
    case invalidMedia = "invalid_media"

    /// Maps the `error` of a Receiver status packet; empty means success.
    init(statusError: String) {
        self = statusError.isEmpty ? .connected : (Self(rawValue: statusError) ?? .captureFailed)
    }

    var localizationKey: String { "sender.media.state." + rawValue }

    /// The link stays up in these states; every other state has closed it.
    var isLinked: Bool {
        switch self {
        case .connected, .permissionPending, .permissionDenied, .deviceMissing, .deviceBusy,
             .formatUnsupported, .captureFailed:
            return true
        default:
            return false
        }
    }
}

/// Capture permission reported by the iMac in the device registry.
enum TBMediaPermission: String, CaseIterable, Sendable {
    case authorized, denied, restricted, notDetermined
    init(wire: String) { self = Self(rawValue: wire) ?? .notDetermined }
}

/// Result of the last virtual-device install action on the Sender.
enum TBVirtualDeviceState: String, CaseIterable, Sendable {
    case notInstalled = "not_installed"
    case signingRequired = "signing_required"
    case moveToApplications = "move_to_applications"
    case installing
    case approvalRequired = "approval_required"
    case installed
    case restartRequired = "restart_required"
    case speakerRestartRequired = "speaker_restart_required"
    case installFailed = "install_failed"

    var localizationKey: String { "sender.media.devices." + rawValue }
}

/// What one reused iMac peripheral can do right now, shown per device.
enum TBMediaEndpointStatus: String, CaseIterable, Sendable {
    /// The build has no Developer team signature, so macOS will not register the virtual device.
    case signingRequired = "signing_required"
    case notInstalled = "not_installed"
    case disconnected
    /// The iMac reports no such capture device.
    case unavailable
    case permissionPending = "permission_pending"
    case permissionDenied = "permission_denied"
    case inactive
    case active

    var localizationKey: String { "sender.media.endpoint." + rawValue }

    /// Camera or microphone: an iMac capture device feeding a Sender virtual device.
    static func capture(installed: Bool, signingConfigured: Bool, linked: Bool, deviceCount: Int,
                        permission: TBMediaPermission, active: Bool) -> Self {
        // The virtual devices only accept frames from a Sender signed by their own team.
        if !signingConfigured { return .signingRequired }
        if !installed { return .notInstalled }
        if !linked { return .disconnected }
        if active { return .active }
        if permission == .denied || permission == .restricted { return .permissionDenied }
        if deviceCount == 0 { return .unavailable }
        return permission == .authorized ? .inactive : .permissionPending
    }

    /// Speakers: Sender audio played by the iMac through the virtual output device.
    /// `audioEnabled`: a connected session has its sound switch on.
    static func speaker(installed: Bool, sessionConnected: Bool, audioEnabled: Bool, selectedAsOutput: Bool) -> Self {
        if !installed { return .notInstalled }
        if !sessionConnected { return .disconnected }
        return audioEnabled && selectedAsOutput ? .active : .inactive
    }
}
