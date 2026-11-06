import AppKit
import Foundation
import GlideCore
import Network
import IOKit.pwr_mgt

/// One connected client: handshake, message dispatch, video + cursor streaming.
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
    /// Created at auth if the viewer advertised clipboard support; started after ServerHello.
    private var clipboard: ClipboardSync?
    /// Created at auth if the viewer advertised file transfer (caps bit 11) and it's enabled.
    private var files: SessionFiles?
    var onEnd: ((Session) -> Void)?
    /// Called (on the session queue) once the peer proved the password with a valid ClientHello,
    /// before streaming starts. Until then the session must not affect any other session.
    var onAuthenticated: ((Session) -> Void)?
    static let authTimeout: TimeInterval = 5

    init(id: Int, connection: NWConnection, settings: HostSettings) {
        self.id = id
        self.settings = settings
        self.channel = SecureChannel(connection: connection, queue: DispatchQueue(label: "glide.session.\(id)", qos: .userInteractive))
        self.injector = InputInjector(displayID: settings.displayID)
    }

    var peer: String { "\(channel.connection.endpoint)" }

    func start() {
        channel.connection.stateUpdateHandler = { [weak self] st in
            guard let self else { return }
            switch st {
            case .ready:
                self.channel.acceptHandshake(password: self.settings.password, salt: self.settings.salt, passwordKey: self.settings.passwordKey) { err in
                    if let err { log("session \(self.id): handshake failed: \(err)"); self.end(); return }
                    self.channel.startReceiving()
                }
            case .failed(let e): log("session \(self.id): connection failed: \(e)"); self.end()
            case .cancelled: self.end()
            default: break
            }
        }
        channel.onMessage = { [weak self] d in self?.handle(d) }
        // Outbound (dialed) connections can sit in the viewer's accept backlog for a moment: allow longer.
        let authTimeout = Session.authTimeout * (channel.connection.state == .ready ? 2 : 1)
        channel.queue.asyncAfter(deadline: .now() + authTimeout) { [weak self] in
            guard let self, !self.authed, !self.ended else { return }
            log("session \(self.id): no valid ClientHello within \(Int(authTimeout))s from \(self.peer); closing")
            self.end()
        }
        channel.onClose = { [weak self] err in
            guard let self else { return }
            if let err, case WireError.decryptFailed = err, !self.authed {
                log("session \(self.id): authentication failed (wrong password) from \(self.peer)")
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

    private var ended = false
    func end() {
        guard !ended else { return }
        ended = true
        channel.close()
        statsTimer?.cancel()
        Power.release(displayAssertion); displayAssertion = nil
        if let o = displayObserver { NotificationCenter.default.removeObserver(o) }
        displayRestart?.cancel()
        cursor.stop()
        clipboard?.stop(); clipboard = nil
        files?.stop(); files = nil
        HostStatus.shared.fileProgress = nil
        inputQueue.async { self.injector.releaseAll() }
        if let p = pipeline { Task { await p.stop() } }
        pipeline = nil
        if authed { DisplayModeController.shared.sessionEnded(id: id); HostStatus.shared.sessionEnded(id: id) }
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
        do { msg = try ClientMessage.decode(d) } catch { log("session \(id): bad message: \(error)"); return }
        if !authed {
            guard case let .hello(version, caps, vw, vh, mode, maxFps, name) = msg else { log("session \(id): expected ClientHello"); end(); return }
            authed = true
            clientName = name
            onAuthenticated?(self)
            if ended { return }  // rejected by the server (e.g. paused)
            HostStatus.shared.sessionAuthed(id: id, name: name, endpoint: channel.connection.endpoint, viewW: Int(vw), viewH: Int(vh))
            Power.wakeDisplay()
            displayAssertion = Power.preventDisplaySleep()
            log("session \(id): '\(name)' authenticated from \(peer) (proto v\(version), view \(vw)x\(vh), caps \(caps.rawValue), mode \(mode), fps \(maxFps))")
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
        case .hello: break
        }
    }

    private func startStreaming(caps: CodecCaps, mode: StreamMode, maxFps: UInt8, viewW: UInt16) {
        let codec: Codec = caps.contains(.hevc420) || caps.intersection(.codecMask).isEmpty ? .hevc : .h264
        var m = mode
        if (m == .sharp || m == .hybrid) && !caps.contains(.hevc444) { m = .fast }
        let fps = maxFps > 0 ? min(Int(maxFps), settings.fps) : settings.fps
        // Never send more pixels than the viewer can show 1:1 (e.g. a 5K HiDPI desktop to a 4K monitor).
        let viewerW = Int(viewW) > 0 ? Int(viewW) : settings.maxWidth
        let p = VideoPipeline(options: .init(displayID: settings.displayID, mode: m, codec: codec, fps: fps, bitrateKbps: settings.bitrateKbps, maxWidth: min(settings.maxWidth, viewerW)))
        pipeline = p
        let maxInFlight = settings.maxInFlightBytes
        p.canSend = { [weak self] in (self?.channel.bytesInFlight ?? 0) < maxInFlight }
        if caps.contains(.audioPCM) { setUpAudio(p, maxInFlight: maxInFlight) }
        var sentHello = false
        p.onConfig = { [weak self] cfg, sharpCfg in
            guard let self else { return }
            if !sentHello {
                sentHello = true
                self.send(.serverHello(version: Handshake.version, hostName: Host.current().localizedName ?? "Mac", config: cfg))
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
            } else {
                self.send(.videoConfig(cfg))
                if let sharpCfg { self.send(.sharpLayerConfig(sharpCfg)) }
            }
            HostStatus.shared.video(id: self.id, config: cfg, hybrid: sharpCfg != nil)
            // Cursor bitmaps are in encoded pixels: backing scale x (encoded width / native width).
            let mode = CGDisplayCopyDisplayMode(self.settings.displayID)
            let native = CGFloat(mode?.pixelWidth ?? Int(cfg.width))
            self.cursor.scale = CGFloat(cfg.scale) * CGFloat(cfg.width) / max(native, 1)
        }
        p.onFrame = { [weak self] f in
            guard let self else { return }
            self.frameId &+= 1
            self.send(.videoFrame(frameId: self.frameId, captureTimeUs: f.captureUs, keyframe: f.keyframe, refresh: f.refresh, sharp: f.sharp, rects: f.rects, data: f.data))
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
    private var displayRestart: DispatchWorkItem?
    private func watchDisplayChanges() {
        displayObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let p = self.pipeline, !self.ended else { return }
            self.displayRestart?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, !self.ended else { return }
                log("session \(self.id): display configuration changed -> re-capturing")
                Task { await p.stop(); await self.captureLoop(p) }
            }
            self.displayRestart = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)  // debounce mode-switch churn
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
                HostStatus.shared.stats(id: self.id, fps: Double(s.encoded) / 5, mbps: Double(s.bytes) * 8 / 5 / 1e6, encodeMs: med)
                log(String(format: "stats: sent %.1f fps, %.1f Mbps, encode p50 %.1fms p95 %.1fms, captured %d, keyframes %d, rect frames %d (avg %.1f rects), sharp %d sent/%d dropped (p50 %.1fms), diff p50 %.2fms, identical %d, skipped busy %d / net %d, in-flight %d KB",
                           Double(s.encoded) / 5, Double(s.bytes) * 8 / 5 / 1e6, med, p95, s.captured, s.keyframes, s.rectFrames, s.rectFrames > 0 ? Double(s.rectCount) / Double(s.rectFrames) : 0, s.sharpSent, s.sharpDropped, sharpMed, diffMed, s.identical, s.skippedBusy, s.skippedNet, self.channel.bytesInFlight / 1024))
            }
        }
        t.resume()
        statsTimer = t
    }
}
