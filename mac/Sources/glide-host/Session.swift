import AppKit
import Foundation
import GlideCore
import Network
import IOKit.pwr_mgt

/// One connected client: v2 handshake (Noise XX) + auth phase (pinned key or pairing, see
/// docs/PROTOCOL.md §2), message dispatch, video + cursor streaming.
final class Session: @unchecked Sendable {
    let id: Int
    private let channel: SecureChannel
    private let settings: HostSettings
    private let injector: InputInjector
    private var inputQueue: DispatchQueue { injector.queue }
    /// Guards `ended` and the state end() tears down that other threads read (the main queue: menu
    /// actions and display observers; the pipeline queue; capture tasks). end() itself always runs
    /// on the session queue (`channel.queue`).
    private let stateLock = NSLock()
    private var endedValue = false
    private var ended: Bool { stateLock.withLock { endedValue } }
    private var pipelineValue: VideoPipeline?
    private var pipeline: VideoPipeline? {
        get { stateLock.withLock { pipelineValue } }
        set { stateLock.withLock { pipelineValue = newValue } }
    }
    private var audio: AudioPipeline?
    private var audioOff = false
    private let cursor = CursorMonitor()
    private var frameId: UInt32 = 0
    private var authed = false
    private var displayAssertion: IOPMAssertionID?
    private var statsTimer: DispatchSourceTimer?
    private var clientName = "?"
    /// The viewer asked for FrameTiming messages (PROTOCOL.md §3.4).
    private let timingLock = NSLock()
    private var timingEnabledValue = false
    private var timingEnabled: Bool {
        get { timingLock.lock(); defer { timingLock.unlock() }; return timingEnabledValue }
        set { timingLock.lock(); timingEnabledValue = newValue; timingLock.unlock() }
    }
    /// Latest LatencyReport from the viewer (logged with the stats; written on the session queue,
    /// read on the pipeline queue).
    private var viewerLatencyValue: LatencyReport?
    private var viewerLatency: LatencyReport? {
        get { timingLock.lock(); defer { timingLock.unlock() }; return viewerLatencyValue }
        set { timingLock.lock(); viewerLatencyValue = newValue; timingLock.unlock() }
    }
    /// Created at auth if the viewer advertised clipboard support; started after ServerHello.
    private var clipboardValue: ClipboardSync?
    private var clipboard: ClipboardSync? {
        get { stateLock.withLock { clipboardValue } }
        set { stateLock.withLock { clipboardValue = newValue } }
    }
    /// Created at auth if the viewer advertised file transfer (caps bit 11) and it's enabled.
    private var filesValue: SessionFiles?
    private var files: SessionFiles? {
        get { stateLock.withLock { filesValue } }
        set { stateLock.withLock { filesValue = newValue } }
    }
    /// The viewer set caps bit 13: DisplayList / DisplayChanged / SelectDisplay (PROTOCOL.md §3.5).
    private var displaysEnabled = false
    private let displayLock = NSLock()
    /// The display the viewer was last told it sees; nil until the first capture.
    private var announcedDisplay: CGDirectDisplayID?
    /// A switch we asked for (SelectDisplay / menu bar), reported once its capture starts.
    private var pendingSwitch: (reason: DisplayChangeReason, requested: UInt32)?
    private var lastDisplayList: Data?
    var onEnd: ((Session) -> Void)?
    /// Called (on the session queue) once a paired viewer sent a valid ClientHello, before
    /// streaming starts. Until then the session must not affect any other session.
    var onAuthenticated: ((Session) -> Void)?
    /// Host is paused: answer new handshakes with status 2.
    var isPaused: () -> Bool = { false }
    /// Managed session (ENTERPRISE.md §6.6): the Glide Cloud session this bridged connection was
    /// opened for. Set before `start()`. Such a connection is accepted only for that session's
    /// grant (never pairing, never a paired key); a LAN connection never uses a grant.
    var relaySessionId: String?
    /// LAN mode is on (org policy). A LAN connection is refused while it is off (backstop to the
    /// server's admission check).
    var lanAllowed: () -> Bool = { true }
    /// The live grants (ManagedHost's store).
    var grants = GrantStore()
    /// Client audit events of a managed session (§9).
    var audit: AuditReporter?
    /// The grant this managed session was accepted with.
    private(set) var grant: SessionGrant?
    /// A managed session's permissions (§6.3); nil = LAN session, unrestricted.
    var permissions: CloudPermissions? { grant?.permissions }
    static let authTimeout: TimeInterval = 5

    /// Auth phase (docs/PROTOCOL.md §2.4).
    private enum Phase { case handshake, pairing, awaitHello, streaming, rejected }
    private var phase = Phase.handshake
    /// The viewer's static key once the handshake completed.
    private(set) var viewerKey: Data?
    private var accepted: SecureChannel.HostAccepted?
    private var vote = PairingVote()
    /// Bumped whenever the pre-auth deadline is re-armed (stale timers ignore themselves).
    private var deadlineGen = 0

    /// Marks each session's queue with its id, so end() knows whether it already runs there.
    private static let queueKey = DispatchSpecificKey<Int>()

    /// `queue`: the queue `connection` was already started on (dialer), else a new one.
    init(id: Int, connection: NWConnection, settings: HostSettings, queue: DispatchQueue? = nil) {
        self.id = id
        self.settings = settings
        let q = queue ?? DispatchQueue(label: "glide.session.\(id)", qos: .userInteractive)
        q.setSpecific(key: Session.queueKey, value: id)
        self.channel = SecureChannel(connection: connection, queue: q)
        self.injector = InputInjector()
    }

    var peer: String { "\(channel.connection.endpoint)" }
    /// Peer IP (no port/zone) for logs, notes and the rate limiter.
    var address: String {
        if case let .hostPort(host, _) = channel.connection.endpoint {
            var a = "\(host)"
            if let pct = a.firstIndex(of: "%") { a = String(a[..<pct]) }
            return a
        }
        return peer
    }
    /// Ended without ever streaming (handshake/auth failed): the dialer backs off.
    var failedAuth: Bool { !authed }
    /// The host dialed this connection (Server.dial). Set before `start()`. Outbound sessions stay
    /// out of the inbound rate limiter: the dialer has its own backoff, and charging the PC's
    /// address for our own failed dials would refuse the PC when it dials in (PROTOCOL.md §2.5).
    var outbound = false
    /// Counts a failed attempt against the peer's address (inbound connections only).
    private func chargeFailure() { if !outbound { PairingController.shared.backoff.failed(address) } }

    /// Logs `line`; before authentication through `PeerLog`, so a peer that keeps connecting can't
    /// grow the log without bound.
    private func peerLog(_ line: String) {
        if authed { log(line) } else { PeerLog.line(address, line) }
    }

    /// Security-relevant lines before authentication: never crowded out by connection noise.
    private func securityLog(_ line: String) {
        if authed { log(line) } else { PeerLog.event(address, line) }
    }

    func start() {
        channel.connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.runHandshake()
            case .failed(let e): self.peerLog("session \(self.id): connection failed: \(e)"); self.end()
            case .cancelled: self.end()
            default: break
            }
        }
        channel.onMessage = { [weak self] d in self?.handle(d) }
        // Outbound (dialed) connections can sit in the viewer's accept backlog for a moment: allow longer.
        armDeadline(Session.authTimeout * (channel.connection.state == .ready ? 2 : 1), what: "handshake")
        channel.onClose = { [weak self] err in
            guard let self else { return }
            if let err, !self.authed {
                self.peerLog("session \(self.id): closed during \(self.phase) from \(self.peer): \(err)")
                if self.phase == .handshake || self.phase == .awaitHello { self.chargeFailure() }
            } else if let err {
                log("session \(self.id): closed: \(err)")
            }
            self.end()
        }
        if channel.connection.state == .ready {
            // Outbound (dialer) connection: already connected; re-arm on our queue and handshake now.
            channel.queue.async { self.channel.connection.stateUpdateHandler?(.ready) }
        } else {
            channel.connection.start(queue: channel.queue)
        }
    }

    /// Closes the session if it hasn't authenticated within `seconds` (re-arming replaces it).
    private func armDeadline(_ seconds: TimeInterval, what: String) {
        deadlineGen += 1
        let gen = deadlineGen
        channel.queue.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, gen == self.deadlineGen, !self.authed, !self.ended else { return }
            if self.phase == .pairing {
                log("session \(self.id): pairing with \(self.peer) timed out")
                self.reject(.timeout)
                return
            }
            self.peerLog("session \(self.id): no \(what) within \(Int(seconds))s from \(self.peer); closing")
            self.chargeFailure()
            self.end()
        }
    }

    // MARK: Handshake + auth phase (docs/PROTOCOL.md §1–2)

    private func runHandshake() {
        let pc = PairingController.shared
        let addr = address
        let outbound = outbound
        channel.acceptHandshake(identity: settings.identity, admission: { [weak self] in
            if self?.isPaused() == true { return (GlideHandshake.statusPaused, 0) }
            // A bridged managed session: pairing is never open over the relay.
            if self?.relaySessionId != nil { return (GlideHandshake.statusOK, 0) }
            if let self, !LANGate.admits(relaySessionId: nil, lanAllowed: self.lanAllowed()) { return (GlideHandshake.statusPaused, 0) }
            if !outbound, let left = pc.backoff.blocked(addr) {
                PeerLog.line(addr, "session \(self?.id ?? 0): \(addr) is rate-limited (\(Int(left.rounded(.up))) s left); refusing")
                return (GlideHandshake.statusRateLimited, 0)
            }
            return (GlideHandshake.statusOK, pc.window.isOpen() ? GlideHandshake.hostFlagPairingOpen : 0)
        }) { [weak self] result in
            guard let self, !self.ended else { return }
            switch result {
            case .failure(SecureChannel.HandshakeFailure.v1Viewer):
                // It passed admission (not rate-limited); it counts as a failure like any refusal.
                self.securityLog("session \(self.id): rejected a Glide v1 viewer from \(self.peer) (it shows “unsupported protocol version 2”; update the viewer)")
                HostStatus.shared.note("Rejected a Glide v1 viewer (\(addr)) — update it", warning: true)
                self.chargeFailure()
                self.end()
            case .failure(SecureChannel.HandshakeFailure.refused(let st)):
                if st != GlideHandshake.statusRateLimited { self.peerLog("session \(self.id): refused \(self.peer) (status \(st))") }
                self.end()
            case .failure(let e):
                // EOF right after msg2 = the viewer didn't like our key (pinned to another host key).
                self.peerLog("session \(self.id): handshake with \(self.peer) failed: \(e)")
                self.chargeFailure()
                self.end()
            case .success(let acc):
                self.accepted(acc)
            }
        }
    }

    private func accepted(_ acc: SecureChannel.HostAccepted) {
        accepted = acc
        viewerKey = acc.viewerKey
        let name = PairedViewer.displayName(acc.info.name)
        let fp = GlideHandshake.fingerprint(acc.viewerKey)
        clientName = name
        channel.maxRecordBytes = SecureChannel.preAuthMaxRecord
        channel.startReceiving()
        let pc = PairingController.shared
        let decision = HostAuth.decide(viewerKey: acc.viewerKey, pairRequest: acc.info.pairRequest, relaySessionId: relaySessionId, grants: grants,
                                       isPaired: { TrustStore.shared.isPaired($0) }, claimPairing: { pc.window.claim(id) })
        switch decision {
        case let .granted(g):
            // Managed: the cloud named this key for this session. Nothing is pinned (§6.3).
            grant = g
            clientName = g.user.label
            log("session \(id): managed session \(g.sessionId): \(g.user.label) on “\(g.viewerName)” (\(fp)); \(g.permissions.summary)")
            phase = .awaitHello
        case .paired:
            phase = .awaitHello
        case .pair:
            phase = .pairing
            let code = GlideHandshake.sasCode(handshakeHash: acc.handshakeHash, viewerNonce: acc.info.nonce, hostNonce: acc.hostNonce)
            log("session \(id): pairing with “\(name)” (\(fp)) at \(address); code \(GlideHandshake.sasText(code))")
            armDeadline(PairingWindow.confirmTimeout, what: "pairing confirmation")
            send(.pairReveal(nonce: acc.hostNonce))
            pc.ask(PendingPairing(sessionId: id, viewerName: name, viewerFingerprint: fp, address: address, code: code) { [weak self] ok in
                self?.channel.queue.async { self?.vote.local = ok; self?.evaluateVote() }
            })
        case let .reject(code) where relaySessionId != nil:
            securityLog("session \(id): managed session \(relaySessionId ?? ""): viewer “\(name)” (\(fp)) is not the one the cloud granted (\(code)); closing")
            HostStatus.shared.note("Refused a managed connection whose key didn't match the session", warning: true)
            reject(code)
        case .reject(.pairingClosed):
            securityLog("session \(id): viewer “\(name)” (\(fp)) at \(address) asked to pair, but pairing isn't open")
            HostStatus.shared.note("“\(name)” (\(address)) asked to pair — use Pair New Viewer…", warning: true)
            reject(.pairingClosed)
        case .reject(.busy):
            securityLog("session \(id): viewer “\(name)” asked to pair while another pairing is in progress")
            reject(.busy)
        case let .reject(code):
            securityLog("session \(id): rejected unknown viewer “\(name)” (\(fp)) from \(address)")
            HostStatus.shared.note("Rejected unknown viewer “\(name)” (\(address))", warning: true)
            reject(code)
        }
    }

    private func evaluateVote() {
        guard phase == .pairing, !ended, let acc = accepted else { return }
        let pc = PairingController.shared
        switch vote.outcome {
        case .pending: return
        case .paired:
            TrustStore.shared.add(name: clientName, key: acc.viewerKey)
            pc.window.release(id, paired: true)
            pc.finished(sessionId: id, result: "paired \(clientName)")
            HostStatus.shared.update { $0.pairingUntil = nil }
            HostStatus.shared.note("Paired “\(clientName)”", warning: false)
            log("session \(id): paired viewer “\(clientName)” (\(GlideHandshake.fingerprint(acc.viewerKey)))")
            phase = .awaitHello
            send(.authResult(.ok))
            armDeadline(Session.authTimeout, what: "ClientHello after pairing")
        case .declinedHere:
            log("session \(id): pairing declined on the Mac")
            reject(.declined)
        case .declinedByViewer:
            log("session \(id): pairing declined on the viewer")
            pc.window.release(id, paired: false)
            pc.finished(sessionId: id, result: "failed declined on the PC")
            end()
        }
    }

    /// Sends AuthResult(code), closes once it is flushed, and counts the failure.
    private func reject(_ code: AuthCode) {
        let pc = PairingController.shared
        if phase == .pairing {
            pc.window.release(id, paired: false)
            pc.finished(sessionId: id, result: "failed \(code)")
        }
        chargeFailure()
        phase = .rejected  // ignore whatever else arrives (e.g. a pipelined ClientHello) until flushed
        channel.send(HostMessage.authResult(code).encoded) { [weak self] _ in
            self?.channel.queue.async { self?.end() }
        }
    }

    /// Ends the session; idempotent and callable from any thread. The teardown always runs on the
    /// session queue: right away when called there (callers on it may rely on `ended` afterwards),
    /// else asynchronously. So it never races the queue's own handlers or the stats timer, and
    /// `onEnd` fires exactly once, on that queue.
    func end() {
        if DispatchQueue.getSpecific(key: Session.queueKey) == id {
            endOnQueue()
        } else {
            channel.queue.async { self.endOnQueue() }
        }
    }

    private func endOnQueue() {
        let first = stateLock.withLock { () -> Bool in
            defer { endedValue = true }
            return !endedValue
        }
        guard first else { return }
        if phase == .pairing {
            PairingController.shared.window.release(id, paired: false)
            PairingController.shared.finished(sessionId: id, result: "failed the viewer disconnected")
        }
        channel.close()
        statsTimer?.cancel()
        Power.release(displayAssertion); displayAssertion = nil
        if let o = displayObserver { NotificationCenter.default.removeObserver(o) }
        if let o = preferenceObserver { NotificationCenter.default.removeObserver(o) }
        displayObserver = nil; preferenceObserver = nil
        DispatchQueue.main.async { [self] in displayRestart?.cancel(); displayRestart = nil }  // set on main
        ActiveDisplay.clearSelection(owner: id)
        cursor.stop()
        let (p, clip, f) = stateLock.withLock { () -> (VideoPipeline?, ClipboardSync?, SessionFiles?) in
            defer { pipelineValue = nil; clipboardValue = nil; filesValue = nil }
            return (pipelineValue, clipboardValue, filesValue)
        }
        clip?.stop()
        f?.stop()
        HostStatus.shared.fileProgress = nil
        inputQueue.async { self.injector.releaseAll() }
        // Final: also cancels a capture start still in progress, and any later one (captureLoop).
        if let p { Task { await p.shutdown() } }
        if authed && !hostTestMode { DisplayModeController.shared.sessionEnded(id: id); HostStatus.shared.sessionEnded(id: id) }
        peerLog("session \(id): ended")
        onEnd?(self)
    }

    func send(_ m: HostMessage) { channel.send(m.encoded) }

    /// Menu "Send Files to Viewer…". False if this viewer can't take files.
    func sendFiles(_ urls: [URL]) -> Bool {
        guard let f = files, f.allowSend else { return false }
        f.send(urls)
        return true
    }

    func cancelFiles() { files?.engine.cancelAll() }

    // MARK: Messages

    private func handle(_ d: Data) {
        let msg: ClientMessage
        do { msg = try ClientMessage.decode(d) } catch { peerLog("session \(id): bad message: \(error)"); if !authed { end() }; return }
        if !authed {
            switch (phase, msg) {
            case (.rejected, _):
                return
            case (.pairing, .pairConfirm(let matched)):
                vote.viewer = matched
                evaluateVote()
                return
            case (.awaitHello, .hello):
                break
            default:
                peerLog("session \(id): unexpected \(msg) during \(phase); closing")
                end()
                return
            }
            guard case let .hello(version, caps, vw, vh, mode, maxFps, _) = msg else { return }
            // 0 = not reported (stays "unknown"); anything else within sane limits (a 1x1 view used
            // to end in a 0x0 capture).
            let view = ViewSizeLimits.clamp(Int(vw), Int(vh))
            let viewW = view?.w ?? 0, viewH = view?.h ?? 0
            authed = true
            phase = .streaming
            channel.maxRecordBytes = RecordCipher.maxRecord
            PairingController.shared.backoff.succeeded(address)
            let name = clientName
            if hostTestMode {
                onAuthenticated?(self)
                log("session \(id): TEST MODE: '\(name)' (\(GlideHandshake.fingerprint(viewerKey ?? Data()))) authenticated (proto v\(version), caps \(caps.rawValue)); sending ServerHello only")
                send(.serverHello(version: GlideHandshake.version, hostName: "glide-host test mode", config: VideoConfig(width: 640, height: 360, codec: .hevc, chroma: .yuv420, scale: 1)))
                return
            }
            onAuthenticated?(self)
            if ended { return }  // rejected by the server (e.g. paused)
            HostStatus.shared.sessionAuthed(id: id, name: name, endpoint: channel.connection.endpoint, viewW: viewW, viewH: viewH)
            if let g = grant { HostStatus.shared.managedSession(id: id, grant: g) }
            Power.wakeDisplay()
            displayAssertion = Power.preventDisplaySleep()
            log("session \(id): '\(name)' (\(GlideHandshake.fingerprint(viewerKey ?? Data()))) authenticated from \(peer) (proto v\(version), view \(vw)x\(vh)\(viewW != Int(vw) || viewH != Int(vh) ? " -> \(viewW)x\(viewH)" : ""), caps \(caps.rawValue), mode \(mode), fps \(maxFps))")
            displaysEnabled = caps.contains(.displays)
            // Managed sessions: the grant's permissions narrow what is offered and accepted (§6.3).
            let perms = permissions
            let clipSend = perms.map(ManagedPermissions.hostSendsClipboard) ?? true
            let clipRecv = perms.map(ManagedPermissions.hostAcceptsClipboard) ?? true
            if caps.contains(.clipboard) && !settings.clipboardEnabled {
                log("session \(id): clipboard sync off on this host (Settings → Sharing)")
            } else if caps.contains(.clipboard) && !clipSend && !clipRecv {
                log("session \(id): clipboard sync not allowed for this managed session")
            } else if caps.contains(.clipboard) {
                let c = ClipboardSync(sessionId: id, syncConcealed: settings.clipboardSyncConcealed, allowSend: clipSend, allowReceive: clipRecv) { [weak self] c in self?.send(.clipboard(c)) }
                if let g = grant, let audit {
                    c.onTransfer = { toHost, image, bytes in audit.clipboard(sessionId: g.sessionId, toHost: toHost, image: image, bytes: bytes) }
                }
                clipboard = c
            }
            let filesSend = perms.map(ManagedPermissions.hostSendsFiles) ?? true
            let filesRecv = perms.map(ManagedPermissions.hostAcceptsFiles) ?? true
            if caps.contains(.files) && settings.files.enabled && (filesSend || filesRecv) {
                let ch = channel
                var fc = settings.files
                fc.receive = fc.receive && filesRecv
                let f = SessionFiles(sessionId: id, viewerName: name, config: fc,
                                     capsFlags: ManagedPermissions.hostFileCapsFlags(perms, receiveSetting: settings.files.receive), allowSend: filesSend,
                                     send: { m, onSent in ch.send(HostMessage.file(m).encoded, completion: onSent.map { f in { _ in f() } }) },
                                     backlog: { ch.bytesInFlight })
                if let g = grant, let audit {
                    f.onAudit = { sent, count, bytes, names in audit.files(sent: sent, sessionId: g.sessionId, count: count, bytes: bytes, names: names) }
                }
                files = f
                HostStatus.shared.fileProgress = { f.engine.progress }
                HostStatus.shared.files(id: id, filesSend)
            }
            // Size the virtual display for this viewer (pixels and refresh rate; max_fps is the viewer
            // monitor's refresh), or switch the Mac's display mode if the policy says so, then capture once.
            DisplayModeController.shared.sessionBegan(id: id, viewW: viewW, viewH: viewH, viewerHz: Int(maxFps)) { [weak self] in
                self?.channel.queue.async {
                    guard let self, !self.ended else { return }
                    self.startStreaming(caps: caps, mode: mode, maxFps: maxFps, viewW: viewW)
                }
            }
            return
        }
        if hostTestMode {  // never inject input or capture in test mode
            if case let .ping(t) = msg { send(.pong(clientTimeUs: t, hostTimeUs: hostTimeMicros())) }
            return
        }
        // Managed sessions enforce their permissions on everything the viewer sends (§6.3).
        if let p = permissions, !ManagedPermissions.hostAccepts(msg, p) {
            if case let .file(.offer(fid, _, _)) = msg {
                send(.file(.answer(id: fid, status: FileStatus.declined, detail: "this session doesn't allow files to this computer")))
            }
            return
        }
        switch msg {
        case let .mouseMove(x, y): Power.wakeDisplay(); inputQueue.async { self.injector.mouseMove(x: x, y: y) }
        case let .mouseButton(b, down): inputQueue.async { self.injector.mouseButton(b, down: down) }
        case let .mouseWheel(dx, dy): inputQueue.async { self.injector.wheel(dx: dx, dy: dy) }
        case let .key(u, down): Power.wakeDisplay(); inputQueue.async { self.injector.key(usage: u, down: down) }
        case .releaseAll: inputQueue.async { self.injector.releaseAll() }
        case let .scroll(precise, dx, dy): inputQueue.async { self.injector.scroll(precise: precise, dx: dx, dy: dy) }
        case let .mouseDelta(dx, dy): Power.wakeDisplay(); inputQueue.async { self.injector.mouseDelta(dx: dx, dy: dy) }
        case let .keyExtra(k): Power.wakeDisplay(); inputQueue.async { self.injector.keyExtra(k) }
        case .requestKeyframe: pipeline?.requestKeyframe()
        case let .viewSize(rawW, rawH):
            guard let view = ViewSizeLimits.clamp(Int(rawW), Int(rawH)) else {
                log("session \(id): ignoring ViewSize \(rawW)x\(rawH)")
                return
            }
            let vw = view.w, vh = view.h
            HostStatus.shared.viewSize(id: id, w: vw, h: vh)
            // Debounced; may switch the display mode, in which case the display-change observer re-captures.
            DisplayModeController.shared.viewSizeChanged(id: id, viewW: vw, viewH: vh) { [weak self] switched in
                guard let self, !self.ended, let p = self.pipeline else { return }
                let target = min(self.settings.maxWidth, vw)
                if switched { p.setMaxWidth(target); return }
                guard target != p.options.maxWidth else { return }
                log("session \(self.id): viewer now \(vw)px wide -> re-capturing at max width \(target)")
                Task {
                    do { try await p.restart(maxWidth: target) }
                    catch { log("session \(self.id): restart failed: \(error)") }
                }
            }
        case let .setMode(mode, br, fps):
            guard let p = pipeline else { return }
            log("session \(id): setMode \(mode) bitrate=\(br)kbps fps=\(fps)")
            Task {
                do { try await p.restart(mode: mode, bitrateKbps: Int(br), fps: Int(fps)) }
                catch { log("session \(self.id): restart failed: \(error)") }
            }
        case let .ping(t): send(.pong(clientTimeUs: t, hostTimeUs: hostTimeMicros()))
        case let .audioEnable(on):
            log("session \(id): viewer \(on ? "unmuted" : "muted") audio")
            audio?.setEnabled(on)
            if audio != nil { HostStatus.shared.audio(id: id, on ? "on" : "muted") }
        case let .clipboard(c): clipboard?.apply(c)
        case let .file(m): files?.handle(m)  // nil unless negotiated in this authenticated session
        case let .latencyEnable(f):
            timingEnabled = f & 1 != 0
            log("session \(id): viewer \(timingEnabled ? "enabled" : "disabled") per-frame latency timing")
        case let .latencyReport(r):
            viewerLatency = r
            HostStatus.shared.viewerLatency(id: id, r)
        case let .setDisplayPreference(m):
            guard let p = DisplayModePreference(wire: m) else { log("session \(id): unknown display preference \(m)"); return }
            DisplayModeController.shared.setSessionPreference(id: id, p) { [weak self] _ in self?.sendDisplayInfo() }
        case let .selectDisplay(d): selectDisplay(d, by: .selected)
        case .hello, .pairConfirm: break
        }
    }

    /// `viewW`: clamped to `ViewSizeLimits`, 0 = unknown.
    private func startStreaming(caps: CodecCaps, mode: StreamMode, maxFps: UInt8, viewW: Int) {
        let codec: Codec = caps.contains(.hevc420) || caps.intersection(.codecMask).isEmpty ? .hevc : .h264
        var m = mode
        if (m == .sharp || m == .hybrid) && !caps.contains(.hevc444) { m = .fast }
        let fps = maxFps > 0 ? min(Int(maxFps), settings.fps) : settings.fps
        // Never send more pixels than the viewer can show 1:1 (e.g. a 5K HiDPI desktop to a 4K monitor).
        let viewerW = viewW > 0 ? viewW : settings.maxWidth
        let p = VideoPipeline(options: .init(displayID: ActiveDisplay.current(), mode: m, codec: codec, fps: fps, bitrateKbps: settings.bitrateKbps, maxWidth: min(settings.maxWidth, viewerW)))
        pipeline = p
        let maxInFlight = settings.maxInFlightBytes
        p.canSend = { [weak self] in (self?.channel.bytesInFlight ?? 0) < maxInFlight }
        if caps.contains(.audioPCM) { setUpAudio(p, maxInFlight: maxInFlight) }
        var sentHello = false
        p.onConfig = { [weak self] cfg, sharpCfg in
            guard let self else { return }
            if !sentHello {
                sentHello = true
                self.send(.serverHello(version: GlideHandshake.version, hostName: Host.current().localizedName ?? "Mac", config: cfg))
                if let sharpCfg { self.send(.sharpLayerConfig(sharpCfg)) }
                if let clip = self.clipboard {
                    // Only to viewers with caps bit 8 (PROTOCOL.md §5), and only after ServerHello.
                    self.send(.clipboardCaps(formats: ClipboardData.capsText | ClipboardData.capsPNG, maxBytes: UInt32(ClipboardData.maxBytes)))
                    clip.start()
                }
                // Only to viewers with caps bit 11 (PROTOCOL.md §6), after ServerHello.
                if let f = self.files { self.send(.file(f.caps)) }
                // Only to viewers with caps bit 12 (PROTOCOL.md §3.6), after ServerHello.
                if caps.contains(.inputExt) { self.send(.inputCaps(.all)) }
                if self.audioOff { self.send(.audioConfig(.off)) }
                self.audio?.arm()
                self.helloSent = true
                self.sendDisplayInfo()
            } else {
                self.send(.videoConfig(cfg))
                if let sharpCfg { self.send(.sharpLayerConfig(sharpCfg)) }
            }
            // Still on the pipeline queue, so this goes out before the first frame of the capture.
            self.displayCaptured(p.options.displayID)
            HostStatus.shared.video(id: self.id, config: cfg, hybrid: sharpCfg != nil)
            // Cursor bitmaps are in encoded pixels: backing scale x (encoded width / native width).
            // Input maps onto the display actually being captured (it changes when the lid closes or a
            // monitor is swapped; the display-change observer re-captures).
            let shown = p.options.displayID
            self.inputQueue.async { self.injector.setDisplay(shown) }
            let mode = ActiveDisplay.mode(of: shown)  // also right for Glide's own virtual display
            let native = CGFloat(mode?.pixelWidth ?? Int(cfg.width))
            self.cursor.scale = CGFloat(cfg.scale) * CGFloat(cfg.width) / max(native, 1)
        }
        p.onFrame = { [weak self] f in
            guard let self else { return }
            self.frameId &+= 1
            let msg = HostMessage.videoFrame(frameId: self.frameId, captureTimeUs: f.captureUs, keyframe: f.keyframe, refresh: f.refresh, sharp: f.sharp, rects: f.rects, data: f.data)
            guard self.timingEnabled else { self.send(msg); return }
            // §3.4: once the network stack has taken the whole record, tell the viewer when each
            // stage of this frame happened on the host.
            let id = self.frameId
            let flags: UInt8 = (f.keyframe ? 1 : 0) | (f.refresh ? 2 : 0) | (f.sharp ? 4 : 0) | (f.rects != nil ? 8 : 0)
            let enqueued = hostTimeMicros()
            self.channel.send(msg.encoded) { [weak self] err in
                guard err == nil, let self else { return }
                let sent = hostTimeMicros(), c = f.captureUs
                self.send(.frameTiming(FrameTiming(frameId: id, captureUs: c, flags: flags, callback: FrameTiming.delta(f.callbackUs, from: c),
                                                   submit: FrameTiming.delta(f.submitUs, from: c), encoded: FrameTiming.delta(f.encodedUs, from: c),
                                                   enqueued: FrameTiming.delta(enqueued, from: c), sent: FrameTiming.delta(sent, from: c))))
            }
        }
        cursor.onShape = { [weak self] shape, isNew in
            if isNew {
                self?.send(.cursorShape(id: shape.id, w: UInt16(shape.w), h: UInt16(shape.h), hotX: UInt16(shape.hotX), hotY: UInt16(shape.hotY), bgra: shape.bgra))
            } else {
                self?.send(.cursorShapeRef(id: shape.id))
            }
        }
        Task { await self.captureLoop(p) }
    }

    /// System audio for viewers that advertise it (§3.2). host.json `audio.enabled: false` or
    /// GLIDE_NO_AUDIO=1 turns it off host-side.
    private func setUpAudio(_ p: VideoPipeline, maxInFlight: Int) {
        let envOff = ProcessInfo.processInfo.environment["GLIDE_NO_AUDIO"] == "1"
        let orgOff = permissions.map { !ManagedPermissions.hostSendsAudio($0) } ?? false
        guard !envOff && !orgOff && settings.audioEnabled else {
            log("session \(id): audio disabled on this host (\(envOff ? "GLIDE_NO_AUDIO=1" : orgOff ? "not allowed for this managed session" : "Settings → Sharing"))")
            audioOff = true  // tell the viewer right after ServerHello
            HostStatus.shared.audio(id: id, "off")
            return
        }
        let a = AudioPipeline()
        a.onConfig = { [weak self] cfg in
            log("audio: -> \(cfg.codec) \(cfg.sampleRate) Hz \(cfg.channels) ch, \(cfg.frameSamples) samples/frame")
            self?.send(.audioConfig(cfg))
        }
        a.onFrame = { [weak self] seq, us, pcm in self?.send(.audioFrame(seq: seq, captureTimeUs: us, pcm: pcm)) }
        // Audio is tiny; drop it only when the backlog is far past the video limit.
        a.canSend = { [weak self] in (self?.channel.bytesInFlight ?? 0) < maxInFlight * 2 }
        p.audio = a
        audio = a
        HostStatus.shared.audio(id: id, "on")
    }

    /// Starts capture, retrying until it works or the session ends. The display can be unavailable
    /// (asleep, locked, reconfiguring); the session stays alive meanwhile so input still reaches the
    /// Mac (which wakes the display).
    private var capturing = false  // stateLock
    private func captureLoop(_ p: VideoPipeline) async {
        let mine = stateLock.withLock { () -> Bool in
            defer { capturing = true }
            return !capturing
        }
        guard mine else { return }
        defer { stateLock.withLock { capturing = false } }
        var attempt = 0
        while !ended {
            attempt += 1
            do {
                try await p.start()
                // end() may have run while capture was starting (a viewer that dropped right away, or
                // a new session replacing this one): never leave that capture running.
                if ended { await p.shutdown(); return }
                let attempts = attempt
                channel.queue.async { [self] in  // like end(), so end's teardown can't be undone here
                    guard !ended else { return }
                    cursor.start()
                    if statsTimer == nil { startStats() }
                    if displayObserver == nil { watchDisplayChanges() }
                    if attempts > 1 { log("session \(id): capture started after \(attempts) attempts") }
                }
                HostStatus.shared.captureError(id: id, nil)
                return
            } catch let stopped as VideoPipeline.Stopped {
                // Shut down (the session ended), or a re-capture stopped this start: start over now.
                if stopped.final || ended { return }
                attempt -= 1
            } catch {
                if attempt <= 3 || attempt % 15 == 0 {
                    log("session \(id): capture unavailable (attempt \(attempt), screen recording \(CGPreflightScreenCaptureAccess() ? "granted" : "NOT granted")): \(error.localizedDescription) — waking display and retrying")
                }
                HostStatus.shared.captureError(id: id, CGPreflightScreenCaptureAccess() ? "display unavailable, retrying" : "Screen Recording not granted")
                Power.wakeDisplay()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    /// Re-capture when the Mac's display mode changes (resolution / HiDPI switch), so the new
    /// pixel size and backing scale take effect without restarting the host.
    private var displayObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    private var displayRestart: DispatchWorkItem?
    private func watchDisplayChanges() {
        preferenceObserver = NotificationCenter.default.addObserver(forName: DisplayModeController.preferenceChanged, object: nil, queue: .main) { [weak self] _ in
            self?.sendDisplayInfo()
        }
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sendDisplayInfo()
            ActiveDisplay.refreshNames()
            self?.sendDisplayList()  // a display came or went, or a mode/arrangement changed (deduplicated)
            guard let self, let p = self.pipeline, !self.ended else { return }
            // Debounce mode-switch churn. The restart re-resolves the display: a selected display that
            // went away falls back to the default, and one that came back is captured again (§3.5).
            self.scheduleRecapture(p, after: 1.0, why: "display configuration changed")
        }
    }

    /// Main queue. Restarts capture after `delay` (replacing a pending restart).
    private func scheduleRecapture(_ p: VideoPipeline, after delay: TimeInterval, why: String) {
        displayRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.ended else { return }
            log("session \(self.id): \(why) -> re-capturing")
            Task { await p.stop(); await self.captureLoop(p) }
        }
        displayRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: Multiple displays (PROTOCOL.md §3.5)

    /// Stream display `display` (0 = the default) for the rest of this session. `reason`: .selected
    /// (the viewer's SelectDisplay) or .host (the menu bar). Any thread.
    func selectDisplay(_ display: UInt32, by reason: DisplayChangeReason) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.authed, !self.ended else { return }
            ActiveDisplay.refreshNames()
            var identity: DisplayIdentity?
            if display != 0 {
                guard let d = ActiveDisplay.descriptor(display) else {
                    log("session \(self.id): display \(display) is not available; staying on \(ActiveDisplay.current())")
                    if self.displaysEnabled {
                        let now = self.displayLock.withLock { self.announcedDisplay } ?? ActiveDisplay.current()
                        self.send(.displayChanged(id: now, reason: DisplayChangeReason.unavailable.rawValue, requested: display))
                    }
                    return
                }
                identity = d.identity
            }
            ActiveDisplay.select(identity, owner: self.id)
            let target = ActiveDisplay.current()
            log("session \(self.id): \(reason == .host ? "Mac menu" : "viewer") selected \(identity.map { "display \(display) “\($0.name)”" } ?? "the default display") -> streaming \(target)")
            guard let p = self.pipeline else {
                // Not capturing yet: the first capture picks the selection up; move the mode policy now.
                DisplayModeController.shared.servedDisplayChanged { _ in }
                return
            }
            let shown = self.displayLock.withLock { self.announcedDisplay }
            if target == shown {
                self.sendDisplayList()  // selected_id changed
                if self.displaysEnabled { self.send(.displayChanged(id: target, reason: reason.rawValue, requested: display)) }
                return
            }
            self.displayLock.withLock { self.pendingSwitch = (reason, display) }
            // Restore the old display's mode, apply the policy to the new one, then capture it once.
            DisplayModeController.shared.servedDisplayChanged { [weak self] _ in
                self?.scheduleRecapture(p, after: 0, why: "display \(target) selected")
            }
        }
    }

    /// Pipeline queue, on every capture (re)start right after its VideoConfig: if the captured
    /// display changed, tell the viewer which one it sees now (DisplayList, then DisplayChanged).
    /// Input follows the captured display via `injector.setDisplay` in onConfig.
    private func displayCaptured(_ shown: CGDirectDisplayID) {
        let (prev, pending) = displayLock.withLock { () -> (CGDirectDisplayID?, (reason: DisplayChangeReason, requested: UInt32)?) in
            let prev = announcedDisplay, pending = pendingSwitch
            announcedDisplay = shown
            pendingSwitch = nil
            return (prev, pending)
        }
        let ds = ActiveDisplay.displays()
        let name = ds.first { $0.id == shown }?.name ?? "display \(shown)"
        guard prev != nil else { sendDisplayList(); return }  // first capture of the session
        guard prev != shown || pending != nil else { return }
        let sel = ActiveDisplay.selection
        var reason = pending?.reason ?? DisplaySelection.unrequestedReason(selection: sel, now: shown, displays: ds)
        var requested = pending?.requested ?? (reason == .fallback ? (sel?.id ?? 0) : reason == .restored ? shown : 0)
        if let pending, pending.requested != 0, prev == shown {
            reason = .unavailable  // capture couldn't get the requested display
            requested = pending.requested
        }
        log("session \(id): now streaming display \(shown) “\(name)” (was \(prev.map(String.init) ?? "-"), \(reason))")
        sendDisplayList()
        if displaysEnabled { send(.displayChanged(id: shown, reason: reason.rawValue, requested: requested)) }
        sendDisplayInfo()
    }

    /// DisplayList (§3.5) if the viewer supports it and it changed since the last one. Any thread.
    private func sendDisplayList() {
        guard displaysEnabled, helloSent, !ended else { return }
        let ds = ActiveDisplay.displays()
        let streamed = displayLock.withLock { announcedDisplay } ?? ActiveDisplay.current()
        let sel = ActiveDisplay.selection
        let msg = HostMessage.displayList(streamed: streamed, selected: sel.map { $0.match(in: ds) ?? $0.id } ?? 0, displays: ds).encoded
        let changed = displayLock.withLock { () -> Bool in
            guard msg != lastDisplayList else { return false }
            lastDisplayList = msg
            return true
        }
        if changed { channel.send(msg) }
    }

    /// DisplayInfo (§3.3): current preference + mode, sent after ServerHello and whenever it changes.
    private var helloSent = false
    private var lastDisplayInfo: Data?
    private func sendDisplayInfo() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let dm = DisplayModeController.shared
            let msg = HostMessage.displayInfo(preference: dm.effectivePreference, mode: dm.currentMode())
            self.channel.queue.async {
                guard self.helloSent, !self.ended else { return }
                let enc = msg.encoded
                guard enc != self.lastDisplayInfo else { return }
                self.lastDisplayInfo = enc
                self.channel.send(enc)
            }
        }
    }

    private func startStats() {
        let t = DispatchSource.makeTimerSource(queue: channel.queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in
            guard let self, let p = self.pipeline else { return }
            p.queue.async {
                var s = p.stats
                p.stats.reset()
                s.encodeMs.sort()
                let med = s.encodeMs.isEmpty ? 0 : s.encodeMs[s.encodeMs.count / 2]
                let p95 = s.encodeMs.isEmpty ? 0 : s.encodeMs[min(s.encodeMs.count - 1, s.encodeMs.count * 95 / 100)]
                s.sharpMs.sort(); s.diffUs.sort()
                let diffMed = s.diffUs.isEmpty ? 0 : s.diffUs[s.diffUs.count / 2] / 1000
                let sharpMed = s.sharpMs.isEmpty ? 0 : s.sharpMs[s.sharpMs.count / 2]
                func pct(_ a: [Double], _ p: Int) -> Double? { let v = a.sorted(); return v.isEmpty ? nil : v[min(v.count - 1, v.count * p / 100)] }
                let capMed = pct(s.captureMs, 50), capP95 = pct(s.captureMs, 95), waitMed = pct(s.waitMs, 50)
                HostStatus.shared.stats(id: self.id, fps: Double(s.encoded) / 5, mbps: Double(s.bytes) * 8 / 5 / 1e6, encodeMs: med, captureMs: capMed)
                if let capMed, let capP95 {
                    log(String(format: "latency: capture->callback p50 %.1fms p95 %.1fms, callback->encode p50 %.1fms, encode p50 %.1fms p95 %.1fms", capMed, capP95, waitMed ?? 0, med, p95)
                        + (self.viewerLatency.map { "; viewer " + $0.summary } ?? ""))
                }
                log(String(format: "stats: sent %.1f fps, %.1f Mbps, encode p50 %.1fms p95 %.1fms, captured %d, keyframes %d, rect frames %d (avg %.1f rects), sharp %d sent/%d dropped (p50 %.1fms), diff p50 %.2fms, identical %d, skipped busy %d / net %d, in-flight %d KB",
                           Double(s.encoded) / 5, Double(s.bytes) * 8 / 5 / 1e6, med, p95, s.captured, s.keyframes, s.rectFrames, s.rectFrames > 0 ? Double(s.rectCount) / Double(s.rectFrames) : 0, s.sharpSent, s.sharpDropped, sharpMed, diffMed, s.identical, s.skippedBusy, s.skippedNet, self.channel.bytesInFlight / 1024))
            }
        }
        t.resume()
        statsTimer = t
    }
}

/// Log lines about connections that haven't authenticated. Anyone who can reach the port can
/// open connections (rate-limited ones too), so these lines go through a `LogCoalescer`: a few per
/// address bucket per minute, then one "N more ... suppressed" summary once the minute is over.
enum PeerLog {
    static let coalescer = LogCoalescer(window: 60, perKey: 6, total: 30)
    /// Security events (unknown viewer rejected, pairing requested, v1 viewer rejected) have their
    /// own budget, per address only: connection noise from any peer can't push them out of the log,
    /// and one peer flooding events only silences itself (its count still appears in the summary).
    static let events = LogCoalescer(window: 60, perKey: 6, total: .max, subject: "pairing/authentication events")
    private static let flushLock = NSLock()
    private static var flushScheduled = false

    /// `address`: the peer's IP (bucketed like the rate limiter: IPv4 address, IPv6 /64).
    static func line(_ address: String, _ text: String) {
        let d = coalescer.admit(HandshakeBackoff.key(address), now: ProcessInfo.processInfo.systemUptime)
        if let s = d.summary { log("server: " + s) }
        if d.log { log(text) } else { scheduleFlush() }
    }

    static func event(_ address: String, _ text: String) {
        let d = events.admit(HandshakeBackoff.key(address), now: ProcessInfo.processInfo.systemUptime)
        if let s = d.summary { log("server: " + s) }
        if d.log { log(text) } else { scheduleFlush() }
    }

    /// Reports the suppressed count when the window ends, not only at the next connection.
    private static func scheduleFlush() {
        guard let at = [coalescer.pendingSummaryAt, events.pendingSummaryAt].compactMap({ $0 }).min() else { return }
        let first = flushLock.withLock { () -> Bool in
            defer { flushScheduled = true }
            return !flushScheduled
        }
        guard first else { return }
        let delay = max(1, at - ProcessInfo.processInfo.systemUptime + 0.1)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) {
            flushLock.withLock { flushScheduled = false }
            let now = ProcessInfo.processInfo.systemUptime
            if let s = coalescer.flush(now: now) { log("server: " + s) }
            if let s = events.flush(now: now) { log("server: " + s) }
            scheduleFlush()  // a newer window may have suppressed lines meanwhile
        }
    }
}
