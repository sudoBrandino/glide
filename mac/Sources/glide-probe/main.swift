import AppKit
import CoreMedia
import CryptoKit
import Foundation
import GlideCore
import ImageIO
import Network
import UniformTypeIdentifiers
import VideoToolbox

// Headless test client: connects to a glide-host, decodes frames with VideoToolbox, and reports
// throughput and end-to-end latency (exact when run on the same Mac as the host: shared clock).
// Usage: glide-probe [host] [--port N] [--seconds N] [--mode fast|sharp]
//                    [--animate] [--png out.png] [--forget-host]
// Security v2: the probe is a viewer with its own key (probe.json in the host's config folder, or
// $GLIDE_PROBE_CONFIG); the first connection pairs (the host must be in pairing mode; the code is
// printed here and must be confirmed on both sides; GLIDE_PAIR_CONFIRM=yes answers here).

var args = Array(CommandLine.arguments.dropFirst())
func take(_ f: String) -> String? {
    guard let i = args.firstIndex(of: f), i + 1 < args.count else { return nil }
    defer { args.removeSubrange(i...i + 1) }
    return args[i + 1]
}
func flag(_ f: String) -> Bool { if let i = args.firstIndex(of: f) { args.remove(at: i); return true }; return false }

let port = UInt16(take("--port") ?? "7420")!
let forgetHost = flag("--forget-host")
let seconds = Double(take("--seconds") ?? "8")!
let modeArg = take("--mode")
let mode: StreamMode = modeArg == "sharp" ? .sharp : modeArg == "hybrid" ? .hybrid : .fast
let pngPath = take("--png")
let animate = flag("--animate")
let animateFor = Double(take("--animate-for") ?? "") ?? 1e9
let viewW = UInt16(take("--view-width") ?? "2560")!
let listenMode = flag("--listen")
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
    var config: VideoConfig?
    var hostName = ""
}

func pct(_ a: [Double], _ p: Double) -> Double { let s = a.sorted(); return s.isEmpty ? -1 : s[min(s.count - 1, Int(Double(s.count) * p))] }

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
app.setActivationPolicy(animate ? .accessory : .prohibited)
var animWindow: NSWindow?
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

// MARK: Identity + pins (probe.json)

struct ProbeConfig: Codable {
    var key: String
    var pins: [String: String] = [:]
    static var url: URL {
        if let p = ProcessInfo.processInfo.environment["GLIDE_PROBE_CONFIG"], !p.isEmpty { return URL(fileURLWithPath: p) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Glide/probe.json")
    }
    static func load() -> ProbeConfig {
        if let d = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(ProbeConfig.self, from: d), Data(hex: c.key)?.count == 32 { return c }
        let c = ProbeConfig(key: Curve25519.KeyAgreement.PrivateKey().rawRepresentation.hex)
        c.save()
        return c
    }
    func save() {
        try? FileManager.default.createDirectory(at: ProbeConfig.url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: ProbeConfig.url.path, contents: try! JSONEncoder().encode(self), attributes: [.posixPermissions: 0o600])
    }
}
var probeConfig = ProbeConfig.load()
let probeKey = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(hex: probeConfig.key)!)
let pinTarget = listenModeFlagPeek() ? "listen:\(port)" : "\(host):\(port)"
func listenModeFlagPeek() -> Bool { CommandLine.arguments.contains("--listen") }
if forgetHost { probeConfig.pins[pinTarget] = nil; probeConfig.save(); print("forgot the host key pinned for \(pinTarget)"); exit(0) }

// MARK: Connection

let decoder = Decoder()
let lock = NSLock()
var stats = Stats()
let q = DispatchQueue(label: "probe")
var conn: NWConnection!
var ch: SecureChannel!
var started = Date()
var pingTimer: DispatchSourceTimer?
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
        case .authResult(let c):
            print("host rejected this probe: \(c) (pair it: glide-host --pair, then run the probe again)"); exit(1)
        case let .serverHello(_, name, cfg):
            lock.lock(); stats.hostName = name; stats.config = cfg; lock.unlock()
            decoder.reset(codec: cfg.codec)
            print("connected to '\(name)': \(cfg.width)x\(cfg.height) \(cfg.codec) chroma \(cfg.chroma)")
        case let .videoConfig(cfg):
            lock.lock(); stats.config = cfg; lock.unlock()
            decoder.reset(codec: cfg.codec)
        case let .videoFrame(_, cap, key, refresh, sharp, rects, data):
        if sharp { lock.lock(); stats.sharpFrames += 1; lock.unlock(); return }
        if let rects { lock.lock(); stats.rectFrames += 1; stats.rectCount += rects.count; if stats.sampleRects.count < 6 { stats.sampleRects.append(rects.prefix(3).map { "\($0.x),\($0.y) \($0.w)x\($0.h)" }.joined(separator: " | ")) }; lock.unlock() }
            lock.lock()
            stats.frames += 1; stats.bytes += data.count; if key { stats.keyframes += 1 }
            if !refresh { stats.e2eRecvMs.append(Double(Int64(now) - Int64(cap)) / 1000) }
            lock.unlock()
            decoder.decode(data) { _ in
                let t = hostTimeMicros()
                if !refresh { lock.lock(); stats.e2eDecodedMs.append(Double(Int64(t) - Int64(cap)) / 1000); lock.unlock() }
            }
        case let .pong(c, _):
            lock.lock(); stats.rttMs.append(Double(now - c) / 1000); lock.unlock()
        case .cursorShape: lock.lock(); stats.cursorShapes += 1; lock.unlock()
        default: break
        }
    }
    ch.onClose = { err in finish("closed: \(err.map { "\($0)" } ?? "eof")") }
    func sendHello() {
        started = Date()
        ch.send(ClientMessage.hello(version: GlideHandshake.version, caps: capsArg, viewW: viewW, viewH: viewW * 9 / 16, mode: mode, maxFps: 60, name: "glide-probe").encoded)
        let pt = DispatchSource.makeTimerSource(queue: q)
        pt.schedule(deadline: .now(), repeating: 0.25)
        pt.setEventHandler { ch.send(ClientMessage.ping(clientTimeUs: hostTimeMicros()).encoded) }
        pt.resume()
        pingTimer = pt
    }
    conn.stateUpdateHandler = { st in
        switch st {
        case .ready:
            let pinned = probeConfig.pins[pinTarget].flatMap { Data(hex: $0) }
            ch.performHandshake(identity: probeKey, name: "glide-probe", pinned: pinned) { res in
                guard case .success(let vc) = res else {
                    if case .failure(let e) = res { print("handshake failed: \(e)") }
                    exit(1)
                }
                guard vc.pairing else { ch.startReceiving(); sendHello(); return }
                // Pairing (docs/PROTOCOL.md §2.4): PairReveal -> code -> PairConfirm -> AuthResult.
                print("pairing with \(pinTarget) (host key \(GlideHandshake.fingerprint(vc.hostKey)), pairing window \(vc.hostInfo.pairingOpen ? "open" : "closed"))")
                let normal = ch.onMessage
                ch.onMessage = { d in
                    switch try? HostMessage.decode(d) {
                    case .pairReveal(let nH)?:
                        guard GlideHandshake.commitment(nH) == vc.hostInfo.commitment else { print("pairing: commitment mismatch"); exit(1) }
                        let code = GlideHandshake.sasCode(handshakeHash: vc.handshakeHash, viewerNonce: vc.viewerNonce, hostNonce: nH)
                        print("PAIRING CODE \(GlideHandshake.sasText(code)) — confirm on the Mac too")
                        DispatchQueue.global().async {
                            var ok: Bool
                            if let v = ProcessInfo.processInfo.environment["GLIDE_PAIR_CONFIRM"] { ok = ["1", "y", "yes"].contains(v.lowercased()) }
                            else { print("Does the Mac show the same code? [y/N] ", terminator: ""); fflush(stdout); ok = ["y", "yes"].contains((readLine() ?? "").lowercased()) }
                            ch.send(ClientMessage.pairConfirm(ok).encoded)
                            if !ok { print("pairing declined"); exit(1) }
                        }
                    case .authResult(let c)?:
                        guard c == .ok else { print("host: \(c)"); exit(1) }
                        probeConfig.pins[pinTarget] = vc.hostKey.hex
                        probeConfig.save()
                        print("paired; pinned host key for \(pinTarget)")
                        ch.onMessage = normal
                        sendHello()
                    default:
                        print("unexpected message during pairing"); exit(1)
                    }
                }
                ch.startReceiving()
            }
        case .failed(let e): print("connect failed: \(e)"); exit(1)
        default: break
        }
    }
    
    c.start(queue: q)
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
