import Foundation
import IOKit
import IOKit.pwr_mgt

/// Keeps recovery intent across transport failure, but never across user Stop.
struct TBSenderSleepState {
    private(set) var systemSleeping = false
    private(set) var screensSleeping = false
    private(set) var needsResume = false
    var isSleeping: Bool { systemSleeping || screensSleeping }

    mutating func sleep(system: Bool, activeSession: Bool) {
        if system { systemSleeping = true } else { screensSleeping = true }
        needsResume = needsResume || activeSession
    }

    /// Returns true only for a transition out of sleep; unlock notifications
    /// must not trigger a second restart or override a manual display-off.
    mutating func wake(system: Bool) -> Bool {
        let wasSleeping = isSleeping
        if system { systemSleeping = false; screensSleeping = false }
        else { screensSleeping = false }
        return wasSleeping && !isSleeping
    }

    mutating func resumed() { needsResume = false }
    mutating func cancelResume() { needsResume = false }
}

/// IOKit lets us finish the remote off request before acknowledging forced
/// system sleep. Never hold up sleep for more than two seconds.
/// https://developer.apple.com/library/archive/qa/qa1340/_index.html
@MainActor
final class TBSystemPowerObserver {
    var onWillSleep: ((@escaping @MainActor () -> Void) -> Void)?
    var onDidWake: (() -> Void)?
    nonisolated(unsafe) private var rootPort: io_connect_t = 0
    nonisolated(unsafe) private var notificationPort: IONotificationPortRef?
    nonisolated(unsafe) private var notifier: io_object_t = 0
    nonisolated(unsafe) private var pendingSleepID: Int?

    @discardableResult
    func start() -> Bool {
        guard rootPort == 0 else { return true }
        rootPort = IORegisterForSystemPower(Unmanaged.passUnretained(self).toOpaque(),
            &notificationPort, { context, _, message, argument in
                guard let context else { return }
                let observer = Unmanaged<TBSystemPowerObserver>.fromOpaque(context).takeUnretainedValue()
                // The notification source below is attached to the main run loop.
                MainActor.assumeIsolated { observer.receive(message, id: Int(bitPattern: argument)) }
            }, &notifier)
        guard rootPort != 0, let notificationPort,
              let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() else {
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    private func receive(_ message: UInt32, id: Int) {
        switch message {
        // IOMessage.h uses function-like macros that Swift cannot import.
        // iokit_common_msg(x) = 0xe0000000 | x.
        case 0xe0000270: // kIOMessageCanSystemSleep
            IOAllowPowerChange(rootPort, id)
        case 0xe0000280: // kIOMessageSystemWillSleep
            pendingSleepID = id
            let allow: @MainActor () -> Void = { [weak self] in self?.allowSleep(id) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { allow() }
            if let onWillSleep { onWillSleep(allow) } else { allow() }
        case 0xe0000300: // kIOMessageSystemHasPoweredOn
            onDidWake?()
        default: break
        }
    }

    private func allowSleep(_ id: Int) {
        guard pendingSleepID == id, rootPort != 0 else { return }
        pendingSleepID = nil
        IOAllowPowerChange(rootPort, id)
    }

    deinit {
        if let pendingSleepID, rootPort != 0 { IOAllowPowerChange(rootPort, pendingSleepID) }
        if let notificationPort {
            if let source = IONotificationPortGetRunLoopSource(notificationPort)?.takeUnretainedValue() {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
            if notifier != 0 { IODeregisterForSystemPower(&notifier) }
            if rootPort != 0 { IOServiceClose(rootPort) }
            IONotificationPortDestroy(notificationPort)
        }
    }
}

/// A TCP connection may remain nominally ready while the peer has reaped it.
/// Bound each wake attempt rather than waiting for Network's eventual timeout.
struct TBSenderWakeRecovery {
    static func shouldReconnect(elapsed: Double, requiresPowerAck: Bool,
                                powerConfirmed: Bool, captureReady: Bool) -> Bool {
        (elapsed >= 8 && requiresPowerAck && !powerConfirmed) ||
            (elapsed >= 12 && !captureReady)
    }
}
