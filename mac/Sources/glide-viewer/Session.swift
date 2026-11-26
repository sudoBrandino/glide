import AppKit
import CryptoKit
import Foundation
import GlideCore
import Network

/// The viewer's persistent files. viewer.json writes are a locked read-modify-write, so another
/// viewer process editing the same file at the same time loses nothing.
enum ViewerStore {
    static func load() throws -> ViewerConfig {
        try ConfigFile.read(ViewerConfig.self, from: ViewerPaths.config) ?? ViewerConfig()
    }

    /// Applies `change` to viewer.json. Errors are logged (and returned).
    @discardableResult
    static func update(_ change: (inout ViewerConfig) -> Void) -> Error? {
        do {
            try ViewerPaths.ensureDirectory()
            // Several glide-viewer processes share viewer.json: hold an exclusive lock on a
            // sidecar file across the whole read-modify-write so no update (a new pin) is lost.
            let lockPath = ViewerPaths.config.path + ".lock"
            let fd = open(lockPath, O_RDWR | O_CREAT, 0o600)
            if fd >= 0 { _ = flock(fd, LOCK_EX) }
            defer { if fd >= 0 { _ = flock(fd, LOCK_UN); _ = Darwin.close(fd) } }
            _ = try ConfigFile.update(ViewerPaths.config, defaults: { ViewerConfig() }) { c in change(&c) }
            return nil
        } catch {
            print("error: \(error)")
            return error
        }
    }
}

/// Which stream messages one connection may deliver, read and written on the network queue and
/// the main thread. Nothing reaches the decoder until this viewer has sent ClientHello (so it has
/// authenticated the host, or finished pairing), and no frame until a ServerHello followed it: an
/// unpaired peer can't stream during the pairing prompt or lift the pre-auth record cap.
final class StreamGate: @unchecked Sendable {
    private let lock = NSLock()
    private var helloSent = false
    private var streaming = false

    func openHello() { lock.lock(); helloSent = true; lock.unlock() }

    /// A ServerHello arrived: true if it is allowed (ClientHello was sent), and streaming starts.
    func acceptServerHello() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if helloSent { streaming = true }
        return helloSent
    }

    var isStreaming: Bool { lock.lock(); defer { lock.unlock() }; return streaming }
}

/// One viewer window connected to one host: connection, handshake and pairing (PROTOCOL.md
/// §1–2), the stream (§3), input, and reconnecting. Everything here runs on the main thread
/// except the channel callbacks and the decoder, which run on `net` (see `received`).
final class ViewerSession: NSObject, VideoViewInput, KeySink {
    enum Phase: Equatable { case idle, connecting, handshaking, pairing, authenticating, streaming, stopped }

    let target: ViewerTarget
    let connectionID: String?
    /// What the user called it (saved connection name, else the address).
    let label: String
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private var forcePair: Bool
    /// The host answered AuthResult 1 (it forgot us): pair again, still requiring the pinned key.
    private var repair = false
    private let wantFullscreen: Bool
    /// Called once the window is closed.
    var onEnd: (() -> Void)?

    let window: NSWindow
    private let video: VideoView
    private let status: NSTextField
    private let keys: KeyCapture

    private let net = DispatchQueue(label: "glide.viewer.net", qos: .userInteractive)
    private var channel: SecureChannel?
    private var gate = StreamGate()
    private var generation = 0
    private(set) var phase: Phase = .idle
    private var backoff = ReconnectBackoff()
    private var retryWork: DispatchWorkItem?
    private var deadlineWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var hostName = ""
    private var config: VideoConfig?
    private var sentViewSize: (w: Int, h: Int)?
    private var lastKeyframeRequest = Date.distantPast
    private var scroll = ScrollAccumulator()
    private var pendingPair: SecureChannel.ViewerConnected?
    private var pairConfirmed = false
    private var pairingAlert: NSAlert?
    private var cursorShapes: [UInt32: HostCursorShape] = [:]
    private var cursorBytes = 0
    private var rttText = ""
    /// ⌃⌥⇧K: keys stay with this Mac until the user clicks the session (or the window becomes
    /// key again, or ⌃⌥⇧K once more).
    private(set) var keyboardReleased = false
    /// The session menu (⌃⌥⇧Space) is tracking: its keys must reach the menu.
    private var menuOpen = false
    private var hintShown = false
    private let toast = ToastView()
    /// Builds the session menu (⌃⌥⇧Space); set by the app.
    var sessionMenu: (() -> NSMenu?)?
    /// Managed session (ENTERPRISE.md §5.3): the cloud connector, else nil for a LAN connection.
    /// It never reconnects on its own: every attempt is a new session request (and approval).
    let cloud: CloudConnector?

    init(target: ViewerTarget, connectionID: String?, label: String, identity: Curve25519.KeyAgreement.PrivateKey,
         remap: Bool, forcePair: Bool, fullscreen: Bool, cloud: CloudConnector? = nil) {
        self.cloud = cloud
        self.target = target
        self.connectionID = connectionID
        self.label = label
        self.identity = identity
        self.forcePair = forcePair
        self.wantFullscreen = fullscreen
        keys = KeyCapture(remap: remap)

        let frame = NSRect(x: 0, y: 0, width: 960, height: 540)
        let w = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        w.title = label
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black

        let container = NSView(frame: frame)
        container.wantsLayer = true
        let v = VideoView(frame: container.bounds)
        v.autoresizingMask = [.width, .height]
        container.addSubview(v)
        let st = NSTextField(wrappingLabelWithString: "")
        st.textColor = .white
        st.alignment = .center
        st.font = NSFont.systemFont(ofSize: 15)
        st.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(st)
        NSLayoutConstraint.activate([
            st.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            st.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            st.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        toast.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toast)
        NSLayoutConstraint.activate([
            toast.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            toast.topAnchor.constraint(equalTo: container.topAnchor, constant: 24),
            toast.widthAnchor.constraint(lessThanOrEqualTo: container.widthAnchor, constant: -40),
        ])
        w.contentView = container
        window = w
        video = v
        status = st
        super.init()
        window.delegate = self
        video.input = self
        keys.sink = self
    }

    func start() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(video)
        NSApp.activate(ignoringOtherApps: true)
        if wantFullscreen { window.toggleFullScreen(nil) }
        keys.start()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged(_:)),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(managedPolicyChanged(_:)),
                                               name: ManagedViewer.changed, object: nil)
        connect()
    }

    /// LAN settings at runtime (ENTERPRISE.md §6.7): when `lan_mode` becomes false a LAN session
    /// ends at once (connecting, pairing, streaming or waiting to retry); a pairing in progress
    /// ends when `allow_local_pairing` becomes false. Managed sessions are not affected.
    @objc private func managedPolicyChanged(_ n: Notification) {
        guard phase != .stopped else { return }
        let mv = ManagedViewer.shared
        guard ViewerLANGate.mustEnd(managedSession: cloud != nil, pairing: phase == .pairing, policy: mv.policy) else { return }
        if let why = mv.lanBlockedReason {
            print("LAN mode turned off (\(why)): ending the session with \(label)")
            stop(message: "LAN connections were \(why), so the session with \(label) ended.")
        } else {
            print("pairing turned off by \(mv.orgName): ending the pairing with \(label)")
            stop(message: pairingOffText)
        }
    }

    /// A LAN pairing may start (§6.7: never while `allow_local_pairing` or `lan_mode` is false).
    private var mayPair: Bool { ViewerLANGate.mayPair(managedSession: cloud != nil, policy: ManagedViewer.shared.policy) }

    private var pairingOffText: String {
        "Pairing is turned off by \(ManagedViewer.shared.orgName). Ask your administrator, or connect through your organization's list."
    }

    // MARK: Status

    private func setStatus(_ text: String?) {
        status.stringValue = text ?? ""
        status.isHidden = text == nil
        if let text { print(text) }
    }

    private func updateTitle() {
        var t = hostName.isEmpty ? label : hostName
        if let c = cloud {
            t += " — via Glide Cloud"
            if c.permissions?.control == false { t += " (view only)" }
        }
        if !rttText.isEmpty { t += " — \(rttText)" }
        if keyboardReleased { t += " — keyboard released" }
        window.title = t
    }

    /// The shortcut hint, once per session when the stream starts, and on entering full screen.
    private func showShortcutHint() {
        toast.show(ShortcutBindings.hint, seconds: 5)
    }

    // MARK: Connection

    private func connect() {
        retryWork?.cancel()
        retryWork = nil
        generation += 1
        let gen = generation
        phase = .connecting
        pendingPair = nil
        pairConfirmed = false
        if let cloud {
            connectCloud(cloud, gen: gen)
            return
        }
        if let why = ManagedViewer.shared.lanBlockedReason {
            stop(message: "LAN connections are \(why). Connect through your organization's list instead.")
            return
        }
        setStatus("Connecting to \(label)…")
        guard let port = NWEndpoint.Port(rawValue: target.port) else { stop(message: "Bad port \(target.port)"); return }
        let conn = NWConnection(host: NWEndpoint.Host(target.host), port: port, using: SecureChannel.tcpParameters())
        attach(conn, gen: gen)
        let label = self.label
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready:
                DispatchQueue.main.async { self?.connected(gen) }
            case .failed(let e):
                DispatchQueue.main.async { self?.failed(gen, "Can't connect to \(label) (\(e))", retryAfter: nil) }
            case .waiting(let e):
                DispatchQueue.main.async { self?.failed(gen, "Can't reach \(label) (\(e))", retryAfter: nil) }
            default:
                break
            }
        }
        arm(gen, seconds: 10, what: "connecting")
        conn.start(queue: net)
    }

    /// A managed session: ask Glide Cloud (waiting for the host's approval), then the relay; the
    /// loopback connection it hands over is used like a dialed one (§6.6).
    private func connectCloud(_ c: CloudConnector, gen: Int) {
        // POST /v1/sessions may wait 60 s for an approval, the relay 60 s for the host.
        arm(gen, seconds: 150, what: "waiting for the session")
        c.open(queue: net, status: { [weak self] text in
            guard let self, self.generation == gen, self.phase == .connecting else { return }
            self.setStatus(text)
        }, completion: { [weak self] r in
            guard let self, self.generation == gen, self.phase == .connecting else {
                if case let .success(conn) = r { conn.cancel() }
                return
            }
            switch r {
            case let .failure(f): self.stop(message: f.text)
            case let .success(conn):
                self.attach(conn, gen: gen)
                conn.stateUpdateHandler = { [weak self] st in
                    switch st {
                    case .failed, .cancelled: DispatchQueue.main.async { self?.closed(gen, nil) }
                    default: break
                    }
                }
                self.connected(gen)
            }
        })
    }

    /// The channel, decoder and message handlers for connection attempt `gen`.
    private func attach(_ conn: NWConnection, gen: Int) {
        let ch = SecureChannel(connection: conn, queue: net)
        ch.maxRecordBytes = SecureChannel.preAuthMaxRecord
        channel = ch
        let gate = StreamGate()
        self.gate = gate
        let decoder = VideoDecoder()
        decoder.onFrame = { [weak self] pb in
            DispatchQueue.main.async { if let self, self.generation == gen { self.video.show(pb) } }
        }
        decoder.onError = { [weak self] why in
            DispatchQueue.main.async { self?.decodeError(gen, why) }
        }
        let perms = cloud?.permissions
        ch.onMessage = { [weak self, weak ch] d in
            guard let ch else { return }
            self?.received(d, gen: gen, channel: ch, decoder: decoder, gate: gate, permissions: perms)
        }
        ch.onClose = { [weak self] err in DispatchQueue.main.async { self?.closed(gen, err) } }
    }

    /// Fails attempt `gen` if it hasn't got past the pre-auth phases within `seconds`.
    private func arm(_ gen: Int, seconds: TimeInterval, what: String) {
        deadlineWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            switch self.phase {
            case .connecting, .handshaking, .pairing, .authenticating:
                self.failed(gen, "Timed out \(what) (\(self.label))", retryAfter: nil)
            default: break
            }
        }
        deadlineWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: w)
    }

    private func connected(_ gen: Int) {
        guard gen == generation, phase == .connecting, let ch = channel else { return }
        phase = .handshaking
        // Pre-auth deadline (PROTOCOL.md §2.4): 5 s for the handshake and PairReveal / ServerHello.
        arm(gen, seconds: 5, what: "waiting for the host")
        let pinned = currentPin()
        // A managed session never pairs: the cloud named the host key (pinned in memory).
        if cloud != nil, pinned == nil { stop(message: "Glide Cloud didn't name the computer's key."); return }
        let wantsPairing = cloud == nil && (forcePair || repair)
        if wantsPairing, !mayPair {
            stop(message: pairingOffText)
            return
        }
        ch.performHandshake(identity: identity, name: Host.current().localizedName ?? "Mac", pinned: pinned,
                            requestPairing: cloud == nil && (forcePair || repair) && mayPair, requireOpenPairingWindow: true) { [weak self] res in
            DispatchQueue.main.async { self?.handshakeDone(gen, res) }
        }
    }

    private func currentPin() -> Data? {
        if let cloud { return cloud.pin?.hostKey }  // relay:<session_id>, never viewer.json
        return (try? ViewerStore.load())?.pinnedKey(for: target)
    }

    private func handshakeDone(_ gen: Int, _ res: Result<SecureChannel.ViewerConnected, Error>) {
        guard gen == generation, phase == .handshaking, let ch = channel else { return }
        switch res {
        case .failure(let e):
            cloud?.reportError("handshake_failed", "\(e)")
            switch e {
            case SecureChannel.ViewerFailure.hostKeyChanged(_, let presented) where cloud != nil:
                stop(message: "The computer presented a key (\(GlideHandshake.fingerprint(presented))) that isn't the one Glide Cloud named. Not connecting.")
            case SecureChannel.ViewerFailure.hostKeyChanged(_, let presented):
                stop(message: ViewerStatusText.hostKeyChanged(host: target.display, presented: presented))
                showAlert("Host key changed", ViewerStatusText.hostKeyChanged(host: target.display, presented: presented))
            case SecureChannel.ViewerFailure.hostPairingClosed:
                failed(gen, ViewerStatusText.pairingClosed(host: label), retryAfter: 3)
            case SecureChannel.ViewerFailure.hostIsV1:
                failed(gen, "\(label) closed the connection without answering (not a Glide v2 host?)", retryAfter: nil)
            case GlideHandshake.HandshakeError.status(let version, let st):
                let text = ViewerStatusText.refused(status: st, version: version, host: label)
                if st == GlideHandshake.statusUnsupportedVersion { stop(message: text) } else { failed(gen, text, retryAfter: st == GlideHandshake.statusRateLimited ? 5 : nil) }
            default:
                failed(gen, "Handshake with \(label) failed: \(e)", retryAfter: nil)
            }
        case .success(let vc):
            if vc.pairing, !mayPair {
                // The host started a pairing this Mac may not take part in.
                stop(message: cloud != nil ? "\(label) asked to pair over Glide Cloud. Not connecting." : pairingOffText)
                return
            }
            if vc.pairing {
                phase = .pairing
                pendingPair = vc
                setStatus("Pairing with \(label)…")
            } else {
                phase = .authenticating
                sendHello(ch)
            }
            ch.startReceiving()
        }
    }

    private func sendHello(_ ch: SecureChannel) {
        let s = window.screen ?? NSScreen.main
        let px = screenPixels(s)
        sentViewSize = px
        gate.openHello()
        let fps = s?.maximumFramesPerSecond ?? 60
        var hello = ViewerHello.message(viewW: px.w, viewH: px.h, maxFps: fps, name: Host.current().localizedName ?? "Mac")
        if let p = cloud?.permissions, case let .hello(v, caps, w, h, mode, f, n) = hello {
            hello = .hello(version: v, caps: ManagedPermissions.viewerCaps(caps, p), viewW: w, viewH: h, mode: mode, maxFps: f, name: n)
        }
        ch.send(hello.encoded)
    }

    private func screenPixels(_ s: NSScreen?) -> (w: Int, h: Int) {
        guard let s else { return (1920, 1080) }
        return (Int((s.frame.width * s.backingScaleFactor).rounded()), Int((s.frame.height * s.backingScaleFactor).rounded()))
    }

    /// Channel callback, on `net`. Video stays on this queue (decoder order = stream order);
    /// everything else goes to the main thread.
    private func received(_ d: Data, gen: Int, channel ch: SecureChannel, decoder: VideoDecoder, gate: StreamGate, permissions: CloudPermissions?) {
        guard let m = try? HostMessage.decode(d) else { return }  // unknown message types are ignored
        // Managed sessions also enforce the permissions on what the host sends (§6.3).
        if let p = permissions, !ManagedPermissions.viewerAccepts(m, p) { return }
        switch m {
        case let .videoFrame(_, _, _, _, sharp, _, data):
            // Fast mode only: no sharp layer, and every base frame is decoded and shown whole.
            guard gate.isStreaming, !sharp else { return }
            decoder.decode(data)
            return
        case let .serverHello(_, _, cfg):
            // Before ClientHello (during pairing) a ServerHello is a protocol violation: drop the
            // connection rather than configure the stream.
            guard gate.acceptServerHello() else {
                ch.close()
                return
            }
            decoder.reset(codec: cfg.codec)
            ch.maxRecordBytes = RecordCipher.maxRecord
        case let .videoConfig(cfg):
            guard gate.isStreaming else { return }
            decoder.reset(codec: cfg.codec)
        default:
            break
        }
        DispatchQueue.main.async { [weak self] in self?.handle(m, gen) }
    }

    private func handle(_ m: HostMessage, _ gen: Int) {
        guard gen == generation, let ch = channel else { return }
        switch m {
        case let .pairReveal(nH):
            guard phase == .pairing, let vc = pendingPair, pairingAlert == nil, !pairConfirmed else { return }
            guard mayPair else { stop(message: pairingOffText); return }
            guard GlideHandshake.commitment(nH) == vc.hostInfo.commitment else {
                stop(message: "Pairing failed: the host's pairing nonce doesn't match its commitment.")
                return
            }
            // The host has committed: now involve the user, with a total of 120 s.
            deadlineWork?.cancel()
            arm(gen, seconds: 120, what: "waiting for the codes to be confirmed")
            let code = GlideHandshake.sasText(GlideHandshake.sasCode(handshakeHash: vc.handshakeHash, viewerNonce: vc.viewerNonce, hostNonce: nH))
            print("pairing with \(target.display): code \(code) (host key \(GlideHandshake.fingerprint(vc.hostKey)))")
            askToPair(gen, code: code, hostKey: vc.hostKey, channel: ch)
        case let .authResult(code):
            dismissPairingAlert()
            if code == .ok, phase == .pairing, pairConfirmed, let vc = pendingPair {
                let t = target, key = vc.hostKey
                ViewerStore.update { $0.pin(t, key: key, name: "", at: Date()) }
                print("paired; pinned host key \(GlideHandshake.fingerprint(key)) for \(t.pinKey)")
                repair = false
                forcePair = false
                pendingPair = nil
                phase = .authenticating
                setStatus("Paired. Starting the stream…")
                arm(gen, seconds: 5, what: "waiting for the host")
                sendHello(ch)
                return
            }
            let text = ViewerStatusText.authResult(code, host: label)
            if cloud != nil {
                cloud?.reportError("handshake_failed", "the host refused the session (\(code))")
                stop(message: "\(label) refused the managed session (\(code)).")
                return
            }
            switch code {
            case .unknownViewer where !mayPair:
                stop(message: "\(text)\n\n\(pairingOffText)")
            case .unknownViewer:
                repair = true
                failed(gen, text, retryAfter: 2)
            case .pairingClosed: failed(gen, text, retryAfter: 3)
            case .busy: failed(gen, text, retryAfter: 5)
            case .declined, .timeout, .ok: stop(message: text)
            }
        case let .serverHello(_, name, cfg):
            guard phase == .authenticating else { return }
            phase = .streaming
            deadlineWork?.cancel()
            backoff.reset()
            hostName = name
            if cloud == nil {
                let t = target, id = connectionID, key = currentPin()
                ViewerStore.update { c in
                    c.markConnected(id: id, target: t, at: Date())
                    if let key { c.renamePin(t, key: key, name: name) }
                }
            }
            print("connected to '\(name)': \(cfg.width)x\(cfg.height) \(cfg.codec)")
            setStatus(nil)
            video.clear()
            video.resetHostCursor()
            cursorShapes.removeAll()
            cursorBytes = 0
            video.active = true
            applyConfig(cfg)
            startPing()
            updateTitle()
            if !window.isKeyWindow { releaseAll() }
            if !hintShown {
                hintShown = true
                showShortcutHint()
            }
        case let .videoConfig(cfg):
            applyConfig(cfg)
        case let .pong(c, _):
            let now = hostTimeMicros()
            if now >= c { rttText = String(format: "%.1f ms", Double(now - c) / 1000) }
            updateTitle()
        case let .cursorShape(id, w, h, hx, hy, bgra):
            guard w <= 256, h <= 256 else { return }
            let s = HostCursorShape(w: Int(w), h: Int(h), hotX: Int(hx), hotY: Int(hy), bgra: bgra)
            if cursorShapes.count >= 1024 || cursorBytes + bgra.count > 64 << 20 { cursorShapes.removeAll(); cursorBytes = 0 }
            cursorShapes[id] = s
            cursorBytes += bgra.count
            video.setHostCursor(s)
        case let .cursorShapeRef(id):
            if let s = cursorShapes[id] { video.setHostCursor(s) }
        case let .cursorPos(_, _, visible):
            video.setHostCursorVisible(visible)
        default:
            break
        }
    }

    private func applyConfig(_ cfg: VideoConfig) {
        let changed = config.map { $0.width != cfg.width || $0.height != cfg.height } ?? true
        config = cfg
        video.videoSize = CGSize(width: CGFloat(cfg.width), height: CGFloat(cfg.height))
        guard changed, cfg.width > 0, cfg.height > 0 else { return }
        window.contentAspectRatio = NSSize(width: CGFloat(cfg.width), height: CGFloat(cfg.height))
        guard !window.styleMask.contains(.fullScreen) else { return }
        // 1:1 physical pixels, shrunk (aspect kept) to fit the screen.
        let scale = window.backingScaleFactor
        var size = NSSize(width: CGFloat(cfg.width) / scale, height: CGFloat(cfg.height) / scale)
        if let vis = (window.screen ?? NSScreen.main)?.visibleFrame {
            let maxContent = window.contentRect(forFrameRect: vis).size
            let fit = PointerMath.fitRect(content: size, in: CGRect(origin: .zero, size: maxContent))
            if fit.width < size.width { size = fit.size }
        }
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        let old = window.frame
        frame.origin = NSPoint(x: old.midX - frame.width / 2, y: old.maxY - frame.height)
        if let vis = (window.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.origin.x, vis.minX), max(vis.maxX - frame.width, vis.minX))
            frame.origin.y = min(max(frame.origin.y, vis.minY), max(vis.maxY - frame.height, vis.minY))
        }
        window.setFrame(frame, display: true)
    }

    private func decodeError(_ gen: Int, _ why: String) {
        guard gen == generation, phase == .streaming else { return }
        let now = Date()
        guard now.timeIntervalSince(lastKeyframeRequest) > 0.5 else { return }
        lastKeyframeRequest = now
        print("decode problem (\(why)); requesting a keyframe")
        channel?.send(ClientMessage.requestKeyframe.encoded)
    }

    private func startPing() {
        pingTimer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, self.phase == .streaming else { return }
            self.channel?.send(ClientMessage.ping(clientTimeUs: hostTimeMicros()).encoded)
        }
        RunLoop.main.add(t, forMode: .common)
        pingTimer = t
        channel?.send(ClientMessage.ping(clientTimeUs: hostTimeMicros()).encoded)
    }

    /// Ends attempt / session `gen` and, unless told otherwise, reconnects with backoff.
    private func failed(_ gen: Int, _ message: String, retryAfter: TimeInterval?) {
        guard gen == generation, phase != .stopped else { return }
        if cloud != nil {
            // No automatic retry: it would be a new session request for the host to approve.
            stop(message: message)
            return
        }
        drop()
        let delay = retryAfter ?? backoff.next()
        phase = .idle
        setStatus("\(message)\nRetrying in \(Int(delay.rounded())) s…")
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .idle else { return }
            self.connect()
        }
        retryWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    /// The channel closed (by the host or the network).
    private func closed(_ gen: Int, _ err: Error?) {
        guard gen == generation, phase != .stopped else { return }
        let why = err.map { "\($0)" } ?? "closed"
        if cloud != nil {
            stop(message: phase == .streaming ? "The session with \(label) ended." : "\(label) closed the connection (\(why)).")
            return
        }
        switch phase {
        case .streaming: failed(gen, "Connection to \(label) lost (\(why))", retryAfter: 1)
        case .pairing: failed(gen, "Pairing failed: the host closed the connection", retryAfter: nil)
        default: failed(gen, "\(label) closed the connection (\(why))", retryAfter: nil)
        }
    }

    /// Closes the current connection without reporting it.
    private func drop() {
        generation += 1
        deadlineWork?.cancel()
        deadlineWork = nil
        pingTimer?.invalidate()
        pingTimer = nil
        dismissPairingAlert()
        if phase == .streaming { channel?.send(ClientMessage.releaseAll.encoded) }
        channel?.close()
        channel = nil
        cloud?.close(byUser: false)
        pendingPair = nil
        pairConfirmed = false
        config = nil
        rttText = ""
        video.active = false
        scroll.reset()
        updateTitle()
    }

    /// Gives up (no reconnect) and shows `message`.
    private func stop(message: String?) {
        drop()
        retryWork?.cancel()
        retryWork = nil
        phase = .stopped
        setStatus(message.map { "\($0)\n\nUse Connection → Reconnect to try again, or Disconnect to go back to your connections." } ?? "Disconnected.")
    }

    @objc func reconnect(_ sender: Any?) {
        drop()
        backoff.reset()
        phase = .idle
        connect()
    }

    /// Settings changed the modifier remap: applies from the next key. Held keys are released
    /// first, so a modifier pressed under the old mapping doesn't stay down on the PC.
    func setRemap(_ on: Bool) {
        guard keys.remap != on else { return }
        releaseAll()
        keys.remap = on
    }

    /// ⌃⌥⇧K / Connection → Release Keyboard: stop (or resume) sending keys to the PC. Held
    /// keys are released on the PC first.
    func setKeyboardReleased(_ released: Bool) {
        guard released != keyboardReleased else { return }
        releaseAll()
        keyboardReleased = released
        updateTitle()
        if released {
            toast.show("Keyboard released: shortcuts stay on this Mac. Click the session or press \(ShortcutBindings.label(.releaseKeyboard)) to send keys to the PC again.", seconds: 5)
        } else {
            toast.show("Keys go to the PC again.", seconds: 2)
        }
    }

    func toggleFullScreen() { window.toggleFullScreen(nil) }

    /// ⌃⌥⇧Space: the session menu at the pointer (in the middle when the pointer is elsewhere).
    func showSessionMenu() {
        guard !menuOpen, let menu = sessionMenu?() else { return }
        releaseAll()
        menuOpen = true
        let p = video.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let at = video.bounds.contains(p) ? p : NSPoint(x: video.bounds.midX, y: video.bounds.midY)
        menu.popUp(positioning: nil, at: at, in: video)
        menuOpen = false
    }

    func close() {
        cloud?.close(byUser: phase == .streaming)
        drop()
        retryWork?.cancel()
        phase = .stopped
        window.close()
    }

    // MARK: Pairing prompt (PROTOCOL.md §2.4)

    private func askToPair(_ gen: Int, code: String, hostKey: Data, channel ch: SecureChannel) {
        let alert = NSAlert()
        alert.messageText = "Pairing code: \(code)"
        alert.informativeText = """
        Pair this Mac with \(target.display)?

        Check that the PC shows the same code, then confirm on both. If the codes differ, cancel: someone may be intercepting the connection.

        PC key:     \(GlideHandshake.fingerprint(hostKey))
        This Mac:  \(GlideHandshake.fingerprint(identity.publicKey.rawRepresentation))
        """
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        let pair = alert.addButton(withTitle: "Codes Match — Pair")
        pair.keyEquivalent = ""
        pair.isEnabled = false
        pairingAlert = alert
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, self.pairingAlert === alert else { return }
            self.pairingAlert = nil
            guard gen == self.generation, self.phase == .pairing else { return }
            let ok = response == .alertSecondButtonReturn
            ch.send(ClientMessage.pairConfirm(ok).encoded)
            if ok {
                self.pairConfirmed = true
                self.setStatus("Waiting for the PC to confirm the code…")
            } else {
                self.stop(message: "Pairing cancelled on this Mac.")
            }
        }
        // The confirm button only becomes usable after 1 s (no accidental Return-through).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { pair.isEnabled = true }
        if !NSApp.isActive { NSApp.requestUserAttention(.criticalRequest) }
    }

    private func dismissPairingAlert() {
        guard let a = pairingAlert else { return }
        pairingAlert = nil
        window.endSheet(a.window, returnCode: .abort)
    }

    private func showAlert(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.alertStyle = .critical
        a.beginSheetModal(for: window, completionHandler: nil)
    }

    // MARK: Input

    private func send(_ m: ClientMessage) {
        guard phase == .streaming else { return }
        if let p = cloud?.permissions, !ManagedPermissions.viewerMaySend(m, p) { return }
        channel?.send(m.encoded)
    }

    private func releaseAll() {
        send(.releaseAll)
        scroll.reset()
        keys.reset()
    }

    var capturingKeys: Bool {
        phase == .streaming && window.isKeyWindow && NSApp.isActive && window.attachedSheet == nil && !keyboardReleased && !menuOpen
    }

    func sendKey(usage: UInt16, down: Bool) { send(.key(usage: usage, down: down)) }

    func shortcut(_ s: ViewerShortcut) {
        // From inside the event tap / key monitor: act after it returns (closing the window stops
        // the capture, and the menu runs its own tracking loop).
        DispatchQueue.main.async { [weak self] in
            guard let self, self.phase != .stopped || s == .disconnect || s == .reconnect else { return }
            print("shortcut \(ShortcutBindings.label(s)): \(s.title)")
            switch s {
            case .disconnect: self.close()
            case .reconnect: self.reconnect(nil)
            case .toggleFullScreen: self.toggleFullScreen()
            case .releaseKeyboard: self.setKeyboardReleased(true)
            case .openMenu: self.showSessionMenu()
            }
        }
    }

    func pointerMoved(x: Float, y: Float) { send(.mouseMove(x: x, y: y)) }

    func mouseButton(_ button: UInt8, down: Bool) {
        // Held-back Control/Option/Shift apply to the click (Shift-click, Ctrl-click); the filter
        // also tracks the button so modifiers pressed mid-drag reach the PC at once.
        keys.mouseButton(button, down: down)
        send(.mouseButton(button: button, down: down))
    }

    func scrolled(dx: Double, dy: Double, precise: Bool) {
        if capturingKeys { keys.flushModifiers() }
        if let n = scroll.add(dx: dx, dy: dy, precise: precise) { send(.mouseWheel(dx: n.dx, dy: n.dy)) }
    }

    func clickToCapture() -> Bool {
        guard keyboardReleased, phase == .streaming else { return false }
        setKeyboardReleased(false)
        return true
    }

    // MARK: Window

    fileprivate func windowResignedKey() {
        // Keys and buttons released elsewhere would otherwise stay held on the PC.
        releaseAll()
    }

    fileprivate func windowBecameKey() {
        // Coming back to the session (a click on it, ⌘Tab) ends "keyboard released".
        if keyboardReleased && phase == .streaming { setKeyboardReleased(false) }
    }

    @objc private func screenParametersChanged(_ n: Notification) { sendViewSizeIfChanged() }

    fileprivate func sendViewSizeIfChanged() {
        guard phase == .streaming else { return }
        let px = screenPixels(window.screen)
        if let s = sentViewSize, s.w == px.w, s.h == px.h { return }
        sentViewSize = px
        print("view size -> \(px.w)x\(px.h) (screen changed); sending ViewSize")
        send(.viewSize(w: UInt16(clamping: px.w), h: UInt16(clamping: px.h)))
    }

    fileprivate func windowClosing() {
        cloud?.close(byUser: phase == .streaming)
        drop()
        retryWork?.cancel()
        retryWork = nil
        phase = .stopped
        keys.stop()
        NotificationCenter.default.removeObserver(self)
        let end = onEnd
        onEnd = nil
        DispatchQueue.main.async { end?() }
    }
}

// Conformance in an extension: a global-actor protocol in the class declaration would make the
// whole class @MainActor in Swift 5 mode, and the channel callbacks run on `net`.
extension ViewerSession: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) { windowResignedKey() }
    func windowDidBecomeKey(_ notification: Notification) { windowBecameKey() }
    func windowDidEnterFullScreen(_ notification: Notification) { showShortcutHint() }
    func windowDidChangeScreen(_ notification: Notification) { sendViewSizeIfChanged() }
    func windowWillClose(_ notification: Notification) { windowClosing() }
}
