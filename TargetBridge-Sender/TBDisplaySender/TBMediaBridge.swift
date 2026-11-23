import Foundation
import Network
import Observation
import Security

private final class TBMediaTransport: @unchecked Sendable {
    enum Event: Sendable { case connected, registry(TBMediaRegistry), status(TBMediaStatus), failed(TBMediaBridgeState) }
    // Also serializes native camera queues and HAL writes across reconnects.
    static let queue = DispatchQueue(label: "com.revoyage.sender.media", qos: .userInitiated)
    let connection: NWConnection
    let event: @Sendable (Event) -> Void
    private var buffer = Data()
    private var handshake: TBMediaHandshake
    private var authenticated: Bool { handshake.authenticated }
    private var supportsBandwidthLimit = false
    private var cancelled = false
    private var deadline = ProcessInfo.processInfo.systemUptime + 8
    private var timer: DispatchSourceTimer?
    private var cameraEnabled = false
    private var microphoneEnabled = false
    private var wantedCamera = false
    private var wantedMicrophone = false
    private var sequenceGate = TBMediaSequenceGate()

    init(host: String, localIP: String?, key: String, event: @escaping @Sendable (Event) -> Void) throws {
        self.event = event
        handshake = try TBMediaHandshake(key: key)
        let (dialHost, parameters) = try TBWiredConnection.dial(host: host, localIP: localIP)
        connection = NWConnection(host: dialHost, port: NWEndpoint.Port(rawValue: TBMediaProtocol.port)!, using: parameters)
    }
    func start() {
        Self.queue.async { [self] in
            connection.stateUpdateHandler = { [weak self] state in
                guard let self, !self.cancelled else { return }
                switch state {
                case .ready: self.receive()
                case .failed: self.fail(.connectionFailed)
                default: break
                }
            }
            connection.start(queue: Self.queue)
            let timer = DispatchSource.makeTimerSource(queue: Self.queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in
                guard let self, !self.cancelled else { return }
                if ProcessInfo.processInfo.systemUptime > self.deadline { self.fail(.connectionTimeout); return }
                if self.authenticated { self.send(.heartbeat) }
            }
            self.timer = timer; timer.resume()
        }
    }
    func stop() { Self.queue.async { [self] in finish() } }
    private func finish() {
        guard !cancelled else { return }; cancelled = true
        timer?.cancel(); timer = nil; connection.stateUpdateHandler = nil; connection.cancel()
        buffer.removeAll(); tb_virtual_camera_stop(); tb_virtual_microphone_stop()
    }
    private func fail(_ error: TBMediaBridgeState) { guard !cancelled else { return }; finish(); event(.failed(error)) }
    private func send(_ type: TBMediaPacket, _ payload: Data = Data()) {
        guard !cancelled else { return }
        connection.send(content: TBMediaProtocol.packet(type, payload), completion: .contentProcessed { [weak self] error in
            if error != nil { self?.fail(.connectionFailed) }
        })
    }
    func configure(camera: String?, microphone: String?, cameraMbps: Double) {
        Self.queue.async { [self] in
            guard authenticated, !cancelled, !sequenceGate.awaitingConfiguration else { return }
            guard supportsBandwidthLimit || camera == nil || cameraMbps == 25 else { fail(.bandwidthUnsupported); return }
            cameraEnabled = false; microphoneEnabled = false
            tb_virtual_camera_stop(); tb_virtual_microphone_stop()
            if camera != nil && tb_virtual_camera_start() != 0 { fail(.cameraUnavailable); return }
            if microphone != nil && tb_virtual_microphone_start() != 0 { fail(.microphoneUnavailable); return }
            wantedCamera = camera != nil; wantedMicrophone = microphone != nil
            sequenceGate.beginConfiguration()
            deadline = ProcessInfo.processInfo.systemUptime + 130
            do { send(.request, try JSONEncoder().encode(TBMediaRequest(cameraID: camera, microphoneID: microphone, cameraMbps: supportsBandwidthLimit ? cameraMbps : nil))) }
            catch { fail(.invalidMedia) }
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self, !self.cancelled else { return }
            if let data {
                self.buffer.append(data)
                do {
                    while let (type, payload) = try TBMediaProtocol.drain(&self.buffer) { try self.handle(type, payload) }
                } catch { self.fail(.invalidMedia); return }
            }
            if error != nil || complete { self.fail(.connectionFailed); return }
            self.receive()
        }
    }
    private func handle(_ type: TBMediaPacket, _ data: Data) throws {
        if !authenticated {
            if let reply = try handshake.receive(type, data) { send(.authentication, reply) }
            if authenticated { deadline = ProcessInfo.processInfo.systemUptime + 8; event(.connected) }
            return
        }
        switch type {
        case .registry:
            guard data.count <= 65_536 else { throw TBMediaProtocol.Failure.invalidPacket }
            let registry = try JSONDecoder().decode(TBMediaRegistry.self, from: data)
            guard registry.isValid else { throw TBMediaProtocol.Failure.invalidPacket }; supportsBandwidthLimit = registry.supportsBandwidthLimit == true; event(.registry(registry))
        case .status:
            let status = try JSONDecoder().decode(TBMediaStatus.self, from: data)
            guard sequenceGate.awaitingConfiguration, data.count <= 8192, status.isValid, !status.cameraActive || wantedCamera,
                  !status.microphoneActive || wantedMicrophone else { throw TBMediaProtocol.Failure.invalidPacket }
            if status.error != "permission_pending" {
                // Samples queued before the command ACK belong to the previous
                // capture generation; the ACK starts a fresh sequence domain.
                sequenceGate.reset()
                cameraEnabled = status.cameraActive; microphoneEnabled = status.microphoneActive
                if !cameraEnabled { tb_virtual_camera_stop() }; if !microphoneEnabled { tb_virtual_microphone_stop() }
                deadline = ProcessInfo.processInfo.systemUptime + 8
            }
            event(.status(status))
        case .heartbeat:
            guard data.isEmpty else { throw TBMediaProtocol.Failure.invalidPacket }
            if deadline - ProcessInfo.processInfo.systemUptime < 10 { deadline = ProcessInfo.processInfo.systemUptime + 8 }
        case .jpeg:
            guard try sequenceGate.acceptJPEG(data) else { return }
            if cameraEnabled {
                let image = data.dropFirst(8)
                let result = image.withUnsafeBytes { tb_virtual_camera_push_jpeg($0.bindMemory(to: UInt8.self).baseAddress, image.count) }
                if result < 0 { throw TBMediaProtocol.Failure.invalidPacket }
            }
        case .pcm:
            guard try sequenceGate.acceptPCM(data) else { return }
            if microphoneEnabled {
                let pcm = data.dropFirst(8)
                let result = pcm.withUnsafeBytes { tb_virtual_microphone_push_pcm($0.bindMemory(to: UInt8.self).baseAddress, pcm.count) }
                if result != 0 { fail(.microphoneUnavailable) }
            }
        default: throw TBMediaProtocol.Failure.invalidPacket
        }
    }
}

@MainActor @Observable
final class TBMediaBridge {
    static let shared = TBMediaBridge()
    var host = UserDefaults.standard.string(forKey: "com.revoyage.sender.pairing-host.v2") ?? ""
    private(set) var state = TBMediaBridgeState.disconnected
    private(set) var devices: [TBMediaDevice] = []
    private(set) var cameras: [TBMediaDevice] = []
    private(set) var microphones: [TBMediaDevice] = []
    private(set) var cameraID: String?
    private(set) var microphoneID: String?
    private(set) var requestPending = false
    private(set) var cameraPermission = TBMediaPermission.notDetermined
    private(set) var microphonePermission = TBMediaPermission.notDetermined
    @ObservationIgnored private var transport: TBMediaTransport?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var bandwidthInterface = ""

    func connect() {
        disconnect()
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { state = .receiverRequired; return }
        let key = TBReceiverPairingCredential.localConnectionCode
        self.host = host; state = .connecting; let attempt = generation
        let transport: TBMediaTransport
        do {
            let link = try TBWiredConnection.select(host: host, localIP: TBDisplaySenderService.shared.wiredLocalIP(forReceiver: host), links: TBWiredConnection.currentLinks())
            bandwidthInterface = link.name
            transport = try TBMediaTransport(host: host, localIP: link.ip, key: key, event: { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, self.generation == attempt else { return }
                switch event {
                case .connected: self.state = .connected
                case .registry(let registry):
                    self.devices = registry.devices; self.cameraPermission = TBMediaPermission(wire: registry.cameraPermission)
                    self.cameras = registry.devices.filter { $0.kind == "camera" }
                    self.microphones = registry.devices.filter { $0.kind == "microphone" }
                    self.microphonePermission = TBMediaPermission(wire: registry.microphonePermission)
                case .status(let status):
                    if status.error == "permission_pending" { self.state = .permissionPending; return }
                    self.requestPending = false
                    if !status.cameraActive { self.cameraID = nil }; if !status.microphoneActive { self.microphoneID = nil }
                    self.state = TBMediaBridgeState(statusError: status.error)
                case .failed(let error):
                    self.transport = nil; self.devices = []; self.cameras = []; self.microphones = []; self.cameraID = nil; self.microphoneID = nil
                    self.requestPending = false; self.state = error
                }
            }
        }) } catch {
            state = error as? TBWiredConnection.Failure == .linkTooSlow ? .linkTooSlow : .wiredRequired; return
        }
        self.transport = transport; transport.start()
    }
    func configure(camera: String?, microphone: String?) {
        guard transport != nil, !requestPending,
              camera == nil || devices.contains(where: { $0.id == camera && $0.kind == "camera" }),
              microphone == nil || devices.contains(where: { $0.id == microphone && $0.kind == "microphone" }) else { return }
        cameraID = camera; microphoneID = microphone; requestPending = true
        let service = TBDisplaySenderService.shared
        let interface = bandwidthInterface
        let capacity = service.videoLinkCapacity(for: interface)
        let allocation = service.bandwidthAllocation(for: interface)
        transport?.configure(camera: camera, microphone: microphone, cameraMbps: allocation.cameraCeiling(capacity: capacity))
    }
    func disconnect() {
        generation = UUID(); transport?.stop(); transport = nil; devices = []; cameras = []; microphones = []
        cameraID = nil; microphoneID = nil; requestPending = false; state = .disconnected
    }
}
