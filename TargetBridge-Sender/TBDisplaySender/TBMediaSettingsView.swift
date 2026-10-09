import SwiftUI

struct TBMediaSettingsView: View {
    let language: TBDisplaySenderLanguage
    var body: some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(TBDisplaySenderL10n.text("sender.media.title", language)).font(.headline)
                Text(TBDisplaySenderL10n.text("sender.media.hint", language)).font(.footnote).foregroundStyle(.secondary)
                TBMediaConnectionSettings(language: language)
                TBMediaCaptureSettings(language: language)
                TBMediaInstallationSettings(language: language)
            }
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
                    .disabled(bridge.state == "connecting" || !bridge.devices.isEmpty)
                Button(text("connect")) { bridge.connect() }.disabled(bridge.state == "connecting" || !bridge.devices.isEmpty)
                Button(text("disconnect")) { bridge.disconnect() }.disabled(bridge.state == "disconnected")
            }
            Text(text("state." + bridge.state)).font(.footnote).foregroundStyle(.secondary)
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
            Text(text("devices." + virtualDevices.state)).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
