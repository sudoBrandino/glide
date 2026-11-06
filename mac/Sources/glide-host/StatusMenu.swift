import AppKit
import GlideCore

/// The host's only UI: a menu-bar status item (the app is LSUIElement).
final class StatusMenu: NSObject, NSMenuDelegate {
    /// What the menu can ask the server to do.
    struct Actions {
        var disconnect: () -> Void = {}
        var setPaused: (Bool) -> Void = { _ in }
        /// Send files to the connected viewer; false if it can't take files.
        var sendFiles: ([URL]) -> Bool = { _ in false }
        var cancelFiles: () -> Void = {}
    }

    let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private let actions: Actions
    private let password: String
    private let displayID: CGDirectDisplayID
    private var refreshTimer: Timer?
    private var menuOpen = false
    /// launchd label when run as the LaunchAgent (KeepAlive relaunches us on exit).
    let launchdLabel: String?

    // Info rows
    private let headerItem = NSMenuItem()
    private let viewerItem = NSMenuItem()
    private let streamItem = NSMenuItem()
    private let resolutionItem = NSMenuItem()
    private let statsItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let warningItem = NSMenuItem()
    // Actions
    private let disconnectItem = NSMenuItem(title: "Disconnect Viewer", action: #selector(disconnect), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    private let displayItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
    private let displayMenu = NSMenu()
    private var prefItems: [DisplayModePreference: NSMenuItem] = [:]
    private var highDPIItems: [HighDPIViewerChoice: NSMenuItem] = [:]
    private let restoreToggleItem = NSMenuItem(title: "Restore Mode on Disconnect", action: #selector(toggleRestore), keyEquivalent: "")
    private let restoreNowItem = NSMenuItem(title: "Restore Now", action: #selector(restoreNow), keyEquivalent: "")
    private let displayInfoItem = NSMenuItem()
    private let displayActionItem = NSMenuItem()
    // File transfer (§6)
    private let sendFilesItem = NSMenuItem(title: "Send Files to Viewer…", action: #selector(sendFiles), keyEquivalent: "")
    private let fileProgressItem = NSMenuItem()
    private let cancelFilesItem = NSMenuItem(title: "Cancel File Transfer", action: #selector(cancelFiles), keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent Transfers", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()
    /// Where received files go (host.json files.downloadDir).
    var downloadDir: URL?

    init(actions: Actions, password: String, displayID: CGDirectDisplayID, showStatusItem: Bool = true) {
        self.actions = actions
        self.password = password
        self.displayID = displayID
        let env = ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"]
        launchdLabel = (env?.isEmpty == false && env != "0") ? env : nil
        super.init()
        buildMenu()
        if showStatusItem {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.menu = menu
            item.button?.toolTip = "Glide Host"
            statusItem = item
        }
        HostStatus.shared.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    // MARK: Building

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self
        for i in [headerItem, viewerItem, streamItem, resolutionItem, statsItem, detailItem, warningItem] {
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())
        for i in [disconnectItem, pauseItem] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        for i in [sendFilesItem, cancelFilesItem] { i.target = self }
        fileProgressItem.isEnabled = false
        recentMenu.autoenablesItems = false
        recentItem.submenu = recentMenu
        for i in [sendFilesItem, fileProgressItem, cancelFilesItem, recentItem] { menu.addItem(i) }
        menu.addItem(.separator())

        displayMenu.autoenablesItems = false
        let prefs: [(DisplayModePreference, String)] = [
            (.automatic, "Automatic"),
            (.crisp, "Crisp — native 1x"),
            (.smooth, "Smooth — HiDPI scaled"),
            (.retina, "Retina — HiDPI 1:1"),
            (.manual, "Don't Change"),
        ]
        for (p, title) in prefs {
            let i = NSMenuItem(title: title, action: #selector(choosePreference(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = p.rawValue
            prefItems[p] = i
            displayMenu.addItem(i)
        }
        displayMenu.addItem(.separator())
        let hdr = NSMenuItem(title: "Automatic on 4K Viewers", action: nil, keyEquivalent: "")
        hdr.isEnabled = false
        displayMenu.addItem(hdr)
        for (c, title) in [(HighDPIViewerChoice.retina, "Retina — looks like 1920×1080"), (.smooth, "More Space — looks like 2560×1440")] {
            let i = NSMenuItem(title: title, action: #selector(chooseHighDPI(_:)), keyEquivalent: "")
            i.target = self; i.representedObject = c.rawValue; i.indentationLevel = 1
            highDPIItems[c] = i
            displayMenu.addItem(i)
        }
        displayMenu.addItem(.separator())
        restoreToggleItem.target = self
        restoreNowItem.target = self
        displayMenu.addItem(restoreToggleItem)
        displayMenu.addItem(restoreNowItem)
        displayMenu.addItem(.separator())
        for i in [displayInfoItem, displayActionItem] { i.isEnabled = false; displayMenu.addItem(i) }
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        menu.addItem(.separator())
        add("Open Log", #selector(openLog))
        add("Copy Viewer Password", #selector(copyPassword))
        menu.addItem(.separator())
        if launchdLabel != nil {
            add("Restart Glide Host", #selector(restart))
            add("Quit Until Next Login", #selector(quitUntilLogin))
        } else {
            add("Quit Glide Host", #selector(quit))
        }
    }

    private func add(_ title: String, _ sel: Selector) {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
    }

    // MARK: Refresh

    func refresh() {
        let s = HostStatus.shared.snapshot
        let phase = s.phase
        statusItem?.button?.image = Self.icon(for: phase)
        statusItem?.button?.toolTip = "Glide Host — \(Self.phaseTitle(phase))"

        headerItem.title = "Glide Host — \(Self.phaseTitle(phase))"
        if let v = s.viewer {
            viewerItem.title = "Viewer: \(v.name) (\(v.address))"
            if let c = v.video {
                let chroma = v.hybrid ? "4:2:0 + 4:4:4 refine" : (c.chroma == .yuv444 ? "4:4:4" : "4:2:0")
                let mode = v.hybrid ? "Hybrid" : (c.chroma == .yuv444 ? "Sharp" : "Fast")
                streamItem.title = "Stream: \(mode) · \(c.codec == .hevc ? "HEVC" : "H.264") \(chroma)" + (v.audio.map { " · audio \($0)" } ?? "")
                resolutionItem.title = "Video: \(c.width)×\(c.height) · viewer \(v.viewW)×\(v.viewH)"
            } else {
                streamItem.title = "Stream: starting…"
                resolutionItem.title = "Viewer screen: \(v.viewW)×\(v.viewH)"
            }
            if let fps = v.fps, let mbps = v.mbps, let enc = v.encodeMs {
                statsItem.title = String(format: "%.0f fps · %.1f Mbps · encode %.1f ms", fps, mbps, enc)
            } else {
                statsItem.title = "Stats: waiting…"
            }
        }
        for i in [viewerItem, streamItem, resolutionItem, statsItem] { i.isHidden = s.viewer == nil }

        var detail: String?
        if let e = s.viewer?.captureError { detail = "Capture: \(e)" }
        else if let e = s.serverError { detail = e }
        else if s.paused { detail = "Not accepting or dialing connections" }
        else if s.viewer == nil, let t = s.dialTarget { detail = "Dialing \(t)" + (s.dialDetail.map { " — \($0)" } ?? "") }
        else if s.viewer == nil, let p = s.listenPort { detail = "Listening on port \(p)" }
        detailItem.title = detail ?? ""
        detailItem.isHidden = detail == nil

        var warnings: [String] = []
        if !CGPreflightScreenCaptureAccess() { warnings.append("Screen Recording") }
        if !AXIsProcessTrusted() { warnings.append("Accessibility") }
        warningItem.title = "⚠︎ Missing permission: " + warnings.joined(separator: ", ")
        warningItem.isHidden = warnings.isEmpty

        disconnectItem.isEnabled = s.viewer != nil
        refreshFiles(s)
        pauseItem.title = s.paused ? (s.dialTarget != nil ? "Resume Dialing" : "Resume") : (s.dialTarget != nil ? "Pause Dialing" : "Pause (Refuse Connections)")

        // Display submenu
        let dm = DisplayModeController.shared
        dm.loadSettings()
        let st = dm.settings
        for (p, i) in prefItems { i.state = st.preference == p ? .on : .off }
        for (c, i) in highDPIItems { i.state = st.highDPIChoice == c ? .on : .off; i.isEnabled = true }
        restoreToggleItem.state = st.restoreEnabled ? .on : .off
        if let r = dm.restoreTarget {
            restoreNowItem.title = "Restore \(r) Now"
            restoreNowItem.isHidden = false
        } else { restoreNowItem.isHidden = true }
        if let m = CGDisplayCopyDisplayMode(displayID) {
            let info = DisplayModeInfo(m)
            displayInfoItem.title = "Mac display: " + (info.hiDPI ? "looks like \(info.width)×\(info.height) (HiDPI, \(info.pixelWidth)×\(info.pixelHeight) px)" : "\(info.width)×\(info.height) (1x)") + String(format: " @ %.0f Hz", m.refreshRate)
        } else { displayInfoItem.title = "Mac display: unknown" }
        var action = dm.lastAction.map { "Last: \($0)" } ?? dm.describeChoice().map { "This viewer: \($0)" }
        if dm.userOverride { action = "Changed manually — automatic paused until next session" }
        displayActionItem.title = action ?? ""
        displayActionItem.isHidden = action == nil
        displayItem.title = "Display Mode: \(Self.prefTitle(st.preference))"
    }

    private func refreshFiles(_ s: HostStatus.Snapshot) {
        sendFilesItem.isEnabled = s.viewer?.files == true
        sendFilesItem.toolTip = s.viewer == nil ? "No viewer connected" : (s.viewer?.files == true ? nil : "This viewer doesn't support file transfer")
        let progress = HostStatus.shared.fileProgress?() ?? []
        fileProgressItem.title = progress.map { p in
            let pct = p.total == 0 ? 100 : Int(min(100, p.done * 100 / p.total))
            return "\(p.incoming ? "Receiving" : "Sending") \(FileOffers.fileText(p.files)) — \(pct)% of \(FileOffers.byteText(p.total))"
        }.joined(separator: " · ")
        fileProgressItem.isHidden = progress.isEmpty
        cancelFilesItem.isHidden = progress.isEmpty

        recentMenu.removeAllItems()
        let tf = DateFormatter()
        tf.timeStyle = .short; tf.dateStyle = .none
        for t in s.transfers {
            let when = tf.string(from: t.date)
            let title: String
            if !t.ok { title = "⚠︎ \(t.text ?? "Transfer failed") — \(when)" }
            else if t.incoming { title = "Received \(FileOffers.fileText(t.files)) · \(FileOffers.byteText(t.bytes)) — \(when)" }
            else { title = "Sent \(FileOffers.fileText(t.files)) · \(FileOffers.byteText(t.bytes)) — \(when)" }
            let i = NSMenuItem(title: title, action: t.incoming && t.ok ? #selector(revealTransfer(_:)) : nil, keyEquivalent: "")
            i.target = self
            i.representedObject = t.items
            i.isEnabled = t.incoming && t.ok
            if t.incoming && t.ok { i.toolTip = "Show in Finder" }
            recentMenu.addItem(i)
        }
        if !s.transfers.isEmpty { recentMenu.addItem(.separator()) }
        let open = NSMenuItem(title: "Open Received Files Folder", action: #selector(openDownloads), keyEquivalent: "")
        open.target = self
        recentMenu.addItem(open)
        recentItem.title = s.transfers.isEmpty ? "File Transfers" : "Recent Transfers"
    }

    static func phaseTitle(_ p: HostStatus.Phase) -> String {
        switch p {
        case .idle: return "Waiting for Viewer"
        case .dialing: return "Dialing Viewer"
        case .connected: return "Connected"
        case .paused: return "Paused"
        case .error: return "Problem"
        }
    }

    static func prefTitle(_ p: DisplayModePreference) -> String {
        switch p {
        case .automatic: return "Automatic"
        case .crisp: return "Crisp"
        case .smooth: return "Smooth"
        case .retina: return "Retina"
        case .manual: return "Don't Change"
        }
    }

    /// SF Symbol per state, template-rendered so it follows the menu bar appearance.
    static func icon(for p: HostStatus.Phase) -> NSImage? {
        let names: [String]
        switch p {
        case .idle: names = ["display"]
        case .dialing: names = ["antenna.radiowaves.left.and.right", "display"]
        case .connected: names = ["play.display", "display.2", "display"]
        case .paused: names = ["pause.circle", "display"]
        case .error: names = ["exclamationmark.triangle", "display"]
        }
        for n in names {
            if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Glide Host: \(phaseTitle(p))") {
                let sized = img.withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) ?? img
                sized.isTemplate = true
                return sized
            }
        }
        return nil
    }

    // MARK: NSMenuDelegate — refresh live while open

    func menuWillOpen(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = true
        refresh()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menuOpen = false
        refreshTimer?.invalidate(); refreshTimer = nil
    }

    // MARK: Actions

    @objc private func disconnect() { log("menu: disconnect viewer"); actions.disconnect() }

    /// NSOpenPanel (files and folders, multi-select) -> the connected viewer's Downloads\\Glide.
    @objc private func sendFiles() {
        let p = NSOpenPanel()
        p.title = "Send Files to Viewer"
        p.prompt = "Send"
        p.message = "Choose files or folders to send to \(HostStatus.shared.snapshot.viewer?.name ?? "the viewer")."
        p.canChooseFiles = true
        p.canChooseDirectories = true
        p.allowsMultipleSelection = true
        p.resolvesAliases = false
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        log("menu: send \(p.urls.count) item(s) to the viewer")
        if !actions.sendFiles(p.urls) { log("menu: the viewer can't take files (not connected or no file transfer support)") }
    }

    @objc private func cancelFiles() { log("menu: cancel file transfer"); actions.cancelFiles() }

    @objc private func revealTransfer(_ sender: NSMenuItem) {
        HostNotifier.reveal(sender.representedObject as? [URL] ?? [])
    }

    @objc private func openDownloads() {
        guard let d = downloadDir else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([d])
    }

    @objc private func togglePause() {
        let paused = !HostStatus.shared.snapshot.paused
        log("menu: \(paused ? "pause" : "resume")")
        actions.setPaused(paused)
    }

    @objc private func choosePreference(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let p = DisplayModePreference(rawValue: raw) else { return }
        DisplayModeController.shared.setPreference(p)
        refresh()
    }

    @objc private func chooseHighDPI(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let c = HighDPIViewerChoice(rawValue: raw) else { return }
        DisplayModeController.shared.setHighDPIChoice(c)
        refresh()
    }

    @objc private func toggleRestore() {
        DisplayModeController.shared.setRestoreOnDisconnect(!DisplayModeController.shared.settings.restoreEnabled)
        refresh()
    }

    @objc private func restoreNow() { DisplayModeController.shared.restoreNow(reason: "menu"); refresh() }

    @objc private func openLog() {
        NSWorkspace.shared.open(Self.logURL())
    }

    /// The file stderr is redirected to (the LaunchAgent's log), else ~/Library/Logs/glide-host.log.
    static func logURL() -> URL {
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        if fcntl(STDERR_FILENO, F_GETPATH, &buf) != -1 {
            let path = String(cString: buf)
            var st = stat()
            if stat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG { return URL(fileURLWithPath: path) }
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/glide-host.log")
    }

    @objc private func copyPassword() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(password, forType: .string)
        // Ask clipboard managers / sync not to keep it (nspasteboard.org convention).
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        log("menu: viewer password copied to the clipboard")
    }

    @objc private func restart() {
        log("menu: restart (launchd relaunches the host)")
        exit(0)
    }

    @objc private func quit() {
        DisplayModeController.shared.restoreNow(reason: "quit")
        log("menu: quit")
        exit(0)
    }

    @objc private func quitUntilLogin() {
        guard let label = launchdLabel else { quit(); return }
        DisplayModeController.shared.restoreNow(reason: "quit until next login")
        log("menu: quit until next login (launchctl bootout gui/\(getuid())/\(label))")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
        do { try p.run() } catch { log("menu: launchctl failed: \(error); exiting (KeepAlive may relaunch)"); exit(0) }
        // bootout SIGTERMs us; fall back to exiting if it hasn't within a few seconds.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { exit(0) }
    }

    // MARK: --selftest-ui

    /// Prints the menu tree (titles, hidden/disabled/checked) for inspection.
    func dump() -> String {
        var out: [String] = []
        func walk(_ m: NSMenu, _ depth: Int) {
            for i in m.items {
                let pad = String(repeating: "  ", count: depth)
                if i.isSeparatorItem { out.append(pad + "  ----"); continue }
                if i.isHidden { continue }
                let mark = i.state == .on ? "✓" : " "
                out.append("\(pad)\(mark) \(i.title)\(i.isEnabled ? "" : "  [info]")\(i.submenu != nil ? "  ▸" : "")")
                if let sub = i.submenu { walk(sub, depth + 1) }
            }
        }
        walk(menu, 0)
        return out.joined(separator: "\n")
    }
}
