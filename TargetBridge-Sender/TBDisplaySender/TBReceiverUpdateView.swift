import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TBReceiverUpdateView: View {
    let service: TBDisplaySenderService
    @Bindable var updater: TBReceiverUpdater
    @Binding var host: String
    let language: TBDisplaySenderLanguage
    let receivers: [TBDiscoveredReceiver]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(text("hint")).font(.footnote).foregroundStyle(.secondary)
            if !receivers.isEmpty {
                Picker(text("receiver"), selection: $host) {
                    if !receivers.contains(where: { $0.preferredIP == host }) {
                        Text(text("custom_host")).tag(host)
                    }
                    ForEach(receivers) { receiver in
                        Text(receiver.displayText).tag(receiver.preferredIP)
                    }
                }
                .disabled(updater.isBusy)
            }
            TextField(text("receiver"), text: $host).textFieldStyle(.roundedBorder).disabled(updater.isBusy)
            HStack {
                Button(text("action"), action: choosePackage).buttonStyle(.borderedProminent)
                Button(text("check")) {
                    updater.checkStatus(host: host.trimmingCharacters(in: .whitespacesAndNewlines),
                        localIP: service.wiredLocalIP(forReceiver: host))
                }.buttonStyle(.bordered)
            }
            .disabled(updater.isBusy || TBReceiverPairingCredential.normalizedHost(host) == nil)
            if updater.isBusy {
                ProgressView(value: updater.progress)
                Text(text(updater.phase.rawValue)).font(.footnote)
            } else if updater.phase == .failed {
                Text(errorText).font(.footnote).foregroundStyle(.orange)
            } else {
                Text(text(updater.phase.rawValue)).font(.footnote).foregroundStyle(.secondary)
            }
            if !updater.receiverBuild.isEmpty {
                Text(TBDisplaySenderL10n.text("sender.receiver_update.build", language, ["build":updater.receiverBuild]))
                    .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(text("bootstrap")).font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func text(_ key: String) -> String { TBDisplaySenderL10n.text("sender.receiver_update." + key, language) }
    private var errorText: String {
        let known = ["unavailable", "wired_required", "invalid_package", "invalid_archive", "incompatible_package", "transfer_failed", "installation_failed", "interrupted", "result_unknown", "busy", "invalid_request"]
        return text(known.contains(updater.errorCode) ? updater.errorCode : "installation_failed")
    }
    private func choosePackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]; panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        updater.update(packageURL: url, host: host, localIP: service.wiredLocalIP(forReceiver: host), service: service)
    }
}
