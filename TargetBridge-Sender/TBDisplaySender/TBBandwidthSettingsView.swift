import SwiftUI

struct TBBandwidthSettingsView: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var interface = ""
    @State private var capacity = 900.0
    @State private var allocation = TBBandwidthAllocation()
    @State private var feedback = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TBDisplaySenderL10n.text("sender.bandwidth.hint", service.language))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Picker(TBDisplaySenderL10n.text("sender.video_protection.interface", service.language), selection: $interface) {
                    ForEach(service.videoLinkNames, id: \.self) { Text($0).tag($0) }
                }
                TextField(TBDisplaySenderL10n.text("sender.video_protection.capacity", service.language), value: $capacity, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                Text("Mbps").foregroundStyle(.secondary)
            }
            .onChange(of: interface) { _, name in
                capacity = service.videoLinkCapacity(for: name)
                allocation = service.bandwidthAllocation(for: name)
                feedback = ""
            }
            HStack {
                ForEach(["display", "call", "files"], id: \.self) { name in
                    Button(TBDisplaySenderL10n.text("sender.bandwidth.preset." + name, service.language)) {
                        allocation = .preset(name); feedback = ""
                    }.buttonStyle(.bordered)
                }
                Spacer()
                Picker(TBDisplaySenderL10n.text("sender.bandwidth.mode", service.language), selection: $allocation.borrowUnused) {
                    Text(TBDisplaySenderL10n.text("sender.bandwidth.fixed", service.language)).tag(false)
                    Text(TBDisplaySenderL10n.text("sender.bandwidth.borrow", service.language)).tag(true)
                }.frame(maxWidth: 220)
            }
            TBBandwidthPoolsView(forward: allocation.forward, reverse: allocation.reverse, capacity: capacity, language: service.language)
            TBBandwidthChannelRow(name: "video", direction: "→ iMac", value: $allocation.video, minimum: 2, capacity: capacity, language: service.language)
            TBBandwidthChannelRow(name: "speaker", direction: "→ iMac", value: $allocation.speaker, minimum: 2, capacity: capacity, language: service.language)
            TBBandwidthChannelRow(name: "camera", direction: "→ Sender", value: $allocation.camera, minimum: 1, capacity: min(1000, capacity), language: service.language)
            TBBandwidthChannelRow(name: "microphone", direction: "→ Sender", value: $allocation.microphone, minimum: 1, capacity: capacity, language: service.language)
            TBBandwidthChannelRow(name: "disk", direction: "↔", value: $allocation.disk, minimum: 0, capacity: capacity, language: service.language, managed: false)
            TBBandwidthChannelRow(name: "sd", direction: "↔", value: $allocation.sd, minimum: 0, capacity: capacity, language: service.language, managed: false)
            Text(TBDisplaySenderL10n.text("sender.bandwidth.boundary", service.language))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Button(TBDisplaySenderL10n.text("sender.bandwidth.apply", service.language)) {
                    feedback = service.applyBandwidth(allocation, capacity: capacity, for: interface)
                        ? "sender.bandwidth.applied" : "sender.bandwidth.rejected"
                }.buttonStyle(.borderedProminent)
                    .disabled(interface.isEmpty || !allocation.isValid(capacity: capacity) || service.anyConnected || TBMediaBridge.shared.state != "disconnected")
                if !feedback.isEmpty { Text(TBDisplaySenderL10n.text(feedback, service.language)).font(.footnote) }
            }
            ForEach(service.sessions) { session in
                if !session.videoProtectionSummary.isEmpty {
                    Text("\(session.receiverDisplayName): \(session.videoProtectionSummary)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if !session.receiverMetricsSummary.isEmpty {
                    Text(session.receiverMetricsSummary).font(.footnote).foregroundStyle(.secondary)
                }
                if !session.audioQueueSummary.isEmpty {
                    Text(session.audioQueueSummary).font(.footnote).foregroundStyle(.secondary)
                }
            }
        }.onAppear { interface = service.videoLinkNames.first ?? "" }
    }
}

private struct TBBandwidthPoolsView: View {
    let forward: Double, reverse: Double, capacity: Double
    let language: TBDisplaySenderLanguage
    var body: some View {
        HStack(spacing: 18) {
            ForEach([0, 1], id: \.self) { index in
                let total = index == 0 ? forward : reverse
                let available = capacity.isFinite ? max(0, capacity) : 0
                VStack(alignment: .leading, spacing: 4) {
                    Text(index == 0 ? "Sender → iMac" : "iMac → Sender").font(.caption.bold())
                    ProgressView(value: total.isFinite ? min(max(0, total), available) : 0, total: max(1, available))
                    Text("\(total.formatted(.number.precision(.fractionLength(1)))) / \(available.formatted()) Mbps")
                        .font(.caption).foregroundStyle(total <= available ? Color.secondary : .orange)
                    if total > available { Text(TBDisplaySenderL10n.text("sender.bandwidth.over", language)).font(.caption).foregroundStyle(.orange) }
                }
            }
        }
    }
}

private struct TBBandwidthChannelRow: View {
    let name: String, direction: String
    @Binding var value: Double
    let minimum: Double, capacity: Double
    let language: TBDisplaySenderLanguage
    var managed = true
    var body: some View {
        HStack(spacing: 10) {
            Text(TBDisplaySenderL10n.text("sender.bandwidth." + name, language)).frame(width: 80, alignment: .leading)
            Text(direction).font(.caption).foregroundStyle(.secondary).frame(width: 72, alignment: .leading)
            if managed {
                Slider(value: $value, in: minimum...max(minimum + 1, capacity.isFinite ? capacity : 900), step: 1)
                TextField("Mbps", value: $value, format: .number).textFieldStyle(.roundedBorder).frame(width: 65)
                Text("Mbps · \((value / 8).formatted(.number.precision(.fractionLength(1)))) MB/s")
                    .font(.caption).monospacedDigit().frame(width: 145, alignment: .trailing)
            } else {
                Text(TBDisplaySenderL10n.text("sender.bandwidth.smb", language)).font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}
