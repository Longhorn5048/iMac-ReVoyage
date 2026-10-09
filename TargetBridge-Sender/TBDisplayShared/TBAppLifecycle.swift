import AppKit
import Foundation

@MainActor
enum TBAppLifecycle {
    private static var pending = false
    static func requestUninstall() throws {
        guard !pending else { return }
        let bundle = Bundle.main.bundleURL
        let helper = bundle.appendingPathComponent("Contents/MacOS/ReVoyageUninstaller")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw NSError(domain: "ReVoyageUninstaller", code: 1, userInfo: [NSLocalizedDescriptionKey:
                TBDisplaySenderL10n.text("sender.uninstall.helper_missing", TBDisplaySenderService.shared.language)])
        }
        let alert = NSAlert()
        alert.messageText = "Uninstall iMac ReVoyage / 卸载 iMac ReVoyage"
        alert.informativeText = "Remove this app, virtual devices, pairing credentials, settings, caches and logs. Stored files and physical devices are kept.\n移除应用、虚拟设备、配对凭据、设置、缓存和日志。保留存储文件及物理设备。"
        alert.addButton(withTitle: "Cancel / 取消"); alert.addButton(withTitle: "Uninstall / 卸载")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        pending = true; TBMediaBridge.shared.disconnect()
        TBVirtualDevices.shared.deactivateCamera { result in
            pending = false
            do {
                try result.get()
                let process = Process(); process.executableURL = helper
                process.arguments = ["--role", "sender", "--app", bundle.path, "--gui", "--apply"]
                try process.run()
            } catch { showError(error) }
        }
    }
    static func showError(_ error: Error) {
        let alert = NSAlert(); alert.messageText = "Uninstall incomplete / 卸载未完成"
        alert.informativeText = error.localizedDescription; alert.runModal()
    }
}
