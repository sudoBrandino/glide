import AppKit
import GlideCore
import SwiftUI

/// The Settings window (menu bar → Settings…, ⌘,): everything Glide Host keeps in host.json and
/// the login item, in one place. Display and virtual-display choices go through their controllers
/// (they apply at once, like the menu); clipboard, audio and file transfer apply to the next
/// connection; listening applies after a restart. The setup window stays the first-run checklist.
final class SettingsModel: ObservableObject {
    struct Actions {
        /// Dial this PC now (nil stops dialing). The listener is unaffected.
        var setDialTarget: (String?) -> Void = { _ in }
        var isDialing: () -> Bool = { false }
        var openPairing: () -> Void = {}
        var cancelPairing: () -> Void = {}
        var removeViewer: (PairedViewer) -> Void = { _ in }
        /// Clipboard/audio/files changed: the next session uses them.
        var sharingChanged: (HostConfig) -> Void = { _ in }
        var showSetup: () -> Void = {}
    }

    enum Tab: String, CaseIterable, Identifiable {
        case general, connection, display, viewers, sharing, advanced
        var id: String { rawValue }
        var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .connection: return "network"
            case .display: return "display"
            case .viewers: return "person.2"
            case .sharing: return "arrow.left.arrow.right"
            case .advanced: return "slider.horizontal.3"
            }
        }
    }

    let actions: Actions
    @Published var tab: Tab = .general
    /// host.json as last read (defaults when there is none).
    @Published private(set) var config = HostConfig()
    /// host.json exists but can't be read: nothing is saved until it's fixed.
    @Published private(set) var configProblem: String?
    @Published private(set) var loginItem = Instance.loginItem
    @Published private(set) var status = HostStatus.shared.snapshot
    @Published private(set) var display = DisplaySettings()
    @Published private(set) var virtual = VirtualDisplayConfig()
    /// The PC address field (saved with Save / Return).
    @Published var connectDraft = ""
    @Published var downloadDirDraft = ""
    @Published var error: String?
    /// What the last change does and when it applies.
    @Published var notice: String?
    /// The listen setting was changed: it only applies after a restart.
    @Published private(set) var needsRestart = false

    private var timer: Timer?
    private var shownConnect: String??
    private var shownDownloadDir: String??

    init(actions: Actions) {
        self.actions = actions
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        do {
            let c = try ConfigFile.read(HostConfig.self, from: HostConfig.url) ?? HostConfig()
            if c != config { config = c }
            if configProblem != nil { configProblem = nil }
        } catch {
            let p = "\(error)"
            if p != configProblem { configProblem = p }
        }
        // Only replace a field's text when the saved value changed (the user may be typing).
        if shownConnect != .some(config.connect) { shownConnect = .some(config.connect); connectDraft = config.connect ?? "" }
        let dir = config.files?.downloadDir
        if shownDownloadDir != .some(dir) { shownDownloadDir = .some(dir); downloadDirDraft = dir ?? FileSettings.defaultDownloadDir }
        let li = Instance.loginItem
        if li != loginItem { loginItem = li }
        status = HostStatus.shared.snapshot
        let dm = DisplayModeController.shared
        dm.loadSettings()
        if dm.settings != display { display = dm.settings }
        let vd = VirtualDisplayManager.shared
        vd.loadConfig()
        if vd.config != virtual { virtual = vd.config }
    }

    /// Read-modify-write of host.json; false (and `error` says why) when the file can't be used.
    @discardableResult
    private func save(_ what: String, _ change: (inout HostConfig) -> Void) -> HostConfig? {
        do {
            let c = try HostConfig.update(change)
            config = c
            error = nil
            return c
        } catch {
            self.error = HostConfig.notSavedText(error, what: what)
            return nil
        }
    }

    // MARK: General

    var startsAtLogin: Bool { loginItem == .on || loginItem == .onViaScript || loginItem == .needsApproval || loginItem == .managed }

    func setStartAtLogin(_ on: Bool) {
        guard loginItem != .managed else { return }
        do {
            if on {
                try Instance.enableLoginItem()
                if Instance.loginItem == .needsApproval {
                    notice = "Allow Glide Host in System Settings → General → Login Items."
                    SMAppServiceHelper.openLoginItems()
                } else {
                    notice = "Glide Host starts when you log in."
                }
            } else {
                if Instance.launchdLabel != nil {
                    let a = NSAlert()
                    a.messageText = "Stop starting Glide Host at login?"
                    a.informativeText = "This copy was started at login, so macOS may quit it now. Open Glide Host from Applications to keep using it until you log out."
                    a.addButton(withTitle: "Turn Off")
                    a.addButton(withTitle: "Cancel")
                    guard a.runModal() == .alertFirstButtonReturn else { return }
                }
                try Instance.disableLoginItem()
                notice = "Glide Host no longer starts at login."
            }
            error = nil
        } catch {
            self.error = "Couldn't change the login item: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLog() { NSWorkspace.shared.open(StatusMenu.logURL()) }

    // MARK: Connection

    var connectProblem: String? { DialPolicy.validateTarget(connectDraft) }
    var connectDraftChanged: Bool { connectDraft.trimmingCharacters(in: .whitespaces) != (config.connect ?? "") }

    func saveConnect() {
        guard connectProblem == nil else { return }
        let t = connectDraft.trimmingCharacters(in: .whitespaces)
        guard let c = save("the PC's address", { $0.connect = t.isEmpty ? nil : t }) else { return }
        shownConnect = .some(c.connect)
        connectDraft = c.connect ?? ""
        if let target = c.connect {
            // Dial the new address now only if Glide would anyway (at launch, or already dialing).
            if c.dialsAtLaunch || actions.isDialing() {
                actions.setDialTarget(target)
                notice = "Saved. Glide Host is connecting to \(target)."
            } else {
                notice = "Saved. Glide Host connects to \(target) when you click Connect Now (or menu bar → Connect to PC)."
            }
        } else {
            actions.setDialTarget(nil)
            notice = "PC address removed. Glide Host only waits for the PC to connect."
        }
    }

    func clearConnect() {
        connectDraft = ""
        saveConnect()
    }

    func setConnectAtLaunch(_ on: Bool) {
        guard save("the connect-at-launch setting", { $0.connectAtLaunch = on ? nil : false }) != nil else { return }
        notice = on ? "Glide Host connects to the PC whenever it starts."
            : "Glide Host won't connect to the PC on its own when it starts. Use Connect Now, or menu bar → Connect to PC."
    }

    func connectNow() {
        guard let t = config.connect else { return }
        actions.setDialTarget(t)
        notice = "Connecting to \(t)…"
    }

    func stopConnecting() {
        actions.setDialTarget(nil)
        notice = "Stopped connecting to the PC. Glide Host still waits for the PC to connect" + (config.dialsAtLaunch ? ", and connects out again when it restarts." : ".")
    }

    func setListen(_ on: Bool) {
        guard save("the listen setting", { $0.listen = on ? nil : false }) != nil else { return }
        needsRestart = true
        notice = "Takes effect when Glide Host restarts."
    }

    func restart() { Instance.relaunch(reason: "Settings window") }

    // MARK: Display (through the controllers, like the menu: applied at once)

    func setPreference(_ p: DisplayModePreference) { DisplayModeController.shared.setPreference(p); refresh() }
    func setHighDPIChoice(_ c: HighDPIViewerChoice) { DisplayModeController.shared.setHighDPIChoice(c); refresh() }
    func setRestoreOnDisconnect(_ on: Bool) { DisplayModeController.shared.setRestoreOnDisconnect(on); refresh() }
    func setVirtualEnabled(_ on: Bool) { VirtualDisplayManager.shared.setEnabled(on); refresh() }
    func setMonitorMode(_ m: VirtualDisplayMonitorMode) { VirtualDisplayManager.shared.setMonitorMode(m); refresh() }
    func setMakeMain(_ on: Bool) { VirtualDisplayManager.shared.setMakeMain(on); refresh() }
    func setAlwaysOn(_ on: Bool) { VirtualDisplayManager.shared.setAlwaysOn(on); refresh() }

    // MARK: Viewers

    func pair() { actions.openPairing() }
    func cancelPairing() { actions.cancelPairing() }

    func unpair(_ v: PairedViewer) {
        let a = NSAlert()
        a.messageText = "Unpair “\(v.name)”?"
        a.informativeText = "This viewer will no longer be able to connect until it is paired again (Pair New Viewer…). If it is connected now, it is disconnected.\n\nKey \(v.fingerprint), paired \(Self.pairedDate(v.paired))"
        a.addButton(withTitle: "Unpair")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        actions.removeViewer(v)
        notice = "Unpaired “\(v.name)”."
        refresh()
    }

    static func pairedDate(_ iso: String) -> String {
        guard let d = ISO8601DateFormatter().date(from: iso) else { return iso }
        return DateFormatter.localizedString(from: d, dateStyle: .medium, timeStyle: .short)
    }

    // MARK: Sharing (next connection)

    private func saveSharing(_ what: String, _ change: (inout HostConfig) -> Void) {
        guard let c = save(what, change) else { return }
        actions.sharingChanged(c)
        notice = status.viewer == nil ? "Saved. Applies to the next connection." : "Saved. Applies from the next connection (disconnect the viewer to apply it now)."
    }

    func setClipboard(_ on: Bool) {
        saveSharing("the clipboard setting") { c in var s = c.clipboard ?? ClipboardSettings(); s.enabled = on ? nil : false; c.clipboard = s }
    }

    func setSyncConcealed(_ on: Bool) {
        saveSharing("the clipboard setting") { c in var s = c.clipboard ?? ClipboardSettings(); s.syncConcealed = on ? true : nil; c.clipboard = s }
    }

    func setAudio(_ on: Bool) {
        saveSharing("the audio setting") { c in var s = c.audio ?? AudioSettings(); s.enabled = on ? nil : false; c.audio = s }
    }

    func setFiles(_ on: Bool) {
        saveSharing("the file transfer setting") { c in var s = c.files ?? FileSettings(); s.enabled = on ? nil : false; c.files = s }
    }

    func setReceive(_ on: Bool) {
        saveSharing("the file transfer setting") { c in var s = c.files ?? FileSettings(); s.receive = on ? nil : false; c.files = s }
    }

    var resolvedDownloadDir: URL { HostFileConfig(config.files).downloadDir }

    func chooseDownloadDir() {
        let p = NSOpenPanel()
        p.title = "Received Files Folder"
        p.prompt = "Choose"
        p.message = "Files the viewer sends to this Mac are saved here."
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.canCreateDirectories = true
        p.allowsMultipleSelection = false
        p.directoryURL = resolvedDownloadDir
        guard p.runModal() == .OK, let u = p.url else { return }
        setDownloadDir(u.path)
    }

    /// `~` is kept (host.json is easier to read and survives a renamed home folder).
    func setDownloadDir(_ path: String?) {
        var value = path?.trimmingCharacters(in: .whitespaces)
        if let v = value {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            if v == home { value = "~" } else if v.hasPrefix(home + "/") { value = "~" + v.dropFirst(home.count) }
        }
        if value == FileSettings.defaultDownloadDir || value?.isEmpty == true { value = nil }
        saveSharing("the received files folder") { c in var s = c.files ?? FileSettings(); s.downloadDir = value; c.files = s }
        shownDownloadDir = nil
        refresh()
    }

    func revealDownloadDir() {
        let d = resolvedDownloadDir
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([d])
    }

    // MARK: Advanced

    func revealConfig() { NSWorkspace.shared.activateFileViewerSelecting([HostConfig.url]) }

    func resetSettings() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Reset Glide Host's settings?"
        a.informativeText = "Every setting goes back to its default: the PC's address is removed and connecting out stops, the display mode is Automatic, the virtual display is on, and clipboard, audio and file transfer are on.\n\nYour paired viewers, this Mac's key and the login item are kept."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let wasListening = config.listen != false
        guard let c = save("the reset", { $0 = $0.resettingPreferences() }) else { return }
        DisplayModeController.shared.resetPreferences()
        VirtualDisplayManager.shared.resetPreferences()
        actions.setDialTarget(nil)
        actions.sharingChanged(c)
        if !wasListening { needsRestart = true }
        notice = "Settings reset." + (wasListening ? "" : " Listening for the PC starts when Glide Host restarts.")
        shownConnect = nil
        shownDownloadDir = nil
        refresh()
    }
}

// MARK: - View

struct SettingsView: View {
    @ObservedObject var m: SettingsModel

    var body: some View {
        VStack(spacing: 0) {
            if let p = m.configProblem {
                Text("Settings can't be saved: \(p). Glide Host won't overwrite it, so your paired viewers are kept. Fix the file, or move it away to start over.")
                    .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding([.horizontal, .top], 16)
            }
            TabView(selection: $m.tab) {
                general.tabItem { Label("General", systemImage: SettingsModel.Tab.general.symbol) }.tag(SettingsModel.Tab.general)
                connection.tabItem { Label("Connection", systemImage: SettingsModel.Tab.connection.symbol) }.tag(SettingsModel.Tab.connection)
                displayTab.tabItem { Label("Display", systemImage: SettingsModel.Tab.display.symbol) }.tag(SettingsModel.Tab.display)
                viewers.tabItem { Label("Viewers", systemImage: SettingsModel.Tab.viewers.symbol) }.tag(SettingsModel.Tab.viewers)
                sharing.tabItem { Label("Sharing", systemImage: SettingsModel.Tab.sharing.symbol) }.tag(SettingsModel.Tab.sharing)
                advanced.tabItem { Label("Advanced", systemImage: SettingsModel.Tab.advanced.symbol) }.tag(SettingsModel.Tab.advanced)
            }
            .padding(.top, 8)
            footer
        }
        .frame(width: 620, height: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let e = m.error {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled).lineLimit(3)
            } else if let n = m.notice {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text(n).foregroundStyle(.secondary).font(.callout).lineLimit(3)
            }
            Spacer(minLength: 8)
            if m.needsRestart { Button("Restart Glide Host") { m.restart() } }
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 20).padding(.vertical, 10)
    }

    private func toggle(_ title: String, _ value: Bool, _ set: @escaping (Bool) -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { value }, set: set))
    }

    private func note(_ s: String) -> some View {
        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    // MARK: General

    /// Glide Cloud (ENTERPRISE.md): who manages this Mac and what that changes.
    @ViewBuilder private var organization: some View {
        if let g = m.status.managed {
            Section {
                LabeledContent("Status", value: g.summary)
                if let d = g.deviceName { LabeledContent("This Mac in the console", value: d) }
                if let u = g.cloudURL { LabeledContent("Glide Cloud", value: u) }
                if let e = g.enrolledAt { LabeledContent("Enrolled", value: SettingsModel.pairedDate(e)) }
                if g.updateRequired {
                    Text("This version (\(GlideVersion.version)) is older than your organization's minimum (\(g.minAppVersion ?? "?")). Update Glide Host to accept sessions through Glide Cloud.")
                        .foregroundStyle(.red).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if !g.lanAllowed { note("LAN connections are \(g.lanOffReason ?? "off"): viewers connect through Glide Cloud only.") }
                else if !g.pairingAllowed { note("Pairing new viewers on the local network is turned off by \(g.orgName ?? "your organization").") }
                ForEach(g.problems, id: \.self) { p in Text(p).font(.callout).foregroundStyle(.orange) }
            } header: {
                Text(g.orgName.map { "Managed by \($0)" } ?? "Organization")
            } footer: {
                note("People your organization allows connect through Glide Cloud with their work account. You see who is connected in the menu bar and can end the session there at any time.")
            }
        }
    }

    private var general: some View {
        Form {
            organization
            Section {
                if m.loginItem == .managed {
                    LabeledContent("Start Glide Host at login", value: "Managed by your organization")
                } else {
                    toggle("Start Glide Host at login", m.startsAtLogin) { m.setStartAtLogin($0) }
                        .disabled(m.loginItem == .onViaScript || !Instance.isAppBundle)
                }
                switch m.loginItem {
                case .managed:
                    note("Your organization's installer starts Glide Host at login for every user of this Mac.")
                case .needsApproval:
                    HStack {
                        note("Waiting for your approval in System Settings → General → Login Items.")
                        Spacer()
                        Button("Open Login Items") { SMAppServiceHelper.openLoginItems() }
                    }
                case .onViaScript:
                    note("Started at login by the LaunchAgent the install script set up. Remove it with tools/install-host.sh --uninstall.")
                case .on:
                    note("Glide Host also restarts on its own if it quits unexpectedly. Whether it connects out to the PC when it starts is under Connection.")
                case .off:
                    note("Off: open Glide Host by hand after you log in, or the PC can't reach this Mac.")
                }
            }
            Section {
                LabeledContent("Version", value: GlideVersion.display)
                LabeledContent("Log") {
                    Button("Open Log") { m.openLog() }
                }
                LabeledContent("Setup checklist") {
                    Button("Set Up Glide Host…") { m.actions.showSetup() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Connection

    private var connectionStatus: String {
        let s = m.status
        if let v = s.viewer, let u = v.cloudUser { return "Connected through Glide Cloud: \(u.label)." }
        if let v = s.viewer { return "Connected: \(v.name) (\(v.address))." }
        var parts: [String] = []
        if s.paused { parts.append("Paused from the menu bar: not accepting or dialing connections.") }
        if let p = s.listenPort { parts.append("Waiting for the PC on port \(p).") }
        else if m.config.connect != nil && m.config.listen == false { parts.append("Not listening (only this Mac connects).") }
        if let e = s.serverError { parts.append(e) }
        if let t = s.dialTarget { parts.append("Connecting to \(t)" + (s.dialDetail.map { ": \($0)." } ?? ".")) }
        else if m.config.connect != nil { parts.append("Not connecting out right now.") }
        return parts.joined(separator: " ")
    }

    private var connection: some View {
        Form {
            Section {
                note(connectionStatus)
                if let g = m.status.managed, !g.lanAllowed {
                    Text("LAN connections are \(g.lanOffReason ?? "off"). These settings apply again if that changes.")
                        .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                HStack {
                    TextField("PC address", text: $m.connectDraft, prompt: Text("e.g. 192.168.1.20 or 192.168.1.20:7420"))
                        .onSubmit { m.saveConnect() }
                    Button("Save") { m.saveConnect() }
                        .disabled(!m.connectDraftChanged || m.connectProblem != nil)
                    if m.config.connect != nil { Button("Clear") { m.clearConnect() } }
                }
                if let p = m.connectProblem { Text(p).font(.callout).foregroundStyle(.red) }
                toggle("Connect out to the PC automatically when Glide Host starts", m.config.dialsAtLaunch) { m.setConnectAtLaunch($0) }
                    .disabled(m.config.connect == nil)
                HStack {
                    if m.status.dialTarget != nil {
                        Button("Stop Connecting") { m.stopConnecting() }
                    } else {
                        Button("Connect Now") { m.connectNow() }.disabled(m.config.connect == nil || m.status.paused)
                    }
                    Spacer()
                }
            } header: {
                Text("Connect out to the PC")
            } footer: {
                note("Only needed when the network lets this Mac reach the PC but not the other way round. Glide Host retries every few seconds until the PC answers. Turn the automatic connection off if you'd rather connect only when you ask.")
            }
            Section {
                toggle("Accept connections from the PC", m.config.listen != false || m.config.connect == nil) { m.setListen($0) }
                    .disabled(m.config.connect == nil)
                LabeledContent("Port", value: "\(m.status.listenPort.map(String.init) ?? "7420")")
            } header: {
                Text("Listen")
            } footer: {
                note("Turning this off needs a PC address above: then nothing on this Mac accepts connections, and only this Mac connects. Takes effect when Glide Host restarts. The port is set with glide-host --port; the viewer must use the same one.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Display

    private static let prefs: [(DisplayModePreference, String, String)] = [
        (.automatic, "Automatic", "Crisp for most viewers; for 4K-class viewers, the choice below."),
        (.crisp, "Crisp — native 1x", "A non-HiDPI mode matching the viewer pixel for pixel."),
        (.retina, "Retina — HiDPI 1:1", "A HiDPI mode whose pixels match the viewer (4K looks like 1920×1080)."),
        (.smooth, "Smooth — HiDPI scaled", "A HiDPI mode that looks like about two-thirds of the viewer, downscaled."),
        (.manual, "Don't Change", "Never change the display mode."),
    ]

    private var displayTab: some View {
        Form {
            Section {
                Picker("Display mode", selection: Binding(get: { m.display.preference }, set: { m.setPreference($0) })) {
                    ForEach(Self.prefs, id: \.0) { p in Text(p.1).tag(p.0) }
                }
                note(Self.prefs.first { $0.0 == m.display.preference }?.2 ?? "")
                Picker("Automatic on 4K viewers", selection: Binding(get: { m.display.highDPIChoice }, set: { m.setHighDPIChoice($0) })) {
                    Text("Retina — looks like 1920×1080").tag(HighDPIViewerChoice.retina)
                    Text("More Space — looks like 2560×1440").tag(HighDPIViewerChoice.smooth)
                }
                .disabled(m.display.preference != .automatic)
                toggle("Restore the Mac's display mode when the viewer disconnects", m.display.restoreEnabled) { m.setRestoreOnDisconnect($0) }
            } header: {
                Text("Display mode")
            } footer: {
                note("Applies right away, also to a connected viewer. A viewer's own per-session choice is replaced.")
            }
            Section {
                toggle("Use a virtual display sized to the viewer", m.virtual.isEnabled) { m.setVirtualEnabled($0) }
                if let why = VirtualDisplayManager.unavailableReason {
                    Text("Not available on this Mac: \(why)").font(.callout).foregroundStyle(.red)
                }
                Picker("With a monitor attached", selection: Binding(get: { m.virtual.monitorMode }, set: { m.setMonitorMode($0) })) {
                    ForEach(VirtualDisplayMonitorMode.allCases, id: \.self) { mode in Text(StatusMenu.monitorModeTitle(mode)).tag(mode) }
                }
                .disabled(!m.virtual.isEnabled)
                if m.virtual.monitorMode == .extend {
                    toggle("Make it the main display", m.virtual.wantsMain) { m.setMakeMain($0) }
                        .disabled(!m.virtual.isEnabled)
                }
                toggle("Keep it when no viewer is connected", m.virtual.alwaysOn) { m.setAlwaysOn($0) }
                    .disabled(!m.virtual.isEnabled)
            } header: {
                Text("Virtual display")
            } footer: {
                note("Glide creates a monitor with the viewer's exact pixels and refresh rate and streams it 1:1 (docs/VIRTUAL_DISPLAY.md). Turning it on or off applies now when no viewer is connected; the monitor choice applies from the next connection.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Viewers

    private var viewers: some View {
        let s = m.status
        let open = s.pairingUntil.map { $0 > Date() } ?? false
        return Form {
            Section {
                if s.pairedViewers.isEmpty {
                    note("No viewer is paired yet. Pair one to let a PC connect.")
                }
                ForEach(s.pairedViewers, id: \.key) { v in
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(v.name).font(.headline)
                                if s.viewer?.name == v.name { Text("connected").font(.caption).foregroundStyle(.green) }
                            }
                            Text(v.fingerprint).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("Paired \(SettingsModel.pairedDate(v.paired))").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Unpair…") { m.unpair(v) }
                    }
                }
            } header: {
                Text("Paired viewers")
            }
            Section {
                HStack {
                    if let who = s.pairingWith {
                        note("Pairing with “\(who)”: compare the code on both screens.")
                    } else if open, let until = s.pairingUntil {
                        let left = max(0, Int(until.timeIntervalSinceNow.rounded(.up)))
                        note(String(format: "Pairing is open for %d:%02d. Connect from the PC; both screens show the same code.", left / 60, left % 60))
                    } else if let g = s.managed, !g.pairingAllowed {
                        note("Pairing is turned off by \(g.orgName ?? "your organization"). Viewers connect through Glide Cloud.")
                    } else {
                        note("A new viewer proves who it is once, with a code shown on both screens.")
                    }
                    Spacer()
                    if open { Button("Stop Pairing") { m.cancelPairing() } }
                    else { Button("Pair New Viewer…") { m.pair() }.disabled(s.pairingWith != nil || s.managed?.pairingAllowed == false) }
                }
                LabeledContent("This Mac's key") {
                    Text(s.hostFingerprint ?? "?").font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Sharing

    private var sharing: some View {
        let clip = m.config.clipboard ?? ClipboardSettings()
        let files = HostFileConfig(m.config.files)
        return Form {
            Section {
                toggle("Sync the clipboard with the viewer", clip.isEnabled) { m.setClipboard($0) }
                toggle("Also sync passwords from password managers", clip.syncsConcealed) { m.setSyncConcealed($0) }
                    .disabled(!clip.isEnabled)
                toggle("Send this Mac's sound to the viewer", m.config.audio?.isEnabled ?? true) { m.setAudio($0) }
            } header: {
                Text("Clipboard and sound")
            }
            Section {
                toggle("Allow file transfer", files.enabled) { m.setFiles($0) }
                toggle("Accept files sent from the viewer", files.receive) { m.setReceive($0) }
                    .disabled(!files.enabled)
                LabeledContent("Save received files in") {
                    HStack {
                        Text(m.resolvedDownloadDir.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Choose…") { m.chooseDownloadDir() }
                        Button { m.revealDownloadDir() } label: { Image(systemName: "folder") }.help("Show in Finder")
                    }
                }
                .disabled(!files.enabled)
                if m.config.files?.downloadDir != nil {
                    HStack { Spacer(); Button("Use Default Folder") { m.setDownloadDir(nil) } }
                }
            } header: {
                Text("File transfer")
            } footer: {
                note("Changes apply from the next connection.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Advanced

    private var advanced: some View {
        Form {
            Section {
                LabeledContent("Settings file") {
                    HStack {
                        Text(HostConfig.url.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        Button("Show in Finder") { m.revealConfig() }
                    }
                }
                note("host.json holds these settings and the paired viewers; host-key next to it is this Mac's identity. Other options (frame rate, bitrate, the default display) are command-line flags: glide-host --help.")
            }
            Section {
                HStack {
                    note("Every setting back to its default. Paired viewers, this Mac's key and the login item are kept.")
                    Spacer()
                    Button("Reset Settings…") { m.resetSettings() }
                }
                HStack {
                    note("Quit and start again, e.g. after changing Listen.")
                    Spacer()
                    Button("Restart Glide Host") { m.restart() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Window

final class SettingsWindowController: NSObject, NSWindowDelegate {
    static var shared: SettingsWindowController?
    let model: SettingsModel
    let window: NSWindow

    init(model: SettingsModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 560), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Glide Host Settings"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SettingsView(m: model))
        window.center()
    }

    func show(tab: SettingsModel.Tab? = nil) {
        if let tab { model.tab = tab }
        model.start()
        AppWindows.opened()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        model.notice = nil
        model.error = nil
        AppWindows.closed(window)
    }

    /// Render one tab to a PNG without showing it (--settings-preview, docs).
    static func renderPreview(_ model: SettingsModel, to path: String, dark: Bool = false) -> Bool {
        let view = NSHostingView(rootView: SettingsView(m: model))
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 560)
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }
}

/// A menu-bar app becomes a regular app (Dock icon, Cmd-Tab, keyboard focus) while one of its
/// windows is open, and goes back to the menu bar only when the last one closes.
enum AppWindows {
    static func opened() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func closed(_ closing: NSWindow) {
        let others = [SetupWindowController.shared?.window, SettingsWindowController.shared?.window]
            .compactMap { $0 }.filter { $0 !== closing && $0.isVisible }
        if others.isEmpty { NSApp.setActivationPolicy(.accessory) }
    }
}
