import Foundation
import CoreAudio

struct TBAudioOutputRoute {
    static let speakerUID = "re.voyage.imac.speaker"
    var deviceUID: String?
    var allowsReceiverAudio: Bool { deviceUID == Self.speakerUID }
}

enum TBiMacSpeakerPCMTransport {
    static let pull: AudioObjectPropertySelector = 0x72767364 // rvsd: CFData, never legacy raw rvsp
    static func decode(_ packet: CFPropertyList?, pointerSize: UInt32) -> Data? {
        guard pointerSize == MemoryLayout<Unmanaged<CFPropertyList>?>.size,
              let packet, CFGetTypeID(packet) == CFDataGetTypeID(), let data = packet as? Data,
              data.count <= 1920, data.count % 4 == 0 else { return nil }
        return data
    }
}

@MainActor
final class TBAudioOutputRouteObserver {
    var onChange: ((Bool) -> Void)?
    private(set) var allowsReceiverAudio = false
    private(set) var deviceID: AudioObjectID = kAudioObjectUnknown
    nonisolated(unsafe) private var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    nonisolated(unsafe) private var timer: Timer?

    func start() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block) == noErr {
                listeners.append((address, block))
            }
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device: AudioObjectID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) != noErr {
            device = kAudioObjectUnknown
        }
        var uid: Unmanaged<CFString>?
        address.mSelector = kAudioDevicePropertyDeviceUID
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var deviceUID: String?
        if device != kAudioObjectUnknown,
           AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr {
            deviceUID = uid?.takeRetainedValue() as String?
        }
        let allowed = TBAudioOutputRoute(deviceUID: deviceUID).allowsReceiverAudio
        let changed = deviceID != device || allowed != allowsReceiverAudio
        deviceID = device
        allowsReceiverAudio = allowed
        if changed { onChange?(allowed) }
    }

    deinit {
        timer?.invalidate()
        for (var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
        }
    }
}

/// Reads only the virtual device's mixed output, never audio routed to a local
/// speaker or headphone. No hardware installation happens here.
final class TBiMacSpeakerAudioSource: @unchecked Sendable {
    private let timer: DispatchSourceTimer
    private let lock = NSLock()
    private var device: AudioObjectID = kAudioObjectUnknown
    private var stopped = false
    private var lastStatus: OSStatus?
    private let onStatus: @Sendable (OSStatus) -> Void
    private static let clear: AudioObjectPropertySelector = 0x72767363 // rvsc

    init(onStatus: @escaping @Sendable (OSStatus) -> Void, onAudio: @escaping @Sendable (Data) -> Void) {
        self.onStatus = onStatus
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "re.voyage.speaker.pcm", qos: .userInteractive))
        timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, let data = self.read() else { return }
            onAudio(data)
        }
        timer.resume()
    }

    func select(_ device: AudioObjectID) {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, self.device != device else { return }
        self.device = device
        lastStatus = nil
        if device != kAudioObjectUnknown {
            var address = AudioObjectPropertyAddress(mSelector: Self.clear,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var unused: UInt8 = 0 // CoreAudio requires a non-null pointer even for zero-size data.
            AudioObjectSetPropertyData(device, &address, 0, nil, 0, &unused)
        }
    }

    private func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard !stopped, device != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: TBiMacSpeakerPCMTransport.pull,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var packet: Unmanaged<CFPropertyList>?
        var size = UInt32(MemoryLayout<Unmanaged<CFPropertyList>?>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &packet)
        let data = status == noErr ? TBiMacSpeakerPCMTransport.decode(packet?.takeRetainedValue(), pointerSize: size) : nil
        let validatedStatus = status == noErr && data == nil
            ? kAudioHardwareBadPropertySizeError : status
        if lastStatus != validatedStatus { lastStatus = validatedStatus; onStatus(validatedStatus) }
        guard validatedStatus == noErr, let data, !data.isEmpty else { return nil }
        return data
    }

    func stop() {
        lock.lock(); stopped = true; device = kAudioObjectUnknown; lock.unlock()
        timer.cancel()
    }
    deinit { timer.cancel() }
}
