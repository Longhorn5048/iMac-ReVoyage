import Foundation
import Network
import Combine

enum TBStorageMonitorStatus: Equatable {
    case needsHost
    case connecting
    case connected
    case unavailable
}

@MainActor
final class TBStorageVolumeMonitor: ObservableObject {
    @Published private(set) var volumes: [TBMonitorRemovableVolume] = []
    @Published private(set) var status: TBStorageMonitorStatus = .needsHost

    private let queue = DispatchQueue(label: "com.revoyage.sender.storage-monitor")
    private let localIPForReceiver: (String) -> String?
    private var host = ""
    private var pairingCode: String?
    private var connection: NWConnection?
    private var buffer = Data()
    private var sentAuthentication = false
    private var generation = UUID()

    init(localIPForReceiver: @escaping (String) -> String?) {
        self.localIPForReceiver = localIPForReceiver
    }

    func configure(host candidateHost: String, pairingCode candidatePairingCode: String?) {
        let cleanedHost = candidateHost.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanedPairingCode = TBReceiverPairingCredential.pairingRequired
            ? candidatePairingCode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            : TBReceiverPairingCredential.localConnectionCode
        guard host != cleanedHost || pairingCode != cleanedPairingCode else { return }

        host = cleanedHost
        pairingCode = cleanedPairingCode
        generation = UUID()
        connection?.cancel()
        connection = nil
        buffer.removeAll(keepingCapacity: false)
        volumes = []
        sentAuthentication = false

        guard !host.isEmpty else {
            status = .needsHost
            return
        }
        guard let pairingCode,
              pairingCode.count == 64,
              pairingCode.utf8.allSatisfy({
                  ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
              }) else {
            status = .unavailable
            return
        }
        connect(generation: generation)
    }

    private func connect(generation expectedGeneration: UUID) {
        guard expectedGeneration == generation,
              let port = NWEndpoint.Port(rawValue: 54322) else { return }
        status = .connecting
        guard let (dialHost, parameters) = try? TBWiredConnection.dial(host: host,
            localIP: localIPForReceiver(host)) else { retry(generation: expectedGeneration); return }
        let attempt = NWConnection(host: dialHost, port: port, using: parameters)
        connection = attempt
        sentAuthentication = false
        buffer.removeAll(keepingCapacity: true)
        attempt.stateUpdateHandler = { [weak self, weak attempt] state in
            Task { @MainActor [weak self, weak attempt] in
                guard let self, let attempt,
                      self.connection === attempt,
                      expectedGeneration == self.generation else { return }
                switch state {
                case .ready:
                    self.receiveNext(on: attempt, generation: expectedGeneration)
                case .failed, .cancelled:
                    self.retry(generation: expectedGeneration)
                case .waiting:
                    self.status = .connecting
                default:
                    break
                }
            }
        }
        attempt.start(queue: queue)
    }

    private func receiveNext(on connection: NWConnection, generation expectedGeneration: UUID) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            Task { @MainActor [weak self, weak connection] in
                guard let self, let connection,
                      self.connection === connection,
                      expectedGeneration == self.generation else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    guard self.drainPackets(on: connection) else {
                        self.retry(generation: expectedGeneration)
                        return
                    }
                }
                if error != nil || isComplete {
                    self.retry(generation: expectedGeneration)
                    return
                }
                self.receiveNext(on: connection, generation: expectedGeneration)
            }
        }
    }

    private func drainPackets(on connection: NWConnection) -> Bool {
        do {
            while let (type, payload) = try TBMonitorProtocol.drainPacket(from: &buffer) {
                switch type {
                case .storageMonitorChallenge:
                    guard !sentAuthentication,
                          let pairingCode,
                          let packet = TBMonitorProtocol.makeStorageMonitorAuthPacket(
                            nonce: payload,
                            pairingCode: pairingCode
                          ) else { return false }
                    sentAuthentication = true
                    connection.send(content: packet, completion: .contentProcessed { [weak self] error in
                        guard error != nil else { return }
                        Task { @MainActor [weak self] in
                            guard let self, self.connection === connection else { return }
                            self.retry(generation: self.generation)
                        }
                    })
                case .storageMonitorSnapshot:
                    guard let snapshot = TBMonitorProtocol.decodeJSON(
                        TBMonitorRemovableVolumeSnapshot.self,
                        from: payload
                    ), TBMonitorProtocol.isValidRemovableVolumeSnapshot(snapshot) else { return false }
                    volumes = snapshot.volumes
                    status = .connected
                default:
                    // Unknown packet types are skipped by drainPacket for
                    // forward compatibility; known unrelated messages are ignored.
                    break
                }
            }
            return true
        } catch {
            return false
        }
    }

    private func retry(generation expectedGeneration: UUID) {
        guard expectedGeneration == generation else { return }
        connection?.cancel()
        connection = nil
        volumes = []
        status = .unavailable
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor [weak self] in
                self?.connect(generation: expectedGeneration)
            }
        }
    }
}
