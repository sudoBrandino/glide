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
    private let inputQueue = DispatchQueue(label: "glide.input", qos: .userInteractive)
    private var pipeline: VideoPipeline?
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
    private var clipboard: ClipboardSync?
    /// Created at auth if the viewer advertised file transfer (caps bit 11) and it's enabled.
    private var files: SessionFiles?
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

    /// `queue`: the queue `connection` was already started on (dialer), else a new one.
    init(id: Int, connection: NWConnection, settings: HostSettings, queue: DispatchQueue? = nil) {
        self.id = id
        self.settings = settings
        self.channel = SecureChannel(connection: connection, queue: queue ?? DispatchQueue(label: "glide.session.\(id)", qos: .userInteractive))
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

    func start() {
        channel.connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.runHandshake()
            case .failed(let e): log("session \(self.id): connection failed: \(e)"); self.end()
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
                log("session \(self.id): closed during \(self.phase) from \(self.peer): \(err)")
                if self.phase == .handshake || self.phase == .awaitHello { PairingController.shared.backoff.failed(self.address) }
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
            log("session \(self.id): no \(what) within \(Int(seconds))s from \(self.peer); closing")
            PairingController.shared.backoff.failed(self.address)
            self.end()
        }
    }

    // MARK: Handshake + auth phase (docs/PROTOCOL.md §1–2)

    private func runHandshake() {
        let pc = PairingController.shared
        let addr = address
        channel.acceptHandshake(identity: settings.identity, admission: { [weak self] in
            if self?.isPaused() == true { return (GlideHandshake.statusPaused, 0) }
            if let left = pc.backoff.blocked(addr) {
                log("session \(self?.id ?? 0): \(addr) is rate-limited (\(Int(left.rounded(.up))) s left); refusing")
                return (GlideHandshake.statusRateLimited, 0)
            }
            return (GlideHandshake.statusOK, pc.window.isOpen() ? GlideHandshake.hostFlagPairingOpen : 0)
        }) { [weak self] result in
            guard let self, !self.ended else { return }
            switch result {
            case .failure(SecureChannel.HandshakeFailure.v1Viewer):
                log("session \(self.id): rejected a Glide v1 viewer from \(self.peer) (it shows “unsupported protocol version 2”; update the viewer)")
                HostStatus.shared.note("Rejected a Glide v1 viewer (\(addr)) — update it", warning: true)
                self.end()
            case .failure(SecureChannel.HandshakeFailure.refused(let st)):
                if st != GlideHandshake.statusRateLimited { log("session \(self.id): refused \(self.peer) (status \(st))") }
                self.end()
            case .failure(let e):
                // EOF right after msg2 = the viewer didn't like our key (pinned to another host key).
                log("session \(self.id): handshake with \(self.peer) failed: \(e)")
                pc.backoff.failed(addr)
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
        if acc.info.pairRequest {
            switch pc.window.claim(id) {
            case .closed:
                log("session \(id): viewer “\(name)” (\(fp)) at \(address) asked to pair, but pairing isn't open")
                HostStatus.shared.note("“\(name)” (\(address)) asked to pair — use Pair New Viewer…", warning: true)
                reject(.pairingClosed)
            case .busy:
                log("session \(id): viewer “\(name)” asked to pair while another pairing is in progress")
                reject(.busy)
            case .granted:
                phase = .pairing
                let code = GlideHandshake.sasCode(handshakeHash: acc.handshakeHash, viewerNonce: acc.info.nonce, hostNonce: acc.hostNonce)
                log("session \(id): pairing with “\(name)” (\(fp)) at \(address); code \(GlideHandshake.sasText(code))")
                armDeadline(PairingWindow.confirmTimeout, what: "pairing confirmation")
                send(.pairReveal(nonce: acc.hostNonce))
                pc.ask(PendingPairing(sessionId: id, viewerName: name, viewerFingerprint: fp, address: address, code: code) { [weak self] ok in
                    self?.channel.queue.async { self?.vote.local = ok; self?.evaluateVote() }
                })
            }
        } else if TrustStore.shared.isPaired(acc.viewerKey) {
            phase = .awaitHello
        } else {
            log("session \(id): rejected unknown viewer “\(name)” (\(fp)) from \(address)")
            HostStatus.shared.note("Rejected unknown viewer “\(name)” (\(address))", warning: true)
            reject(.unknownViewer)
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
        pc.backoff.failed(address)
        phase = .rejected  // ignore whatever else arrives (e.g. a pipelined ClientHello) until flushed
        channel.send(HostMessage.authResult(code).encoded) { [weak self] _ in
            self?.channel.queue.async { self?.end() }
        }
    }

    private var ended = false
    func end() {
        guard !ended else { return }
        ended = true
        if phase == .pairing {
            PairingController.shared.window.release(id, paired: false)
            PairingController.shared.finished(sessionId: id, result: "failed the viewer disconnected")
        }
        channel.close()
        statsTimer?.cancel()
        Power.release(displayAssertion); displayAssertion = nil
        if let o = displayObserver { NotificationCenter.default.removeObserver(o) }
        if let o = preferenceObserver { NotificationCenter.default.removeObserver(o) }
        displayRestart?.cancel()
        ActiveDisplay.clearSelection(owner: id)
        cursor.stop()
        clipboard?.stop(); clipboard = nil
        files?.stop(); files = nil
        HostStatus.shared.fileProgress = nil
        inputQueue.async { self.injector.releaseAll() }
        if let p = pipeline { Task { await p.stop() } }
        pipeline = nil
        if authed && !hostTestMode { DisplayModeController.shared.sessionEnded(id: id); HostStatus.shared.sessionEnded(id: id) }
        log("session \(id): ended")
        onEnd?(self)
    }

    func send(_ m: HostMessage) { channel.send(m.encoded) }

    /// Menu "Send Files to Viewer…". False if this viewer can't take files.
    func sendFiles(_ urls: [URL]) -> Bool {
        guard let f = files else { return false }
        f.send(urls)
        return true
    }

    func cancelFiles() { files?.engine.cancelAll() }

    // MARK: Messages

    private func handle(_ d: Data) {
        let msg: ClientMessage
        do { msg = try ClientMessage.decode(d) } catch { log("session \(id): bad message: \(error)"); if !authed { end() }; return }
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
                log("session \(id): unexpected \(msg) during \(phase); closing")
                end()
                return
            }
            guard case let .hello(version, caps, vw, vh, mode, maxFps, _) = msg else { return }
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
            HostStatus.shared.sessionAuthed(id: id, name: name, endpoint: channel.connection.endpoint, viewW: Int(vw), viewH: Int(vh))
            Power.wakeDisplay()
            displayAssertion = Power.preventDisplaySleep()
            log("session \(id): '\(name)' (\(GlideHandshake.fingerprint(viewerKey ?? Data()))) authenticated from \(peer) (proto v\(version), view \(vw)x\(vh), caps \(caps.rawValue), mode \(mode), fps \(maxFps))")
            displaysEnabled = caps.contains(.displays)
            if caps.contains(.clipboard) {
                clipboard = ClipboardSync(sessionId: id, syncConcealed: settings.clipboardSyncConcealed) { [weak self] c in self?.send(.clipboard(c)) }
            }
            if caps.contains(.files) && settings.files.enabled {
                let ch = channel
                let f = SessionFiles(sessionId: id, viewerName: name, config: settings.files,
                                     send: { m, onSent in ch.send(HostMessage.file(m).encoded, completion: onSent.map { f in { _ in f() } }) },
                                     backlog: { ch.bytesInFlight })
                files = f
                HostStatus.shared.fileProgress = { f.engine.progress }
                HostStatus.shared.files(id: id, true)
            }
            // Switch the Mac's display mode for this viewer first (if the policy says so), then capture once.
            DisplayModeController.shared.sessionBegan(id: id, viewW: Int(vw), viewH: Int(vh)) { [weak self] in
                self?.channel.queue.async {
                    guard let self, !self.ended else { return }
                    self.startStreaming(caps: caps, mode: mode, maxFps: maxFps, viewW: vw)
                }
            }
            return
        }
        if hostTestMode {  // never inject input or capture in test mode
            if case let .ping(t) = msg { send(.pong(clientTimeUs: t, hostTimeUs: hostTimeMicros())) }
            return
        }
        switch msg {
        case let .mouseMove(x, y): Power.wakeDisplay(); inputQueue.async { self.injector.mouseMove(x: x, y: y) }
        case let .mouseButton(b, down): inputQueue.async { self.injector.mouseButton(b, down: down) }
        case let .mouseWheel(dx, dy): inputQueue.async { self.injector.wheel(dx: dx, dy: dy) }
        case let .key(u, down): Power.wakeDisplay(); inputQueue.async { self.injector.key(usage: u, down: down) }
        case .releaseAll: inputQueue.async { self.injector.releaseAll() }
        case .requestKeyframe: pipeline?.requestKeyframe()
        case let .viewSize(vw, vh):
            HostStatus.shared.viewSize(id: id, w: Int(vw), h: Int(vh))
            // Debounced; may switch the display mode, in which case the display-change observer re-captures.
            DisplayModeController.shared.viewSizeChanged(id: id, viewW: Int(vw), viewH: Int(vh)) { [weak self] switched in
                guard let self, !self.ended, let p = self.pipeline else { return }
                let target = min(self.settings.maxWidth, Int(vw))
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

    private func startStreaming(caps: CodecCaps, mode: StreamMode, maxFps: UInt8, viewW: UInt16) {
        let codec: Codec = caps.contains(.hevc420) || caps.intersection(.codecMask).isEmpty ? .hevc : .h264
        var m = mode
        if (m == .sharp || m == .hybrid) && !caps.contains(.hevc444) { m = .fast }
        let fps = maxFps > 0 ? min(Int(maxFps), settings.fps) : settings.fps
        // Never send more pixels than the viewer can show 1:1 (e.g. a 5K HiDPI desktop to a 4K monitor).
        let viewerW = Int(viewW) > 0 ? Int(viewW) : settings.maxWidth
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

    /// System audio for viewers that advertise it (§3.2). GLIDE_NO_AUDIO=1 turns it off host-side.
    private func setUpAudio(_ p: VideoPipeline, maxInFlight: Int) {
        guard ProcessInfo.processInfo.environment["GLIDE_NO_AUDIO"] != "1" else {
            log("session \(id): audio disabled on this host (GLIDE_NO_AUDIO=1)")
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
    private var capturing = false
    private func captureLoop(_ p: VideoPipeline) async {
        if capturing { return }
        capturing = true
        defer { capturing = false }
        var attempt = 0
        while !ended {
            attempt += 1
            do {
                try await p.start()
                cursor.start()
                if statsTimer == nil { startStats() }
                if displayObserver == nil { watchDisplayChanges() }
                if attempt > 1 { log("session \(id): capture started after \(attempt) attempts") }
                HostStatus.shared.captureError(id: id, nil)
                return
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
