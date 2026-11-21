import AppKit
import GlideCore
import SwiftUI

/// The setup window: everything a first install needs, without Terminal. A checklist rather than
/// a wizard, so it also works as a status page later (menu bar → Set Up Glide Host…).
///
/// 1. Install: copy the app into Applications (or replace the running copy).
/// 2. Start at login: the bundled LaunchAgent via SMAppService (KeepAlive, so it restarts on a crash).
/// 3. Screen Recording + Accessibility, with live status and the right Settings page.
/// 4. Connection: this Mac's addresses for the PC, and the PC's address so the Mac can dial it
///    too. The host always listens as well, so whichever direction the network allows connects.
/// 5. Pair a viewer (the pairing alert shows the code).
final class SetupModel: ObservableObject {
    struct Actions {
        var setDialTarget: (String?) -> Void = { _ in }
        var openPairing: () -> Void = {}
        var cancelPairing: () -> Void = {}
        /// The Settings window (Settings.swift).
        var showSettings: () -> Void = {}
    }

    enum Check: Equatable { case ok, missing, unknown }

    /// Installer role: another Glide Host is running (this is a new download, or another copy).
    let installer: (version: String?, path: String?)?
    let actions: Actions

    @Published var inApplications = Instance.isInApplications
    @Published var loginItem = Instance.loginItem
    @Published var screen: Check = .unknown
    /// Screen Recording is granted, but this process started before the grant.
    @Published var screenNeedsRestart = false
    @Published var accessibility: Check = .unknown
    @Published var addresses: [(address: String, interface: String)] = Instance.localAddresses()
    @Published var pcAddress: String = HostConfig.load().connect ?? ""
    @Published var savedPC: String? = HostConfig.load().connect
    @Published var status = HostStatus.shared.snapshot
    @Published var paired: [PairedViewer] = TrustStore.shared.list
    @Published var busy: String?
    @Published var error: String?
    /// host.json exists but can't be read: nothing is saved until it's fixed (HostConfig.update).
    @Published var configProblem: String? = HostConfig.problem

    private var timer: Timer?
    private var checking = false
    /// Granted at launch (CGPreflightScreenCaptureAccess is only right for a fresh process).
    private let screenAtLaunch = CGPreflightScreenCaptureAccess()

    init(installer: (version: String?, path: String?)?, actions: Actions) {
        self.installer = installer
        self.actions = actions
    }

    var allDone: Bool {
        installer == nil && inApplications && loginItem != .off && loginItem != .needsApproval
            && screen == .ok && !screenNeedsRestart && accessibility == .ok && !paired.isEmpty
    }

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stop() { timer?.invalidate(); timer = nil }

    func refresh() {
        inApplications = Instance.isInApplications
        loginItem = Instance.loginItem
        accessibility = AXIsProcessTrusted() ? .ok : .missing
        status = HostStatus.shared.snapshot
        paired = TrustStore.shared.list
        let problem = HostConfig.problem
        if problem != configProblem { configProblem = problem }
        let a = Instance.localAddresses()
        if a.map(\.address) != addresses.map(\.address) { addresses = a }
        guard !checking else { return }
        if screenAtLaunch { screen = .ok; screenNeedsRestart = false; return }
        // A fresh process sees a new Screen Recording grant; this one only after a relaunch. The
        // child is this app's own binary, so macOS answers for Glide Host.
        checking = true
        DispatchQueue.global().async {
            let r = Instance.run(Bundle.main.executablePath ?? CommandLine.arguments[0], ["--permission-status"])
            let granted = r.output.contains("screen-recording=granted")
            DispatchQueue.main.async {
                self.checking = false
                self.screen = granted ? .ok : .missing
                self.screenNeedsRestart = granted
            }
        }
    }

    // MARK: Actions

    func install() {
        let dest = Instance.installDestination(existing: installer?.path)
        let stop = installer != nil, running = installer?.path
        busy = stop && Instance.installsInPlace(existing: running) ? "Restarting Glide Host…" : "Installing…"
        DispatchQueue.global().async {
            let err = Instance.installAndRelaunch(to: dest, stopRunning: stop, runningPath: running)  // returns only on failure
            DispatchQueue.main.async { self.busy = nil; self.error = err }
        }
    }

    func enableLogin() {
        do {
            try Instance.enableLoginItem()
            if Instance.loginItem == .needsApproval { SMAppServiceHelper.openLoginItems() }
            else if Instance.launchdLabel == nil {
                // launchd starts the login item now; it takes over from this copy and reopens
                // this window.
                busy = "Starting Glide Host in the background…"
            }
        } catch {
            self.error = "Couldn't add the login item: \(error.localizedDescription)"
        }
        refresh()
    }

    func requestScreen() {
        // A grant made for an earlier build (signed ad hoc) can look switched on without applying;
        // clear it so macOS asks again. Nothing is lost: the permission is missing either way.
        Instance.run("/usr/bin/tccutil", ["reset", "ScreenCapture", Instance.bundleID])
        if !CGRequestScreenCaptureAccess() {
            Self.openPrivacy("Privacy_ScreenCapture")
            PermissionDragHelper.shared.show(permission: "Screen Recording") { [weak self] in self?.screen == .ok }
        }
    }

    func requestAccessibility() {
        Instance.run("/usr/bin/tccutil", ["reset", "Accessibility", Instance.bundleID])
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        Self.openPrivacy("Privacy_Accessibility")
        PermissionDragHelper.shared.show(permission: "Accessibility") { AXIsProcessTrusted() }
    }

    func restartForScreen() { Instance.relaunch(reason: "Screen Recording granted (setup window)") }

    func savePC() {
        let t = pcAddress.trimmingCharacters(in: .whitespaces)
        do {
            let c = try HostConfig.update { $0.connect = t.isEmpty ? nil : t }
            savedPC = c.connect
            // With "connect automatically at startup" off (Settings), saving only stores the address.
            if c.connect == nil || c.dialsAtLaunch { actions.setDialTarget(c.connect) }
        } catch {
            self.error = HostConfig.notSavedText(error, what: "the PC's address")
        }
        refresh()
    }

    func pair() { actions.openPairing() }
    func cancelPairing() { actions.cancelPairing() }

    /// Remembers that setup was finished for this version. False (and `error` says why) when
    /// host.json couldn't be updated: the window then stays open.
    @discardableResult
    func finish() -> Bool {
        do {
            try HostConfig.update { $0.setupVersion = GlideVersion.display }
            return true
        } catch {
            self.error = HostConfig.notSavedText(error, what: "that setup is finished")
            return false
        }
    }

    static func openPrivacy(_ pane: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(u) }
    }

    /// Show the window at launch? Until setup was finished once, and whenever a permission is
    /// missing (each ad-hoc-signed build needs new grants; without them the host is useless).
    static func shouldShowAtLaunch() -> Bool {
        HostConfig.load().setupVersion == nil || !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted()
    }
}

enum SMAppServiceHelper {
    static func openLoginItems() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}

// MARK: - View

struct SetupView: View {
    @ObservedObject var m: SetupModel
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let p = m.configProblem {
                        Text("Settings can't be saved: \(p). Glide Host won't overwrite it, so your paired viewers are kept. Fix the file, or move it away to start over.")
                            .foregroundStyle(.red).font(.callout).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let i = m.installer { installerRow(i) } else {
                        installRow
                        loginRow
                        screenRow
                        accessibilityRow
                        connectionRow
                        pairRow
                    }
                    if let e = m.error {
                        Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 600, height: m.installer == nil ? 720 : 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up Glide Host").font(.title2.weight(.semibold))
                Text("Lets your Windows PC see and control this Mac. Version \(GlideVersion.display).")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            if let b = m.busy { ProgressView().controlSize(.small); Text(b).foregroundStyle(.secondary) }
            Spacer()
            if m.installer == nil {
                Button("Settings…") { m.actions.showSettings() }
                Button(m.allDone ? "Done" : "Finish Later") { if m.finish() { close() } }
                    .keyboardShortcut(m.allDone ? .defaultAction : .cancelAction)
            } else {
                Button("Cancel") { NSApp.terminate(nil) }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }

    // MARK: Rows

    private func installerRow(_ i: (version: String?, path: String?)) -> some View {
        let running = "Glide Host \(i.version ?? "(an older version)") is running\(i.path.map { " from \($0)" } ?? ""). "
        // This copy already replaced the running host's app on disk: restart into it, no copy.
        let inPlace = Instance.installsInPlace(existing: i.path)
        return Row(state: .todo, title: inPlace ? "Restart with this version" : "Replace the running Glide Host",
            detail: running + (inPlace
                ? "This copy (\(GlideVersion.display)) is already in its place. Restart Glide Host to use it? Your settings and paired viewers stay."
                : "Install this version (\(GlideVersion.display)) in its place? Your settings and paired viewers stay.")) {
            Button(inPlace ? "Restart Glide Host" : "Install \(GlideVersion.display)") { m.install() }
                .keyboardShortcut(.defaultAction).disabled(m.busy != nil)
        }
    }

    private var installRow: some View {
        Row(state: m.inApplications ? .done : .todo, title: "Install in Applications",
            detail: m.inApplications ? "Glide Host is in \((Instance.bundlePath as NSString).deletingLastPathComponent)."
                : "Glide Host is running from \(Instance.isTranslocated ? "the download" : (Instance.bundlePath as NSString).deletingLastPathComponent). Move it to Applications so it can start at login.") {
            if !m.inApplications { Button("Move to Applications") { m.install() }.disabled(m.busy != nil) }
        }
    }

    private var loginRow: some View {
        let state: Row<AnyView>.State
        let detail: String
        switch m.loginItem {
        case .on: state = .done; detail = "Glide Host starts when you log in, and restarts if it quits unexpectedly."
        case .onViaScript: state = .done; detail = "Started at login by the LaunchAgent the install script set up."
        case .needsApproval: state = .todo; detail = "Allow Glide Host in System Settings → General → Login Items."
        case .off: state = m.inApplications ? .todo : .waiting; detail = "So the Mac is reachable after a restart, without logging in to open it by hand."
        }
        return Row(state: state, title: "Start at login", detail: detail) {
            AnyView(Group {
                switch m.loginItem {
                case .off: Button("Start at Login") { m.enableLogin() }.disabled(!m.inApplications || m.busy != nil)
                case .needsApproval: Button("Open Login Items") { SMAppServiceHelper.openLoginItems() }
                default: EmptyView()
                }
            })
        }
    }

    private var screenRow: some View {
        Row(state: m.screen == .ok && !m.screenNeedsRestart ? .done : (m.screen == .unknown ? .waiting : .todo),
            title: "Screen Recording",
            detail: m.screenNeedsRestart ? "Allowed. Glide Host restarts to use it."
                : m.screen == .ok ? "Allowed: the PC can see this Mac's screen."
                : "Needed to show this Mac's screen on the PC. Switch on Glide Host in the list that opens, or drag it in if it isn't listed.") {
            if m.screenNeedsRestart { Button("Restart Glide Host") { m.restartForScreen() }.keyboardShortcut(.defaultAction) }
            else if m.screen == .missing { Button("Allow…") { m.requestScreen() } }
        }
    }

    private var accessibilityRow: some View {
        Row(state: m.accessibility == .ok ? .done : .todo, title: "Accessibility",
            detail: m.accessibility == .ok ? "Allowed: the PC's mouse and keyboard control this Mac."
                : "Needed for the PC's mouse and keyboard. Switch on Glide Host in the list that opens, or drag it in if it isn't listed.") {
            if m.accessibility != .ok { Button("Allow…") { m.requestAccessibility() } }
        }
    }

    private var connectionRow: some View {
        let s = m.status
        let connected = s.viewer != nil
        var lines: [String] = []
        if let v = s.viewer { lines.append("Connected: \(v.name) (\(v.address)).") }
        else {
            if let p = s.listenPort { lines.append("Waiting for the PC to connect on port \(p).") }
            if let e = s.serverError { lines.append(e) }
            if let t = s.dialTarget { lines.append("Also connecting to the PC at \(t)" + (s.dialDetail.map { ": \($0)." } ?? ".")) }
        }
        return Row(state: connected ? .done : .waiting, title: "Connect the PC", detail: nil) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("On the PC, enter this Mac's address in Glide:").foregroundStyle(.secondary)
                    if m.addresses.isEmpty { Text("No network connection").foregroundStyle(.red) }
                    ForEach(m.addresses, id: \.address) { a in
                        HStack(spacing: 8) {
                            Text(a.address).font(.system(.title3, design: .monospaced).weight(.semibold)).textSelection(.enabled)
                            Text(a.interface).foregroundStyle(.tertiary).font(.caption)
                            Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.address, forType: .string) } label: {
                                Image(systemName: "doc.on.doc")
                            }.buttonStyle(.borderless).help("Copy")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("If the network only lets this Mac reach the PC, enter the PC's address too:").foregroundStyle(.secondary)
                    HStack {
                        TextField("PC address, e.g. 192.168.1.20", text: $m.pcAddress)
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .onSubmit { m.savePC() }
                        Button(m.pcAddress.trimmingCharacters(in: .whitespaces).isEmpty && m.savedPC != nil ? "Remove" : "Save") { m.savePC() }
                            .disabled(m.pcAddress.trimmingCharacters(in: .whitespaces) == (m.savedPC ?? ""))
                    }
                }
                Text(lines.joined(separator: " ")).font(.callout).foregroundStyle(connected ? .green : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pairRow: some View {
        let s = m.status
        let open = s.pairingUntil.map { $0 > Date() } ?? false
        let detail: String
        if open { detail = "Pairing is open for 2 minutes. Open Glide on the PC: both screens show the same code; confirm on both." }
        else if m.paired.isEmpty { detail = "The PC proves who it is once, with a code shown on both screens. After that it connects on its own." }
        else { detail = "Paired: " + m.paired.map(\.name).joined(separator: ", ") + "." }
        return Row(state: m.paired.isEmpty ? (open ? .waiting : .todo) : .done, title: "Pair the PC", detail: detail) {
            if open { Button("Stop Pairing") { m.cancelPairing() } }
            else { Button(m.paired.isEmpty ? "Pair a Viewer…" : "Pair Another Viewer…") { m.pair() } }
        }
    }
}

/// One checklist row: status icon, title, detail, controls.
struct Row<Content: View>: View {
    enum State { case done, todo, waiting }
    let state: State
    let title: String
    let detail: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : state == .todo ? "circle" : "clock")
                .font(.title2)
                .foregroundStyle(state == .done ? Color.green : state == .todo ? Color.accentColor : Color.secondary)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                if let d = detail { Text(d).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                content()
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Window

final class SetupWindowController: NSObject, NSWindowDelegate {
    static var shared: SetupWindowController?
    let model: SetupModel
    let window: NSWindow

    init(model: SetupModel) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 720), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Glide Host Setup"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: SetupView(m: model) { [weak self] in self?.window.close() })
        window.center()
    }

    func show() {
        model.start()
        // A menu-bar app: become a regular app while the window is open, so it gets a Dock icon,
        // Cmd-Tab and keyboard focus.
        AppWindows.opened()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        AppWindows.closed(window)
        if model.installer != nil { NSApp.terminate(nil) }
    }

    /// Render the window's content to a PNG without showing it (--setup-preview, docs, CI).
    static func renderPreview(_ model: SetupModel, to path: String, dark: Bool = false) -> Bool {
        let view = NSHostingView(rootView: SetupView(m: model) {})
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.contentView = view
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return FileManager.default.createFile(atPath: path, contents: png)
    }
}
