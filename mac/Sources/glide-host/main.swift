import AppKit
import Foundation
import GlideCore
import Network

struct HostSettings {
    var port: UInt16 = 7420
    var password: String
    var salt: Data
    var passwordKey: Data
    var displayID: CGDirectDisplayID = CGMainDisplayID()
    var fps = 60
    var bitrateKbps = 0
    var maxWidth = 3840
    var maxInFlightBytes = 6 * 1024 * 1024
}

/// Persistent host identity: password salt (and a generated password if none supplied).
struct HostConfig: Codable {
    var salt: String
    var password: String?
    /// Default `--connect` target (viewer running `--listen`), used when no CLI flag is given.
    var connect: String?

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glide", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("host.json")
    }

    static func load() -> HostConfig {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(HostConfig.self, from: d) { return c }
        let c = HostConfig(salt: Handshake.randomBytes(16).hex, password: nil, connect: nil)
        c.save()
        return c
    }

    func save() {
        let d = try! JSONEncoder().encode(self)
        FileManager.default.createFile(atPath: HostConfig.url.path, contents: d, attributes: [.posixPermissions: 0o600])
    }
}

func usage() -> Never {
    print("""
    usage: glide-host [--port N] [--password PW | --password-file PATH] [--fps N] [--bitrate-kbps N]
                      [--max-width PX] [--display ID] [--connect HOST[:PORT]]
           glide-host --request-permissions     (prompt for Screen Recording + Accessibility, wait, exit)
           glide-host --set-connect HOST[:PORT] (save the default dial-out target in host.json)
           glide-host --set-password-file PATH  (save the password in host.json)
      --connect: dial out to a client running `glide-client --listen` (reconnects automatically)
                 instead of listening. Use when the network only allows Mac -> viewer connections.
      Password resolution: --password, --password-file, $GLIDE_PASSWORD, saved password in
      ~/Library/Application Support/Glide/host.json (generated on first run).
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

var config = HostConfig.load()
if let v = takeValue("--set-connect") { config.connect = v; config.save(); print("saved connect target \(v)"); exit(0) }
if let f = takeValue("--set-password-file") {
    guard let pw = try? String(contentsOfFile: f, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !pw.isEmpty else { print("can't read \(f)"); exit(2) }
    config.password = pw; config.save(); print("saved password to \(HostConfig.url.path)"); exit(0)
}
var password: String
if let p = takeValue("--password") { password = p }
else if let f = takeValue("--password-file") { password = (try? String(contentsOfFile: f, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
else if let p = ProcessInfo.processInfo.environment["GLIDE_PASSWORD"] { password = p }
else if let p = config.password { password = p }
else {
    let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
    password = String((0..<12).map { _ in alphabet[Int.random(in: 0..<alphabet.count)] })
    config.password = password
    config.save()
    print("Generated password: \(password)  (saved to \(HostConfig.url.path))")
}
guard !password.isEmpty else { print("empty password"); exit(2) }
let salt = Data(hex: config.salt)!

var settings = HostSettings(password: password, salt: salt, passwordKey: Handshake.passwordKey(password, salt: salt))
if let v = takeValue("--port"), let n = UInt16(v) { settings.port = n }
if let v = takeValue("--fps"), let n = Int(v) { settings.fps = n }
if let v = takeValue("--bitrate-kbps"), let n = Int(v) { settings.bitrateKbps = n }
if let v = takeValue("--max-width"), let n = Int(v) { settings.maxWidth = n }
if let v = takeValue("--display"), let n = UInt32(v) { settings.displayID = n }
let connectTarget = takeValue("--connect") ?? config.connect
guard args.isEmpty else { print("unknown arguments: \(args)"); usage() }

// Permissions
if !CGPreflightScreenCaptureAccess() {
    log("Screen Recording permission missing — requesting (grant it in System Settings, then restart glide-host)")
    CGRequestScreenCaptureAccess()
}
if !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
    log("Accessibility permission missing — remote input will not work until granted")
}

// Listener
final class Server: @unchecked Sendable {
    let settings: HostSettings
    let listener: NWListener
    var current: Session?
    var nextId = 1
    let lock = NSLock()

    init(settings: HostSettings) throws {
        self.settings = settings
        listener = try NWListener(using: SecureChannel.tcpParameters(), on: NWEndpoint.Port(rawValue: settings.port)!)
    }

    /// Outbound mode: keep a connection to `host:port` alive, redialing after it drops.
    func dial(host: String, port: UInt16) {
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: SecureChannel.tcpParameters())
        log("dialer: connecting to \(host):\(port)")
        let redial = { [weak self] in
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { self?.dial(host: host, port: port) }
        }
        var sessionStarted = false
        conn.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready where !sessionStarted:
                sessionStarted = true
                // Hand the live connection to a Session (it re-installs its own state handler).
                self.adopt(conn, onEnd: redial)
            case .waiting(let e):
                log("dialer: waiting (\(e)); retrying"); conn.cancel(); redial()
            case .failed(let e) where !sessionStarted:
                log("dialer: failed (\(e)); retrying"); redial()
            default: break
            }
        }
        conn.start(queue: DispatchQueue(label: "glide.dialer"))
    }

    private func adopt(_ conn: NWConnection, onEnd extra: (() -> Void)? = nil) {
        lock.lock()
        let id = nextId; nextId += 1
        let old = current
        let s = Session(id: id, connection: conn, settings: settings)
        current = s
        lock.unlock()
        if let old { log("server: new connection replaces session \(old.id)"); old.end() }
        log("server: connection \(id) with \(conn.endpoint)")
        s.onEnd = { [weak self] ended in
            guard let self else { return }
            self.lock.lock(); if self.current === ended { self.current = nil }; self.lock.unlock()
            extra?()
        }
        s.start()
    }

    func start() {
        listener.newConnectionHandler = { [weak self] conn in
            guard let self else { return }
            self.adopt(conn); return
            self.lock.lock()
            let id = self.nextId; self.nextId += 1
            let old = self.current
            let s = Session(id: id, connection: conn, settings: self.settings)
            self.current = s
            self.lock.unlock()
            if let old { log("server: new connection replaces session \(old.id)"); old.end() }
            log("server: connection \(id) from \(conn.endpoint)")
            s.onEnd = { [weak self] ended in
                guard let self else { return }
                self.lock.lock(); if self.current === ended { self.current = nil }; self.lock.unlock()
            }
            s.start()
        }
        listener.stateUpdateHandler = { st in
            switch st {
            case .ready: log("server: listening on port \(self.settings.port)")
            case .failed(let e): log("server: listener failed: \(e)"); exit(1)
            default: break
            }
        }
        listener.start(queue: DispatchQueue(label: "glide.listener"))
    }
}

let app = NSApplication.shared
let sleepAssertion = Power.preventSystemSleep()
log(sleepAssertion != nil ? "power: preventing idle system sleep while the host runs" : "power: could not create sleep assertion")
app.setActivationPolicy(.prohibited)
let server = try Server(settings: settings)
if let target = connectTarget {
    let parts = target.split(separator: ":")
    server.dial(host: String(parts[0]), port: parts.count > 1 ? UInt16(parts[1]) ?? 7420 : 7420)
} else {
    server.start()
}
signal(SIGINT) { _ in exit(0) }
app.run()
