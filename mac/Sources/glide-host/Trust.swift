import AppKit
import CryptoKit
import Foundation
import GlideCore

/// Security v2 on the host (docs/PROTOCOL.md §2): the host's static key, the paired-viewer list,
/// the pairing window with its code confirmation (menu-bar alert or `glide-host --pair` over the
/// control socket), and the rate limiter.

/// The host's long-term X25519 key: `host-key` (64 hex chars) in the 0700 config folder, mode
/// 0600. A file rather than the Keychain on purpose: the host runs as a LaunchAgent on a usually
/// headless Mac, and a legacy-keychain item is bound to the code signature, so a rebuilt/re-signed
/// binary (or the CLI) could trigger an "allow access" prompt nobody can click; the data-protection
/// keychain needs a provisioning-profile entitlement this app doesn't have. Same-user code can read
/// the file, but same-user code could also replace the app itself. FileVault protects it at rest.
enum HostIdentity {
    static var url: URL { HostConfig.dir.appendingPathComponent("host-key") }

    /// Loads the key, creating it on first run. A present but unreadable file is fatal: silently
    /// replacing it would make every paired viewer report "host key changed".
    static func loadOrCreate() throws -> Curve25519.KeyAgreement.PrivateKey {
        if let d = try? Data(contentsOf: url) {
            let s = String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count == 64, let raw = Data(hex: s), raw.count == 32,
                  let k = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: raw) else {
                throw NSError(domain: "glide", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.path) is not a valid key (move it away to create a new one; all viewers must then pair again)"])
            }
            return k
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "glide", code: 2, userInfo: [NSLocalizedDescriptionKey: "cannot read \(url.path)"])
        }
        let k = Curve25519.KeyAgreement.PrivateKey()
        let tmp = url.appendingPathExtension("tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: Data((k.rawRepresentation.hex + "\n").utf8), attributes: [.posixPermissions: 0o600]),
              rename(tmp.path, url.path) == 0 else {
            throw NSError(domain: "glide", code: 3, userInfo: [NSLocalizedDescriptionKey: "cannot write \(url.path)"])
        }
        log("identity: created this Mac's key \(GlideHandshake.fingerprint(k.publicKey.rawRepresentation)) at \(url.path)")
        return k
    }
}

/// The paired viewers (host.json `pairedViewers`), cached in memory, persisted on change.
final class TrustStore: @unchecked Sendable {
    static let shared = TrustStore()
    private let lock = NSLock()
    private var viewers: [PairedViewer] = []

    func load(_ c: HostConfig) {
        lock.lock(); viewers = (c.pairedViewers ?? []).filter { $0.keyData != nil }; lock.unlock()
        HostStatus.shared.update { $0.pairedViewers = self.list }
    }

    var list: [PairedViewer] { lock.lock(); defer { lock.unlock() }; return viewers }

    func isPaired(_ key: Data) -> Bool { lock.lock(); defer { lock.unlock() }; return PairedViewers.contains(viewers, key: key) }

    func name(of key: Data) -> String? { lock.lock(); defer { lock.unlock() }; return viewers.first { $0.keyData == key }?.name }

    func add(name: String, key: Data) {
        lock.lock()
        viewers = PairedViewers.adding(viewers, name: name, key: key, at: Date())
        let v = viewers
        lock.unlock()
        persist(v)
    }

    /// Removes by full key hex, key prefix (≥ 8 hex chars), fingerprint prefix, or exact name.
    /// Returns the removed entries.
    @discardableResult
    func remove(matching q: String) -> [PairedViewer] {
        let needle = q.lowercased().replacingOccurrences(of: " ", with: "")
        lock.lock()
        let gone = viewers.filter { v in
            v.name == q || (needle.count >= 8 && (v.key.lowercased().hasPrefix(needle) || v.fingerprint.replacingOccurrences(of: " ", with: "").hasPrefix(needle)))
        }
        viewers.removeAll { v in gone.contains(v) }
        let v = viewers
        lock.unlock()
        if !gone.isEmpty { persist(v) }
        return gone
    }

    private func persist(_ v: [PairedViewer]) {
        HostConfig.modify { $0.pairedViewers = v }
        HostStatus.shared.update { $0.pairedViewers = v }
    }
}

/// One pairing waiting for the Mac user's answer.
struct PendingPairing {
    let sessionId: Int
    let viewerName: String
    let viewerFingerprint: String
    let address: String
    /// SAS, 6 digits.
    let code: UInt32
    let answer: (Bool) -> Void
}

/// The pairing window, the confirmation UI (menu-bar alert + control-socket CLI) and the rate
/// limiter. Thread-safe; UI work hops to the main queue.
final class PairingController: NSObject, @unchecked Sendable {
    static let shared = PairingController()
    let window = PairingWindow()
    let backoff = HandshakeBackoff()
    /// Called (main queue) when the window opens, so the dialer redials right away.
    var onOpen: (() -> Void)?
    /// Show the menu-bar alert (false for --selftest-ui / tests).
    var showAlerts = true

    private let lock = NSLock()
    private var pending: PendingPairing?
    private var alert: NSAlert?
    private var expiry: DispatchWorkItem?
    /// `glide-host --pair` clients waiting for events.
    private var watchers: [ControlClientRef] = []

    // MARK: Window

    func openWindow(source: String, duration: TimeInterval = PairingWindow.defaultDuration) {
        window.open(duration: duration)
        backoff.reset()
        let until = Date().addingTimeInterval(duration)
        HostStatus.shared.update { $0.pairingUntil = until; $0.note = nil }
        log("pairing: window open for \(Int(duration)) s (\(source))")
        let work = DispatchWorkItem { [weak self] in self?.windowExpired() }
        lock.lock(); expiry?.cancel(); expiry = work; lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.2, execute: work)
        DispatchQueue.main.async { self.onOpen?() }
    }

    func cancelWindow(source: String) {
        window.close()
        // A pairing still waiting for its confirmation ends with the window.
        lock.lock(); let p = pending; lock.unlock()
        if let p { answer(false, via: "pairing window cancelled", sessionId: p.sessionId) }
        HostStatus.shared.update { $0.pairingUntil = nil }
        log("pairing: window closed (\(source))")
        broadcast("done closed")
    }

    private func windowExpired() {
        guard !window.isOpen() else { return }
        HostStatus.shared.update { $0.pairingUntil = nil }
        lock.lock(); let busy = pending != nil; lock.unlock()
        if !busy { log("pairing: window expired"); broadcast("done closed") }
    }

    // MARK: Confirmation

    /// A viewer is waiting: ask the Mac user (alert + CLI watchers). `answer` gets the first
    /// answer; `dismiss` cancels if the session ends first.
    func ask(_ p: PendingPairing) {
        lock.lock(); pending = p; lock.unlock()
        HostStatus.shared.update { $0.pairingWith = p.viewerName }
        broadcast("code \(String(format: "%06u", p.code)) \(p.viewerFingerprint.replacingOccurrences(of: " ", with: "")) \(p.viewerName)")
        guard showAlerts else { return }
        DispatchQueue.main.async { self.showAlert(p) }
    }

    /// Answer the pending pairing for `sessionId` (if still pending). Returns false if none.
    @discardableResult
    func answer(_ ok: Bool, via: String, sessionId: Int? = nil) -> Bool {
        lock.lock()
        guard let p = pending, sessionId == nil || sessionId == p.sessionId else { lock.unlock(); return false }
        pending = nil
        lock.unlock()
        log("pairing: Mac user \(ok ? "confirmed" : "declined") the code for “\(p.viewerName)” (\(via))")
        DispatchQueue.main.async { self.closeAlert() }
        p.answer(ok)
        return true
    }

    /// `glide-host --pair-code NNNNNN`: confirm iff the code matches (a typed code is compared by
    /// the machine, so the user can't just click through).
    func answer(code: String) -> String {
        let digits = code.filter(\.isNumber)
        lock.lock(); let p = pending; lock.unlock()
        guard let p else { return "error no viewer is waiting to pair (open the window with glide-host --pair, then connect the viewer)" }
        let ok = digits.count == 6 && UInt32(digits) == p.code
        answer(ok, via: "typed code", sessionId: p.sessionId)
        return ok ? "ok confirmed — waiting for the PC to confirm too" : "error code mismatch — pairing declined (the PC may be talking to someone else)"
    }

    /// The session ended or the viewer answered no / timed out: withdraw the question.
    func finished(sessionId: Int, result: String) {
        lock.lock()
        let was = pending?.sessionId == sessionId
        if was { pending = nil }
        lock.unlock()
        HostStatus.shared.update { $0.pairingWith = nil }
        if was { DispatchQueue.main.async { self.closeAlert() } }
        broadcast("done \(result)")
        if !window.isOpen() { HostStatus.shared.update { $0.pairingUntil = nil } }
    }

    var pendingCode: UInt32? { lock.lock(); defer { lock.unlock() }; return pending?.code }

    // MARK: Alert (menu-bar app; non-modal so the host keeps running)

    /// Builds the alert (also used by --selftest-ui).
    static func makeAlert(name: String, fingerprint: String, address: String, code: UInt32) -> NSAlert {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Pair “\(name)” with this Mac?"
        a.informativeText = "Only continue if the PC shows exactly the same code. Confirm on the PC as well.\n\nViewer key: \(fingerprint)\nFrom: \(address)\n\nIf the codes differ, click Cancel: someone may be intercepting the connection."
        let label = NSTextField(labelWithString: GlideHandshake.sasText(code))
        label.font = .monospacedDigitSystemFont(ofSize: 36, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: 260, height: 48)
        a.accessoryView = label
        a.addButton(withTitle: "Codes Match — Pair")
        a.addButton(withTitle: "Cancel")
        return a
    }

    private func showAlert(_ p: PendingPairing) {
        closeAlert()
        let a = Self.makeAlert(name: p.viewerName, fingerprint: p.viewerFingerprint, address: p.address, code: p.code)
        a.buttons[0].target = self; a.buttons[0].action = #selector(matchClicked); a.buttons[0].tag = p.sessionId
        a.buttons[1].target = self; a.buttons[1].action = #selector(cancelClicked); a.buttons[1].tag = p.sessionId
        a.layout()
        a.window.level = .floating
        a.window.center()
        NSApp.activate(ignoringOtherApps: true)
        a.window.makeKeyAndOrderFront(nil)
        alert = a
    }

    private func closeAlert() {
        alert?.window.orderOut(nil)
        alert = nil
    }

    @objc private func matchClicked(_ b: NSButton) { answer(true, via: "menu-bar alert", sessionId: b.tag) }
    @objc private func cancelClicked(_ b: NSButton) { answer(false, via: "menu-bar alert", sessionId: b.tag) }

    // MARK: Control socket (glide-host --pair / --pair-code / --paired / --unpair)

    /// `control.sock` in the config folder ($GLIDE_HOST_CONTROL_SOCKET overrides, e.g. for a test
    /// instance whose config folder path is too long for a socket address).
    static var socketPath: String {
        if let p = ProcessInfo.processInfo.environment["GLIDE_HOST_CONTROL_SOCKET"], !p.isEmpty { return p }
        return HostConfig.dir.appendingPathComponent("control.sock").path
    }
    private var server: ControlServer?

    func startControlSocket() {
        let s = ControlServer(path: Self.socketPath) { [weak self] line, client in self?.control(line, client) }
        do { try s.start(); server = s; log("control: listening on \(Self.socketPath)") }
        catch { log("control: not available: \(error)") }
    }

    private func broadcast(_ line: String) {
        lock.lock(); watchers.removeAll { $0.isClosed }; let w = watchers; lock.unlock()
        for c in w { c.send(line) }
    }

    private func control(_ line: String, _ c: ControlClientRef) {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first ?? "" {
        case "open":
            openWindow(source: "glide-host --pair")
            c.send("ok open \(Int(PairingWindow.defaultDuration))")
        case "wait":
            lock.lock(); watchers.append(c); let p = pending; lock.unlock()
            if let p { c.send("code \(String(format: "%06u", p.code)) \(p.viewerFingerprint.replacingOccurrences(of: " ", with: "")) \(p.viewerName)") }
        case "code":
            c.send(answer(code: parts.count > 1 ? parts[1] : ""))
        case "cancel":
            cancelWindow(source: "glide-host CLI")
            c.send("ok closed")
        case "list":
            for v in TrustStore.shared.list { c.send("viewer \(v.key) \(v.paired) \(v.name)") }
            c.send("end")
        case "unpair":
            let gone = TrustStore.shared.remove(matching: parts.count > 1 ? parts[1] : "")
            if gone.isEmpty { c.send("error no paired viewer matches") }
            else {
                for v in gone { log("pairing: removed viewer “\(v.name)” (\(v.fingerprint)) via CLI") }
                DispatchQueue.main.async { self.onRemove?(gone) }
                c.send("ok removed \(gone.map(\.name).joined(separator: ", "))")
            }
        case "identity":
            c.send("identity \(HostStatus.shared.snapshot.hostFingerprint ?? "?")")
        default:
            // Instance coordination (Instance.swift): instance / show-setup / handoff / quit.
            if let reply = instanceCommand?(line) { c.send(reply) } else { c.send("error unknown command") }
        }
    }

    /// Handles the instance commands; nil = unknown.
    var instanceCommand: ((String) -> String?)?

    /// Called (main queue) after viewers were removed, so their sessions can be ended.
    var onRemove: (([PairedViewer]) -> Void)?
}
