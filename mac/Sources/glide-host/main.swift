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
    /// Default `--connect` target (viewer running `--listen`), used when no CLI flag is given.
    var connect: String?
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
                      [--connect HOST[:PORT]]
           glide-host --pair                (open the 2-minute pairing window of the running host;
                                             in a terminal, wait for the viewer and type its code)
           glide-host --pair-code NNNNNN    (confirm the viewer that is waiting to pair, if the code
                                             matches what the PC shows; else decline it)
           glide-host --paired              (list paired viewers)
           glide-host --unpair NAME|KEY     (remove a paired viewer: name, key or fingerprint prefix)
           glide-host --identity            (print this Mac's key fingerprint)
           glide-host --version             (print the version and protocol version)
           glide-host --request-permissions (prompt for Screen Recording + Accessibility, wait, exit)
           glide-host --set-connect HOST[:PORT] (save the default dial-out target in host.json)
           glide-host --selftest-ui [--out DIR] (print the status menu per state + display-mode picks; no capture)
           glide-host --encode-bench [SECONDS]  (offline VideoToolbox encode timing, normal vs low-latency RC,
                                                synthetic 2560x1440 desktop content; no capture, no network)
           glide-host --virtual-display-selftest [--viewer WxH] [--hz N] [--yes]
                                               (CREATES a temporary virtual display for ~20 s and checks
                                                creation, HiDPI/1x, resizing and removal; may move windows;
                                                no capture, no network; docs/VIRTUAL_DISPLAY.md)
           glide-host --list-display-modes [ID] (print a display's current and usable modes; read-only)
      Latency tuning (env, see docs/LATENCY.md): GLIDE_FPS=N (like --fps), GLIDE_LL=1 (low-latency RC),
      GLIDE_SCK_QUEUE_DEPTH=N (default 5), GLIDE_SCK_INTERVAL=native|fps (minimumFrameInterval)
      --connect: dial out to a client running `glide-client --listen` (reconnects automatically)
                 instead of listening. Use when the network only allows Mac -> viewer connections.
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
if args.contains("--virtual-display-selftest") {  // explicit only: creates a temporary virtual display
    args.removeAll { $0 == "--virtual-display-selftest" }
    let yes = args.contains("--yes")
    runVirtualDisplaySelfTest(viewer: takeValue("--viewer"), hz: takeValue("--hz").flatMap(Double.init), skipCountdown: yes)
}
if let i = args.firstIndex(of: "--encode-bench") {  // offline; never captures or listens
    let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 3 : 3
    runEncodeBench(seconds: secs)
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

var config = HostConfig.load()
if let v = takeValue("--set-connect") { config.connect = v; config.save(); print("saved connect target \(v)"); exit(0) }
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
guard args.isEmpty else { print("unknown arguments: \(args)"); usage() }

/// GLIDE_HOST_TEST_MODE=1: protocol-only test instance (used with $GLIDE_HOST_CONFIG_DIR and
/// another --port to exercise handshake/pairing against the real viewer without disturbing a
/// running host): no capture, no display-mode changes, no power assertions, no status item, no
/// alerts; an authenticated viewer gets a ServerHello and nothing else.
let hostTestMode = ProcessInfo.processInfo.environment["GLIDE_HOST_TEST_MODE"] == "1"
if hostTestMode { log("TEST MODE: protocol only (no capture, no display changes, no UI)") }

// Permissions
if hostTestMode {} else if !CGPreflightScreenCaptureAccess() {
    log("Screen Recording permission missing — requesting (grant it in System Settings, then restart glide-host)")
    CGRequestScreenCaptureAccess()
}
if !hostTestMode && !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
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

    /// Outbound mode: keep a connection to `host:port` alive, redialing after it drops.
    func dial(host: String, port: UInt16) {
        lock.lock()
        dialTarget = (host, port)
        if paused { dialLoopActive = false; lock.unlock(); return }
        dialLoopActive = true
        let queue = DispatchQueue(label: "glide.session.\(nextId)", qos: .userInteractive)
        lock.unlock()
        HostStatus.shared.update { $0.dialTarget = "\(host):\(port)"; $0.dialDetail = "connecting" }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: SecureChannel.tcpParameters())
        lock.lock(); let quiet = dialFailures > 2; lock.unlock()
        if !quiet { log("dialer: connecting to \(host):\(port)") }
        let redial = { [weak self] in self?.scheduleRedial(host: host, port: port) }
        var sessionStarted = false
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready where !sessionStarted:
                sessionStarted = true
                // Hand the live connection to a Session (it re-installs its own state handler).
                self.adopt(conn, queue: queue) { [weak self] s in
                    guard let self else { return }
                    self.lock.lock()
                    self.dialFailures = s.failedAuth ? self.dialFailures + 1 : 0
                    self.lock.unlock()
                    redial()
                }
            case .waiting(let e):
                log("dialer: waiting (\(e)); retrying"); conn.cancel()
                HostStatus.shared.update { $0.dialDetail = "\(e)" }
                redial()
            case .failed(let e) where !sessionStarted:
                log("dialer: failed (\(e)); retrying")
                HostStatus.shared.update { $0.dialDetail = "\(e)" }
                redial()
            default: break
            }
        }
        conn.start(queue: queue)
    }

    /// Redial after 2 s, or longer after repeated failed handshakes (2 s doubling to 60 s), so an
    /// unpaired/impostor viewer isn't hammered. `kickDialer()` (pairing window opened) cuts it short.
    private func scheduleRedial(host: String, port: UInt16) {
        lock.lock()
        let n = dialFailures
        let delay = n <= 1 ? 2.0 : min(2.0 * pow(2, Double(min(n - 1, 5))), 60)
        var work: DispatchWorkItem!
        work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock(); if self.pendingRedial === work { self.pendingRedial = nil }; self.lock.unlock()
            self.dial(host: host, port: port)
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
            log("server: too many unauthenticated connections; dropping pending session \(evicted.id)")
            evicted.end()
        }
        log("server: connection \(id) with \(conn.endpoint) (authenticating)")
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
        let needDial = !p && target != nil && !dialLoopActive
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
            case .failed(let e): log("server: listener failed: \(e)"); exit(1)
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
                                           selectDisplay: { server.current?.selectDisplay($0, by: .host) }),
                            showStatusItem: !hostTestMode)
HostNotifier.shared.setUp()
statusMenu.downloadDir = settings.files.downloadDir
log("files: transfer \(settings.files.enabled ? "on" : "off"), receiving \(settings.files.receive ? "on" : "off") into \(settings.files.downloadDir.path)")
if let target = connectTarget {
    let parts = target.split(separator: ":")
    server.dial(host: String(parts[0]), port: parts.count > 1 ? UInt16(parts[1]) ?? 7420 : 7420)
} else {
    server.start()
}
signal(SIGINT) { _ in unlink(PairingController.socketPath); exit(0) }
signal(SIGTERM) { _ in unlink(PairingController.socketPath); exit(0) }
app.run()
