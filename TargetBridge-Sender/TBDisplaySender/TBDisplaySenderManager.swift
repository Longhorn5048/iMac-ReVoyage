import AppKit
import ApplicationServices
import Combine
import Foundation
import Network

enum TBTransportKind: String, CaseIterable, Identifiable {
    case thunderboltBridge
    case networkLink

    var id: String { rawValue }

    func title(_ language: TBDisplaySenderLanguage) -> String {
        switch (self, language) {
        case (.thunderboltBridge, .italian): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .english): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .german): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .french): return "Thunderbolt Bridge"
        case (.thunderboltBridge, .chinese): return "Thunderbolt Bridge"
        case (.networkLink, .italian): return "Network Link (sperimentale)"
        case (.networkLink, .english): return "Network Link (experimental)"
        case (.networkLink, .german): return "Network Link (experimentell)"
        case (.networkLink, .french): return "Network Link (expérimental)"
        case (.networkLink, .chinese): return "Network Link（实验性）"
        }
    }
}

struct TBLocalLinkInterface: Identifiable, Hashable {
    let name: String
    let ip: String
    let transportKind: TBTransportKind
    let linkMbps: Int

    var id: String { "\(transportKind.rawValue)|\(name)|\(ip)" }

    func displayText(_ language: TBDisplaySenderLanguage) -> String {
        "\(name) · \(ip) · \(transportKind.title(language)) · \(linkMbps > 0 ? "\(linkMbps) Mbps" : TBDisplaySenderL10n.text("sender.network.speed_unknown", language))"
    }
}

@MainActor
final class TBDisplaySenderService: ObservableObject {
    let receiverUpdater = TBReceiverUpdater()
    static let shared = TBDisplaySenderService()
    private static let receiverNoSignalSleepDefaultsKey = "com.revoyage.receiver.noSignalSleepSeconds.v1"

    @Published var sessions: [TBDisplaySenderSession] = []
    @Published private(set) var localInterfaces: [TBLocalLinkInterface] = []
    @Published private(set) var videoLinkNames: [String] = []
    @Published private(set) var discoveredReceivers: [TBDiscoveredReceiver] = []
    @Published private(set) var addons: [TBAddonRecord] = []
    @Published private(set) var receiverPairingConfigured = TBReceiverPairingCredential.load(forReceiver:
        UserDefaults.standard.string(forKey: "com.revoyage.sender.pairing-host.v2") ?? "") != nil
    @Published var receiverPairingHost = UserDefaults.standard.string(forKey: "com.revoyage.sender.pairing-host.v2") ?? "" {
        didSet {
            UserDefaults.standard.set(receiverPairingHost, forKey: "com.revoyage.sender.pairing-host.v2")
            receiverPairingConfigured = TBReceiverPairingCredential.load(forReceiver: receiverPairingHost) != nil
        }
    }
    @Published var receiverStorageHost: String = UserDefaults.standard.string(forKey: "com.revoyage.sender.receiverStorageHost.v1") ?? "" {
        didSet {
            UserDefaults.standard.set(receiverStorageHost, forKey: "com.revoyage.sender.receiverStorageHost.v1")
            scheduleStorageMonitorConfiguration()
        }
    }
    @Published private(set) var receiverStorageVolumes: [TBMonitorRemovableVolume] = []
    @Published private(set) var receiverStorageMonitorStatus: TBStorageMonitorStatus = .needsHost
    /// Changes whenever the app returns from System Settings so permission cards
    /// re-evaluate their live TCC state instead of showing a stale warning.
    @Published private(set) var privacyPermissionsRevision = 0
    @Published var language: TBDisplaySenderLanguage = .load() {
        didSet {
            language.persist()
            sessions.forEach { $0.language = language }
            pushLanguageUpdateToDiscoveredReceivers()
            objectWillChange.send()
        }
    }
    @Published var showsMenuBarIcon = true
    @Published var hidesDockIcon = UserDefaults.standard.bool(forKey: "com.revoyage.sender.hidesDockIcon.v1") {
        didSet {
            UserDefaults.standard.set(hidesDockIcon, forKey: "com.revoyage.sender.hidesDockIcon.v1")
        }
    }
    @Published var largeCursor: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.largeCursor") {
        didSet {
            UserDefaults.standard.set(largeCursor, forKey: "fd.tbdisplaysender.largeCursor")
            sessions.forEach { $0.largeCursor = largeCursor }
            objectWillChange.send()
        }
    }
    @Published var preventDisplaySleep: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.preventDisplaySleep") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.preventDisplaySleep")
    }() {
        didSet {
            UserDefaults.standard.set(preventDisplaySleep, forKey: "fd.tbdisplaysender.preventDisplaySleep")
            sessions.forEach { $0.preventDisplaySleep = preventDisplaySleep }
            objectWillChange.send()
        }
    }
    @Published var autoRestartOnWake: Bool = {
        if UserDefaults.standard.object(forKey: "fd.tbdisplaysender.autoRestartOnWake") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.autoRestartOnWake")
    }() {
        didSet {
            UserDefaults.standard.set(autoRestartOnWake, forKey: "fd.tbdisplaysender.autoRestartOnWake")
            sessions.forEach { $0.autoRestartOnWake = autoRestartOnWake }
            objectWillChange.send()
        }
    }
    @Published var verboseDisplayLogging: Bool = UserDefaults.standard.bool(forKey: "fd.tbdisplaysender.verboseDisplayLogging") {
        didSet {
            UserDefaults.standard.set(verboseDisplayLogging, forKey: "fd.tbdisplaysender.verboseDisplayLogging")
            sessions.forEach { $0.verboseDisplayLogging = verboseDisplayLogging }
            objectWillChange.send()
        }
    }
    @Published var audioEnabled: Bool = UserDefaults.standard.object(forKey: "fd.tbdisplaysender.audioEnabled") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(audioEnabled, forKey: "fd.tbdisplaysender.audioEnabled")
            objectWillChange.send()
        }
    }
    @Published var receiverNoSignalSleepSeconds: Int = {
        let saved = UserDefaults.standard.integer(forKey: receiverNoSignalSleepDefaultsKey)
        return [15, 30, 60, 120, 300, 600].contains(saved) ? saved : 30
    }() {
        didSet {
            guard [15, 30, 60, 120, 300, 600].contains(receiverNoSignalSleepSeconds) else {
                receiverNoSignalSleepSeconds = 30
                return
            }
            UserDefaults.standard.set(receiverNoSignalSleepSeconds,
                                      forKey: Self.receiverNoSignalSleepDefaultsKey)
            sessions.forEach { $0.syncReceiverSettingsNow() }
            objectWillChange.send()
        }
    }
    private var sessionCancellables: [UUID: AnyCancellable] = [:]
    private let receiverDiscovery = TBReceiverDiscovery()
    private let addonStore = TBAddonStore.shared
    private let inputRelayController = TBInputRelayController()
    // Resolve through this instance: shared is still being initialized at startup.
    private lazy var storageVolumeMonitor = TBStorageVolumeMonitor(localIPForReceiver: { [weak self] host in
        self?.wiredLocalIP(forReceiver: host)
    })
    private var discoveryCancellable: AnyCancellable?
    private var addonCancellable: AnyCancellable?
    private var storageVolumesCancellable: AnyCancellable?
    private var storageStatusCancellable: AnyCancellable?
    private var storageHostDebounceTask: Task<Void, Never>?
    private var activationObserver: NSObjectProtocol?
    private var terminationObserver: NSObjectProtocol?
    private var clipboardTimer: Timer?
    private var lastClipboardChangeCount: Int = NSPasteboard.general.changeCount
    private var languageCommands: [String: TBAuthenticatedReceiverCommand] = [:]
    private var sentLanguages: [String: String] = [:]
    @Published private(set) var videoLinkCapacities: [String: Double] =
        UserDefaults.standard.dictionary(forKey: "com.revoyage.sender.video-link-capacities.v1") as? [String: Double] ?? [:]
    @Published private(set) var bandwidthAllocations: [String: TBBandwidthAllocation] = {
        guard let data = UserDefaults.standard.data(forKey: "com.revoyage.sender.bandwidth.v1") else { return [:] }
        return (try? JSONDecoder().decode([String: TBBandwidthAllocation].self, from: data)) ?? [:]
    }()
    func bandwidthAllocation(for interface: String) -> TBBandwidthAllocation {
        let capacity = videoLinkCapacity(for: interface)
        let saved = bandwidthAllocations[interface] ?? TBBandwidthAllocation()
        if saved.isValid(capacity: capacity) { return saved }
        return TBBandwidthAllocation(video: max(2, min(700, capacity - 15)),
            speaker: max(2, min(10, capacity - 7)), camera: max(1, min(25, capacity - 6)))
    }
    @discardableResult
    func applyBandwidth(_ allocation: TBBandwidthAllocation, capacity: Double, for interface: String) -> Bool {
        guard !interface.isEmpty, allocation.isValid(capacity: capacity),
              videoLinkBudgets[interface]?.videoReservations.isEmpty ?? true,
              videoLinkBudgets[interface]?.cableTester == nil,
              TBMediaBridge.shared.state == .disconnected,
              !sessions.contains(where: { $0.isConnected || $0.isStreaming }) else { return false }
        guard setVideoLinkCapacity(capacity, for: interface) else { return false }
        bandwidthAllocations[interface] = allocation
        if let data = try? JSONEncoder().encode(bandwidthAllocations) {
            UserDefaults.standard.set(data, forKey: "com.revoyage.sender.bandwidth.v1")
        }
        return true
    }
    func videoBandwidthCeiling(for session: TBDisplaySenderSession) -> Double {
        let name = TBConnectionDiagnostics.interfaceName(forLocalIP: session.localInterfaceIP,
            in: TBConnectionDiagnostics.currentIPv4Interfaces()) ?? "unresolved"
        return bandwidthAllocation(for: name).videoCeiling(capacity: videoLinkCapacity(for: name))
    }
    private var videoLinkBudgets: [String: TBVideoBandwidthBudget] = [:]
    private var sessionBudgetLinks: [UUID: String] = [:]

    func videoLinkCapacity(for interface: String) -> Double {
        let saved = videoLinkCapacities[interface] ?? 900
        return TBVideoBandwidthBudget.validCapacity(saved) ? saved : 900
    }

    @discardableResult
    func setVideoLinkCapacity(_ capacity: Double, for interface: String) -> Bool {
        guard !interface.isEmpty, TBVideoBandwidthBudget.validCapacity(capacity) else { return false }
        var budget = videoLinkBudgets[interface] ?? TBVideoBandwidthBudget(capacityMbps: capacity)
        guard budget.setCapacity(capacity) else { return false }
        videoLinkBudgets[interface] = budget
        videoLinkCapacities[interface] = capacity
        UserDefaults.standard.set(videoLinkCapacities, forKey: "com.revoyage.sender.video-link-capacities.v1")
        return true
    }

    func videoBackgroundCeiling(for interface: String) -> Double {
        (videoLinkBudgets[interface] ?? TBVideoBandwidthBudget(capacityMbps: videoLinkCapacity(for: interface)))
            .backgroundCeilingMbps
    }

    func reserveVideoLink(for session: TBDisplaySenderSession, videoMbps: Double, cableTest: Bool = false) -> Bool {
        let link = sessionBudgetLinks[session.id] ?? TBConnectionDiagnostics.interfaceName(
            forLocalIP: session.localInterfaceIP, in: TBConnectionDiagnostics.currentIPv4Interfaces()
        ) ?? "unresolved"
        var budget = videoLinkBudgets[link] ?? TBVideoBandwidthBudget(capacityMbps: videoLinkCapacity(for: link))
        let allocation = bandwidthAllocation(for: link)
        guard cableTest || allocation.isValid(capacity: videoLinkCapacity(for: link)) else { return false }
        let videoCeiling = allocation.videoCeiling(capacity: videoLinkCapacity(for: link))
        let otherVideo = budget.videoReservations.filter { $0.key != session.id }.values.reduce(0, +)
        if !cableTest && (otherVideo + videoMbps > videoCeiling ||
            Double(budget.videoReservations.filter { $0.key != session.id }.count + 1) * 2 > allocation.speaker) { return false }
        let accepted = cableTest ? budget.beginCableTest(for: session.id)
            : budget.reserveVideo(for: session.id, megabitsPerSecond: videoMbps)
        guard accepted else { return false }
        videoLinkBudgets[link] = budget
        sessionBudgetLinks[session.id] = link
        objectWillChange.send()
        return true
    }

    func releaseVideoLink(for session: TBDisplaySenderSession) {
        guard let link = sessionBudgetLinks.removeValue(forKey: session.id) else { return }
        videoLinkBudgets[link]?.release(session.id)
        objectWillChange.send()
    }

    private init() {
        discoveryCancellable = receiverDiscovery.$receivers.sink { [weak self] receivers in
            guard let self else { return }
            discoveredReceivers = receivers
            pushLanguageUpdateToDiscoveredReceivers()
            objectWillChange.send()
        }
        addonCancellable = addonStore.$addons.sink { [weak self] addons in
            guard let self else { return }
            self.addons = addons
            normalizeAddonState()
            objectWillChange.send()
        }
        storageVolumesCancellable = storageVolumeMonitor.$volumes.sink { [weak self] volumes in
            guard let self else { return }
            receiverStorageVolumes = volumes
            objectWillChange.send()
        }
        storageStatusCancellable = storageVolumeMonitor.$status.sink { [weak self] status in
            guard let self else { return }
            receiverStorageMonitorStatus = status
            objectWillChange.send()
        }
        configureStorageMonitor()
        refreshLocalInterfaces()
        addonStore.refresh()
        restorePersistedSessions()
        startClipboardMonitoring()
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshPrivacyPermissions()
            }
        }
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { TBMediaBridge.shared.disconnect(); self?.stopAll() }
        }
    }

    @discardableResult
    func saveReceiverPairingCode(_ value: String) -> Bool {
        guard let host = TBReceiverPairingCredential.normalizedHost(receiverPairingHost),
              TBReceiverPairingCredential.save(value, forReceiver: host) else { return false }
        receiverPairingConfigured = true
        configureStorageMonitor()
        sessions.filter { TBReceiverPairingCredential.normalizedHost($0.receiverIP) == host }
            .forEach { $0.syncReceiverSettingsNow() }
        sentLanguages.removeValue(forKey: host)
        pushLanguageUpdateToDiscoveredReceivers()
        objectWillChange.send()
        return true
    }

    private func configureStorageMonitor() {
        storageVolumeMonitor.configure(
            host: receiverStorageHost,
            pairingCode: TBReceiverPairingCredential.load(forReceiver: receiverStorageHost)
        )
    }

    private func scheduleStorageMonitorConfiguration() {
        storageHostDebounceTask?.cancel()
        storageHostDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.configureStorageMonitor()
        }
    }

    func refreshPrivacyPermissions() {
        privacyPermissionsRevision &+= 1
    }

    var anyConnected: Bool {
        sessions.contains { $0.isConnected || $0.isStreaming }
    }

    var anyStreaming: Bool {
        sessions.contains { $0.isStreaming }
    }

    var connectedSessionCount: Int {
        sessions.reduce(into: 0) { count, session in
            if session.isConnected || session.isStreaming {
                count += 1
            }
        }
    }

    var localInterfaceSummaryText: String {
        guard !localInterfaces.isEmpty else {
            return TBDisplaySenderL10n.notDetected(language)
        }
        return localInterfaces
            .map { $0.displayText(language) }
            .joined(separator: "   ")
    }

    var availableTransportKinds: [TBTransportKind] {
        TBTransportKind.allCases.filter { transportKind in
            switch transportKind {
            case .thunderboltBridge:
                return true
            case .networkLink:
                return isAddonCapabilityEnabled(.networkLink)
            }
        }
    }

    var audioRelayAvailable: Bool {
        isAddonCapabilityEnabled(.audioRelay)
    }

    var inputDockstationAvailable: Bool {
        isAddonCapabilityEnabled(.inputDockstation)
    }

    var localInputInjectionTrusted: Bool {
        AXIsProcessTrusted()
    }

    var localInputMonitoringTrusted: Bool {
        CGPreflightListenEventAccess()
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func configurationChecks(for session: TBDisplaySenderSession) -> [TBConfigurationCheck] {
        let interfaces = TBConnectionDiagnostics.currentIPv4Interfaces()
        let role = session.inputControlRole
        let snapshot = TBConfigurationDiagnosticSnapshot(
            hasScreenRecording: session.screenCaptureAccess.diagnosticPermission(preflight: CGPreflightScreenCaptureAccess()),
            transportIsThunderbolt: session.transportKind == .thunderboltBridge,
            localInterfaceName: TBConnectionDiagnostics.interfaceName(forLocalIP: session.localInterfaceIP, in: interfaces),
            receiverAddress: session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines),
            receiverProfileAvailable: session.receiverSupportsHEVCDecodeHint != nil,
            receiverSupportsHEVC: session.receiverSupportsHEVCDecodeHint,
            requiresHEVC: session.capturePreset.codecName == "HEVC",
            cableRate: session.cableTestResult,
            requiresSenderInputMonitoring: role == .senderMaster,
            senderInputMonitoringGranted: localInputMonitoringTrusted,
            requiresSenderAccessibility: role == .receiverMaster,
            senderAccessibilityGranted: localInputInjectionTrusted,
            requiresReceiverInputMonitoring: role == .receiverMaster,
            receiverInputMonitoringGranted: session.receiverInputMonitoringTrustedHint,
            requiresReceiverAccessibility: role == .senderMaster,
            receiverAccessibilityGranted: session.receiverAccessibilityTrustedHint
        )
        return TBConfigurationDiagnostics.checks(for: snapshot)
    }

    func addSession() {
        let session = TBDisplaySenderSession(
            language: language,
            largeCursor: largeCursor,
            preventDisplaySleep: preventDisplaySleep,
            autoRestartOnWake: autoRestartOnWake,
            audioEnabled: audioEnabled && audioRelayAvailable,
            verboseDisplayLogging: verboseDisplayLogging
        )
        if let previous = sessions.last {
            session.capturePreset = previous.capturePreset
            session.captureSource = previous.captureSource
            session.transportKind = previous.transportKind
            session.audioEnabled = audioRelayAvailable && previous.audioEnabled
            session.inputGestureMode = previous.inputGestureMode
        }
        session.audioAddonAvailable = audioRelayAvailable
        if let suggestedInterface = suggestedInterfaceForNewSession(transportKind: session.transportKind) {
            session.localInterfaceIP = suggestedInterface.ip
        }
        attachSession(session)
        sessions.append(session)
        schedulePersist()
        objectWillChange.send()
    }

    func removeSession(_ session: TBDisplaySenderSession) {
        guard sessions.count > 1 else { return }
        session.stop()
        sessions.removeAll { $0.id == session.id }
        sessionCancellables.removeValue(forKey: session.id)
        normalizeAddonState()
        normalizeSessionInterfaces()
        schedulePersist()
        objectWillChange.send()
    }

    func stopAll() {
        receiverUpdater.cancelAutomaticResume()
        sessions.forEach { $0.persistExtendedDisplayArrangementSnapshot() }
        sessions.forEach { $0.stop(persistArrangement: false) }
    }

    // MARK: - Session persistence

    private static let persistedSessionsKey = "fd.tbdisplaysender.sessions.v1"
    private static let receiverDisplayProfilesKey = "fd.tbdisplaysender.receiverDisplayProfiles.v1"

    /// Snapshot of the user-configurable settings for a single session. Transient
    /// runtime state (connection, FPS, …) is intentionally excluded — only the
    /// choices the user makes in the UI are remembered across launches. The input
    /// master role (Input Dockstation) is a user choice, so it is persisted too;
    /// role and bindings are optional for backward compatibility with sessions
    /// saved before either setting was added.
    private struct PersistedSession: Codable {
        var transportKind: String
        var localInterfaceIP: String
        var receiverIP: String
        var selectedReceiverID: String
        var capturePreset: String
        var captureSource: String
        var audioEnabled: Bool
        var brightness: Double
        var inputGestureMode: String
        var volume: Double?
        var inputControlRole: String?
        var inputBindings: [TBInputBinding]?
        var matchRenderToStream: Bool?
        var automaticQuality: Bool?
    }

    private var lastPersistedData: Data?
    private var persistScheduled = false

    /// Coalesces the many synchronous `objectWillChange` notifications a single
    /// user action produces into one write. Runs on the next main-loop tick, so
    /// it observes the post-change values rather than the pre-change ones that
    /// `objectWillChange` fires with.
    private func schedulePersist() {
        guard !persistScheduled else { return }
        persistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.persistScheduled = false
            self.persistSessions()
        }
    }

    private func persistSessions() {
        let configs = sessions.map { session in
            PersistedSession(
                transportKind: session.transportKind.rawValue,
                localInterfaceIP: session.localInterfaceIP,
                receiverIP: session.receiverIP,
                selectedReceiverID: session.selectedReceiverID,
                capturePreset: session.capturePreset.rawValue,
                captureSource: session.captureSource.rawValue,
                audioEnabled: session.audioEnabled,
                brightness: session.brightness,
                inputGestureMode: session.inputGestureMode.rawValue,
                volume: session.volume,
                inputControlRole: session.inputControlRole.rawValue,
                inputBindings: session.inputBindings,
                matchRenderToStream: session.matchRenderToStream,
                automaticQuality: session.automaticQuality
            )
        }
        guard let data = try? JSONEncoder().encode(configs) else { return }
        // Streaming churns `objectWillChange` constantly; skip redundant writes.
        guard data != lastPersistedData else { return }
        lastPersistedData = data
        UserDefaults.standard.set(data, forKey: Self.persistedSessionsKey)
    }

    private func restorePersistedSessions() {
        guard let data = UserDefaults.standard.data(forKey: Self.persistedSessionsKey),
              let configs = try? JSONDecoder().decode([PersistedSession].self, from: data),
              !configs.isEmpty
        else {
            addSession()
            return
        }

        lastPersistedData = data
        for config in configs {
            let session = TBDisplaySenderSession(
                language: language,
                largeCursor: largeCursor,
                preventDisplaySleep: preventDisplaySleep,
                autoRestartOnWake: autoRestartOnWake,
                audioEnabled: audioEnabled && audioRelayAvailable,
                verboseDisplayLogging: verboseDisplayLogging
            )
            apply(config, to: session)
            session.audioAddonAvailable = audioRelayAvailable
            attachSession(session)
            sessions.append(session)
        }
        // Enforce the single-master invariant: only one session may hold a
        // non-`off` input role. (Persisted data should already satisfy this, but
        // restore sets roles directly, so guard against stale/edited defaults.)
        if let firstMaster = sessions.first(where: { $0.inputControlRole != .off }) {
            for session in sessions where session.id != firstMaster.id {
                session.inputControlRole = .off
            }
        }
        // Drop transports/audio for addons that are no longer enabled and make
        // sure every restored interface still exists on this machine.
        normalizeAddonState()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    private func apply(_ config: PersistedSession, to session: TBDisplaySenderSession) {
        if let transport = TBTransportKind(rawValue: config.transportKind) {
            session.transportKind = transport
        }
        if let preset = TBDisplayCapturePreset(rawValue: config.capturePreset) {
            session.capturePreset = preset
        }
        if let source = TBDisplayCaptureSource(rawValue: config.captureSource) {
            session.captureSource = source
        }
        if let gesture = TBInputGestureMode(rawValue: config.inputGestureMode) {
            session.inputGestureMode = gesture
        }
        if let roleRaw = config.inputControlRole,
           let role = TBInputControlRole(rawValue: roleRaw) {
            session.inputControlRole = role
        }
        if let bindings = config.inputBindings {
            session.inputBindings = bindings
        }
        session.automaticQuality = config.automaticQuality ?? false
        session.receiverIP = config.receiverIP
        session.selectedReceiverID = config.selectedReceiverID
        session.localInterfaceIP = config.localInterfaceIP
        session.audioEnabled = config.audioEnabled && audioRelayAvailable
        session.brightness = config.brightness
        session.volume = config.volume ?? 0.5
        session.matchRenderToStream = config.matchRenderToStream ?? false
    }

    func refreshLocalInterfaces() {
        localInterfaces = detectLocalInterfaces()
        videoLinkNames = Array(Set(localInterfaces.map(\.name))).sorted()
        receiverDiscovery.refresh()
        normalizeSessionInterfaces()
        objectWillChange.send()
    }

    func applyDiscoveredReceiver(_ receiver: TBDiscoveredReceiver, to session: TBDisplaySenderSession) {
        session.receiverIP = receiver.ip(for: session.transportKind)
        session.receiverSupportsHEVCDecodeHint = receiver.supportsHEVCDecode
        session.receiverIdentityHint = receiver.receiverID
        if session.localInterfaceIP.isEmpty {
            session.localInterfaceIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                ?? availableInterfaces(for: session.transportKind).first?.ip
                ?? ""
        }
        restoreDisplayProfile(for: session)
        objectWillChange.send()
    }

    func applyDisplayProfile(_ profile: TBDisplayProfile, to session: TBDisplaySenderSession) {
        guard !session.isConnected, !session.isStreaming else { return }

        session.automaticQuality = false
        let settings = profile.settings
        session.captureSource = settings.captureSource
        session.capturePreset = settings.capturePreset
        session.matchRenderToStream = settings.matchRenderToStream
        session.audioEnabled = settings.audioEnabled && audioRelayAvailable

        guard let receiverKey = receiverProfileKey(for: session) else { return }
        var profiles = persistedDisplayProfiles
        profiles[receiverKey] = profile.rawValue
        UserDefaults.standard.set(profiles, forKey: Self.receiverDisplayProfilesKey)
    }

    func migrateDisplayProfileAfterAuthentication(host: String, identity: String) {
        var profiles = persistedDisplayProfiles
        let newKey = "id:\(identity)"
        guard profiles[newKey] == nil else { return }
        let legacyKeys = ["ip:\(host)"] + discoveredReceivers.map { "id:\($0.serviceName)|\(host)" }
        if let value = legacyKeys.compactMap({ profiles[$0] }).first {
            profiles[newKey] = value
            UserDefaults.standard.set(profiles, forKey: Self.receiverDisplayProfilesKey)
        }
    }

    private var persistedDisplayProfiles: [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.receiverDisplayProfilesKey) as? [String: String] ?? [:]
    }

    private func receiverProfileKey(for session: TBDisplaySenderSession) -> String? {
        if let identity = TBReceiverPairingCredential.verifiedIdentity(forReceiver: session.receiverIP) {
            return "id:\(identity)"
        }

        let receiverIP = session.receiverIP.trimmingCharacters(in: .whitespacesAndNewlines)
        return receiverIP.isEmpty ? nil : "ip:\(receiverIP)"
    }

    private func restoreDisplayProfile(for session: TBDisplaySenderSession) {
        guard let receiverKey = receiverProfileKey(for: session),
              let rawValue = persistedDisplayProfiles[receiverKey],
              let profile = TBDisplayProfile(rawValue: rawValue)
        else {
            return
        }

        applyDisplayProfile(profile, to: session)
    }

    func sessionTitle(for session: TBDisplaySenderSession) -> String {
        let index = sessions.firstIndex(where: { $0.id == session.id }).map { $0 + 1 } ?? 0
        return TBDisplaySenderL10n.sessionTitle(language, index: index)
    }

    func interfaceDisplayText(for ip: String) -> String {
        localInterfaces.first(where: { $0.ip == ip })?.displayText(language) ?? ip
    }

    func availableInterfaces(for transportKind: TBTransportKind) -> [TBLocalLinkInterface] {
        localInterfaces.filter { $0.transportKind == transportKind }
    }

    func defaultLocalInterfaceIP(for transportKind: TBTransportKind) -> String {
        suggestedInterfaceForNewSession(transportKind: transportKind)?.ip
            ?? availableInterfaces(for: transportKind).first?.ip
            ?? ""
    }

    func transportDidChange(for session: TBDisplaySenderSession) {
        session.localInterfaceIP = defaultLocalInterfaceIP(for: session.transportKind)
        if let receiver = discoveredReceivers.first(where: { $0.id == session.selectedReceiverID }) {
            session.receiverIP = receiver.ip(for: session.transportKind)
            session.receiverIdentityHint = receiver.receiverID
        }
        objectWillChange.send()
    }

    func refreshAddons() {
        addonStore.refresh()
    }

    func openAddonsFolder() {
        addonStore.openAddonsFolder()
    }

    func importAddonManifest(from url: URL) throws {
        _ = try addonStore.importManifest(from: url)
        normalizeAddonState()
    }

    func isAddonEnabled(_ addon: TBAddonRecord) -> Bool {
        addonStore.isEnabled(addon)
    }

    func setAddonEnabled(_ enabled: Bool, for addon: TBAddonRecord) {
        addonStore.setEnabled(enabled, for: addon)
        normalizeAddonState()
    }

    func isAddonCompatible(_ addon: TBAddonRecord) -> Bool {
        addonStore.isCompatible(addon)
    }

    func summaryStatusText() -> String {
        if anyStreaming {
            return TBDisplaySenderL10n.multiSessionSummaryStreaming(language, active: connectedSessionCount, total: sessions.count)
        }
        if anyConnected {
            return TBDisplaySenderL10n.multiSessionSummaryConnected(language, active: connectedSessionCount, total: sessions.count)
        }
        return TBDisplaySenderStatusState.ready.text(language)
    }

    private func attachSession(_ session: TBDisplaySenderSession) {
        session.audioAddonAvailable = audioRelayAvailable
        session.onRemoteSwitchRequest = { [weak self, weak session] direction in
            guard let self, let session else { return }
            self.switchReceiverMasterTarget(from: session, direction: direction)
        }
        session.onRemoteDeactivateInputRequest = { [weak self, weak session] in
            guard let self, let session else { return }
            self.setInputControlRole(.off, for: session)
        }
        sessionCancellables[session.id] = session.objectWillChange.sink { [weak self] _ in
            self?.updateInputRelayController()
            self?.schedulePersist()
            self?.objectWillChange.send()
        }
    }

    func isInputRelayActive(for session: TBDisplaySenderSession) -> Bool {
        session.inputControlRole != .off
    }

    func setInputControlRole(_ role: TBInputControlRole, for session: TBDisplaySenderSession) {
        for candidate in sessions {
            if candidate.id == session.id {
                candidate.inputControlRole = role
            } else if role != .off {
                candidate.inputControlRole = .off
            }
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchSenderMasterTarget(direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let current = connected.first(where: { $0.inputControlRole == .senderMaster }),
              let currentIndex = connected.firstIndex(where: { $0.id == current.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != current.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .senderMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    func switchReceiverMasterTarget(from session: TBDisplaySenderSession, direction: Int) {
        let connected = sessions.filter { $0.isConnected || $0.isStreaming }
        guard connected.count > 1,
              let currentIndex = connected.firstIndex(where: { $0.id == session.id })
        else {
            return
        }

        let nextIndex = (currentIndex + (direction >= 0 ? 1 : connected.count - 1)) % connected.count
        let next = connected[nextIndex]
        guard next.id != session.id else { return }

        for candidate in sessions {
            candidate.inputControlRole = (candidate.id == next.id) ? .receiverMaster : .off
        }
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
        objectWillChange.send()
    }

    private func isAddonCapabilityEnabled(_ capability: TBAddonCapability) -> Bool {
        addonStore.isCapabilityEnabled(capability)
    }

    private func normalizeAddonState() {
        let networkLinkEnabled = isAddonCapabilityEnabled(.networkLink)
        let audioEnabled = audioRelayAvailable
        let inputEnabled = inputDockstationAvailable

        for session in sessions {
            session.audioAddonAvailable = audioEnabled
            if !audioEnabled {
                session.audioEnabled = false
            }
            if !networkLinkEnabled, session.transportKind == .networkLink {
                session.transportKind = .thunderboltBridge
            }
            if !inputEnabled {
                session.inputControlRole = .off
                session.inputGestureMode = .native
            }
        }

        normalizeSessionInterfaces()
        updateInputRelayController()
        sessions.forEach { $0.updateInputControlMode() }
    }

    private func updateInputRelayController() {
        guard inputDockstationAvailable,
              let session = sessions.first(where: { $0.inputControlRole == .senderMaster })
        else {
            inputRelayController.stop()
            return
        }

        inputRelayController.start(
            gestureMode: session.inputGestureMode,
            handler: { [weak self] relayEvent in
                guard let self,
                      session.isConnected
                else { return }
                session.sendInputEvent(relayEvent)
            },
            switchHandler: { [weak self] direction in
                self?.switchSenderMasterTarget(direction: direction)
            },
            deactivateHandler: { [weak self, weak session] in
                guard let self, let session else { return }
                self.setInputControlRole(.off, for: session)
            }
        )
    }

    private func startClipboardMonitoring() {
        clipboardTimer?.invalidate()
        clipboardTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pollClipboardIfNeeded()
            }
        }
    }

    private func pollClipboardIfNeeded() {
        guard let session = sessions.first(where: { $0.inputControlRole == .senderMaster && ($0.isConnected || $0.isStreaming) }) else {
            lastClipboardChangeCount = NSPasteboard.general.changeCount
            return
        }

        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastClipboardChangeCount else { return }
        lastClipboardChangeCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string) else { return }
        session.sendClipboardText(text)
    }

    private func suggestedInterfaceForNewSession(transportKind: TBTransportKind) -> TBLocalLinkInterface? {
        let candidates = availableInterfaces(for: transportKind)
        let usedIPs = Set(
            sessions
                .filter { $0.transportKind == transportKind }
                .map(\.localInterfaceIP)
                .filter { !$0.isEmpty }
        )
        return candidates.first(where: { !usedIPs.contains($0.ip) }) ?? candidates.first
    }

    private func normalizeSessionInterfaces() {
        for session in sessions {
            let available = availableInterfaces(for: session.transportKind)
            let validIPs = Set(available.map(\.ip))
            let fallbackIP = suggestedInterfaceForNewSession(transportKind: session.transportKind)?.ip
                ?? available.first?.ip
                ?? ""
            if session.localInterfaceIP.isEmpty || !validIPs.contains(session.localInterfaceIP) {
                session.localInterfaceIP = fallbackIP
            }
        }
    }

    private func pushLanguageUpdateToDiscoveredReceivers() {
        let languageCode = language.fileStem
        for receiver in discoveredReceivers {
            let candidateIPs = [receiver.preferredIP, receiver.thunderboltIP, receiver.networkIP]
            // Receiver has one main socket. Never queue an auxiliary command
            // behind an active display connection or dial every alias at once.
            guard !sessions.contains(where: {
                $0.hasActiveConnection && (candidateIPs.contains($0.receiverIP) || $0.selectedReceiverID == receiver.id)
            }), let ip = candidateIPs.first(where: { TBReceiverPairingCredential.load(forReceiver: $0) != nil })
            else { continue }
            sendLanguageUpdate(to: ip, languageCode: languageCode)
        }
    }

    func cancelReceiverCommands(forReceiver host: String) {
        guard let host = TBReceiverPairingCredential.normalizedHost(host) else { return }
        languageCommands[host]?.cancel()
    }

    private func sendLanguageUpdate(to receiverIP: String, languageCode: String) {
        guard let host = TBReceiverPairingCredential.normalizedHost(receiverIP),
              sentLanguages[host] != languageCode,
              languageCommands[host] == nil, languageCommands.count < 8,
              let pairingCode = TBReceiverPairingCredential.load(forReceiver: host),
              let packet = TBMonitorProtocol.makeJSONPacket(
                type: .uiLanguage,
                value: TBMonitorUILanguageUpdate(uiLanguage: languageCode)
              )
        else { return }

        guard let command = TBAuthenticatedReceiverCommand(host: host, pairingCode: pairingCode, command: packet,
                                                           completion: { [weak self] success in
            guard let self else { return }
            self.languageCommands.removeValue(forKey: host)
            if success {
                self.sentLanguages[host] = languageCode
                self.pushLanguageUpdateToDiscoveredReceivers()
            }
        }) else { return }
        languageCommands[host] = command
        command.start()
    }

    func wiredLocalIP(forReceiver host: String) -> String? {
        sessions.first(where: { $0.receiverIP == host && !$0.localInterfaceIP.isEmpty })?.localInterfaceIP
    }

    private func detectLocalInterfaces() -> [TBLocalLinkInterface] {
        TBWiredConnection.currentLinks().filter { isLikelyLANIPv4($0.ip) }.map { link in
            TBLocalLinkInterface(name: link.name, ip: link.ip,
                transportKind: link.name.hasPrefix("bridge") && link.ip.hasPrefix("169.254.") ? .thunderboltBridge : .networkLink,
                linkMbps: link.mbps)
        }.sorted { $0.id < $1.id }
    }

    private func isLikelyLANIPv4(_ ip: String) -> Bool {
        if ip.hasPrefix("127.") {
            return false
        }
        if ip.hasPrefix("169.254.") || ip.hasPrefix("10.") || ip.hasPrefix("192.168.") {
            return true
        }
        let components = ip.split(separator: ".")
        guard components.count == 4,
              let first = Int(components[0]),
              let second = Int(components[1])
        else {
            return false
        }
        return first == 172 && (16...31).contains(second)
    }
}
