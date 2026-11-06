import CoreMedia
import Foundation
import GlideCore
@preconcurrency import ScreenCaptureKit

/// Screen capture (ScreenCaptureKit) -> hardware encode, with latest-frame-wins scheduling,
/// network backpressure, dirty-rect tracking and (hybrid mode) a 4:4:4 refinement layer.
///
/// Modes:
///  - fast:   base layer only, 4:2:0, idle "refresh" re-encodes for quality.
///  - sharp:  base layer only, 4:4:4 every frame.
///  - hybrid: base layer 4:2:0 while the screen changes (with dirty rects), plus a standalone
///            4:4:4 IDR on the sharp layer once the screen has been still for `sharpDelay`.
final class VideoPipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct Options {
        var displayID: CGDirectDisplayID
        var mode: StreamMode
        var codec: Codec
        var fps: Int
        var bitrateKbps: Int  // 0 = auto
        var maxWidth: Int
    }

    struct Frame {
        let data: Data
        let keyframe: Bool
        let captureUs: UInt64
        let refresh: Bool
        let sharp: Bool
        let rects: [FrameRect]?
        /// Host-clock stamps (µs) for FrameTiming (PROTOCOL.md §3.3): the capture callback ran,
        /// the buffer was handed to the encoder, the encoder output arrived.
        var callbackUs: UInt64? = nil
        var submitUs: UInt64? = nil
        var encodedUs: UInt64? = nil
    }

    /// Called on `queue` with each encoded access unit.
    var onFrame: ((Frame) -> Void)?
    /// Called on `queue` when the encoded config changes (before the next keyframe).
    /// `sharp` is the refinement-layer config in hybrid mode.
    var onConfig: ((_ base: VideoConfig, _ sharp: VideoConfig?) -> Void)?
    /// Returns false when the network is backed up and new frames should be skipped.
    var canSend: () -> Bool = { true }
    /// System audio rides on the base stream when set (see AudioPipeline). Set before `start()`.
    var audio: AudioPipeline?

    let queue = DispatchQueue(label: "glide.video", qos: .userInteractive)
    private(set) var options: Options
    private var baseStream: SCStream?
    private var sharpStream: SCStream?
    private var encoder: VideoEncoder?
    private var sharpEncoder: VideoEncoder?
    private(set) var config: VideoConfig?

    // Scheduling state (queue-confined)
    /// `us` = SCK presentation time (capture), `cb` = when our capture callback ran.
    private var latest: (pb: CVPixelBuffer, us: UInt64, cb: UInt64)?
    private var latestSharp: (pb: CVPixelBuffer, us: UInt64, cb: UInt64)?
    private var prevBase: CVPixelBuffer?
    private var dirty = false
    private var encoding = 0
    private var sharpEncoding = false
    private var maxInFlight = Int(ProcessInfo.processInfo.environment["GLIDE_INFLIGHT"] ?? "") ?? 1
    private var refinesLeft = 0
    private var nextIsRefresh = false
    private var lastNewFrameAt: UInt64 = 0
    private var lastBaseCaptureUs: UInt64 = 0
    /// Changes not yet delivered on the base layer: (capture time, rects or nil = full frame).
    /// Consumed by the encoded frame whose capture is at least as new (rects attach at send time,
    /// so the pixel diff runs in parallel with the hardware encode).
    private var pendingChanges: [(us: UInt64, rects: [CGRect]?)] = []
    private var idleTimer: DispatchSourceTimer?
    private var running = false
    private var frameSize = CGSize.zero
    private let sharpDelayUs: UInt64 = UInt64(ProcessInfo.processInfo.environment["GLIDE_SHARP_DELAY_MS"].flatMap { UInt64($0) } ?? 200) * 1000
    private var lastSignificantAt: UInt64 = 0
    private var lastSharpAt: UInt64 = 0
    private var dirtySinceSharp = true
    /// A large change happened since the last sharp frame (sharpen once it settles).
    private var significantSinceSharp = true
    /// Area (px) of small changes since the last sharp frame (sharpen once it adds up and goes quiet).
    private var smallAreaSinceSharp: CGFloat = 0
    private var colorLogged = 0
    private var sharpCaptureUs: UInt64 = 0
    private var rectsDuringSharp: [CGRect] = []
    private var fullDuringSharp = false
    /// Recent base-layer changes (capture time, rects or nil = full), for patching after a sharp frame.
    private var recentChanges: [(us: UInt64, rects: [CGRect]?)] = []
    // While small areas keep changing (spinners, clocks), re-sharpen at most this often: each 4K 4:4:4
    // IDR occupies the encoder ~25-40 ms and delays base frames behind it.
    private let sharpMinIntervalUs: UInt64 = 3_000_000
    private var debugRects = Int(ProcessInfo.processInfo.environment["GLIDE_DEBUG_RECTS"] ?? "") ?? 0
    /// Encoder PTS: a frame counter at the nominal rate (default), or wall-clock time
    /// (`GLIDE_PTS=wallclock`). VideoToolbox's real-time mode paces itself by PTS gaps: an
    /// isolated frame after an idle period (the usual interactive case: one keystroke, one frame)
    /// measured ~20 ms to encode at 2560x1440 with wall-clock PTS vs ~11 ms with consecutive
    /// PTS, at the same size (docs/LATENCY.md). The PTS is not used for anything else.
    private let wallclockPts = ProcessInfo.processInfo.environment["GLIDE_PTS"] == "wallclock"
    private var basePtsIndex: Int64 = 0
    private var sharpPtsIndex: Int64 = 0

    var hybrid: Bool { options.mode == .hybrid }

    // Stats
    var stats = Stats()
    struct Stats {
        var captured = 0, encoded = 0, skippedBusy = 0, skippedNet = 0, bytes = 0, keyframes = 0
        var sharpSent = 0, sharpDropped = 0, rectFrames = 0, rectCount = 0
        var identical = 0
        var encodeMs: [Double] = [], sharpMs: [Double] = [], diffUs: [Double] = []
        /// SCK frame PTS -> our capture callback (base stream), ms.
        var captureMs: [Double] = []
        /// Capture callback -> encoder submit (encoder busy / backpressure wait), ms.
        var waitMs: [Double] = []
        mutating func reset() { self = Stats() }
    }

    init(options: Options) {
        self.options = options
    }

    // MARK: Lifecycle

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == options.displayID }) ?? content.displays.first else {
            throw NSError(domain: "Glide", code: 1, userInfo: [NSLocalizedDescriptionKey: "no display to capture"])
        }
        options.displayID = display.displayID
        let mode = CGDisplayCopyDisplayMode(display.displayID)
        let nativeW = mode?.pixelWidth ?? display.width
        var pw = nativeW, ph = mode?.pixelHeight ?? display.height
        let scale = Float(pw) / Float(max(display.width, 1))
        if pw > options.maxWidth {  // downscale very large displays, keep aspect
            ph = ph * options.maxWidth / pw
            pw = options.maxWidth
        }
        pw &= ~1; ph &= ~1

        if options.mode == .hybrid && options.codec != .hevc { options.mode = .fast }
        let baseChroma: Chroma = (options.mode == .sharp && options.codec == .hevc) ? .yuv444 : .yuv420
        let fps = max(1, min(options.fps, 240))
        let autoBps = Int(Double(pw * ph * fps) * (baseChroma == .yuv444 ? 0.25 : 0.2))
        let bps = options.bitrateKbps > 0 ? options.bitrateKbps * 1000 : min(autoBps, 250_000_000)

        // Latency tuning knobs (docs/LATENCY.md hypothesis a): SCK's queue depth and frame-rate cap.
        let env = ProcessInfo.processInfo.environment
        let queueDepth = Int(env["GLIDE_SCK_QUEUE_DEPTH"] ?? "").map { max(1, min($0, 8)) } ?? 5
        let nativeInterval = env["GLIDE_SCK_INTERVAL"] == "native"
        func streamConfig(bgra: Bool, fps: Int) -> SCStreamConfiguration {
            let cfg = SCStreamConfiguration()
            cfg.width = pw
            cfg.height = ph
            // "native": no cap (CMTime.zero = every display refresh); default: 1/fps.
            cfg.minimumFrameInterval = nativeInterval ? .zero : CMTime(value: 1, timescale: CMTimeScale(fps))
            cfg.queueDepth = queueDepth
            cfg.showsCursor = false
            cfg.capturesAudio = false
            cfg.pixelFormat = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
            cfg.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
            cfg.colorSpaceName = CGColorSpace.sRGB
            cfg.scalesToFit = true
            return cfg
        }

        let enc = try VideoEncoder(.init(width: pw, height: ph, codec: options.codec, chroma: baseChroma, fps: fps, bitrate: bps))
        let vc = VideoConfig(width: UInt16(pw), height: UInt16(ph), codec: options.codec, chroma: baseChroma, scale: scale)
        var sharpEnc: VideoEncoder?
        var sharpVC: VideoConfig?
        if hybrid {
            // Rare, standalone IDRs: give them a generous budget so a still screen is crisp.
            sharpEnc = try VideoEncoder(.init(width: pw, height: ph, codec: .hevc, chroma: .yuv444, fps: 5, bitrate: min(Int(Double(pw * ph) * 4), 250_000_000)))
            sharpVC = VideoConfig(width: UInt16(pw), height: UInt16(ph), codec: .hevc, chroma: .yuv444, scale: scale)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let baseCfg = streamConfig(bgra: baseChroma == .yuv444, fps: fps)
        audio?.configure(baseCfg)
        let base = SCStream(filter: filter, configuration: baseCfg, delegate: self)
        try base.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if let audio {
            do { try audio.attach(to: base) } catch { log("audio: cannot add audio output (\(error.localizedDescription)); continuing without audio") }
        }
        var sharp: SCStream?
        if hybrid && ProcessInfo.processInfo.environment["GLIDE_NO_SHARP_STREAM"] != "1" {
            let s = SCStream(filter: filter, configuration: streamConfig(bgra: true, fps: fps), delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            sharp = s
        }

        queue.sync {
            self.encoder = enc
            self.sharpEncoder = sharpEnc
            self.config = vc
            self.latest = nil
            self.latestSharp = nil
            self.dirty = false
            self.pendingChanges = []
            self.prevBase = nil
            self.frameSize = CGSize(width: pw, height: ph)
            self.running = true
        }
        queue.async { self.onConfig?(vc, sharpVC) }
        try await base.startCapture()
        baseStream = base
        if let sharp { try await sharp.startCapture(); sharpStream = sharp }
        startIdleTimer()
        if wallclockPts { log("capture: encoder PTS = wall clock (GLIDE_PTS=wallclock)") }
        if queueDepth != 5 || nativeInterval { log("capture: SCK queueDepth \(queueDepth), minimumFrameInterval \(nativeInterval ? "native (none)" : "1/\(fps)")") }
        log("capture: display \(display.displayID) \(display.width)x\(display.height)pt (\(nativeW)px wide) -> \(pw)x\(ph)px, mode \(options.mode), \(options.codec) base \(baseChroma == .yuv444 ? "4:4:4" : "4:2:0")\(hybrid ? " + 4:4:4 sharp layer" : ""), \(fps)fps, \(bps / 1_000_000) Mbps")
    }

    func stop() async {
        queue.sync { running = false; idleTimer?.cancel(); idleTimer = nil }
        if let s = baseStream { try? await s.stopCapture() }
        if let s = sharpStream { try? await s.stopCapture() }
        baseStream = nil; sharpStream = nil
        queue.sync {
            encoder?.invalidate(); encoder = nil
            sharpEncoder?.invalidate(); sharpEncoder = nil
            latest = nil; latestSharp = nil; prevBase = nil
        }
    }

    func restart(mode: StreamMode? = nil, bitrateKbps: Int? = nil, fps: Int? = nil, maxWidth: Int? = nil) async throws {
        await stop()
        if let maxWidth, maxWidth > 0 { options.maxWidth = maxWidth }
        if let mode { options.mode = mode }
        if let bitrateKbps { options.bitrateKbps = bitrateKbps }
        if let fps, fps > 0 { options.fps = fps }
        try await start()
    }

    /// Sets the max encoded width for the next (re)start without restarting now (used when a display
    /// mode switch is about to trigger a re-capture anyway).
    func setMaxWidth(_ w: Int) { if w > 0 { options.maxWidth = w } }

    func requestKeyframe() {
        queue.async {
            self.encoder?.requestKeyframe()
            self.dirty = true
            self.dirtySinceSharp = true  // resend the sharp layer too
            self.pump()
        }
    }

    // MARK: Capture

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        let cbUs = hostTimeMicros()
        guard type == .screen, running, sb.isValid else { return }
        guard let atts = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = atts.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        // PTS is host-clock time (CLOCK_UPTIME_RAW timebase).
        let us = UInt64(max(0, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))) * 1_000_000)

        if stream === sharpStream {
            latestSharp = (pb, us, cbUs)
            if debugRects > 0 { log("debug: sharp frame us=\(us) lastBase=\(lastBaseCaptureUs)") }
            return
        }

        // Dirty rects for this update. SCK's are coarse (Electron apps report whole windows), so in
        // hybrid mode refine them with a real pixel diff against the previous capture.
        var sckRects: [CGRect]? = nil
        if let rawRects = info[.dirtyRects] as? [Any] {
            let rects = rawRects.compactMap { r -> CGRect? in
                guard let d = r as? NSDictionary else { return nil }
                return CGRect(dictionaryRepresentation: d as CFDictionary)
            }.filter { $0.width > 0 && $0.height > 0 }
            if rects.isEmpty { return }  // nothing visibly changed (e.g. cursor-only update)
            sckRects = rects
        }
        // Start encoding right away; the pixel diff (several ms at 4K) runs while the hardware
        // encoder works, and its rects are attached when the frame is sent.
        stats.captured += 1
        stats.captureMs.append(Double(Int64(cbUs) - Int64(us)) / 1000)
        if latest != nil, dirty { stats.skippedBusy += 1 }
        latest = (pb, us, cbUs)
        lastBaseCaptureUs = us
        dirty = true
        refinesLeft = hybrid ? 0 : 2
        nextIsRefresh = false
        lastNewFrameAt = hostTimeMicros()
        pump()

        var rects = sckRects
        if hybrid, ProcessInfo.processInfo.environment["GLIDE_NO_DIFF"] != "1", let prev = prevBase {
            let t0 = hostTimeMicros()
            if let diff = TileDiff.changedRects(prev: prev, cur: pb, within: sckRects) {
                stats.diffUs.append(Double(hostTimeMicros() - t0))
                if diff.isEmpty { stats.identical += 1 }
                rects = diff
            }
        }
        prevBase = pb
        pendingChanges.append((us, rects))
        if let rects {
            if !rects.isEmpty { noteChange(rects: rects, area: rects.reduce(CGFloat(0)) { $0 + $1.width * $1.height }, captureUs: us) }
        } else {
            noteChange(rects: nil, area: frameSize.width * frameSize.height, captureUs: us)
        }
    }

    // SCK dirty rects are in output-frame pixels (measured at 2560 and 3840 outputs of a 5120px display).

    /// Hybrid bookkeeping. "Significant" changes (big areas) restart the sharp countdown; small ones
    /// (spinners, clocks, a blinking caret) don't, but are remembered so the sharp frame can be
    /// followed by a base-layer patch of anything that changed during its encode.
    private func noteChange(rects: [CGRect]?, area: CGFloat, captureUs: UInt64) {
        guard hybrid else { return }
        let now = hostTimeMicros()
        if rects == nil || area > frameSize.width * frameSize.height * 0.05 {
            lastSignificantAt = now
            significantSinceSharp = true
            if debugSharp, sigLogs < 40 { sigLogs += 1; log("debug: significant change: \(rects == nil ? "no rects (full)" : "area \(Int(area)) = \(String(format: "%.1f", area * 100 / (frameSize.width * frameSize.height)))% in \(rects!.count) rects: \(rects!.prefix(3).map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" })")") }
        }
        dirtySinceSharp = true
        if rects != nil { smallAreaSinceSharp += area }
        recentChanges.append((captureUs, rects))
        if recentChanges.count > 64 { recentChanges.removeFirst(recentChanges.count - 64) }
        if sharpEncoding, captureUs > sharpCaptureUs {
            if let rects { rectsDuringSharp.append(contentsOf: rects) } else { fullDuringSharp = true }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        log("capture: stream stopped: \(error.localizedDescription)")
    }

    // MARK: Scheduling (queue)

    /// Consumes pending changes captured at or before `upTo` and returns padded/aligned/merged rects,
    /// or nil when a full update is required or cheaper.
    private func takeRects(upTo: UInt64, keyframe: Bool) -> [FrameRect]? {
        let taken = pendingChanges.filter { $0.us <= upTo }
        pendingChanges.removeAll { $0.us <= upTo }
        if keyframe || !hybrid || taken.isEmpty || taken.contains(where: { $0.rects == nil }) { return nil }
        let W = frameSize.width, H = frameSize.height
        let pad: CGFloat = 8, align: CGFloat = 16
        var out: [CGRect] = []
        for r in taken.flatMap({ $0.rects! }) {
            var x0 = floor((r.minX - pad) / align) * align, y0 = floor((r.minY - pad) / align) * align
            var x1 = ceil((r.maxX + pad) / align) * align, y1 = ceil((r.maxY + pad) / align) * align
            x0 = max(0, x0); y0 = max(0, y0); x1 = min(W, x1); y1 = min(H, y1)
            guard x1 > x0, y1 > y0 else { continue }
            var nr = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            var merged = true
            while merged {
                merged = false
                if let i = out.firstIndex(where: { $0.intersects(nr.insetBy(dx: -1, dy: -1)) }) {
                    nr = nr.union(out.remove(at: i)); merged = true
                }
            }
            out.append(nr)
        }
        let area = out.reduce(0) { $0 + $1.width * $1.height }
        if out.count > 64 || area > W * H * 0.5 { return nil }
        return out.map { FrameRect(x: UInt16($0.minX), y: UInt16($0.minY), w: UInt16($0.width), h: UInt16($0.height)) }
    }

    private func pump() {
        guard running, dirty, encoding < maxInFlight, let enc = encoder, let f = latest else { return }
        guard canSend() else { stats.skippedNet += 1; return }  // retried by the idle timer
        dirty = false
        let isRefresh = nextIsRefresh
        encoding += 1
        // Encoder PTS: strictly increasing even when re-encoding the same buffer (see wallclockPts).
        let submitUs = hostTimeMicros()
        if !isRefresh { stats.waitMs.append(Double(Int64(submitUs) - Int64(f.cb)) / 1000) }
        basePtsIndex += 1
        let encPts = wallclockPts ? CMTime(value: CMTimeValue(submitUs), timescale: 1_000_000)
                                  : CMTime(value: basePtsIndex, timescale: CMTimeScale(max(1, options.fps)))
        enc.encode(f.pb, pts: encPts) { [weak self] data, key, _, ms in
            let encodedUs = hostTimeMicros()
            guard let self else { return }
            self.queue.async {
                self.encoding -= 1
                self.stats.encoded += 1
                self.stats.bytes += data.count
                if key { self.stats.keyframes += 1 }
                self.stats.encodeMs.append(ms)
                let r = isRefresh ? nil : self.takeRects(upTo: f.us, keyframe: key)
                if let r { self.stats.rectFrames += 1; self.stats.rectCount += r.count }
                self.onFrame?(Frame(data: data, keyframe: key, captureUs: f.us, refresh: isRefresh, sharp: false, rects: r,
                                    callbackUs: f.cb, submitUs: submitUs, encodedUs: encodedUs))
                self.pump()
            }
        }
    }

    /// Hybrid: once no *significant* change has happened for `sharpDelayUs`, send one standalone
    /// 4:4:4 IDR of the current screen. If small areas keep changing (spinner, clock), repeat at most
    /// once per `sharpMinIntervalUs`. Anything captured after the sharp frame's capture is re-sent
    /// as a base-layer patch right after it, so the canvas never regresses.
    private var lastWhyLog: UInt64 = 0
    private var sigLogs = 0
    private let debugSharp = ProcessInfo.processInfo.environment["GLIDE_DEBUG_SHARP"] == "1"
    private func maybeSendSharp() {
        let now = hostTimeMicros()
        if debugSharp, now - lastWhyLog > 500_000 {
            lastWhyLog = now
            log("debug: sharp? hybrid=\(hybrid) encodingSharp=\(sharpEncoding) baseEncoding=\(encoding) dirty=\(dirty) dirtySinceSharp=\(dirtySinceSharp) haveEnc=\(sharpEncoder != nil) haveSharpBuf=\(latestSharp != nil) sigAgo=\((now - lastSignificantAt) / 1000)ms newAgo=\((now - lastNewFrameAt) / 1000)ms sinceSharp=\((now - lastSharpAt) / 1000)ms canSend=\(canSend())")
        }
        guard hybrid, running, !sharpEncoding, encoding == 0, !dirty, dirtySinceSharp,
              let senc = sharpEncoder, let s = latestSharp, latest != nil,
              now - lastSignificantAt >= sharpDelayUs,
              canSend() else { return }
        // Sharpen after a big change settles, or once small changes add up (>3% of the screen) and
        // the screen has been quiet for a second. A blinking caret or ticking clock alone never
        // triggers a full 4:4:4 IDR (each costs ~25-40 ms of encoder time at 4K).
        let screenArea = frameSize.width * frameSize.height
        let smallEnough = smallAreaSinceSharp > screenArea * 0.03 && now - lastNewFrameAt >= 1_000_000
        guard significantSinceSharp || smallEnough else { return }
        guard now - lastSharpAt >= 250_000 else { return }
        sharpEncoding = true
        sharpCaptureUs = s.us
        // Base frames captured after the sharp buffer must be re-applied on top of it.
        rectsDuringSharp = []
        fullDuringSharp = false
        for c in recentChanges where c.us > s.us + 1_000 {
            if let r = c.rects { rectsDuringSharp.append(contentsOf: r) } else { fullDuringSharp = true }
        }
        dirtySinceSharp = false
        significantSinceSharp = false
        smallAreaSinceSharp = 0
        lastSharpAt = now
        // Tag as BT.709 so VideoToolbox converts with the matrix only. SCK tags BGRA as sRGB, which
        // makes VT also convert the transfer curve: dark grays land ~1 code value off the base layer,
        // visible as faint squares where base-layer patches meet sharp pixels.
        CVBufferRemoveAttachment(s.pb, kCVImageBufferCGColorSpaceKey)
        CVBufferRemoveAttachment(s.pb, kCVImageBufferICCProfileKey)
        CVBufferSetAttachment(s.pb, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(s.pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(s.pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        if colorLogged < 2, let base = latest?.pb { colorLogged += 1; logColorSample(base: base, sharp: s.pb) }
        senc.requestKeyframe()
        sharpPtsIndex += 1
        let encPts = wallclockPts ? CMTime(value: CMTimeValue(now), timescale: 1_000_000) : CMTime(value: sharpPtsIndex, timescale: 5)
        senc.encode(s.pb, pts: encPts) { [weak self] data, key, _, ms in
            let encodedUs = hostTimeMicros()
            guard let self else { return }
            self.queue.async {
                self.sharpEncoding = false
                self.stats.sharpMs.append(ms)
                guard key else { self.stats.sharpDropped += 1; self.dirtySinceSharp = true; return }
                self.stats.sharpSent += 1
                self.stats.bytes += data.count
                self.onFrame?(Frame(data: data, keyframe: true, captureUs: s.us, refresh: true, sharp: true, rects: nil,
                                    callbackUs: s.cb, submitUs: now, encodedUs: encodedUs))
                // Patch whatever changed after the sharp capture (it was already sent on the base
                // layer, but the sharp frame just overwrote it on the viewer's canvas).
                if (self.fullDuringSharp || !self.rectsDuringSharp.isEmpty), let cur = self.latest {
                    self.pendingChanges.append((cur.us, self.fullDuringSharp ? nil : self.rectsDuringSharp))
                    self.rectsDuringSharp = []
                    self.fullDuringSharp = false
                    self.dirty = true
                    self.pump()
                }
            }
        }
    }

    /// Diagnostic: compares the same pixel in the base (420v from SCK) and sharp (BGRA) buffers.
    private func logColorSample(base: CVPixelBuffer, sharp: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(base, .readOnly); CVPixelBufferLockBaseAddress(sharp, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(sharp, .readOnly); CVPixelBufferUnlockBaseAddress(base, .readOnly) }
        guard CVPixelBufferGetPlaneCount(base) == 2, let yP = CVPixelBufferGetBaseAddressOfPlane(base, 0), let cP = CVPixelBufferGetBaseAddressOfPlane(base, 1),
              let bP = CVPixelBufferGetBaseAddress(sharp) else { return }
        var out: [String] = []
        for (fx, fy) in [(0.5, 0.5), (0.1, 0.9), (0.9, 0.1)] {
            let x = Int(Double(CVPixelBufferGetWidth(base)) * fx) & ~1, y = Int(Double(CVPixelBufferGetHeight(base)) * fy) & ~1
            let Y = yP.load(fromByteOffset: y * CVPixelBufferGetBytesPerRowOfPlane(base, 0) + x, as: UInt8.self)
            let cb = cP.load(fromByteOffset: (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(base, 1) + x, as: UInt8.self)
            let cr = cP.load(fromByteOffset: (y / 2) * CVPixelBufferGetBytesPerRowOfPlane(base, 1) + x + 1, as: UInt8.self)
            let o = y * CVPixelBufferGetBytesPerRow(sharp) + x * 4
            let b = Double(bP.load(fromByteOffset: o, as: UInt8.self)) / 255, g = Double(bP.load(fromByteOffset: o + 1, as: UInt8.self)) / 255, r = Double(bP.load(fromByteOffset: o + 2, as: UInt8.self)) / 255
            let ly = 0.2126 * r + 0.7152 * g + 0.0722 * b
            out.append(String(format: "(%d,%d) base YCbCr %d/%d/%d vs sharp-RGB->709 %.1f/%.1f/%.1f", x, y, Y, cb, cr, 16 + 219 * ly, 128 + 224 * (b - ly) / 1.8556, 128 + 224 * (r - ly) / 1.5748))
        }
        log("color check: " + out.joined(separator: "; "))
    }

    private func startIdleTimer() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(25), repeating: .milliseconds(25))
        t.setEventHandler { [weak self] in
            guard let self, self.running else { return }
            if self.dirty { self.pump(); return }
            if self.hybrid { self.maybeSendSharp(); return }
            // Fast mode idle refinement: re-encode the last frame so the encoder spends spare bits
            // sharpening static content (text).
            if self.refinesLeft > 0, self.encoding == 0, self.latest != nil,
               hostTimeMicros() - self.lastNewFrameAt > 120_000 {
                self.refinesLeft -= 1
                self.nextIsRefresh = true
                self.dirty = true
                self.pump()
            }
        }
        t.resume()
        idleTimer = t
    }
}
