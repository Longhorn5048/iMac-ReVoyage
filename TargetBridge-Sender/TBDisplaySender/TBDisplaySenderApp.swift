import SwiftUI

@main
struct TBDisplaySenderApp: App {
    @StateObject private var service = TBDisplaySenderService.shared
    private let statusItemController = TBDisplaySenderStatusItemController(service: TBDisplaySenderService.shared)

    var body: some Scene {
        WindowGroup("iMac ReVoyage", id: "main") {
            TBSenderMainWindow(service: service, statusItemController: statusItemController)
                .frame(minWidth: 540)
                .task {
                    TBSenderAutomation.handleLaunchArguments(CommandLine.arguments)
                }
                .onOpenURL { url in
                    if url.scheme == "targetbridge", url.host == "uninstall" {
                        do { try TBAppLifecycle.requestUninstall() }
                        catch { TBAppLifecycle.showError(error) }
                    } else { TBSenderAutomation.handle(url: url) }
                }
        }
        .defaultSize(width: 860, height: 860)

        Settings {
            TBDisplaySenderSettingsView(service: service)
                .frame(minWidth: 760, minHeight: 620)
        }
    }
}

private struct TBSenderMainWindow: View {
    let service: TBDisplaySenderService
    let statusItemController: TBDisplaySenderStatusItemController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TBDisplaySenderContentView(service: service)
            .task {
                statusItemController.activate(openMainWindow: { [openWindow] in openWindow(id: "main") })
            }
    }
}
