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
    /// host.json `clipboard.enabled`: sync the clipboard with the viewer.
    var clipboardEnabled = true
    /// host.json `clipboard.syncConcealed`: also sync password-manager (concealed) items.
    var clipboardSyncConcealed = false
    /// host.json `audio.enabled` (and not `GLIDE_NO_AUDIO=1`): send system audio.
    var audioEnabled = true
    /// host.json `files` (PROTOCOL.md §6).
    var files = HostFileConfig()

    /// The host.json parts a Session reads when it starts (Settings window: next connection).
    mutating func applySharing(_ c: HostConfig) {
        clipboardEnabled = c.clipboard?.isEnabled ?? true
        clipboardSyncConcealed = c.clipboard?.syncsConcealed ?? false
        audioEnabled = c.audio?.isEnabled ?? true
        files = HostFileConfig(c.files)
    }
}

/// host.json reading and writing (the struct and its decisions are in GlideCore/HostConfig.swift).
extension HostConfig {
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

    /// For reading only. Never overwrites an existing file it can't decode (that would drop the
    /// paired viewers); uses defaults in memory instead. To change the file, use `update`.
    static func load() -> HostConfig {
        do {
            if let c = try ConfigFile.read(HostConfig.self, from: url) { return c }
            let c = HostConfig()
            c.save()
            return c
        } catch {
            log("config: \(error); using defaults without saving — fix the file")
            return HostConfig()
        }
    }

    /// Read-modify-write of host.json for callers that show the error (setup window, CLI). A
    /// missing file starts from defaults; an existing file that can't be read or decoded is never
    /// overwritten: this throws `ConfigFile.Failure` and writes nothing. (`modify`, in
    /// DisplayModeController.swift, refuses the same way and only logs.)
    @discardableResult
    static func update(_ change: (inout HostConfig) -> Void) throws -> HostConfig {
        try ConfigFile.update(url, defaults: { HostConfig() }, change)
    }

    /// Why host.json can't be used, or nil when it's fine (or doesn't exist yet).
    static var problem: String? {
        do { _ = try ConfigFile.read(HostConfig.self, from: url); return nil } catch { return "\(error)" }
    }

    /// The message for a refused change (setup window, CLI).
    static func notSavedText(_ error: Error, what: String) -> String {
        "Couldn't save \(what): \(error). Nothing was changed, so your paired viewers are kept. Fix the file or move it away, then try again."
    }

    /// Writes this config as host.json. Never call it on a config from `load()` (that may be
    /// defaults standing in for a file it couldn't decode): change the file with `update`.
    func save() {
        do { try ConfigFile.write(self, to: HostConfig.url) } catch { log("config: \(error)") }
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
           glide-host --settings-preview OUT.png [--tab NAME] [--dark] (render a Settings tab to a PNG: general,
                                                connection, display, viewers, sharing, advanced; no server)
           glide-host --drag-helper-preview     (open System Settings' Screen Recording list with the
                                                drag-into-the-list panel for 90 s; no server)
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

if let out = takeValue("--settings-preview") {  // offscreen render; never listens, captures or writes
    _ = NSApplication.shared
    let tab = takeValue("--tab").flatMap(SettingsModel.Tab.init(rawValue:)) ?? .general
    TrustStore.shared.load(((try? ConfigFile.read(HostConfig.self, from: HostConfig.url)) ?? nil) ?? HostConfig())
    HostStatus.shared.update { $0.listenPort = 7420; $0.hostFingerprint = "eed3 85a2 4ef7 976a" }
    let m = SettingsModel(actions: .init())
    m.tab = tab
    m.refresh()
    print(SettingsWindowController.renderPreview(m, to: out, dark: args.contains("--dark")) ? "wrote \(out)" : "render failed")
    exit(0)
}

if args.contains("--drag-helper-preview") {  // opens System Settings' Screen Recording list; never listens or captures
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    SetupModel.openPrivacy("Privacy_ScreenCapture")
    PermissionDragHelper.shared.show(permission: "Screen Recording") { false }
    DispatchQueue.main.asyncAfter(deadline: .now() + 90) { exit(0) }
    app.run()
}

if let v = takeValue("--set-connect") {
    let target = v.trimmingCharacters(in: .whitespaces)
    do {
        try HostConfig.update { $0.connect = target.isEmpty ? nil : target }
        print(target.isEmpty ? "cleared the connect target" : "saved connect target \(target)")
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("error: \(HostConfig.notSavedText(error, what: "the connect target"))\n".utf8))
        exit(1)
    }
}
var config = HostConfig.load()
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
settings.applySharing(config)
if let v = ProcessInfo.processInfo.environment["GLIDE_FPS"], let n = Int(v), n > 0 { settings.fps = n }  // LaunchAgent-friendly
if let v = takeValue("--fps"), let n = Int(v) { settings.fps = n }
if let v = takeValue("--bitrate-kbps"), let n = Int(v) { settings.bitrateKbps = n }
if let v = takeValue("--max-width"), let n = Int(v) { settings.maxWidth = n }
if let v = takeValue("--display"), let n = UInt32(v) { ActiveDisplay.pinned = n }
let cliConnect = takeValue("--connect")
let noListenFlag = args.contains("--no-listen")
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
    private var settingsValue: HostSettings
    /// What the next session starts with (`updateSharing` changes it; a running session keeps its own).
    var settings: HostSettings { lock.lock(); defer { lock.unlock() }; return settingsValue }
    /// The LAN listener (nil while not listening: `listen: false`, or LAN mode off).
    private var listener: NWListener?
    /// host.json / command line want the LAN listener.
    private var wantsListen = false
    /// Org policy (ENTERPRISE.md §7): LAN mode on. Off = no listener, no dialer.
    private var lanAllowed = true
    /// The dial target set while LAN mode was off, restored when it comes back.
    private var dialTargetBeforeLANOff: String??
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
    /// The scheduled redial / idle check. `token` lets the work item tell whether it is still the
    /// scheduled one (kickDialer may have taken it over and dialed already).
    private var pendingRedial: (token: Int, work: DispatchWorkItem)?
    private var redialSeq = 0
    /// Dialing is held back until pairing opens (DialPolicy.waitForPairing); logged once per stretch.
    private var waitingForPairing = false

    init(settings: HostSettings) throws {
        settingsValue = settings
    }

    /// Last dial error logged, so an unreachable PC doesn't log the same line every 2 s.
    private var lastDialError: String?
    /// Bumped by `setDialTarget`, so a redial scheduled for an old target does nothing.
    private var dialGeneration = 0

    /// Change the PC to dial at runtime (setup window): nil stops dialing. The listener keeps
    /// running either way, so whichever direction the network allows connects.
    func setDialTarget(_ target: String?) {
        lock.lock()
        if !lanAllowed, target != nil {
            dialTargetBeforeLANOff = .some(target)
            lock.unlock()
            log("dialer: not dialing \(target!): LAN connections are turned off by the organization")
            return
        }
        dialGeneration += 1
        pendingRedial?.work.cancel(); pendingRedial = nil
        dialFailures = 0
        lastDialError = nil
        dialLoopActive = false
        waitingForPairing = false
        dialTarget = target.flatMap(Self.parseTarget)
        let t = dialTarget
        lock.unlock()
        HostStatus.shared.update { $0.dialTarget = t.map { "\($0.host):\($0.port)" }; $0.dialDetail = nil }
        if let t { dial(host: t.host, port: t.port) } else { log("dialer: off") }
    }

    static func parseTarget(_ s: String) -> (host: String, port: UInt16)? { DialPolicy.parseTarget(s) }

    /// Shown (menu, setup window) while dialing waits for the pairing window.
    static let waitingForPairingText = "waiting until pairing is opened on this Mac"

    /// Keep a connection to `host:port` alive, redialing after it drops. Idle while another
    /// session (a viewer that dialed in) is active, so there is only ever one, and while no viewer
    /// is paired and the pairing window is closed (DialPolicy): the PC could only be refused then,
    /// which would also grow its per-address backoff for this Mac.
    func dial(host: String, port: UInt16) {
        lock.lock()
        guard let t = dialTarget, t.host == host, t.port == port else { lock.unlock(); return }
        let isPaused = paused || !lanAllowed
        let generation = dialGeneration
        lock.unlock()
        let action = DialPolicy.next(paused: isPaused, sessionActive: sessions.current != nil,
                                     pairedViewers: TrustStore.shared.list.count,
                                     pairingOpen: PairingController.shared.window.isOpen())
        switch action {
        case .stop:
            lock.lock(); dialLoopActive = false; lock.unlock()
            return
        case .waitForSession:
            lock.lock(); waitingForPairing = false; lock.unlock()  // the viewer row replaces dialDetail
            scheduleRedial(host: host, port: port, generation: generation, idle: true)
            return
        case .waitForPairing:
            lock.lock(); let already = waitingForPairing; waitingForPairing = true; dialLoopActive = true; lock.unlock()
            if !already {
                log("dialer: no paired viewer and pairing is closed; not dialing \(host):\(port) until pairing opens (Pair New Viewer…)")
                HostStatus.shared.update { $0.dialTarget = "\(host):\(port)"; $0.dialDetail = Self.waitingForPairingText }
            }
            scheduleRedial(host: host, port: port, generation: generation, idle: true)
            return
        case .dial:
            break
        }
        lock.lock()
        dialLoopActive = true
        waitingForPairing = false
        let queue = DispatchQueue(label: "glide.session.\(nextId)", qos: .userInteractive)
        lock.unlock()
        HostStatus.shared.update {
            $0.dialTarget = "\(host):\(port)"
            if $0.dialDetail == nil || $0.dialDetail == Self.waitingForPairingText { $0.dialDetail = "connecting" }
        }
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
                self.adopt(conn, queue: queue, outbound: true) { [weak self] s in
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
    /// `idle`: nothing was attempted (another session is active, or dialing waits for pairing);
    /// just check again in 2 s.
    private func scheduleRedial(host: String, port: UInt16, generation: Int, idle: Bool = false) {
        lock.lock()
        guard generation == dialGeneration else { lock.unlock(); return }
        let n = idle ? 0 : dialFailures
        let delay = DialPolicy.redialDelay(failures: n)
        redialSeq += 1
        let token = redialSeq
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            // Not ours any more: replaced, cancelled with a target change, or taken by kickDialer.
            let mine = self.pendingRedial?.token == token && generation == self.dialGeneration
            if mine { self.pendingRedial = nil }
            self.lock.unlock()
            if mine { self.dial(host: host, port: port) }
        }
        pendingRedial?.work.cancel()
        pendingRedial = (token, work)
        lock.unlock()
        if n > 1 { HostStatus.shared.update { $0.dialDetail = "viewer not accepted — retrying in \(Int(delay)) s" } }
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// The pairing window opened: forget the dial backoff and dial now if we're waiting (backing
    /// off, or holding back until pairing opens). A dial already in flight is left alone; if it
    /// fails, the reset backoff redials it after 2 s.
    func kickDialer() {
        lock.lock()
        dialFailures = 0
        let w = pendingRedial?.work
        pendingRedial = nil  // the scheduled work item sees it is no longer the pending one
        let target = dialTarget
        let wasWaiting = waitingForPairing
        lock.unlock()
        guard let w, !w.isCancelled, let target else { return }
        w.cancel()
        log("dialer: pairing window opened; \(wasWaiting ? "dialing" : "redialing") \(target.host):\(target.port) now")
        DispatchQueue.global().async { self.dial(host: target.host, port: target.port) }
    }

    /// Paired viewers were removed: end their sessions.
    func endSessions(of keys: [Data]) {
        for s in sessions.all where s.viewerKey.map(keys.contains) == true {
            log("server: ending session \(s.id) (viewer unpaired)")
            s.end()
        }
    }

    /// A managed session's bridged connection (ENTERPRISE.md §6.6): adopted like one the host
    /// dialed (never charged to the inbound rate limiter), accepted only for `sessionId`'s grant.
    func adoptRelay(_ conn: NWConnection, queue: DispatchQueue, sessionId: String, grants: GrantStore, audit: AuditReporter?,
                    onAuthenticated: @escaping (Session) -> Void, onEnd: @escaping (Session) -> Void) {
        adopt(conn, queue: queue, outbound: true, configure: { s in
            s.relaySessionId = sessionId
            s.grants = grants
            s.audit = audit
        }, onAuth: onAuthenticated, onEnd: onEnd)
    }

    /// `outbound`: the dialer opened `conn`; the session then stays out of the inbound rate limiter
    /// (the dialer has its own backoff, see `scheduleRedial`).
    private func adopt(_ conn: NWConnection, queue: DispatchQueue? = nil, outbound: Bool = false, configure: ((Session) -> Void)? = nil,
                       onAuth: ((Session) -> Void)? = nil, onEnd extra: ((Session) -> Void)? = nil) {
        lock.lock()
        let id = nextId; nextId += 1
        lock.unlock()
        let s = Session(id: id, connection: conn, settings: settings, queue: queue)
        s.outbound = outbound
        configure?(s)
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
            onAuth?(s)
        }
        s.onEnd = { [weak self] ended in
            self?.sessions.ended(ended)
            extra?(ended)
        }
        s.start()
    }

    /// Settings window: clipboard, audio and file-transfer options for the next session.
    func updateSharing(_ c: HostConfig) {
        lock.lock(); settingsValue.applySharing(c); let s = settingsValue; lock.unlock()
        log("settings: next session: clipboard \(s.clipboardEnabled ? "on" : "off")\(s.clipboardSyncConcealed ? " (concealed too)" : ""), audio \(s.audioEnabled ? "on" : "off"), files \(s.files.enabled ? "on" : "off") (receiving \(s.files.receive ? "on" : "off") into \(s.files.downloadDir.path))")
    }

    /// Whether the dialer has a PC to dial (setDialTarget with an address).
    var isDialing: Bool { lock.lock(); defer { lock.unlock() }; return dialTarget != nil }

    /// Ends the active session (menu). In dial mode the host redials after 2 s.
    func disconnect() { current?.end() }

    /// Paused: refuse new connections, stop dialing, and end any current/pending session.
    func setPaused(_ p: Bool) {
        lock.lock()
        paused = p
        let target = dialTarget
        // Resuming cancels any redial scheduled before the pause and dials afresh.
        let needDial = !p && target != nil
        if !p { dialGeneration += 1; pendingRedial?.work.cancel(); pendingRedial = nil; dialLoopActive = false; waitingForPairing = false }
        lock.unlock()
        HostStatus.shared.update { $0.paused = p; if p { $0.dialDetail = nil } }
        log("server: \(p ? "paused" : "resumed")")
        if p { sessions.all.forEach { $0.end() } }
        if needDial, let t = target { dial(host: t.host, port: t.port) }
    }

    var isPaused: Bool { lock.lock(); defer { lock.unlock() }; return paused }

    /// Org policy changed (ENTERPRISE.md §7). Off: stop listening and dialing, end LAN sessions
    /// (managed sessions continue). On: listen and dial again as configured.
    func setLANAllowed(_ on: Bool) {
        lock.lock()
        guard on != lanAllowed else { lock.unlock(); return }
        lanAllowed = on
        let listen = wantsListen
        let restore = dialTargetBeforeLANOff
        dialTargetBeforeLANOff = nil
        let current = dialTarget
        lock.unlock()
        if on {
            log("server: LAN mode on")
            if listen { startListening() }
            if let r = restore { setDialTarget(r) } else if let t = current { dial(host: t.host, port: t.port) }
        } else {
            log("server: LAN mode turned off by the organization: not listening or dialing; managed sessions only")
            stopListening()
            lock.lock()
            dialTargetBeforeLANOff = .some(current.map { "\($0.host):\($0.port)" })
            dialGeneration += 1
            pendingRedial?.work.cancel(); pendingRedial = nil
            dialLoopActive = false
            dialTarget = nil
            lock.unlock()
            HostStatus.shared.update { $0.dialTarget = nil; $0.dialDetail = nil; $0.listenPort = nil }
            if PairingController.shared.window.isOpen() { PairingController.shared.cancelWindow(source: "LAN mode turned off") }
            for s in sessions.all where s.relaySessionId == nil {
                log("server: ending LAN session \(s.id) (LAN mode turned off)")
                s.end()
            }
        }
    }

    var isLANAllowed: Bool { lock.lock(); defer { lock.unlock() }; return lanAllowed }

    /// Listen on the LAN port (if LAN mode allows it now; otherwise once it is turned back on).
    func start() {
        lock.lock(); wantsListen = true; let on = lanAllowed; lock.unlock()
        if on { startListening() } else { log("server: not listening: LAN mode is turned off by the organization") }
    }

    private func stopListening() {
        lock.lock(); let l = listener; listener = nil; lock.unlock()
        l?.cancel()
    }

    private func startListening() {
        let l: NWListener
        do { l = try NWListener(using: SecureChannel.tcpParameters(), on: NWEndpoint.Port(rawValue: settings.port)!) } catch {
            log("server: can't create the listener: \(error)")
            HostStatus.shared.update { $0.serverError = "Can't listen on port \(self.settings.port): \(error)" }
            return
        }
        lock.lock(); listener = l; lock.unlock()
        l.newConnectionHandler = { [weak self] conn in
            self?.adopt(conn)
        }
        l.stateUpdateHandler = { st in
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
                // A managed host still takes sessions through Glide Cloud.
                if !dialing && !ManagedHost.shared.isManaged { exit(1) }
            case .cancelled:
                HostStatus.shared.update { $0.listenPort = nil }
            default: break
            }
        }
        l.start(queue: DispatchQueue(label: "glide.listener"))
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
// Managed mode (ENTERPRISE.md): the managed settings and the cached org policy apply before the
// listener starts; the cloud connection starts after it.
let managed = ManagedHost.shared
if !hostTestMode { managed.prepare(identity: identity) }
managed.applyInitialPolicy(to: server)
pairing.pairingAllowed = { managed.policy.localPairingAllowed }
pairing.onOpen = { server.kickDialer() }
pairing.onRemove = { gone in server.endSessions(of: gone.compactMap(\.keyData)) }
pairing.startControlSocket()
let statusMenu = StatusMenu(actions: .init(disconnect: {
                                               if let s = server.current, s.relaySessionId != nil { managed.endByHostUser(s) } else { server.disconnect() }
                                           }, setPaused: { server.setPaused($0) },
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
                                           showSetup: { showSetup() },
                                           showSettings: { showSettings() },
                                           connectNow: { if let pc = HostConfig.load().connect { server.setDialTarget(pc) } },
                                           stopDialing: { server.setDialTarget(nil) }),
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
        isDialing: { server.isDialing },
        openPairing: { pairing.openWindow(source: "setup window") },
        cancelPairing: { pairing.cancelWindow(source: "setup window") },
        showSettings: { showSettings() })))
    SetupWindowController.shared = ctl
    ctl.show()
}
/// The Settings window (Settings.swift): menu bar → Settings… (⌘,), or the setup window.
func showSettings() {
    guard !hostTestMode else { return }
    let ctl = SettingsWindowController.shared ?? SettingsWindowController(model: SettingsModel(actions: .init(
        setDialTarget: { server.setDialTarget($0) },
        isDialing: { server.isDialing },
        openPairing: { pairing.openWindow(source: "settings window") },
        cancelPairing: { pairing.cancelWindow(source: "settings window") },
        removeViewer: { v in
            let gone = TrustStore.shared.remove(matching: v.key)
            for g in gone { log("pairing: removed viewer “\(g.name)” (\(g.fingerprint)) via settings window") }
            server.endSessions(of: gone.compactMap(\.keyData))
        },
        sharingChanged: { c in
            server.updateSharing(c)
            statusMenu.downloadDir = HostFileConfig(c.files).downloadDir
        },
        showSetup: { showSetup() })))
    SettingsWindowController.shared = ctl
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
if config.listensAtLaunch(cli: cliConnect, noListenFlag: noListenFlag) { server.start() } else { log("server: not listening (listen: false); dialing only") }
// After an update the login item may be registered but refused by launchd (Instance.swift).
if !hostTestMode { DispatchQueue.main.async { Instance.reviveLoginItemIfNeeded() } }
if let target = config.launchDialTarget(cli: cliConnect) { server.setDialTarget(target) }
else if let saved = config.connect { log("dialer: not dialing \(saved) at launch (connectAtLaunch is off); menu bar → Connect to PC, or Settings → Connection, dials it") }
if !hostTestMode { managed.start(server: server) }
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
