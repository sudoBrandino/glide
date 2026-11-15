import AppKit
import CryptoKit
import Foundation
import GlideCore
import Network

struct HostSettings {
    var port: UInt16 = 7420
    /// This Mac's static key (host-key, see HostIdentity).
    var identity: Curve25519.KeyAgreement.PrivateKey
    var fps = 60
    var bitrateKbps = 0
    var maxWidth = 3840
    var maxInFlightBytes = 6 * 1024 * 1024
    /// host.json `clipboard.syncConcealed`: also sync password-manager (concealed) items.
    var clipboardSyncConcealed = false
    /// host.json `files` (PROTOCOL.md §6).
    var files = HostFileConfig()
}

/// host.json `"clipboard": {"syncConcealed": false}` (PROTOCOL.md §5).
struct ClipboardSettings: Codable {
    /// Send pasteboard items marked org.nspasteboard.ConcealedType (passwords). Default false.
    var syncConcealed: Bool?
}

/// host.json (`~/Library/Application Support/Glide`, or $GLIDE_HOST_CONFIG_DIR).
struct HostConfig: Codable {
    /// v1 leftovers: no longer used (security v2 pairs keys), but kept untouched in the file so a
    /// rollback to the v1 host still finds its password.
    var salt: String?
    var password: String?
    /// The PC to dial (`--connect` overrides). The host listens as well unless `listen` is false.
    var connect: String?
    /// false: don't listen while a PC address is set (nothing on this Mac accepts connections;
    /// THREAT_MODEL.md "Dial-out mode"). Default true.
    var listen: Bool? = nil
    /// Display-mode policy (DisplayModeController.swift).
    var display: DisplaySettings? = nil
    /// Clipboard sync options (ClipboardSync.swift).
    var clipboard: ClipboardSettings? = nil
    /// Viewers allowed to connect (security v2 pairing).
    var pairedViewers: [PairedViewer]? = nil
    /// File transfer options (HostFiles.swift).
    var files: FileSettings? = nil
    /// Optional virtual display sized to the viewer (VirtualDisplay.swift, docs/VIRTUAL_DISPLAY.md).
    var virtualDisplay: VirtualDisplayConfig? = nil
    /// The version whose setup window was last finished (Setup.swift); nil = never.
    var setupVersion: String? = nil

    static var dir: URL {
        let base: URL
        if let d = ProcessInfo.processInfo.environment["GLIDE_HOST_CONFIG_DIR"], !d.isEmpty {
            base = URL(fileURLWithPath: d, isDirectory: true)
        } else {
            base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glide", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return base
    }

    static var url: URL { dir.appendingPathComponent("host.json") }

    /// Never overwrites an existing file it can't decode (that would drop the paired viewers);
    /// uses defaults in memory instead.
    static func load() -> HostConfig {
        guard let d = try? Data(contentsOf: url) else {
            let c = HostConfig()
            c.save()
            return c
        }
        do { return try JSONDecoder().decode(HostConfig.self, from: d) } catch {
            log("config: \(url.path) is not valid (\(error)); using defaults without saving — fix the file")
            return HostConfig()
        }
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let d = try! enc.encode(self)
        let tmp = HostConfig.url.appendingPathExtension("tmp")
        FileManager.default.createFile(atPath: tmp.path, contents: d, attributes: [.posixPermissions: 0o600])
        rename(tmp.path, HostConfig.url.path)
    }
}

func usage() -> Never {
    print("""
    usage: glide-host [--port N] [--fps N] [--bitrate-kbps N] [--max-width PX] [--display ID]
                      [--connect HOST[:PORT]] [--no-listen]
           glide-host --pair                (open the 2-minute pairing window of the running host;
                                             in a terminal, wait for the viewer and type its code)
           glide-host --pair-code NNNNNN    (confirm the viewer that is waiting to pair, if the code
                                             matches what the PC shows; else decline it)
           glide-host --paired              (list paired viewers)
           glide-host --unpair NAME|KEY     (remove a paired viewer: name, key or fingerprint prefix)
           glide-host --identity            (print this Mac's key fingerprint)
           glide-host --version             (print the version and protocol version)
           glide-host --request-permissions (prompt for Screen Recording + Accessibility, wait, exit)
           glide-host --permission-status   (print whether both are granted, without prompting; run it
                                             with `open -W -a "Glide Host" --stdout F --args …` so
                                             the answer is about Glide Host, not the terminal)
           glide-host --set-connect HOST[:PORT] (save the PC's address: the host dials it as well as listening)
           glide-host --login-item on|off|status (start this app at login, like the setup window's button)
           glide-host --setup-preview OUT.png [--installer] (render the setup window to a PNG; no server)
           glide-host --selftest-ui [--out DIR] (print the status menu per state + display-mode picks; no capture)
           glide-host --encode-bench [SECONDS]  (offline VideoToolbox encode timing, normal vs low-latency RC,
                                                synthetic 2560x1440 desktop content; no capture, no network)
           glide-host --virtual-display-selftest [--viewer WxH] [--hz N] [--yes]
                                               (CREATES temporary virtual displays for ~30 s and checks
                                                creation, HiDPI/1x, resizing, mirroring, removal on release
                                                and after exit; never touches physical displays' modes or
                                                arrangement; no capture, no network; docs/VIRTUAL_DISPLAY.md)
           glide-host --list-display-modes [ID] (print a display's current and usable modes; read-only)
      Latency tuning (env, see docs/LATENCY.md): GLIDE_FPS=N (like --fps), GLIDE_LL=1 (low-latency RC),
      GLIDE_SCK_QUEUE_DEPTH=N (default 5), GLIDE_SCK_INTERVAL=native|fps (minimumFrameInterval)
      --connect: also dial out to the viewer's PC (reconnects automatically). The host always
                 listens too, so whichever direction the network allows connects.
      Security v2: no password. A viewer pairs once (6-digit code confirmed on both screens) and
      is then recognized by its key. Config: ~/Library/Application Support/Glide (host.json,
      host-key; $GLIDE_HOST_CONFIG_DIR overrides).
    """)
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
func takeValue(_ flag: String) -> String? {
    guard let i = args.firstIndex(of: flag) else { return nil }
    guard i + 1 < args.count else { usage() }
    let v = args[i + 1]
    args.removeSubrange(i...i + 1)
    return v
}
if args.contains("-h") || args.contains("--help") { usage() }
if args.contains("--version") || args.contains("-V") { print(GlideVersion.banner("glide-host")); exit(0) }
if args.contains("--selftest-ui") { runSelfTestUI(outDir: takeValue("--out")) }  // offscreen; never captures
if let i = args.firstIndex(of: "--list-display-modes") {  // read-only
    runListDisplayModes(i + 1 < args.count ? UInt32(args[i + 1]) : nil)
}
if args.contains("--virtual-display-selftest-worker") {  // the self-test's child: creates the displays
    args.removeAll { $0 == "--virtual-display-selftest-worker" }
    runVirtualDisplaySelfTestWorker(viewer: takeValue("--viewer"), hz: takeValue("--hz").flatMap(Double.init))
}
if args.contains("--virtual-display-selftest") {  // explicit only: creates temporary virtual displays
    args.removeAll { $0 == "--virtual-display-selftest" }
    let yes = args.contains("--yes")
    runVirtualDisplaySelfTest(viewer: takeValue("--viewer"), hz: takeValue("--hz").flatMap(Double.init), skipCountdown: yes)
}
if let i = args.firstIndex(of: "--encode-bench") {  // offline; never captures or listens
    let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 3 : 3
    runEncodeBench(seconds: secs)
}

if args.contains("--permission-status") {
    // Read-only, for install.sh: a fresh process sees a new Screen Recording grant, which the
    // --request-permissions process only sees after a relaunch.
    print("screen-recording=\(CGPreflightScreenCaptureAccess() ? "granted" : "missing") accessibility=\(AXIsProcessTrusted() ? "granted" : "missing")")
    exit(0)
}
if let v = takeValue("--login-item") {  // the setup window's Start at Login, for scripts/uninstall
    do {
        switch v {
        case "on": try Instance.enableLoginItem()
        case "off": try Instance.disableLoginItem()
        case "status": break
        default: usage()
        }
        print("login-item=\(Instance.loginItem)")
        exit(0)
    } catch { print("error: \(error.localizedDescription)"); exit(1) }
}
if args.contains("--request-permissions") {
    // Run from the app bundle so macOS attributes the grants to Glide Host itself.
    let screen0 = CGPreflightScreenCaptureAccess(), ax0 = AXIsProcessTrusted()
    print("Screen Recording: \(screen0 ? "granted" : "missing"), Accessibility: \(ax0 ? "granted" : "missing")")
    if !screen0 { CGRequestScreenCaptureAccess() }
    if !ax0 { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) }
    let deadline = Date().addingTimeInterval(600)
    while Date() < deadline {
        // Screen Recording only reflects a new grant after relaunch; Accessibility updates live.
        if AXIsProcessTrusted() && (screen0 || CGPreflightScreenCaptureAccess()) { break }
        Thread.sleep(forTimeInterval: 1)
    }
    print("Accessibility: \(AXIsProcessTrusted() ? "granted" : "missing"); Screen Recording: \(CGPreflightScreenCaptureAccess() ? "granted" : "grant pending (takes effect on next launch)")")
    exit(0)
}

// Pairing / identity commands talk to the running host over its control socket.
if args.contains("--pair") || args.contains("--paired") || args.contains("--unpair") || args.contains("--pair-code") || args.contains("--identity") {
    runTrustCommand(&args)  // exits
}
for legacy in ["--password", "--password-file", "--set-password-file"] where args.contains(legacy) {
    _ = takeValue(legacy)
    print("note: \(legacy) is ignored: Glide v2 pairs viewers instead of using a password (glide-host --pair)")
}

if let out = takeValue("--setup-preview") {  // offscreen render; never listens or captures
    let installer = args.contains("--installer")
    _ = NSApplication.shared
    let m = SetupModel(installer: installer ? ("0.2.0", "/Users/you/Applications/Glide Host.app") : nil, actions: .init())
    m.refresh()
    Thread.sleep(forTimeInterval: 0.5)  // the Screen Recording check runs in a child process
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    print(SetupWindowController.renderPreview(m, to: out, dark: args.contains("--dark")) ? "wrote \(out)" : "render failed")
    exit(0)
}

var config = HostConfig.load()
if let v = takeValue("--set-connect") { config.connect = v; config.save(); print("saved connect target \(v)"); exit(0) }
Instance.redirectLogIfNeeded()
log("starting \(GlideVersion.banner("glide-host")) (pid \(getpid()))")
if config.password != nil || config.salt != nil || ProcessInfo.processInfo.environment["GLIDE_PASSWORD"] != nil {
    log("config: the v1 password (host.json salt/password, $GLIDE_PASSWORD) is no longer used — viewers pair with this Mac instead; host.json keeps it for a rollback to v1")
}
let identity: Curve25519.KeyAgreement.PrivateKey
do { identity = try HostIdentity.loadOrCreate() } catch { log("identity: \(error.localizedDescription)"); exit(1) }
let hostFingerprint = GlideHandshake.fingerprint(identity.publicKey.rawRepresentation)
log("identity: this Mac's key is \(hostFingerprint)")
TrustStore.shared.load(config)
HostStatus.shared.update { $0.hostFingerprint = hostFingerprint }
log("pairing: \(TrustStore.shared.list.count) paired viewer(s)\(TrustStore.shared.list.isEmpty ? " — open Glide → Pair New Viewer… (or glide-host --pair) to add one" : "")")

var settings = HostSettings(identity: identity)
if let v = takeValue("--port"), let n = UInt16(v) { settings.port = n }
settings.clipboardSyncConcealed = config.clipboard?.syncConcealed ?? false
settings.files = HostFileConfig(config.files)
if let v = ProcessInfo.processInfo.environment["GLIDE_FPS"], let n = Int(v), n > 0 { settings.fps = n }  // LaunchAgent-friendly
if let v = takeValue("--fps"), let n = Int(v) { settings.fps = n }
if let v = takeValue("--bitrate-kbps"), let n = Int(v) { settings.bitrateKbps = n }
if let v = takeValue("--max-width"), let n = Int(v) { settings.maxWidth = n }
if let v = takeValue("--display"), let n = UInt32(v) { ActiveDisplay.pinned = n }
let connectTarget = takeValue("--connect") ?? config.connect
let noListen = args.contains("--no-listen") || config.listen == false
args.removeAll { $0 == "--no-listen" }
guard args.isEmpty else { print("unknown arguments: \(args)"); usage() }

/// GLIDE_HOST_TEST_MODE=1: protocol-only test instance (used with $GLIDE_HOST_CONFIG_DIR and
/// another --port to exercise handshake/pairing against the real viewer without disturbing a
/// running host): no capture, no display-mode changes, no power assertions, no status item, no
/// alerts; an authenticated viewer gets a ServerHello and nothing else.
let hostTestMode = ProcessInfo.processInfo.environment["GLIDE_HOST_TEST_MODE"] == "1"
if hostTestMode { log("TEST MODE: protocol only (no capture, no display changes, no UI)") }

// One host per user (Instance.swift). Only for the app bundle: a bare binary from `swift build`
// or a test instance with its own config folder keeps the old behaviour.
let role: Instance.Role = (Instance.isAppBundle && !hostTestMode) ? Instance.resolveRole() : .primary
switch role {
case .primary: break
case .defer_:
    log("instance: Glide Host is already running; showing its setup window")
    Instance.send("show-setup")
    exit(0)
case let .installer(version, path):
    // A new download (or another copy) while a host runs: only offer to replace it.
    log("instance: Glide Host \(version ?? "(older)") is running from \(path ?? "?"); opening the installer")
    let app = NSApplication.shared
    let ctl = SetupWindowController(model: SetupModel(installer: (version, path), actions: .init()))
    SetupWindowController.shared = ctl
    ctl.show()
    app.run()
    exit(0)
}
let showSetupAtLaunch = Instance.isAppBundle && !hostTestMode && SetupModel.shouldShowAtLaunch()

// Permissions (the setup window asks for them itself, with explanations)
if hostTestMode || showSetupAtLaunch {} else if !CGPreflightScreenCaptureAccess() {
    log("Screen Recording permission missing — requesting (grant it in System Settings, then restart glide-host)")
    CGRequestScreenCaptureAccess()
}
if !hostTestMode && !showSetupAtLaunch && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    log("Accessibility permission missing — remote input will not work until granted")
}

// Listener
final class Server: @unchecked Sendable {
    let settings: HostSettings
    let listener: NWListener
    /// Active session + connections still authenticating (an unauthenticated connection never
    /// touches the active session; see SessionRegistry).
    let sessions = SessionRegistry<Session>(maxPending: 4)
    var current: Session? { sessions.current }
    var nextId = 1
    let lock = NSLock()
    private var paused = false
    private var dialTarget: (host: String, port: UInt16)?
    private var dialLoopActive = false
    /// Dial mode: consecutive sessions that ended without authenticating (backoff 2 s → 60 s).
    private var dialFailures = 0
    private var pendingRedial: DispatchWorkItem?

    init(settings: HostSettings) throws {
        self.settings = settings
        listener = try NWListener(using: SecureChannel.tcpParameters(), on: NWEndpoint.Port(rawValue: settings.port)!)
    }

    /// Last dial error logged, so an unreachable PC doesn't log the same line every 2 s.
    private var lastDialError: String?
    /// Bumped by `setDialTarget`, so a redial scheduled for an old target does nothing.
    private var dialGeneration = 0

    /// Change the PC to dial at runtime (setup window): nil stops dialing. The listener keeps
    /// running either way, so whichever direction the network allows connects.
    func setDialTarget(_ target: String?) {
        lock.lock()
        dialGeneration += 1
        pendingRedial?.cancel(); pendingRedial = nil
        dialFailures = 0
        lastDialError = nil
        dialLoopActive = false
        dialTarget = target.flatMap(Self.parseTarget)
        let t = dialTarget
        lock.unlock()
        HostStatus.shared.update { $0.dialTarget = t.map { "\($0.host):\($0.port)" }; $0.dialDetail = nil }
        if let t { dial(host: t.host, port: t.port) } else { log("dialer: off") }
    }

    /// "host", "host:port" or "[v6]:port" → (host, port); nil for an empty string.
    static func parseTarget(_ s: String) -> (host: String, port: UInt16)? {
        let s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            return (host, rest.hasPrefix(":") ? UInt16(rest.dropFirst()) ?? 7420 : 7420)
        }
        let parts = s.split(separator: ":")
        if parts.count == 2 { return (String(parts[0]), UInt16(parts[1]) ?? 7420) }
        return (s, 7420)  // a bare name, or an IPv6 address without brackets
    }

    /// Keep a connection to `host:port` alive, redialing after it drops. Idle while another
    /// session (a viewer that dialed in) is active, so there is only ever one.
    func dial(host: String, port: UInt16) {
        lock.lock()
        guard let t = dialTarget, t.host == host, t.port == port else { lock.unlock(); return }
        if paused { dialLoopActive = false; lock.unlock(); return }
        dialLoopActive = true
        let generation = dialGeneration
        let queue = DispatchQueue(label: "glide.session.\(nextId)", qos: .userInteractive)
        lock.unlock()
        if sessions.current != nil {
            scheduleRedial(host: host, port: port, generation: generation, idle: true)
            return
        }
        HostStatus.shared.update { $0.dialTarget = "\(host):\(port)"; if $0.dialDetail == nil { $0.dialDetail = "connecting" } }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: SecureChannel.tcpParameters())
        lock.lock(); let quiet = dialFailures > 2 || lastDialError != nil; lock.unlock()
        if !quiet { log("dialer: connecting to \(host):\(port)") }
        let redial = { [weak self] in self?.scheduleRedial(host: host, port: port, generation: generation) }
        var sessionStarted = false
        let failed = { [weak self] (e: NWError) in
            guard let self else { return }
            let text = "\(e)"
            self.lock.lock(); let repeated = self.lastDialError == text; self.lastDialError = text; self.lock.unlock()
            if !repeated { log("dialer: \(host):\(port) not reachable (\(text)); retrying every 2 s") }
            HostStatus.shared.update { $0.dialDetail = Self.dialErrorText(e) }
            redial()
        }
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready where !sessionStarted:
                sessionStarted = true
                self.lock.lock(); self.lastDialError = nil; self.lock.unlock()
                // Hand the live connection to a Session (it re-installs its own state handler).
                self.adopt(conn, queue: queue) { [weak self] s in
                    guard let self else { return }
                    self.lock.lock()
                    self.dialFailures = s.failedAuth ? self.dialFailures + 1 : 0
                    self.lock.unlock()
                    redial()
                }
            case .waiting(let e):
                conn.cancel()
                failed(e)
            case .failed(let e) where !sessionStarted:
                failed(e)
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Short, plain text for the menu and the setup window.
    static func dialErrorText(_ e: NWError) -> String {
        if case let .posix(code) = e {
            switch code {
            case .ECONNREFUSED: return "the PC answers, but Glide isn't waiting for this Mac there"
            case .ETIMEDOUT, .EHOSTUNREACH, .ENETUNREACH, .EHOSTDOWN: return "no answer (a firewall or the network may block it)"
            default: break
            }
        }
        if case .dns = e { return "the name doesn't resolve" }
        return "\(e)"
    }

    /// Redial after 2 s, or longer after repeated failed handshakes (2 s doubling to 60 s), so an
    /// unpaired/impostor viewer isn't hammered. `kickDialer()` (pairing window opened) cuts it short.
    /// `idle`: another session is active; just check again in 2 s.
    private func scheduleRedial(host: String, port: UInt16, generation: Int, idle: Bool = false) {
        lock.lock()
        guard generation == dialGeneration else { lock.unlock(); return }
        let n = idle ? 0 : dialFailures
        let delay = n <= 1 ? 2.0 : min(2.0 * pow(2, Double(min(n - 1, 5))), 60)
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            if self.pendingRedial === work { self.pendingRedial = nil }
            let current = generation == self.dialGeneration
            self.lock.unlock()
            if current { self.dial(host: host, port: port) }
        }
        pendingRedial = work
        lock.unlock()
        if n > 1 { HostStatus.shared.update { $0.dialDetail = "viewer not accepted — retrying in \(Int(delay)) s" } }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pairing window opened: forget the dial backoff and redial now if we're waiting.
    func kickDialer() {
        lock.lock()
        dialFailures = 0
        let w = pendingRedial
        pendingRedial = nil
        let target = dialTarget
        lock.unlock()
        guard let w, !w.isCancelled, let target else { return }
        w.cancel()  // a cancelled work item never runs: dial directly instead
        log("dialer: pairing window opened; redialing now")
        DispatchQueue.global().async { self.dial(host: target.host, port: target.port) }
    }

    /// Paired viewers were removed: end their sessions.
    func endSessions(of keys: [Data]) {
        for s in sessions.all where s.viewerKey.map(keys.contains) == true {
            log("server: ending session \(s.id) (viewer unpaired)")
            s.end()
        }
    }

    private func adopt(_ conn: NWConnection, queue: DispatchQueue? = nil, onEnd extra: ((Session) -> Void)? = nil) {
        lock.lock()
        let id = nextId; nextId += 1
        lock.unlock()
        let s = Session(id: id, connection: conn, settings: settings, queue: queue)
        // A paused host still answers the handshake preamble (status 2) so the viewer can say why.
        s.isPaused = { [weak self] in
            guard let self else { return true }
            self.lock.lock(); defer { self.lock.unlock() }
            return self.paused
        }
        var source = "\(conn.endpoint)"
        if case let .hostPort(host, _) = conn.endpoint { source = "\(host)" }
        if let evicted = sessions.admit(s, source: source) {
            PeerLog.line(source, "server: too many unauthenticated connections; dropping pending session \(evicted.id)")
            evicted.end()
        }
        // Coalesced per address: an unauthenticated peer can open any number of connections.
        PeerLog.line(source, "server: connection \(id) with \(conn.endpoint) (authenticating)")
        s.onAuthenticated = { [weak self] s in
            guard let self else { return }
            self.lock.lock(); let isPaused = self.paused; self.lock.unlock()
            if isPaused { log("server: paused; closing session \(s.id)"); s.end(); return }
            // Only now may the new viewer replace the active one.
            let r = self.sessions.authenticated(s)
            if let old = r.replaced { log("server: session \(s.id) replaces session \(old.id)"); old.end() }
        }
        s.onEnd = { [weak self] ended in
            self?.sessions.ended(ended)
            extra?(ended)
        }
        s.start()
    }

    /// Ends the active session (menu). In dial mode the host redials after 2 s.
    func disconnect() { current?.end() }

    /// Paused: refuse new connections, stop dialing, and end any current/pending session.
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        let target = dialTarget
        // Resuming cancels any redial scheduled before the pause and dials afresh.
        let needDial = !p && target != nil
        if !p { dialGeneration += 1; pendingRedial?.cancel(); pendingRedial = nil; dialLoopActive = false }
        lock.unlock()
        HostStatus.shared.update { $0.paused = p; if p { $0.dialDetail = nil } }
        log("server: \(p ? "paused" : "resumed")")
        if p { sessions.all.forEach { $0.end() } }
        if needDial, let t = target { dial(host: t.host, port: t.port) }
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            self?.adopt(conn)
        }
        listener.stateUpdateHandler = { st in
            switch st {
            case .ready:
                log("server: listening on port \(self.settings.port)")
                HostStatus.shared.update { $0.listenPort = self.settings.port }
            case .failed(let e):
                // Port in use: another host (or app) has it. With a PC address the dialer still
                // works; otherwise nothing could connect, so exit (launchd retries later).
                log("server: listener failed: \(e)")
                HostStatus.shared.update { $0.serverError = "Can't listen on port \(self.settings.port): \(e)" }
                self.lock.lock(); let dialing = self.dialTarget != nil; self.lock.unlock()
                if !dialing { exit(1) }
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "glide.listener"))
    }
}

let app = NSApplication.shared
let sleepAssertion = hostTestMode ? nil : Power.preventSystemSleep()
if !hostTestMode { log(sleepAssertion != nil ? "power: preventing idle system sleep while the host runs" : "power: could not create sleep assertion") }
app.setActivationPolicy(.accessory)  // LSUIElement: menu-bar status item only
let server = try Server(settings: settings)
if !hostTestMode { DisplayModeController.shared.start(); VirtualDisplayManager.shared.start() }
ActiveDisplay.refreshNames()
if !hostTestMode {
    let ds = ActiveDisplay.displays()
    log("displays: " + (ds.isEmpty ? "none awake" : ds.map { "\($0.id) \($0.summary)\($0.isMain ? " (main)" : "")" }.joined(separator: "; "))
        + (ActiveDisplay.pinned.map { "; --display \($0)" } ?? ""))
}
let pairing = PairingController.shared
pairing.showAlerts = !hostTestMode
pairing.onOpen = { server.kickDialer() }
pairing.onRemove = { gone in server.endSessions(of: gone.compactMap(\.keyData)) }
pairing.startControlSocket()
let statusMenu = StatusMenu(actions: .init(disconnect: { server.disconnect() }, setPaused: { server.setPaused($0) },
                                           openPairing: { pairing.openWindow(source: "menu") },
                                           cancelPairing: { pairing.cancelWindow(source: "menu") },
                                           removeViewer: { v in
                                               let gone = TrustStore.shared.remove(matching: v.key)
                                               for g in gone { log("pairing: removed viewer “\(g.name)” (\(g.fingerprint)) via menu") }
                                               server.endSessions(of: gone.compactMap(\.keyData))
                                           },
                                           sendFiles: { server.current?.sendFiles($0) ?? false },
                                           cancelFiles: { server.current?.cancelFiles() },
                                           selectDisplay: { server.current?.selectDisplay($0, by: .host) },
                                           showSetup: { showSetup() }),
                            showStatusItem: !hostTestMode)
HostNotifier.shared.setUp()
statusMenu.downloadDir = settings.files.downloadDir
log("files: transfer \(settings.files.enabled ? "on" : "off"), receiving \(settings.files.receive ? "on" : "off") into \(settings.files.downloadDir.path)")
/// The setup window (Setup.swift): at launch until finished, from the menu, when the app is
/// opened again from Finder, or when another copy asks (`show-setup`).
func showSetup() {
    guard !hostTestMode else { return }
    let ctl = SetupWindowController.shared ?? SetupWindowController(model: SetupModel(installer: nil, actions: .init(
        setDialTarget: { server.setDialTarget($0) },
        openPairing: { pairing.openWindow(source: "setup window") },
        cancelPairing: { pairing.cancelWindow(source: "setup window") })))
    SetupWindowController.shared = ctl
    ctl.show()
}
pairing.instanceCommand = { line in
    Instance.handle(line, showSetup: showSetup, quit: { reason in
        log("instance: \(reason)")
        unlink(PairingController.socketPath)
        restoreDisplaysBeforeExit(reason: reason)
        exit(0)
    })
}
/// Reopening the running app (Finder, Dock, `open`) shows the setup window.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSetup()
        return false
    }
}
let appDelegate = AppDelegate()
app.delegate = appDelegate
if showSetupAtLaunch { DispatchQueue.main.async { showSetup() } }

// Always listen; also dial the PC when its address is known. Whichever direction the network
// allows connects (the dialer stays idle while a viewer that dialed in is connected).
if connectTarget == nil || !noListen { server.start() } else { log("server: not listening (listen: false); dialing only") }
if let target = connectTarget { server.setDialTarget(target) }
// SIGTERM (launchctl, install scripts) and SIGINT: give the Mac its display arrangement back,
// remove the virtual display and restore the monitor's own mode before exiting (a mirror set whose
// master vanishes is dissolved by macOS, which can leave the monitor in another mode). Handled on
// the main queue, where the display state lives; the restore waits up to 1.5 s for the monitor to
// settle after the mirror ends. A wedged main queue still exits after 10 s (launchd's ExitTimeOut,
// after which it sends SIGKILL, is 20 s).
let exitBackstop: TimeInterval = 10
var signalSources: [DispatchSourceSignal] = []
for sig in [SIGINT, SIGTERM] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler {
        unlink(PairingController.socketPath)
        if !hostTestMode { restoreDisplaysBeforeExit(reason: sig == SIGTERM ? "SIGTERM" : "SIGINT") }
        exit(0)
    }
    src.resume()
    signalSources.append(src)
    let backstop = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    backstop.setEventHandler { DispatchQueue.global().asyncAfter(deadline: .now() + exitBackstop) { exit(0) } }
    backstop.resume()
    signalSources.append(backstop)
}
app.run()
