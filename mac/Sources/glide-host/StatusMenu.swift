import AppKit
import GlideCore

/// The host's only UI: a menu-bar status item (the app is LSUIElement).
final class StatusMenu: NSObject, NSMenuDelegate {
    /// What the menu can ask the server to do.
    struct Actions {
        var disconnect: () -> Void = {}
        var setPaused: (Bool) -> Void = { _ in }
        var openPairing: () -> Void = {}
        var cancelPairing: () -> Void = {}
        var removeViewer: (PairedViewer) -> Void = { _ in }
        /// Send files to the connected viewer; false if it can't take files.
        var sendFiles: ([URL]) -> Bool = { _ in false }
        var cancelFiles: () -> Void = {}
        /// Stream display `id` (0 = default) in the current session (PROTOCOL.md §3.5).
        var selectDisplay: (UInt32) -> Void = { _ in }
        /// The setup window (Setup.swift).
        var showSetup: () -> Void = {}
        /// The Settings window (Settings.swift).
        var showSettings: () -> Void = {}
        /// Dial the saved PC address now (host.json `connect`), or stop dialing.
        var connectNow: () -> Void = {}
        var stopDialing: () -> Void = {}
    }

    let menu = NSMenu()
    private var statusItem: NSStatusItem?
    private let actions: Actions
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
    private let latencyItem = NSMenuItem()
    private let detailItem = NSMenuItem()
    private let warningItem = NSMenuItem()
    /// Last security event (rejected viewer, paired, v1 viewer).
    private let noteItem = NSMenuItem()
    /// "Managed by Example Corp" (Glide Cloud, ENTERPRISE.md).
    private let managedItem = NSMenuItem()
    // Actions
    private let disconnectItem = NSMenuItem(title: "Disconnect Viewer", action: #selector(disconnect), keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: #selector(togglePause), keyEquivalent: "")
    /// "Connect to PC (addr)" while a saved address isn't being dialed; "Stop Connecting to PC".
    private let dialItem = NSMenuItem(title: "Connect to PC", action: #selector(toggleDial), keyEquivalent: "")
    /// host.json `connect`, re-read on every refresh (the setup and Settings windows change it).
    var savedConnect: () -> String? = {
        ((try? ConfigFile.read(HostConfig.self, from: HostConfig.url)) ?? nil)?.connect
    }
    private let pairItem = NSMenuItem(title: "Pair New Viewer…", action: #selector(togglePairing), keyEquivalent: "")
    private let viewersItem = NSMenuItem(title: "Paired Viewers", action: nil, keyEquivalent: "")
    private let viewersMenu = NSMenu()
    private let displayItem = NSMenuItem(title: "Display Mode", action: nil, keyEquivalent: "")
    /// "Streamed Display: …" with one item per Mac display (§3.5).
    private let streamedItem = NSMenuItem(title: "Streamed Display", action: nil, keyEquivalent: "")
    private let streamedMenu = NSMenu()
    private var shownDisplays: String?
    private let displayMenu = NSMenu()
    private var prefItems: [DisplayModePreference: NSMenuItem] = [:]
    private var highDPIItems: [HighDPIViewerChoice: NSMenuItem] = [:]
    private let restoreToggleItem = NSMenuItem(title: "Restore Mode on Disconnect", action: #selector(toggleRestore), keyEquivalent: "")
    private let restoreNowItem = NSMenuItem(title: "Restore Now", action: #selector(restoreNow), keyEquivalent: "")
    private let displayInfoItem = NSMenuItem()
    private let displayActionItem = NSMenuItem()
    // Virtual display (VirtualDisplay.swift)
    private let virtualItem = NSMenuItem(title: "Virtual Display", action: nil, keyEquivalent: "")
    private let virtualMenu = NSMenu()
    private let virtualEnableItem = NSMenuItem(title: "Use a Virtual Display Sized to the Viewer", action: #selector(toggleVirtual), keyEquivalent: "")
    private let virtualMonitorHeader = NSMenuItem(title: "With a Monitor Attached:", action: nil, keyEquivalent: "")
    private var virtualMonitorItems: [VirtualDisplayMonitorMode: NSMenuItem] = [:]
    private let virtualAlwaysItem = NSMenuItem(title: "Keep It When No Viewer Is Connected", action: #selector(toggleVirtualAlways), keyEquivalent: "")
    private let virtualMainItem = NSMenuItem(title: "Make It the Main Display", action: #selector(toggleVirtualMain), keyEquivalent: "")
    private let virtualRemoveItem = NSMenuItem(title: "Remove Virtual Display Now", action: #selector(removeVirtual), keyEquivalent: "")
    private let virtualStatusItem = NSMenuItem()
    private let virtualKeepItem = NSMenuItem()
    // File transfer (§6)
    private let sendFilesItem = NSMenuItem(title: "Send Files to Viewer…", action: #selector(sendFiles), keyEquivalent: "")
    private let fileProgressItem = NSMenuItem()
    private let cancelFilesItem = NSMenuItem(title: "Cancel File Transfer", action: #selector(cancelFiles), keyEquivalent: "")
    private let recentItem = NSMenuItem(title: "Recent Transfers", action: nil, keyEquivalent: "")
    private let recentMenu = NSMenu()
    /// Where received files go (host.json files.downloadDir).
    var downloadDir: URL?

    init(actions: Actions, showStatusItem: Bool = true) {
        self.actions = actions
        launchdLabel = Instance.launchdLabel
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
        for i in [headerItem, managedItem, viewerItem, streamItem, resolutionItem, statsItem, latencyItem, detailItem, warningItem, noteItem] {
            i.isEnabled = false
            menu.addItem(i)
        }
        menu.addItem(.separator())
        for i in [disconnectItem, pauseItem, dialItem] { i.target = self; menu.addItem(i) }
        menu.addItem(.separator())
        pairItem.target = self
        menu.addItem(pairItem)
        viewersMenu.autoenablesItems = false
        viewersItem.submenu = viewersMenu
        menu.addItem(viewersItem)
        for i in [sendFilesItem, cancelFilesItem] { i.target = self }
        fileProgressItem.isEnabled = false
        recentMenu.autoenablesItems = false
        recentItem.submenu = recentMenu
        for i in [sendFilesItem, fileProgressItem, cancelFilesItem, recentItem] { menu.addItem(i) }
        menu.addItem(.separator())

        streamedMenu.autoenablesItems = false
        streamedItem.submenu = streamedMenu
        menu.addItem(streamedItem)

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

        virtualMenu.autoenablesItems = false
        virtualEnableItem.target = self
        virtualMenu.addItem(virtualEnableItem)
        virtualMenu.addItem(.separator())
        virtualMonitorHeader.isEnabled = false
        virtualMenu.addItem(virtualMonitorHeader)
        for m in VirtualDisplayMonitorMode.allCases {
            let i = NSMenuItem(title: Self.monitorModeTitle(m), action: #selector(chooseMonitorMode(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = m.rawValue
            i.indentationLevel = 1
            virtualMonitorItems[m] = i
            virtualMenu.addItem(i)
        }
        virtualMainItem.indentationLevel = 2
        virtualMainItem.target = self
        virtualMenu.addItem(virtualMainItem)
        virtualMenu.addItem(.separator())
        virtualAlwaysItem.target = self
        virtualMenu.addItem(virtualAlwaysItem)
        virtualMenu.addItem(.separator())
        for i in [virtualStatusItem, virtualKeepItem] { i.isEnabled = false; virtualMenu.addItem(i) }
        virtualRemoveItem.target = self
        virtualMenu.addItem(virtualRemoveItem)
        virtualItem.submenu = virtualMenu
        menu.addItem(virtualItem)

        menu.addItem(.separator())
        add("Settings…", #selector(showSettings)).keyEquivalent = ","
        add("Set Up Glide Host…", #selector(showSetup))
        add("Open Log", #selector(openLog))
        menu.addItem(withTitle: "Glide Host \(GlideVersion.display)", action: nil, keyEquivalent: "").isEnabled = false
        menu.addItem(.separator())
        if launchdLabel != nil {
            add("Restart Glide Host", #selector(restart))
            add("Quit Until Next Login", #selector(quitUntilLogin))
        } else {
            add("Quit Glide Host", #selector(quit))
        }
    }

    /// "Latency: capture→callback 4.1 · encode 10.8 · glass ~27 ms" (p50s; glass from the viewer).
    static func latencyTitle(_ v: HostStatus.Viewer) -> String {
        var parts: [String] = []
        if let c = v.captureMs { parts.append(String(format: "capture→callback %.1f", c)) }
        if let e = v.encodeMs { parts.append(String(format: "encode %.1f", e)) }
        if let r = v.latency, r.totalUs != timingUnknown {
            parts.append(String(format: "%@ ~%.0f", r.flags & 1 != 0 ? "glass" : "to present", Double(r.totalUs) / 1000))
        }
        return parts.isEmpty ? "" : "Latency: " + parts.joined(separator: " · ") + " ms"
    }

    @discardableResult
    private func add(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        menu.addItem(i)
        return i
    }

    // MARK: Refresh

    func refresh() {
        let s = HostStatus.shared.snapshot
        let phase = s.phase
        statusItem?.button?.image = Self.icon(for: phase)
        statusItem?.button?.toolTip = "Glide Host — \(Self.phaseTitle(phase))"

        headerItem.title = "Glide Host — \(Self.phaseTitle(phase))"
        if let u = s.viewer?.cloudUser {
            // Managed session: a persistent indicator of who is connected (ENTERPRISE.md §3.2).
            headerItem.title = "\(u.label) is connected"
            statusItem?.button?.toolTip = "Glide Host — \(u.label) is connected"
        } else if let who = s.pendingApproval {
            headerItem.title = "\(who) is asking to connect…"
        }
        if let m = s.managed {
            var t = m.summary
            if m.updateRequired { t += " — update required (minimum \(m.minAppVersion ?? "?"))" }
            else if !m.lanAllowed { t += " — LAN connections off" }
            managedItem.title = t
            managedItem.isHidden = false
        } else { managedItem.isHidden = true }
        if let v = s.viewer {
            viewerItem.title = v.cloudUser != nil ? "Via Glide Cloud: \(v.permissions?.summary ?? "")" : "Viewer: \(v.name) (\(v.address))"
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
            latencyItem.title = Self.latencyTitle(v)
        }
        for i in [viewerItem, streamItem, resolutionItem, statsItem] { i.isHidden = s.viewer == nil }
        latencyItem.isHidden = s.viewer == nil || latencyItem.title.isEmpty

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

        if let n = s.note {
            let t = DateFormatter.localizedString(from: n.at, dateStyle: .none, timeStyle: .short)
            noteItem.title = (n.warning ? "⚠︎ " : "") + n.text + (n.count > 1 ? " (×\(n.count))" : "") + " · \(t)"
            noteItem.isHidden = false
        } else { noteItem.isHidden = true }

        // Pairing
        let pairingAllowed = s.managed?.pairingAllowed ?? true
        if !pairingAllowed {
            pairItem.title = "Pair New Viewer… (turned off by \(s.managed?.orgName ?? "your organization"))"
            pairItem.isEnabled = false
        } else if let who = s.pairingWith {
            pairItem.title = "Pairing with “\(who)” — compare the code…"
            pairItem.isEnabled = false
        } else if let until = s.pairingUntil, until > Date() {
            let left = Int(until.timeIntervalSinceNow.rounded(.up))
            pairItem.title = String(format: "Pairing Open — %d:%02d left (Cancel)", left / 60, left % 60)
            pairItem.isEnabled = true
        } else {
            pairItem.title = "Pair New Viewer…"
            pairItem.isEnabled = true
        }
        viewersItem.title = "Paired Viewers (\(s.pairedViewers.count))"
        rebuildViewers(s.pairedViewers, hostFingerprint: s.hostFingerprint)

        disconnectItem.isEnabled = s.viewer != nil
        disconnectItem.title = s.viewer?.cloudUser != nil ? "End Session" : "Disconnect Viewer"
        refreshFiles(s)
        let lanAllowed = s.managed?.lanAllowed ?? true
        if !lanAllowed {
            dialItem.isHidden = true
        } else if s.dialTarget != nil && s.viewer == nil && !s.paused {
            dialItem.title = "Stop Connecting to PC"
            dialItem.isHidden = false
        } else if s.dialTarget == nil, s.viewer == nil, !s.paused, let pc = savedConnect() {
            dialItem.title = "Connect to PC (\(pc))"
            dialItem.isHidden = false
        } else { dialItem.isHidden = true }
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
        if let info = dm.currentMode() {
            let which = ActiveDisplay.isVirtual(dm.displayID) ? "Virtual display" : "Mac display"
            displayInfoItem.title = "\(which): " + (info.hiDPI ? "looks like \(info.width)×\(info.height) (HiDPI, \(info.pixelWidth)×\(info.pixelHeight) px)" : "\(info.width)×\(info.height) (1x)") + String(format: " @ %.0f Hz", info.refreshRate)
        } else { displayInfoItem.title = "Mac display: unknown" }
        var action = dm.lastAction.map { "Last: \($0)" } ?? dm.describeChoice().map { "This viewer: \($0)" }
        if dm.userOverride { action = "Changed manually — automatic paused until next session" }
        displayActionItem.title = action ?? ""
        displayActionItem.isHidden = action == nil
        displayItem.title = "Display Mode: \(Self.prefTitle(st.preference))"

        // Virtual display submenu
        let vd = VirtualDisplayManager.shared
        vd.loadConfig()
        let vc = vd.config
        virtualEnableItem.state = vc.isEnabled ? .on : .off
        virtualEnableItem.toolTip = "Glide creates a virtual monitor with the viewer's exact pixels and refresh rate and streams it 1:1 instead of this Mac's screen (docs/VIRTUAL_DISPLAY.md). On by default."
        for (m, i) in virtualMonitorItems { i.state = vc.monitorMode == m ? .on : .off; i.isEnabled = vc.isEnabled }
        virtualMonitorHeader.isHidden = false
        virtualMainItem.state = vc.wantsMain ? .on : .off
        virtualMainItem.isEnabled = vc.isEnabled && vc.monitorMode == .extend
        virtualMainItem.isHidden = vc.monitorMode != .extend
        virtualAlwaysItem.state = vc.alwaysOn ? .on : .off
        virtualAlwaysItem.isEnabled = vc.isEnabled
        virtualStatusItem.title = "Status: " + vd.statusLine
        virtualKeepItem.title = vc.alwaysOn ? "Kept while Glide runs (hidden behind the monitor when idle)" : "Removed \(Int(vc.keepAlive)) s after the viewer disconnects (kept if it is the only display)"
        virtualKeepItem.isHidden = !vc.isEnabled
        virtualRemoveItem.isHidden = !(vd.exists && !vd.sessionHoldsIt)
        virtualItem.title = "Virtual Display: " + (vd.active ? (vd.exists ? "On" : "Automatic") : "Off")

        refreshDisplays(sessionActive: s.viewer != nil)
    }

    /// The Mac's displays with a check on the streamed one; choosing one switches the current
    /// session to it (like the viewer's display picker). Rebuilt only when something changed.
    private func refreshDisplays(sessionActive: Bool) {
        let list = ActiveDisplay.displays()
        let streamed = ActiveDisplay.current()
        let selected = ActiveDisplay.selection
        let name = list.first { $0.id == streamed }?.name ?? "Display \(streamed)"
        streamedItem.title = "Streamed Display: \(name)"
        streamedItem.isHidden = list.count <= 1 && selected == nil
        let sig = "\(list) \(streamed) \(selected.map { "\($0)" } ?? "-") \(sessionActive)"
        guard sig != shownDisplays else { return }
        shownDisplays = sig
        streamedMenu.removeAllItems()
        let defName = ActiveDisplay.virtualDisplay.map { _ in VirtualDisplayManager.displayName } ?? (ActiveDisplay.pinned != nil ? "Pinned (--display)" : "Main Display")
        let def = NSMenuItem(title: "Automatic — \(defName)", action: #selector(chooseDisplay(_:)), keyEquivalent: "")
        def.target = self; def.tag = 0; def.state = selected == nil ? .on : .off; def.isEnabled = sessionActive
        streamedMenu.addItem(def)
        streamedMenu.addItem(.separator())
        for d in list {
            var title = d.summary
            if d.isMain { title += " · main" }
            let i = NSMenuItem(title: title, action: #selector(chooseDisplay(_:)), keyEquivalent: "")
            i.target = self; i.tag = Int(d.id); i.isEnabled = sessionActive
            i.state = d.id == streamed ? (selected == nil ? .mixed : .on) : .off
            streamedMenu.addItem(i)
        }
        streamedMenu.addItem(.separator())
        let note = NSMenuItem(title: sessionActive ? "The viewer can switch too (Glide menu, Ctrl+Alt+Shift+←/→)" : "Choose while a viewer is connected", action: nil, keyEquivalent: "")
        note.isEnabled = false
        streamedMenu.addItem(note)
    }

    @objc private func chooseDisplay(_ sender: NSMenuItem) {
        actions.selectDisplay(UInt32(truncatingIfNeeded: sender.tag))
    }

    private var shownViewers: [PairedViewer]?
    private var shownFingerprint: String?

    private func rebuildViewers(_ list: [PairedViewer], hostFingerprint: String?) {
        guard list != shownViewers || hostFingerprint != shownFingerprint else { return }
        shownViewers = list
        shownFingerprint = hostFingerprint
        viewersMenu.removeAllItems()
        if list.isEmpty {
            let i = NSMenuItem(title: "None — use Pair New Viewer…", action: nil, keyEquivalent: "")
            i.isEnabled = false
            viewersMenu.addItem(i)
        }
        for v in list {
            let day = v.paired.prefix(10)
            let item = NSMenuItem(title: "\(v.name) — paired \(day)", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            sub.autoenablesItems = false
            let info = NSMenuItem(title: "Key \(v.fingerprint)", action: nil, keyEquivalent: "")
            info.isEnabled = false
            sub.addItem(info)
            let rm = NSMenuItem(title: "Remove…", action: #selector(removeViewer(_:)), keyEquivalent: "")
            rm.target = self
            rm.representedObject = v.key
            sub.addItem(rm)
            item.submenu = sub
            viewersMenu.addItem(item)
        }
        viewersMenu.addItem(.separator())
        let me = NSMenuItem(title: "This Mac's key: \(hostFingerprint ?? "?")", action: nil, keyEquivalent: "")
        me.isEnabled = false
        viewersMenu.addItem(me)
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

    @objc private func toggleVirtual() {
        let vd = VirtualDisplayManager.shared
        vd.setEnabled(!vd.config.isEnabled)
        refresh()
    }

    @objc private func chooseMonitorMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let m = VirtualDisplayMonitorMode(rawValue: raw) else { return }
        VirtualDisplayManager.shared.setMonitorMode(m)
        refresh()
    }

    static func monitorModeTitle(_ m: VirtualDisplayMonitorMode) -> String {
        switch m {
        case .mirror: return "Monitor Mirrors It (One Desktop)"
        case .extend: return "Extend: Place It Beside the Monitor"
        case .stream: return "Stream the Monitor Instead"
        }
    }

    @objc private func toggleVirtualAlways() {
        let vd = VirtualDisplayManager.shared
        vd.setAlwaysOn(!vd.config.alwaysOn)
        refresh()
    }

    @objc private func toggleVirtualMain() {
        let vd = VirtualDisplayManager.shared
        vd.setMakeMain(!vd.config.wantsMain)
        refresh()
    }

    @objc private func removeVirtual() { VirtualDisplayManager.shared.removeNow(); refresh() }

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

    @objc private func togglePairing() {
        let s = HostStatus.shared.snapshot
        if let until = s.pairingUntil, until > Date() { actions.cancelPairing() } else { actions.openPairing() }
        refresh()
    }

    @objc private func removeViewer(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String,
              let v = HostStatus.shared.snapshot.pairedViewers.first(where: { $0.key == key }) else { return }
        let a = NSAlert()
        a.messageText = "Remove “\(v.name)”?"
        a.informativeText = "This viewer will no longer be able to connect until it is paired again (Pair New Viewer…). If it is connected now, it is disconnected.\n\nKey \(v.fingerprint), paired \(v.paired)"
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        actions.removeViewer(v)
        refresh()
    }

    @objc private func showSetup() { actions.showSetup() }
    @objc private func showSettings() { actions.showSettings() }

    @objc private func toggleDial() {
        if HostStatus.shared.snapshot.dialTarget != nil { log("menu: stop connecting to the PC"); actions.stopDialing() }
        else { log("menu: connect to the PC"); actions.connectNow() }
        refresh()
    }

    @objc private func restart() {
        log("menu: restart (launchd relaunches the host)")
        restoreDisplaysBeforeExit(reason: "restart")
        exit(0)
    }

    @objc private func quit() {
        restoreDisplaysBeforeExit(reason: "quit")
        log("menu: quit")
        exit(0)
    }

    @objc private func quitUntilLogin() {
        guard let label = launchdLabel else { quit(); return }
        restoreDisplaysBeforeExit(reason: "quit until next login")
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
