import SwiftUI

struct TBMediaSettingsView: View {
    let language: TBDisplaySenderLanguage
    var sessionConnected = false
    var sessionAudioEnabled = false
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(TBDisplaySenderL10n.text("sender.media.title", language)).font(.headline)
                Text(TBDisplaySenderL10n.text("sender.media.hint", language)).font(.footnote).foregroundStyle(.secondary)
                TBMediaEndpointSummary(language: language, sessionConnected: sessionConnected, sessionAudioEnabled: sessionAudioEnabled)
                TBMediaConnectionSettings(language: language)
                TBMediaCaptureSettings(language: language)
                TBMediaInstallationSettings(language: language)
            }
        }
    }
}

/// One line per reused iMac peripheral: what it can do right now and why.
private struct TBMediaEndpointSummary: View {
    private struct Row: Identifiable {
        let id: String
        let status: TBMediaEndpointStatus
    }
    let language: TBDisplaySenderLanguage
    let sessionConnected: Bool
    let sessionAudioEnabled: Bool
    @State private var bridge = TBMediaBridge.shared
    @State private var virtualDevices = TBVirtualDevices.shared
    private func text(_ key: String) -> String { TBDisplaySenderL10n.text("sender.media." + key, language) }
    private var rows: [Row] {
        let linked = bridge.state.isLinked, signed = virtualDevices.signingConfigured
        return [
            Row(id: "camera", status: .capture(
                installed: virtualDevices.cameraInstalled, signingConfigured: signed, linked: linked,
                deviceCount: bridge.cameras.count, permission: bridge.cameraPermission,
                active: bridge.cameraID != nil && !bridge.requestPending)),
            Row(id: "microphone", status: .capture(
                installed: virtualDevices.microphoneInstalled, signingConfigured: signed, linked: linked,
                deviceCount: bridge.microphones.count, permission: bridge.microphonePermission,
                active: bridge.microphoneID != nil && !bridge.requestPending)),
            Row(id: "speaker", status: .speaker(
                installed: virtualDevices.speakerInstalled, sessionConnected: sessionConnected, audioEnabled: sessionAudioEnabled,
                selectedAsOutput: virtualDevices.speakerSelected))
        ]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(color(row.status)).frame(width: 8, height: 8)
                    Text(text(row.id)).font(.footnote.weight(.semibold)).frame(width: 96, alignment: .leading)
                    Text(TBDisplaySenderL10n.text(row.status.localizationKey, language))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                virtualDevices.refreshPresence()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }
    private func color(_ status: TBMediaEndpointStatus) -> Color {
        switch status {
        case .active: return .green
        case .inactive: return .secondary
        case .disconnected, .permissionPending: return .yellow
        case .signingRequired, .notInstalled, .unavailable, .permissionDenied: return .orange
        }
    }
}

private struct TBMediaConnectionSettings: View {
    let language: TBDisplaySenderLanguage
    @State private var bridge = TBMediaBridge.shared
    private func text(_ key: String) -> String { TBDisplaySenderL10n.text("sender.media." + key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField(text("host"), text: $bridge.host).textFieldStyle(.roundedBorder)
                    .disabled(bridge.state == .connecting || !bridge.devices.isEmpty)
                Button(text("connect")) { bridge.connect() }.disabled(bridge.state == .connecting || !bridge.devices.isEmpty)
                Button(text("disconnect")) { bridge.disconnect() }.disabled(bridge.state == .disconnected)
            }
            Text(TBDisplaySenderL10n.text(bridge.state.localizationKey, language)).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct TBMediaCaptureSettings: View {
    let language: TBDisplaySenderLanguage
    @State private var bridge = TBMediaBridge.shared
    @State private var selectedCamera = ""
    @State private var selectedMicrophone = ""
    private func text(_ key: String) -> String { TBDisplaySenderL10n.text("sender.media." + key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !bridge.devices.isEmpty {
                HStack {
                    Picker(text("camera"), selection: $selectedCamera) {
                        Text(text("choose")).tag("")
                        ForEach(bridge.cameras) { item in Text(item.name).tag(item.id) }
                    }
                    .disabled(bridge.cameraID != nil || bridge.requestPending)
                    Button(text(bridge.cameraID == nil ? "enable" : "disable")) {
                        bridge.configure(camera: bridge.cameraID == nil ? selectedCamera : nil, microphone: bridge.microphoneID)
                    }.disabled(bridge.requestPending || (bridge.cameraID == nil && selectedCamera.isEmpty))
                }
                HStack {
                    Picker(text("microphone"), selection: $selectedMicrophone) {
                        Text(text("choose")).tag("")
                        ForEach(bridge.microphones) { item in Text(item.name).tag(item.id) }
                    }
                    .disabled(bridge.microphoneID != nil || bridge.requestPending)
                    Button(text(bridge.microphoneID == nil ? "enable" : "disable")) {
                        bridge.configure(camera: bridge.cameraID, microphone: bridge.microphoneID == nil ? selectedMicrophone : nil)
                    }.disabled(bridge.requestPending || (bridge.microphoneID == nil && selectedMicrophone.isEmpty))
                }
                Text(text("privacy")).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct TBMediaInstallationSettings: View {
    let language: TBDisplaySenderLanguage
    @State private var virtualDevices = TBVirtualDevices.shared
    private func text(_ key: String) -> String { TBDisplaySenderL10n.text("sender.media." + key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack {
                Button(text("install_speaker")) { virtualDevices.installSpeaker() }
                Button(text("install_camera")) { virtualDevices.installCamera() }
                Button(text("install_microphone")) { virtualDevices.installMicrophone() }
            }.disabled(virtualDevices.busy)
            Text(text("speaker_hint")).font(.footnote).foregroundStyle(.secondary)
            Text(TBDisplaySenderL10n.text(virtualDevices.state.localizationKey, language)).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
