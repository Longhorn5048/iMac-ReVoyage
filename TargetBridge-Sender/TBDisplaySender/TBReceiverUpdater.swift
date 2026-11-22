import Foundation
import Network
import Observation

private final class TBReceiverUpdateRequest: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.revoyage.receiver-update")
    private let connection: NWConnection
    private let header: Data
    private let package: TBReceiverUpdateProtocol.Package?
    private let progress: @Sendable (Double) -> Void
    private var input: FileHandle?
    private var decoder = TBReceiverUpdateProtocol.ResponseDecoder()
    private var completion: CheckedContinuation<(code: Int, body: Data), Error>?
    private var timer: DispatchSourceTimer?
    private var deadline: Double = 0
    private var sent = 0
    private var lastPercent = -1
    private var finished = false

    init(host: String, localIP: String?, package: TBReceiverUpdateProtocol.Package? = nil,
         requestID: UUID = UUID(), progress: @escaping @Sendable (Double) -> Void = { _ in }) throws {
        guard TBReceiverPairingCredential.normalizedHost(host) != nil,
              !host.contains("\r"), !host.contains("\n") else { throw TBReceiverUpdateProtocol.Failure.unavailable }
        let (dialHost, parameters) = try TBWiredConnection.dial(host: host, localIP: localIP)
        connection = NWConnection(host: dialHost, port: NWEndpoint.Port(rawValue: TBReceiverUpdateProtocol.port)!, using: parameters)
        self.package = package; self.progress = progress
        header = package?.header(host: host, requestID: requestID)
            ?? Data("GET /status HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
    }

    func run() async throws -> (code: Int, body: Data) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                completion = continuation
                deadline = ProcessInfo.processInfo.systemUptime + 8
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + 1, repeating: 1)
                timer.setEventHandler { [weak self] in
                    guard let self, !finished else { return }
                    if ProcessInfo.processInfo.systemUptime >= deadline { finish(.failure(TBReceiverUpdateProtocol.Failure.unavailable)) }
                }
                self.timer = timer; timer.resume()
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self, !finished else { return }
                    switch state {
                    case .ready:
                        do { if let package { input = try FileHandle(forReadingFrom: package.url) } }
                        catch { finish(.failure(error)); return }
                        receive()
                        connection.send(content: header, completion: .contentProcessed { [weak self] error in
                            guard let self, !finished else { return }
                            if let error { finish(.failure(error)) } else { sendChunk() }
                        })
                    case .failed(let error): finish(.failure(error))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }
    private func sendChunk() {
        guard !finished, let package, let input else { return }
        do {
            guard let data = try input.read(upToCount: 128 * 1024), !data.isEmpty else {
                guard sent == package.size else { throw TBReceiverUpdateProtocol.Failure.transferFailed }
                deadline = ProcessInfo.processInfo.systemUptime + 30
                return
            }
            guard sent + data.count <= package.size else { throw TBReceiverUpdateProtocol.Failure.transferFailed }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !finished else { return }
                if let error { finish(.failure(error)); return }
                sent += data.count
                deadline = ProcessInfo.processInfo.systemUptime + 30
                let percent = sent * 100 / package.size
                if percent != lastPercent { lastPercent = percent; progress(Double(sent) / Double(package.size)) }
                sendChunk()
            })
        } catch { finish(.failure(error)) }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self, !finished else { return }
            do {
                if let data, let response = try decoder.receive(data) { finish(.success(response)); return }
                if let error { finish(.failure(error)); return }
                if complete { finish(.failure(TBReceiverUpdateProtocol.Failure.invalidResponse)); return }
                receive()
            } catch { finish(.failure(error)) }
        }
    }
    private func finish(_ result: Result<(code: Int, body: Data), Error>) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil; connection.stateUpdateHandler = nil; connection.cancel()
        try? input?.close(); input = nil
        completion?.resume(with: result); completion = nil
    }
}

@MainActor @Observable
final class TBReceiverUpdater {
    enum Phase: String { case idle, preparing, checking, uploading, installing, completed, failed }
    private(set) var phase = Phase.idle
    private(set) var progress = 0.0
    private(set) var errorCode = ""
    private(set) var receiverBuild = ""
    private(set) var host = ""
    var isBusy: Bool { [.preparing, .checking, .uploading, .installing].contains(phase) }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var shouldResume = true

    func cancelAutomaticResume() { shouldResume = false }

    func update(packageURL: URL, host: String, localIP: String?, service: TBDisplaySenderService) {
        guard !isBusy else { return }
        self.host = host; phase = .preparing; errorCode = ""; progress = 0; shouldResume = true
        task = Task {
            var resumeSessions: [TBDisplaySenderSession] = []
            defer {
                task = nil
                for session in resumeSessions where shouldResume && service.sessions.contains(where: { $0.id == session.id }) && session.receiverIP == host {
                    session.connect()
                }
            }
            do {
                let package = try await Task.detached { try TBReceiverUpdateProtocol.Package.prepare(packageURL) }.value
                phase = .checking
                let status = try await fetchStatus(host: host, localIP: localIP)
                receiverBuild = status.receiverBuild ?? ""
                guard ["idle", "completed", "failed"].contains(status.phase) else { errorCode = "busy"; phase = .failed; return }
                // Save the existing arrangement before the update restarts apps.
                resumeSessions = service.sessions.filter { $0.receiverIP == host && ($0.isConnected || $0.isStreaming) }
                resumeSessions.forEach { $0.stop() }
                phase = .uploading
                let requestID = UUID()
                let response = try await TBReceiverUpdateRequest(host: host, localIP: localIP, package: package, requestID: requestID) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.phase == .uploading else { return }; self.progress = fraction
                    }
                }.run()
                guard response.code == 202 else {
                    let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: String]
                    errorCode = object?["error"] ?? "transfer_failed"; phase = .failed; return
                }
                phase = .installing; progress = 1
                try await poll(requestID: requestID.uuidString, host: host, localIP: localIP)
            } catch {
                let failedPhase = phase
                phase = .failed
                if errorCode.isEmpty {
                    switch error {
                    case TBReceiverUpdateProtocol.Failure.invalidPackage: errorCode = "invalid_package"
                    case TBReceiverUpdateProtocol.Failure.resultUnknown: errorCode = "result_unknown"
                    case TBWiredConnection.Failure.wiredInterfaceRequired, TBWiredConnection.Failure.linkTooSlow: errorCode = "wired_required"
                    default:
                        errorCode = failedPhase == .preparing ? "invalid_package"
                            : failedPhase == .uploading ? "result_unknown" : "unavailable"
                    }
                }
            }
        }
    }
    private func fetchStatus(host: String, localIP: String?) async throws -> TBReceiverUpdateProtocol.Status {
        let response = try await TBReceiverUpdateRequest(host: host, localIP: localIP).run()
        guard response.code == 200, let status = try? JSONDecoder().decode(TBReceiverUpdateProtocol.Status.self, from: response.body), status.isValid else {
            throw TBReceiverUpdateProtocol.Failure.invalidResponse
        }
        return status
    }
    private func poll(requestID: String, host: String, localIP: String?) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 180
        while ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .seconds(1))
            guard let status = try? await fetchStatus(host: host, localIP: localIP),
                  status.matches(requestID: requestID) else { continue }
            if status.phase == "completed" {
                // Keep the update controls disabled while the listener settles.
                try? await Task.sleep(for: .seconds(2))
                phase = .completed; receiverBuild = status.receiverBuild ?? ""; return
            }
            if status.phase == "failed" { phase = .failed; errorCode = status.error; return }
        }
        throw TBReceiverUpdateProtocol.Failure.resultUnknown
    }
    func checkStatus(host: String, localIP: String?) {
        guard !isBusy else { return }
        self.host = host; phase = .checking; errorCode = ""
        task = Task {
            defer { task = nil }
            do {
                let status = try await fetchStatus(host: host, localIP: localIP)
                receiverBuild = status.receiverBuild ?? ""
                if ["receiving", "validating", "installing"].contains(status.phase), let request = status.requestID {
                    phase = .installing; try await poll(requestID: request, host: host, localIP: localIP)
                } else if status.phase == "failed" { phase = .failed; errorCode = status.error }
                else { phase = status.phase == "completed" ? .completed : .idle }
            } catch { phase = .failed; errorCode = "unavailable" }
        }
    }
}
