import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TBDisplaySenderSettingsView: View {
    @ObservedObject var service: TBDisplaySenderService
    @State private var importError: String?
    @State private var receiverPairingCode = ""
    @State private var receiverPairingFeedback = ""
    @State private var receiverSSHUser = NSUserName()
    @State private var receiverServicesFeedback = ""
    @State private var uninstallError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SurfaceCard {
                    HStack(alignment: .top, spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.green.opacity(0.30),
                                            Color.cyan.opacity(0.16)
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.95))
                        }
                        .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(settingsTitle)
                                .font(.system(size: 28, weight: .bold, design: .rounded))
                            Text(settingsSubtitle)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            versionChip
                        }

                        Spacer()
                    }
                }

                settingsSection(title: generalTitle) {
                    Picker(TBDisplaySenderL10n.languageGroup(service.language), selection: $service.language) {
                        ForEach(TBDisplaySenderLanguage.allCases) { language in
                            Text(language.pickerTitle).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(noSignalSleepHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if TBReceiverPairingCredential.pairingRequired {
                    settingsSection(title: receiverPairingTitle) {
                        TBReceiverPairingImportView(language: service.language, receivers: service.discoveredReceivers,
                            selectedHost: $service.receiverPairingHost, onImport: importReceiverPairing)
                        Text(receiverPairingHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        TextField(receiverHostPlaceholder, text: $service.receiverPairingHost)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: service.receiverPairingHost) { _, host in
                                receiverPairingCode = TBReceiverPairingCredential.load(forReceiver: host)
                                    ?? TBReceiverPairingCredential.legacyCodeForMigration() ?? ""
                                receiverPairingFeedback = ""
                            }

                        SecureField(receiverPairingFieldTitle, text: $receiverPairingCode)
                            .textFieldStyle(.roundedBorder)

                        HStack(spacing: 12) {
                            Button(receiverPairingSaveTitle) {
                                receiverPairingFeedback = service.saveReceiverPairingCode(receiverPairingCode)
                                    ? receiverPairingSavedText
                                    : receiverPairingInvalidText
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(TBReceiverPairingCredential.normalizedHost(service.receiverPairingHost) == nil)

                            Text(receiverPairingFeedback.isEmpty
                                 ? (service.receiverPairingConfigured ? receiverPairingConfiguredText : receiverPairingMissingText)
                                 : receiverPairingFeedback)
                                .font(.footnote)
                                .foregroundStyle(receiverPairingFeedback == receiverPairingInvalidText ? .orange : .secondary)
                        }
                    }

                }

                settingsSection(title: TBDisplaySenderL10n.text("sender.video_protection.title", service.language)) {
                    TBBandwidthSettingsView(service: service)
                }

                settingsSection(title: TBDisplaySenderL10n.text("sender.receiver_update.title", service.language)) {
                    TBReceiverUpdateView(service: service, updater: service.receiverUpdater,
                        host: $service.receiverStorageHost, language: service.language, receivers: service.discoveredReceivers)
                }

                settingsSection(title: receiverServicesTitle) {
                    Text(receiverServicesHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    TextField(receiverHostPlaceholder, text: $service.receiverStorageHost)
                        .textFieldStyle(.roundedBorder)
                    TextField(receiverSSHUserPlaceholder, text: $receiverSSHUser)
                        .textFieldStyle(.roundedBorder)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                        Button(openSSHSessionTitle, action: openSSHSession)
                            .buttonStyle(.borderedProminent)
                            .disabled(receiverSSHCommand == nil)
                        Button(copySSHCommandTitle, action: copySSHCommand)
                            .buttonStyle(.bordered)
                            .disabled(receiverSSHCommand == nil)
                        Button(openScreenSharingTitle, action: openScreenSharing)
                            .buttonStyle(.bordered)
                        Button(openStorageTitle, action: openStorage)
                            .buttonStyle(.bordered)
                    }
                    .disabled(validReceiverHost == nil)

                    ReceiverRemovableStorageSection(
                        host: service.receiverStorageHost,
                        volumes: service.receiverStorageVolumes,
                        status: service.receiverStorageMonitorStatus,
                        language: service.language
                    )

                    if !receiverServicesFeedback.isEmpty {
                        Text(receiverServicesFeedback)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }

                settingsSection(title: interfaceTitle) {
                    Toggle(TBDisplaySenderL10n.text("sender.toggle.hide_dock_icon", service.language), isOn: $service.hidesDockIcon)
                    Text(TBDisplaySenderL10n.text("sender.dock_icon.hint", service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle(TBDisplaySenderL10n.showMenuBarIcon(service.language), isOn: Binding(
                        get: { service.showsMenuBarIcon || service.hidesDockIcon },
                        set: { service.showsMenuBarIcon = $0 }
                    ))
                        .disabled(service.hidesDockIcon)
                    Toggle(TBDisplaySenderL10n.largeCursor(service.language), isOn: $service.largeCursor)
                        .disabled(service.anyConnected)
                    Toggle(TBDisplaySenderL10n.preventDisplaySleep(service.language), isOn: $service.preventDisplaySleep)
                    Toggle(TBDisplaySenderL10n.autoRestartOnWake(service.language), isOn: $service.autoRestartOnWake)
                    Toggle(TBDisplaySenderL10n.verboseDisplayLogging(service.language), isOn: $service.verboseDisplayLogging)
                }

                settingsSection(title: behaviorTitle) {
                    Text(TBDisplaySenderL10n.settingsHint(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(TBDisplaySenderL10n.modeLine3(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(TBDisplaySenderL10n.modeLine5(service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                TBMediaSettingsView(language: service.language, sessionConnected: service.anyConnected)

                settingsSection(title: addonsTitle) {
                    Text(addonsSubtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if service.anyConnected {
                        Text(addonsConnectedHint)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 12) {
                        Button(importAddonTitle) {
                            importAddonManifest()
                        }
                        .buttonStyle(.borderedProminent)

                        Button(refreshAddonsTitle) {
                            service.refreshAddons()
                        }
                        .buttonStyle(.bordered)

                        Button(openAddonsFolderTitle) {
                            service.openAddonsFolder()
                        }
                        .buttonStyle(.bordered)
                    }

                    if service.addons.isEmpty {
                        Text(noAddonsTitle)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(service.addons) { addon in
                                addonCard(addon)
                            }
                        }
                    }
                }

                settingsSection(title: aboutTitle) {
                    Text(aboutBody)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 12) {
                        Link(destination: URL(string: "https://github.com/swellweb/targetBridge")!) {
                            Label(githubTitle, systemImage: "link")
                        }
                        .buttonStyle(.borderedProminent)

                        Link(destination: URL(string: "https://github.com/swellweb/targetBridge/releases/latest")!) {
                            Label(releaseTitle, systemImage: "shippingbox")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                settingsSection(title: TBDisplaySenderL10n.text("sender.uninstall.title", service.language)) {
                    Text(TBDisplaySenderL10n.text("sender.uninstall.hint", service.language))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button(TBDisplaySenderL10n.text("sender.uninstall.action", service.language), role: .destructive) {
                        do { try TBAppLifecycle.requestUninstall() }
                        catch { uninstallError = error.localizedDescription }
                    }
                    if let uninstallError {
                        Text(uninstallError).font(.footnote).foregroundStyle(.orange)
                    }
                }

            }
            .padding(20)
        }
        .background(appBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            if service.receiverStorageHost.isEmpty,
               let connected = service.sessions.first(where: \.isConnected) {
                service.receiverStorageHost = connected.receiverIP
            }
            if service.receiverPairingHost.isEmpty {
                service.receiverPairingHost = service.receiverStorageHost.isEmpty
                    ? (service.sessions.first?.receiverIP ?? "") : service.receiverStorageHost
            }
            if TBReceiverPairingCredential.pairingRequired && receiverPairingCode.isEmpty {
                receiverPairingCode = TBReceiverPairingCredential.load(forReceiver: service.receiverPairingHost)
                    ?? TBReceiverPairingCredential.legacyCodeForMigration() ?? ""
            }
        }
        .alert(addonImportErrorTitle, isPresented: Binding(
            get: { importError != nil },
            set: { if !$0 { importError = nil } }
        )) {
            Button("OK", role: .cancel) {
                importError = nil
            }
        } message: {
            Text(importError ?? "")
        }
    }

    private func settingsSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        SurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                Text(title.uppercased())
                    .font(.system(.caption, design: .rounded, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(.secondary)
                content()
            }
        }
    }

    private var versionChip: some View {
        Text("\(versionTitle) \(TBDisplaySenderBuildInfo.versionDisplay)")
            .font(.system(.footnote, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.06))
            )
    }

    private func addonCard(_ addon: TBAddonRecord) -> some View {
        SurfaceSubcard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.name)
                            .font(.system(size: 18, weight: .semibold, design: .rounded))
                        Text(addon.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Toggle(
                        service.isAddonEnabled(addon) ? addonEnabledTitle : addonDisabledTitle,
                        isOn: Binding(
                            get: { service.isAddonEnabled(addon) },
                            set: { service.setAddonEnabled($0, for: addon) }
                        )
                    )
                    .toggleStyle(.switch)
                    .disabled(!service.isAddonCompatible(addon) || service.anyConnected)
                }

                HStack(spacing: 8) {
                    addonChip(originTitle(for: addon.origin), tint: addon.origin == .bundled ? .cyan : .orange)
                    addonChip("\(versionTitle) \(addon.version)", tint: .secondary)
                    if addon.manifest.experimental {
                        addonChip(experimentalTitle, tint: .yellow)
                    }
                    if !service.isAddonCompatible(addon) {
                        addonChip(incompatibleTitle, tint: .red)
                    }
                }

                    if !addon.manifest.capabilities.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(capabilitiesTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 8) {
                            ForEach(addon.manifest.capabilities, id: \.self) { capability in
                                addonChip(capabilityTitle(for: capability), tint: .green)
                            }
                        }
                    }
                }
            }
        }
    }

    private func addonChip(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.system(.caption, design: .rounded, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(tint.opacity(0.25), lineWidth: 1)
            )
    }

    private func importAddonManifest() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message = importPanelMessage

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try service.importAddonManifest(from: url)
        } catch {
            importError = error.localizedDescription
        }
    }

    private var appBackground: some View {
        LinearGradient(
            colors: [
                Color(red: 0.12, green: 0.13, blue: 0.14),
                Color(red: 0.08, green: 0.09, blue: 0.10)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var settingsTitle: String {
        switch service.language {
        case .italian: return "Impostazioni TargetBridge"
        case .english: return "TargetBridge Settings"
        case .german: return "TargetBridge-Einstellungen"
        case .french: return "Réglages TargetBridge"
        case .chinese: return "TargetBridge 设置"
        }
    }

    private var settingsSubtitle: String {
        switch service.language {
        case .italian: return "Preferenze globali dell’app separate dalla dashboard operativa."
        case .english: return "Global app preferences separated from the operational dashboard."
        case .german: return "Globale App-Einstellungen getrennt vom operativen Dashboard."
        case .french: return "Préférences globales de l’app séparées du tableau de bord opérationnel."
        case .chinese: return "全局应用偏好设置与主操作面板分离。"
        }
    }

    private var generalTitle: String {
        switch service.language {
        case .italian: return "Generale"
        case .english: return "General"
        case .german: return "Allgemein"
        case .french: return "Général"
        case .chinese: return "通用"
        }
    }

    private var interfaceTitle: String {
        switch service.language {
        case .italian: return "Interfaccia"
        case .english: return "Interface"
        case .german: return "Oberfläche"
        case .french: return "Interface"
        case .chinese: return "界面"
        }
    }

    private var noSignalSleepHint: String {
        TBDisplaySenderL10n.text("sender.display_power.rescue_hint", service.language)
    }

    private var receiverPairingTitle: String {
        switch service.language {
        case .italian: return "Associazione Receiver"
        case .english: return "Receiver Pairing"
        case .german: return "Receiver koppeln"
        case .french: return "Association du Receiver"
        case .chinese: return "配对 Receiver"
        }
    }

    private var receiverServicesTitle: String {
        switch service.language {
        case .italian: return "Servizi Receiver"
        case .english: return "Receiver Services"
        case .german: return "Receiver-Dienste"
        case .french: return "Services du Receiver"
        case .chinese: return "Receiver 高级服务"
        }
    }

    private var receiverServicesHint: String {
        switch service.language {
        case .italian: return "Per lo storage, esegui una volta Receiver/enable_storage_bridge.command: crea una cartella SMB privata e chiede la conferma amministratore. Se SMB non è attivo, abilitalo in Preferenze di Sistema > Condivisione > Condivisione file > Opzioni e autorizza l’account. L’installazione locale del Receiver prova ad attivare SSH con autorizzazione amministratore; segui gli eventuali avvisi sui permessi. Usa l’account dell’iMac. La Condivisione schermo va attivata manualmente."
        case .english: return "For storage, run Receiver/enable_storage_bridge.command once. It creates a private SMB folder and asks for administrator approval. If SMB is off, enable it in System Preferences > Sharing > File Sharing > Options and allow the Receiver account. The local Receiver installer attempts to enable SSH with administrator approval; follow any permission notices. Use the iMac account. Enable Screen Sharing manually."
        case .german: return "Führe für den Speicher einmal Receiver/enable_storage_bridge.command aus. Das erstellt einen privaten SMB-Ordner und fragt nach der Administratorfreigabe. Falls SMB deaktiviert ist, aktiviere es unter Systemeinstellungen > Freigaben > Dateifreigabe > Optionen und erlaube den Receiver-Account. Die lokale Receiver-Installation versucht, SSH mit Administratorfreigabe zu aktivieren; beachte eventuelle Berechtigungshinweise. Verwende den iMac-Account. Die Bildschirmfreigabe muss manuell aktiviert werden."
        case .french: return "Pour le stockage, exécutez une fois Receiver/enable_storage_bridge.command. Le script crée un dossier SMB privé et demande l’autorisation d’un administrateur. Si SMB est désactivé, activez-le dans Préférences Système > Partage > Partage de fichiers > Options et autorisez le compte Receiver. L’installation locale du Receiver tente d’activer SSH avec l’autorisation d’un administrateur ; suivez les éventuels messages de permission. Utilisez le compte de l’iMac. Le partage d’écran reste manuel."
        case .chinese: return "需要网络存储时，在 Receiver 上运行一次 Receiver/enable_storage_bridge.command。它会请求管理员授权并创建关闭访客访问的私有 SMB 文件夹。若 SMB 未开启，请在系统偏好设置→共享→文件共享→选项中启用 SMB 并允许 Receiver 账户连接。本机安装 Receiver 时会尝试授权开启 SSH，请按安装器的权限提示完成设置，并填写 iMac 上的账户名。屏幕共享仍需手动开启。"
        }
    }

    private var receiverHostPlaceholder: String {
        switch service.language {
        case .italian: return "Nome host o indirizzo IP del Receiver"
        case .english: return "Receiver hostname or IP address"
        case .german: return "Receiver-Hostname oder IP-Adresse"
        case .french: return "Nom d’hôte ou adresse IP du Receiver"
        case .chinese: return "Receiver 主机名或 IP 地址"
        }
    }

    private var receiverSSHUserPlaceholder: String {
        switch service.language {
        case .italian: return "Account utente sul Receiver"
        case .english: return "Receiver account name"
        case .german: return "Receiver-Benutzerkonto"
        case .french: return "Compte utilisateur du Receiver"
        case .chinese: return "Receiver 上的账户名"
        }
    }

    private var openSSHSessionTitle: String {
        switch service.language {
        case .italian: return "Apri sessione SSH"
        case .english: return "Open SSH Session"
        case .german: return "SSH-Sitzung öffnen"
        case .french: return "Ouvrir une session SSH"
        case .chinese: return "打开 SSH 会话"
        }
    }

    private var copySSHCommandTitle: String {
        switch service.language {
        case .italian: return "Copia comando SSH"
        case .english: return "Copy SSH Command"
        case .german: return "SSH-Befehl kopieren"
        case .french: return "Copier la commande SSH"
        case .chinese: return "复制 SSH 命令"
        }
    }

    private var openScreenSharingTitle: String {
        switch service.language {
        case .italian: return "Apri Condivisione schermo"
        case .english: return "Open Screen Sharing"
        case .german: return "Bildschirmfreigabe öffnen"
        case .french: return "Ouvrir le partage d’écran"
        case .chinese: return "打开屏幕共享"
        }
    }

    private var openStorageTitle: String {
        switch service.language {
        case .italian: return "Monta archivio iMac"
        case .english: return "Mount iMac Storage"
        case .german: return "iMac-Speicher verbinden"
        case .french: return "Monter le stockage iMac"
        case .chinese: return "挂载 iMac 存储"
        }
    }

    private var validReceiverHost: String? {
        let value = service.receiverStorageHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 253,
              value.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private var validReceiverSSHUser: String? {
        let value = receiverSSHUser.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 64,
              value.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else {
            return nil
        }
        return value
    }

    private var receiverSSHCommand: String? {
        guard let host = validReceiverHost, let user = validReceiverSSHUser else { return nil }
        return "ssh \(user)@\(host)"
    }

    private func copySSHCommand() {
        guard let command = receiverSSHCommand else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        receiverServicesFeedback = command
    }

    private func openSSHSession() {
        guard let command = receiverSSHCommand else { return }
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        NSAppleScript(source: "tell application \"Terminal\" to do script \"\(escaped)\"")?
            .executeAndReturnError(&error)
        receiverServicesFeedback = error.map { String(describing: $0) } ?? command
    }

    private func openScreenSharing() {
        guard let host = validReceiverHost,
              let url = URL(string: "vnc://\(host)") else { return }
        receiverServicesFeedback = NSWorkspace.shared.open(url) ? url.absoluteString : "Could not open \(url.absoluteString)"
    }

    private func openStorage() {
        guard let host = validReceiverHost,
              let url = URL(string: "smb://\(host)/ReVoyageStorage") else { return }
        receiverServicesFeedback = NSWorkspace.shared.open(url) ? url.absoluteString : "Could not open \(url.absoluteString)"
    }

    private func importReceiverPairing() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4096 else {
                throw TBReceiverCommandHandshake.Failure.invalidProof
            }
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            let document = try TBReceiverPairingDocument.decode(try file.read(upToCount: 4097) ?? Data())
            let discovered = service.discoveredReceivers.first {
                $0.receiverID == TBReceiverPairingCredential.normalizedIdentity(document.receiverID)
            }
            let idleSession = service.sessions.first { !$0.isConnected && !$0.isStreaming }
            let host = discovered?.ip(for: idleSession?.transportKind ?? .networkLink) ?? document.host
            service.receiverPairingHost = host
            guard service.saveReceiverPairingCode(document.pairingCode) else {
                throw TBReceiverCommandHandshake.Failure.invalidProof
            }
            TBReceiverPairingCredential.rememberImportedIdentity(document.receiverID, host: host)
            receiverPairingCode = document.pairingCode
            receiverPairingFeedback = receiverPairingSavedText
            if let idleSession {
                if let discovered {
                    idleSession.selectedReceiverID = discovered.id
                    service.applyDiscoveredReceiver(discovered, to: idleSession)
                } else {
                    idleSession.selectedReceiverID = ""
                    idleSession.receiverIP = host
                }
                idleSession.receiverIdentityHint = TBReceiverPairingCredential.normalizedIdentity(document.receiverID)
                idleSession.automaticQuality = true
            }
        } catch { receiverPairingFeedback = receiverPairingInvalidText }
    }

    private var receiverPairingHint: String {
        TBDisplaySenderL10n.text("sender.pairing.scoped_hint", service.language)
    }

    private var receiverPairingFieldTitle: String {
        switch service.language {
        case .italian: return "Codice di associazione (64 caratteri esadecimali)"
        case .english: return "Pairing code (64 hexadecimal characters)"
        case .german: return "Kopplungscode (64 hexadezimale Zeichen)"
        case .french: return "Code d’association (64 caractères hexadécimaux)"
        case .chinese: return "配对码（64 位十六进制）"
        }
    }

    private var receiverPairingSaveTitle: String {
        switch service.language {
        case .italian: return "Salva e sincronizza"
        case .english: return "Save and Sync"
        case .german: return "Speichern und synchronisieren"
        case .french: return "Enregistrer et synchroniser"
        case .chinese: return "保存并同步"
        }
    }

    private var receiverPairingConfiguredText: String {
        switch service.language {
        case .italian: return "Receiver associato · codice nel Portachiavi"
        case .english: return "Receiver paired · code stored in Keychain"
        case .german: return "Receiver gekoppelt · Code im Schlüsselbund gespeichert"
        case .french: return "Receiver associé · code dans le trousseau"
        case .chinese: return "已配对 · 配对码保存在钥匙串"
        }
    }

    private var receiverPairingMissingText: String {
        switch service.language {
        case .italian: return "Receiver non associato"
        case .english: return "Receiver not paired"
        case .german: return "Receiver nicht gekoppelt"
        case .french: return "Receiver non associé"
        case .chinese: return "尚未配对 Receiver"
        }
    }

    private var receiverPairingSavedText: String {
        switch service.language {
        case .italian: return "Codice salvato; sincronizzazione inviata"
        case .english: return "Code saved; sync request sent"
        case .german: return "Code gespeichert; Synchronisierung gesendet"
        case .french: return "Code enregistré ; synchronisation envoyée"
        case .chinese: return "配对码已保存，已发送同步请求"
        }
    }

    private var receiverPairingInvalidText: String {
        switch service.language {
        case .italian: return "Codice non valido: servono 64 caratteri esadecimali"
        case .english: return "Invalid code: enter 64 hexadecimal characters"
        case .german: return "Ungültiger Code: 64 hexadezimale Zeichen erforderlich"
        case .french: return "Code invalide : 64 caractères hexadécimaux requis"
        case .chinese: return "配对码无效：需要 64 位十六进制字符"
        }
    }

    private var behaviorTitle: String {
        switch service.language {
        case .italian: return "Comportamento"
        case .english: return "Behavior"
        case .german: return "Verhalten"
        case .french: return "Comportement"
        case .chinese: return "行为"
        }
    }

    private var aboutTitle: String {
        switch service.language {
        case .italian: return "About"
        case .english: return "About"
        case .german: return "Info"
        case .french: return "À propos"
        case .chinese: return "关于"
        }
    }

    private var aboutBody: String {
        switch service.language {
        case .italian: return "TargetBridge e una utility open source per riutilizzare pannelli iMac Intel come display esterni per Mac moderni. Le preferenze generali vivono qui; le impostazioni operative di ogni sessione restano nella finestra principale."
        case .english: return "TargetBridge is an open-source utility for reusing Intel iMac panels as external displays for modern Macs. Global preferences live here; per-session operational settings stay in the main window."
        case .german: return "TargetBridge ist ein Open-Source-Werkzeug, um Intel-iMac-Panels als externe Displays für moderne Macs weiterzuverwenden. Globale Einstellungen sind hier; operative Sitzungsoptionen sind im Hauptfenster."
        case .french: return "TargetBridge est un utilitaire open source qui permet de réutiliser les dalles d’iMac Intel comme écrans externes pour les Mac modernes. Les préférences globales se trouvent ici ; les réglages de chaque session restent dans la fenêtre principale."
        case .chinese: return "TargetBridge 是一个开源工具，可将 Intel iMac 面板重新用作现代 Mac 的外接显示器。全局偏好设置在这里管理；每个会话的操作设置保留在主窗口中。"
        }
    }

    private var githubTitle: String {
        switch service.language {
        case .italian: return "GitHub"
        case .english: return "GitHub"
        case .german: return "GitHub"
        case .french: return "GitHub"
        case .chinese: return "GitHub"
        }
    }

    private var releaseTitle: String {
        switch service.language {
        case .italian: return "Ultima release"
        case .english: return "Latest release"
        case .german: return "Letztes Release"
        case .french: return "Dernière version"
        case .chinese: return "最新发布"
        }
    }

    private var versionTitle: String {
        switch service.language {
        case .italian: return "Versione"
        case .english: return "Version"
        case .german: return "Version"
        case .french: return "Version"
        case .chinese: return "版本"
        }
    }

    private var addonsTitle: String {
        switch service.language {
        case .italian: return "Add-on"
        case .english: return "Add-ons"
        case .german: return "Add-ons"
        case .french: return "Extensions"
        case .chinese: return "附加组件"
        }
    }

    private var addonsSubtitle: String {
        switch service.language {
        case .italian: return "Gli add-on vengono letti da manifest JSON sicuri. Quelli ufficiali sono inclusi nell'app, mentre quelli personalizzati si importano nella cartella Addons utente."
        case .english: return "Add-ons are loaded from safe JSON manifests. Official ones ship with the app, while custom ones can be imported into the user Addons folder."
        case .german: return "Add-ons werden aus sicheren JSON-Manifests geladen. Offizielle Add-ons sind in der App enthalten, benutzerdefinierte können in den Benutzer-Addons-Ordner importiert werden."
        case .french: return "Les extensions sont chargées depuis des manifestes JSON sûrs. Les extensions officielles sont incluses dans l’app ; les extensions personnalisées peuvent être importées dans le dossier utilisateur Addons."
        case .chinese: return "附加组件通过安全的 JSON 清单加载。官方附加组件随应用提供，自定义附加组件可导入到用户 Addons 文件夹。"
        }
    }

    private var importAddonTitle: String {
        switch service.language {
        case .italian: return "Importa Add-on..."
        case .english: return "Import Add-on..."
        case .german: return "Add-on importieren..."
        case .french: return "Importer une extension..."
        case .chinese: return "导入附加组件..."
        }
    }

    private var refreshAddonsTitle: String {
        switch service.language {
        case .italian: return "Ricarica"
        case .english: return "Reload"
        case .german: return "Neu laden"
        case .french: return "Recharger"
        case .chinese: return "重新加载"
        }
    }

    private var openAddonsFolderTitle: String {
        switch service.language {
        case .italian: return "Apri cartella Addons"
        case .english: return "Open Addons Folder"
        case .german: return "Add-ons-Ordner öffnen"
        case .french: return "Ouvrir le dossier Addons"
        case .chinese: return "打开 Addons 文件夹"
        }
    }

    private var noAddonsTitle: String {
        switch service.language {
        case .italian: return "Nessun add-on trovato. Importa un manifest JSON oppure usa quelli ufficiali inclusi."
        case .english: return "No add-ons found. Import a JSON manifest or use the bundled official ones."
        case .german: return "Keine Add-ons gefunden. Importiere ein JSON-Manifest oder nutze die eingebauten offiziellen Add-ons."
        case .french: return "Aucune extension trouvée. Importez un manifeste JSON ou utilisez les extensions officielles incluses."
        case .chinese: return "未找到附加组件。请导入 JSON 清单或使用内置官方附加组件。"
        }
    }

    private var addonsConnectedHint: String {
        switch service.language {
        case .italian: return "Ferma tutte le sessioni prima di attivare o disattivare un add-on."
        case .english: return "Stop all sessions before enabling or disabling an add-on."
        case .german: return "Beende alle Sitzungen, bevor du ein Add-on aktivierst oder deaktivierst."
        case .french: return "Arrêtez toutes les sessions avant d’activer ou de désactiver une extension."
        case .chinese: return "请先停止所有会话，再启用或禁用附加组件。"
        }
    }

    private var addonEnabledTitle: String {
        switch service.language {
        case .italian: return "Attivo"
        case .english: return "Enabled"
        case .german: return "Aktiv"
        case .french: return "Activée"
        case .chinese: return "已启用"
        }
    }

    private var addonDisabledTitle: String {
        switch service.language {
        case .italian: return "Disattivato"
        case .english: return "Disabled"
        case .german: return "Deaktiviert"
        case .french: return "Désactivée"
        case .chinese: return "已禁用"
        }
    }

    private var experimentalTitle: String {
        switch service.language {
        case .italian: return "Sperimentale"
        case .english: return "Experimental"
        case .german: return "Experimentell"
        case .french: return "Expérimentale"
        case .chinese: return "实验性"
        }
    }

    private var incompatibleTitle: String {
        switch service.language {
        case .italian: return "Incompatibile"
        case .english: return "Incompatible"
        case .german: return "Inkompatibel"
        case .french: return "Incompatible"
        case .chinese: return "不兼容"
        }
    }

    private var capabilitiesTitle: String {
        switch service.language {
        case .italian: return "Capability"
        case .english: return "Capabilities"
        case .german: return "Fähigkeiten"
        case .french: return "Fonctionnalités"
        case .chinese: return "能力"
        }
    }

    private var addonImportErrorTitle: String {
        switch service.language {
        case .italian: return "Importazione add-on fallita"
        case .english: return "Add-on import failed"
        case .german: return "Add-on-Import fehlgeschlagen"
        case .french: return "Échec de l’importation de l’extension"
        case .chinese: return "导入附加组件失败"
        }
    }

    private var importPanelMessage: String {
        switch service.language {
        case .italian: return "Seleziona un file manifest JSON per l'add-on."
        case .english: return "Choose a JSON manifest file for the add-on."
        case .german: return "Wähle eine JSON-Manifestdatei für das Add-on."
        case .french: return "Choisissez un fichier manifeste JSON pour l’extension."
        case .chinese: return "请选择附加组件的 JSON 清单文件。"
        }
    }

    private func originTitle(for origin: TBAddonOrigin) -> String {
        switch (origin, service.language) {
        case (.bundled, .italian): return "Ufficiale"
        case (.bundled, .english): return "Bundled"
        case (.bundled, .german): return "Mitgeliefert"
        case (.bundled, .french): return "Incluse"
        case (.bundled, .chinese): return "内置"
        case (.user, .italian): return "Utente"
        case (.user, .english): return "User"
        case (.user, .german): return "Benutzer"
        case (.user, .french): return "Utilisateur"
        case (.user, .chinese): return "用户"
        }
    }

    private func capabilityTitle(for capability: TBAddonCapability) -> String {
        switch (capability, service.language) {
        case (.networkLink, .italian): return "Network Link"
        case (.networkLink, .english): return "Network Link"
        case (.networkLink, .german): return "Network Link"
        case (.networkLink, .french): return "Network Link"
        case (.networkLink, .chinese): return "网络链路"
        case (.audioRelay, .italian): return "Audio Relay"
        case (.audioRelay, .english): return "Audio Relay"
        case (.audioRelay, .german): return "Audio Relay"
        case (.audioRelay, .french): return "Relais audio"
        case (.audioRelay, .chinese): return "音频转发"
        case (.inputDockstation, .italian): return "Input Dockstation"
        case (.inputDockstation, .english): return "Input Dockstation"
        case (.inputDockstation, .german): return "Input Dockstation"
        case (.inputDockstation, .french): return "Station d’accueil des entrées"
        case (.inputDockstation, .chinese): return "输入扩展坞"
        }
    }
}

private struct ReceiverRemovableStorageSection: View {
    let host: String
    let volumes: [TBMonitorRemovableVolume]
    let status: TBStorageMonitorStatus
    let language: TBDisplaySenderLanguage

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(.caption, design: .rounded, weight: .bold))
                .foregroundStyle(.secondary)

            switch status {
            case .needsHost:
                statusText(needsHostText)
            case .connecting:
                statusText(connectingText)
            case .unavailable:
                statusText(unavailableText)
            case .connected:
                if volumes.isEmpty {
                    statusText(emptyState)
                } else {
                    ForEach(volumes) { volume in
                        HStack(spacing: 12) {
                            Image(systemName: "externaldrive").foregroundStyle(.secondary)
                            Text(volume.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button(mountTitle) { openVolume(volume) }
                                .buttonStyle(.bordered)
                                .disabled(TBMonitorProtocol.removableVolumeSMBURL(
                                    receiverHost: host,
                                    shareName: volume.name
                                ) == nil)
                        }
                    }
                    statusText(mountHint)
                }
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private func statusText(_ value: String) -> some View {
        Text(value)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var title: String {
        let receiver = host.isEmpty ? "Receiver" : host
        switch language {
        case .italian: return "Archivi rimovibili · \(receiver)"
        case .english: return "Removable Storage · \(receiver)"
        case .german: return "Wechselspeicher · \(receiver)"
        case .french: return "Stockage amovible · \(receiver)"
        case .chinese: return "可移动存储 · \(receiver)"
        }
    }

    private var emptyState: String {
        switch language {
        case .italian: return "Nessun volume rimovibile rilevato. Inserisci una scheda o un disco."
        case .english: return "No removable volume detected. Insert a card or drive."
        case .german: return "Kein Wechsellaufwerk erkannt. Karte oder Laufwerk einsetzen."
        case .french: return "Aucun volume amovible détecté. Insérez une carte ou un disque."
        case .chinese: return "尚未检测到可移动卷。请插入 SD 卡或移动磁盘。"
        }
    }

    private var needsHostText: String {
        switch language {
        case .italian: return "Inserisci il nome host o l’indirizzo IP del Receiver sopra."
        case .english: return "Enter the Receiver hostname or IP address above."
        case .german: return "Gib oben den Hostnamen oder die IP-Adresse des Receivers ein."
        case .french: return "Saisissez le nom d’hôte ou l’adresse IP du Receiver ci-dessus."
        case .chinese: return "请先在上方填写 Receiver 主机名或 IP 地址。"
        }
    }

    private var connectingText: String {
        switch language {
        case .italian: return "Connessione al monitoraggio storage indipendente…"
        case .english: return "Connecting to the independent storage monitor…"
        case .german: return "Verbindung zum unabhängigen Speichermonitor…"
        case .french: return "Connexion au moniteur de stockage indépendant…"
        case .chinese: return "正在连接独立存储监视服务…"
        }
    }

    private var unavailableText: String {
        switch language {
        case .italian: return "Monitoraggio non disponibile. Nuovo tentativo automatico in corso."
        case .english: return "Monitor unavailable. Retrying automatically."
        case .german: return "Monitor nicht verfügbar. Neuer Versuch läuft automatisch."
        case .french: return "Moniteur indisponible. Nouvelle tentative automatique."
        case .chinese: return "存储监视暂不可用，正在自动重试。"
        }
    }

    private var mountTitle: String {
        switch language {
        case .italian: return "Monta"
        case .english: return "Mount"
        case .german: return "Verbinden"
        case .french: return "Monter"
        case .chinese: return "挂载"
        }
    }

    private var mountHint: String {
        switch language {
        case .italian: return "Condividi prima questo volume sul Receiver in Condivisione file usando il nome mostrato. L’accesso SMB richiede l’account macOS del Receiver."
        case .english: return "First share this volume on the Receiver in File Sharing using the displayed name. SMB access uses a Receiver macOS account."
        case .german: return "Gib dieses Volume zuerst am Receiver unter Dateifreigabe mit dem angezeigten Namen frei. Für SMB ist ein Receiver-macOS-Account erforderlich."
        case .french: return "Partagez d’abord ce volume sur le Receiver dans Partage de fichiers en utilisant le nom affiché. L’accès SMB utilise un compte macOS du Receiver."
        case .chinese: return "请先在 Receiver 的“文件共享”中用列表显示的名称共享此卷，再点击挂载；SMB 使用 Receiver 的 macOS 账户认证。"
        }
    }

    private func openVolume(_ volume: TBMonitorRemovableVolume) {
        guard let url = TBMonitorProtocol.removableVolumeSMBURL(
            receiverHost: host,
            shareName: volume.name
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct TBReceiverPairingImportView: View {
    let language: TBDisplaySenderLanguage
    let receivers: [TBDiscoveredReceiver]
    @Binding var selectedHost: String
    let onImport: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(TBDisplaySenderL10n.text("sender.pairing.steps", language))
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Menu(TBDisplaySenderL10n.text("sender.pairing.choose", language)) {
                    ForEach(receivers) { receiver in
                        Button(receiver.displayText) { selectedHost = receiver.preferredIP }
                    }
                }
                .disabled(receivers.isEmpty)
                Button(TBDisplaySenderL10n.text("sender.pairing.import", language), action: onImport)
                    .buttonStyle(.bordered)
            }
        }
    }
}
