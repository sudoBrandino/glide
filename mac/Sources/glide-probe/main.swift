import AppKit
import CoreMedia
import Foundation
import GlideCore
import ImageIO
import Network
import UniformTypeIdentifiers
import VideoToolbox

// Headless test client: connects to a glide-host, decodes frames with VideoToolbox, and reports
// throughput and end-to-end latency (exact when run on the same Mac as the host: shared clock).
// Usage: glide-probe [host] [--port N] [--password PW|--password-file F] [--seconds N] [--mode fast|sharp]
//                    [--animate] [--png out.png] [--pattern [--pattern-cell PT] [--pattern-kind target|draw]]
//        glide-probe --pattern-only [--seconds N] [--pattern-hz HZ]   (just the latency test pattern window, no connection)
// --pattern shows the docs/LATENCY.md block-code window (top-left of the main screen) with the host
// clock in it every frame; the probe reads it back from its decoded frames (ground truth: pattern
// clock -> decoded on the same Mac). The probe also asks for FrameTiming (PROTOCOL.md §3.3) and
// prints the host's per-stage breakdown.

var args = Array(CommandLine.arguments.dropFirst())
func take(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }

let port = UInt16(take("--port") ?? "7420")!
var password = take("--password") ?? ProcessInfo.processInfo.environment["GLIDE_PASSWORD"] ?? ""
if let f = take("--password-file") { password = (try! String(contentsOfFile: f, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines) }
let seconds = Double(take("--seconds") ?? "8")!
let modeArg = take("--mode")
let mode: StreamMode = modeArg == "sharp" ? .sharp : modeArg == "hybrid" ? .hybrid : .fast
let pngPath = take("--png")
let animate = flag("--animate")
let animateFor = Double(take("--animate-for") ?? "") ?? 1e9
let viewW = UInt16(take("--view-width") ?? "2560")!
let listenMode = flag("--listen")
let patternOnly = flag("--pattern-only")
let showPattern = flag("--pattern") || patternOnly
let patternCell = CGFloat(Double(take("--pattern-cell") ?? "8") ?? 8)
let patternKind: UInt8 = take("--pattern-kind") == "draw" ? BlockCode.kindDraw : BlockCode.kindTarget
/// Update the code only this often (0 = every display frame). Low rates mimic typing: isolated frames.
let patternHz = Double(take("--pattern-hz") ?? "0") ?? 0
let host = args.first ?? "127.0.0.1"

// MARK: Decoder

final class Decoder {
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var codec: Codec = .hevc
    var lastImage: CVPixelBuffer?
    var decodeMs: [Double] = []
    var errors = 0

    func reset(codec: Codec) {
        if let s = session { VTDecompressionSessionInvalidate(s) }
        session = nil; format = nil; self.codec = codec
    }

    static func splitAnnexB(_ d: Data) -> [Data] {
        var nals: [Data] = []
        let b = [UInt8](d)
        var i = 0, start = -1
        while i + 3 <= b.count {
            if b[i] == 0, b[i + 1] == 0, (b[i + 2] == 1 || (i + 3 < b.count && b[i + 2] == 0 && b[i + 3] == 1)) {
                let scLen = b[i + 2] == 1 ? 3 : 4
                if start >= 0 { nals.append(Data(b[start..<i])) }
                i += scLen; start = i
            } else { i += 1 }
        }
        if start >= 0, start < b.count { nals.append(Data(b[start...])) }
        return nals
    }

    func decode(_ annexB: Data, done: @escaping (Double) -> Void) {
        let nals = Decoder.splitAnnexB(annexB)
        var params: [Data] = [], slices: [Data] = []
        for n in nals where !n.isEmpty {
            let isParam = codec == .hevc ? [32, 33, 34].contains(Int((n[n.startIndex] >> 1) & 0x3F)) : [7, 8].contains(Int(n[n.startIndex] & 0x1F))
            if isParam { params.append(n) } else { slices.append(n) }
        }
        if !params.isEmpty {
            var fd: CMFormatDescription?
            let ptrs = params.map { p -> UnsafePointer<UInt8> in let m = UnsafeMutablePointer<UInt8>.allocate(capacity: p.count); p.copyBytes(to: m, count: p.count); return UnsafePointer(m) }
            defer { ptrs.forEach { $0.deallocate() } }
            let sizes = params.map { $0.count }
            let st = codec == .hevc
                ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &fd)
                : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: params.count, parameterSetPointers: ptrs, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &fd)
            if st == noErr, let fd, format == nil || !CMFormatDescriptionEqual(fd, otherFormatDescription: format!) {
                if let s = session { VTDecompressionSessionInvalidate(s) }
                format = fd
                var s: VTDecompressionSession?
                let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
                VTDecompressionSessionCreate(allocator: nil, formatDescription: fd, decoderSpecification: nil, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &s)
                session = s
            }
        }
        guard let session, let format, !slices.isEmpty else { return }
        var avcc = Data()
        for s in slices { var be = UInt32(s.count).bigEndian; avcc.append(Data(bytes: &be, count: 4)); avcc.append(s) }
        var block: CMBlockBuffer?
        let mem = UnsafeMutableRawPointer.allocate(byteCount: avcc.count, alignment: 16)
        avcc.copyBytes(to: mem.assumingMemoryBound(to: UInt8.self), count: avcc.count)
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: mem, blockLength: avcc.count, blockAllocator: kCFAllocatorMalloc, customBlockSource: nil, offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        var sb: CMSampleBuffer?
        var size = avcc.count
        CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sb)
        let t0 = CFAbsoluteTimeGetCurrent()
        let st = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sb!, flags: [], infoFlagsOut: nil) { [self] status, _, img, _, _ in
            if status != noErr || img == nil { errors += 1; return }
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            decodeMs.append(ms)
            lastImage = img
            done(ms)
        }
        if st != noErr { errors += 1 }
    }
}

// MARK: Stats

struct Stats {
    var frames = 0, keyframes = 0, bytes = 0, cursorShapes = 0, sharpFrames = 0, rectFrames = 0, rectCount = 0
    var sampleRects: [String] = []
    var e2eRecvMs: [Double] = [], e2eDecodedMs: [Double] = [], rttMs: [Double] = []
    /// FrameTiming stages (ms): capture->callback, callback->submit, encode, encoded->sent, enqueued->received.
    var capCbMs: [Double] = [], waitMs: [Double] = [], encodeMs: [Double] = [], sendMs: [Double] = [], netMs: [Double] = []
    var timings = 0
    /// Pattern clock -> decoded here (ground truth), ms; and the frame's capture -> decoded for comparison.
    var gtMs: [Double] = [], gtCaptureMs: [Double] = []
    var lastCode: UInt32?
    var config: VideoConfig?
    var hostName = ""
}

func pp(_ a: [Double]) -> String { String(format: "%.1f/%.1f", pct(a, 0.5), pct(a, 0.95)) }
func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? -1 : s[min(s.count - 1, Int(Double(s.count) * p))] }

// MARK: Latency test pattern (docs/LATENCY.md)

final class PatternView: NSView {
    var counter: UInt8 = 0
    var value: UInt32 = 0
    private var link: CADisplayLink?

    func start() {
        let l = displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
    }

    private var lastUpdate = 0.0
    @objc func tick(_ l: CADisplayLink) {
        if patternHz > 0 {
            guard l.timestamp - lastUpdate >= 1 / patternHz else { return }
            lastUpdate = l.timestamp
        }
        // targetTimestamp: when this frame is due on the display (CACurrentMediaTime = host clock).
        let t = patternKind == BlockCode.kindTarget ? l.targetTimestamp : CACurrentMediaTime()
        value = UInt32(truncatingIfNeeded: UInt64(max(0, t) * 1_000_000))
        counter &+= 1
        needsDisplay = true
        displayIfNeeded()
    }

    override func draw(_ r: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        BlockCode.draw(in: ctx, origin: .zero, cell: patternCell, value: value, kind: patternKind, counter: counter)
    }
}

/// Reads the block code from decoded BGRA frames (Swift port of windows/src/blockcode.rs scan_row).
enum PatternReader {
    static func scanRow(_ row: [UInt8]) -> (value: UInt32, kind: UInt8)? {
        guard row.count > BlockCode.cells * 3 else { return nil }
        var runs: [(start: Int, len: Int, white: Bool)] = []
        var start = 0, cur = row[0] >= 128
        for x in 1..<row.count where (row[x] >= 128) != cur {
            runs.append((start, x - start, cur)); start = x; cur = !cur
        }
        runs.append((start, row.count - start, cur))
        let exp: [Double] = [1, 1, 2, 2, 1]
        guard runs.count > 6 else { return nil }
        for i in 0..<(runs.count - 6) where !runs[i].white && runs[i + 1].white {
            let r = Array(runs[(i + 1)...(i + 5)])
            let c = Double(r[4].start + r[4].len - r[0].start) / 7
            guard c >= 2.5, c <= 64, Double(runs[i].len) >= 1.5 * c,
                  zip(r, exp).allSatisfy({ abs(Double($0.0.len) - $0.1 * c) <= max(1.5, 0.35 * c * $0.1) }) else { continue }
            var bits: [Bool] = []
            for k in 0..<BlockCode.cells {
                let x = Int((Double(r[0].start) + (Double(k) + 0.5) * c).rounded())
                guard x >= 1, x + 1 < row.count else { break }
                bits.append((Int(row[x - 1]) + Int(row[x]) + Int(row[x + 1])) / 3 >= 128)
            }
            guard bits.count == BlockCode.cells else { continue }
            var b = [UInt8](repeating: 0, count: 7)
            for (k, bit) in bits.enumerated() where bit { b[k / 8] |= 1 << (7 - UInt8(k % 8)) }
            guard b[0] == BlockCode.sync, BlockCode.crc8(Array(b[1...5])) == b[6] else { continue }
            return (UInt32(b[1]) << 24 | UInt32(b[2]) << 16 | UInt32(b[3]) << 8 | UInt32(b[4]), b[5] >> 4)
        }
        return nil
    }

    static var row: Int?
    /// Finds the pattern (full scan until located, then the known row) in a BGRA frame.
    static func read(_ pb: CVPixelBuffer) -> (value: UInt32, kind: UInt8)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        func luma(_ y: Int) -> [UInt8] {
            let p = base + y * bpr
            return (0..<w).map { x in UInt8((Int(p[x * 4]) + 2 * Int(p[x * 4 + 1]) + Int(p[x * 4 + 2])) / 4) }
        }
        if let y = row, y < h, let v = scanRow(luma(y)) { return v }
        var first: Int?, last = 0
        for y in stride(from: 0, to: h, by: 2) {
            if scanRow(luma(y)) != nil { if first == nil { first = y }; last = y } else if first != nil { break }
        }
        guard let f = first else { row = nil; return nil }
        row = (f + last) / 2
        return scanRow(luma(row!))
    }
}

func unwrap32(_ low: UInt32, near now: UInt64) -> UInt64 {
    let d = Int64(Int32(bitPattern: UInt32(truncatingIfNeeded: now) &- low))
    return UInt64(max(0, Int64(now) - d))
}

// MARK: Animation window (optional): gives the host something to stream.

final class AnimView: NSView {
    var phase = 0.0
    override func draw(_ r: NSRect) {
        NSColor.black.setFill(); bounds.fill()
        let n = 12
        for i in 0..<n {
            let a = phase + Double(i) * .pi * 2 / Double(n)
            NSColor(hue: CGFloat(i) / CGFloat(n), saturation: 0.8, brightness: 1, alpha: 1).setFill()
            let c = CGPoint(x: bounds.midX + cos(a) * 100, y: bounds.midY + sin(a) * 100)
            NSBezierPath(ovalIn: NSRect(x: c.x - 14, y: c.y - 14, width: 28, height: 28)).fill()
        }
        let s = String(format: "glide probe %.2f", phase) as NSString
        s.draw(at: NSPoint(x: 10, y: 10), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)])
    }
}

let app = NSApplication.shared
app.setActivationPolicy(animate || showPattern ? .accessory : .prohibited)
var animWindow: NSWindow?
var patternWindow: NSWindow?
if showPattern {
    let scr = NSScreen.main!.visibleFrame
    let size = NSSize(width: CGFloat(BlockCode.widthCells) * patternCell, height: CGFloat(BlockCode.heightCells) * patternCell)
    let w = NSWindow(contentRect: NSRect(x: scr.minX + 16, y: scr.maxY - size.height - 16, width: size.width, height: size.height),
                     styleMask: [.borderless], backing: .buffered, defer: false)
    let v = PatternView(frame: NSRect(origin: .zero, size: size))
    w.contentView = v
    w.level = .statusBar
    w.isOpaque = true
    w.ignoresMouseEvents = true
    w.orderFrontRegardless()
    v.start()
    patternWindow = w
    print("latency pattern: \(Int(size.width))x\(Int(size.height)) pt at the top-left of the main screen, \(patternKind == BlockCode.kindTarget ? "display-link target time" : "draw time"), \(patternHz > 0 ? "\(patternHz) updates/s" : "every display frame")")
}
if animate {
    let scr = NSScreen.main!.visibleFrame
    let w = NSWindow(contentRect: NSRect(x: scr.maxX - 340, y: scr.minY + 20, width: 320, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
    w.title = "Glide probe (test animation)"
    let v = AnimView(frame: w.contentView!.bounds)
    w.contentView = v
    w.level = .floating
    w.orderFrontRegardless()
    animWindow = w
    let animStart = Date()
    Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in if Date().timeIntervalSince(animStart) < animateFor { v.phase += 0.05; v.needsDisplay = true } else if w.isVisible { w.orderOut(nil) } }
}

// MARK: Connection

let decoder = Decoder()
let lock = NSLock()
var stats = Stats()
let q = DispatchQueue(label: "probe")
var conn: NWConnection!
var ch: SecureChannel!
var started = Date()
var pingTimer: DispatchSourceTimer?
/// Receive time (host clock) per frame id, until its FrameTiming arrives.
var recvAt: [UInt32: UInt64] = [:]
let capsArg: CodecCaps = flag("--h264") ? [.h264] : [.hevc420, .hevc444, .h264]

func finish(_ reason: String) {
    lock.lock(); let s = stats; lock.unlock()
    let dur = Date().timeIntervalSince(started)
    print("""
    == glide-probe (\(reason)) ==
    host: \(s.hostName)  config: \(s.config.map { "\($0.width)x\($0.height) \($0.codec) \($0.chroma == .yuv444 ? "4:4:4" : "4:2:0") scale \($0.scale)" } ?? "-")
    frames: \(s.frames) in \(String(format: "%.1f", dur))s (\(String(format: "%.1f", Double(s.frames) / dur)) fps), keyframes \(s.keyframes), \(String(format: "%.1f", Double(s.bytes) * 8 / dur / 1e6)) Mbps, cursor shapes \(s.cursorShapes)
    capture->received   ms: p50 \(String(format: "%.1f", pct(s.e2eRecvMs, 0.5)))  p95 \(String(format: "%.1f", pct(s.e2eRecvMs, 0.95)))  max \(String(format: "%.1f", pct(s.e2eRecvMs, 1)))
    capture->decoded    ms: p50 \(String(format: "%.1f", pct(s.e2eDecodedMs, 0.5)))  p95 \(String(format: "%.1f", pct(s.e2eDecodedMs, 0.95)))
    decode only         ms: p50 \(String(format: "%.2f", pct(decoder.decodeMs, 0.5)))  errors \(decoder.errors)
    rtt                 ms: p50 \(String(format: "%.2f", pct(s.rttMs, 0.5)))
    host stages (FrameTiming, \(s.timings) frames) ms p50/p95: capture->callback \(pp(s.capCbMs))  callback->encode \(pp(s.waitMs))  encode \(pp(s.encodeMs))  encoded->sent \(pp(s.sendMs))  network \(pp(s.netMs))
    ground truth (pattern clock -> decoded, \(s.gtMs.count) codes) ms: p5 \(String(format: "%.1f", pct(s.gtMs, 0.05)))  p50 \(String(format: "%.1f", pct(s.gtMs, 0.5)))  p95 \(String(format: "%.1f", pct(s.gtMs, 0.95)));  same frames capture->decoded p50 \(String(format: "%.1f", pct(s.gtCaptureMs, 0.5)))
    hybrid: sharp frames \(s.sharpFrames), rect frames \(s.rectFrames) (avg \(s.rectFrames > 0 ? s.rectCount / s.rectFrames : 0) rects)
    sample rects: \(s.sampleRects.joined(separator: " || "))
    """)
    if let pngPath, let img = decoder.lastImage {
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(img, options: nil, imageOut: &cg)
        if let cg, let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: pngPath) as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(dst, cg, nil); CGImageDestinationFinalize(dst)
            print("last frame written to \(pngPath)")
        }
    }
    exit(s.frames > 0 && decoder.errors == 0 ? 0 : 1)
}

func wire(_ c: NWConnection) {
    conn = c
    ch = SecureChannel(connection: c, queue: q)
ch.onMessage = { d in
        guard let m = try? HostMessage.decode(d) else { print("bad host message"); return }
        let now = hostTimeMicros()
        switch m {
        case let .serverHello(_, name, cfg):
            lock.lock(); stats.hostName = name; stats.config = cfg; lock.unlock()
            decoder.reset(codec: cfg.codec)
            print("connected to '\(name)': \(cfg.width)x\(cfg.height) \(cfg.codec) chroma \(cfg.chroma)")
        case let .videoConfig(cfg):
            lock.lock(); stats.config = cfg; lock.unlock()
            decoder.reset(codec: cfg.codec)
        case let .videoFrame(fid, cap, key, refresh, sharp, rects, data):
            lock.lock(); recvAt[fid] = now; if recvAt.count > 512 { recvAt.removeAll() }; lock.unlock()
        if sharp { lock.lock(); stats.sharpFrames += 1; lock.unlock(); return }
        if let rects { lock.lock(); stats.rectFrames += 1; stats.rectCount += rects.count; if stats.sampleRects.count < 6 { stats.sampleRects.append(rects.prefix(3).map { "\($0.x),\($0.y) \($0.w)x\($0.h)" }.joined(separator: " | ")) }; lock.unlock() }
            lock.lock()
            stats.frames += 1; stats.bytes += data.count; if key { stats.keyframes += 1 }
            if !refresh { stats.e2eRecvMs.append(Double(Int64(now) - Int64(cap)) / 1000) }
            lock.unlock()
            decoder.decode(data) { _ in
                let t = hostTimeMicros()
                if !refresh { lock.lock(); stats.e2eDecodedMs.append(Double(Int64(t) - Int64(cap)) / 1000); lock.unlock() }
                if showPattern, let img = decoder.lastImage, let code = PatternReader.read(img) {
                    lock.lock()
                    if code.value != stats.lastCode {  // first frame showing this value
                        stats.lastCode = code.value
                        stats.gtMs.append(Double(Int64(t) - Int64(unwrap32(code.value, near: t))) / 1000)
                        if !refresh { stats.gtCaptureMs.append(Double(Int64(t) - Int64(cap)) / 1000) }
                    }
                    lock.unlock()
                }
            }
        case let .frameTiming(ft):
            func at(_ d: UInt32) -> Double? { d == timingUnknown ? nil : Double(d) / 1000 }
            lock.lock()
            stats.timings += 1
            if ft.flags & 2 == 0 {
                if let v = at(ft.callback) { stats.capCbMs.append(v) }
                if let a = at(ft.callback), let b = at(ft.submit) { stats.waitMs.append(b - a) }
                if let a = at(ft.submit), let b = at(ft.encoded) { stats.encodeMs.append(b - a) }
                if let a = at(ft.encoded), let b = at(ft.sent) { stats.sendMs.append(b - a) }
                if let e = at(ft.enqueued), let r = recvAt[ft.frameId] { stats.netMs.append(Double(Int64(r) - Int64(ft.captureUs)) / 1000 - e) }
            }
            recvAt[ft.frameId] = nil
            lock.unlock()
        case let .pong(c, _):
            lock.lock(); stats.rttMs.append(Double(now - c) / 1000); lock.unlock()
        case .cursorShape: lock.lock(); stats.cursorShapes += 1; lock.unlock()
        default: break
        }
    }
    ch.onClose = { err in finish("closed: \(err.map { "\($0)" } ?? "eof")") }
    conn.stateUpdateHandler = { st in
        switch st {
        case .ready:
            ch.performHandshake(password: password) { err in
                if let err { print("handshake failed: \(err)"); exit(1) }
                ch.startReceiving()
                started = Date()
                ch.send(ClientMessage.hello(version: 1, caps: capsArg, viewW: viewW, viewH: viewW * 9 / 16, mode: mode, maxFps: 60, name: "glide-probe").encoded)
                ch.send(ClientMessage.latencyEnable(flags: 1).encoded)
                let pt = DispatchSource.makeTimerSource(queue: q)
                pt.schedule(deadline: .now(), repeating: 0.25)
                pt.setEventHandler { ch.send(ClientMessage.ping(clientTimeUs: hostTimeMicros()).encoded) }
                pt.resume()
                pingTimer = pt
            }
        case .failed(let e): print("connect failed: \(e)"); exit(1)
        default: break
        }
    }
    
    c.start(queue: q)
}
// Offline check of the pattern drawing + reader (no window, no connection).
if flag("--pattern-selftest") {
    var pb: CVPixelBuffer?
    CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pb)
    CVPixelBufferLockBaseAddress(pb!, [])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb!), width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb!),
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
    ctx.setFillColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 1280, height: 720))
    let now = hostTimeMicros()
    BlockCode.draw(in: ctx, origin: CGPoint(x: 101, y: 333), cell: 8, value: UInt32(truncatingIfNeeded: now), kind: 1, counter: 3)
    CVPixelBufferUnlockBaseAddress(pb!, [])
    let r = PatternReader.read(pb!)
    let ok = r?.value == UInt32(truncatingIfNeeded: now) && r?.kind == 1 && unwrap32(r!.value, near: now + 5000) == now
    print(ok ? "pattern selftest ok (row \(PatternReader.row ?? -1))" : "pattern selftest FAILED: \(String(describing: r))")
    exit(ok ? 0 : 1)
}
if patternOnly {
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { print("pattern window closed"); exit(0) }
    app.run()
}
if listenMode {
    let l = try! NWListener(using: SecureChannel.tcpParameters(), on: NWEndpoint.Port(rawValue: port)!)
    l.newConnectionHandler = { c in print("accepted connection from \(c.endpoint)"); l.cancel(); wire(c) }
    l.start(queue: q)
    print("listening on \(port) for a dialing host")
} else {
    wire(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: SecureChannel.tcpParameters()))
}

DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { finish("done") }
app.run()
