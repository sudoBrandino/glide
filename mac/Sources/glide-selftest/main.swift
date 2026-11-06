import AppKit
import CoreMedia
import CryptoKit
import Foundation
import GlideCore

// Protocol self-test. Security v2 vectors: docs/test-vectors.json (Python reference transcript),
// docs/test-vectors-rust.json (Rust-generated transcript) and docs/noise-vectors.json (official
// Noise vectors), all next to the path given (default ../docs/test-vectors.json).
// Usage: glide-selftest [path/to/test-vectors.json]

var failures = 0
func check(_ ok: Bool, _ what: String) {
    if ok { print("  ok   \(what)") } else { failures += 1; print("  FAIL \(what)") }
}

func run() throws {
    let path = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "../docs/test-vectors.json"
    let docs = URL(fileURLWithPath: path).deletingLastPathComponent()
    try noiseVectorTests(docs.appendingPathComponent("noise-vectors.json").path)
    try transcriptTests(path)
    try transcriptTests(docs.appendingPathComponent("test-vectors-rust.json").path)
    try wireUnitTests()
    pairingLogicTests()
    try channelTests()
    try controlSocketTests()

    print("messages + keymap:")
    if case let .hello(_, caps, vw, vh, _, fps, name) = try ClientMessage.decode(Data(hex: "01020007000000000f7008003c0b00746573742d766965776572")!) {
        check(caps == [.hevc420, .hevc444, .h264] && vw == 3840 && vh == 2160 && fps == 60 && name == "test-viewer", "ClientHello fields")
    } else { check(false, "ClientHello decode") }
    if case let .mouseMove(x, y) = try ClientMessage.decode(Data(hex: "100000803e0000403f")!) {
        check(x == 0.25 && y == 0.75, "MouseMove fields")
    } else { check(false, "MouseMove decode") }
    let sh = "0202000900746573742d686f7374000aa00501000000000040"
    if case let .serverHello(_, name, cfg) = try HostMessage.decode(Data(hex: sh)!) {
        check(name == "test-host" && cfg == VideoConfig(width: 2560, height: 1440, codec: .hevc, chroma: .yuv420, scale: 2.0), "ServerHello fields")
        check(HostMessage.serverHello(version: 2, hostName: name, config: cfg).encoded.hex == sh, "ServerHello re-encode")
    } else { check(false, "ServerHello decode") }

    // Keymap: letters, digits, Enter..Space, punctuation, modifiers all mapped.
    var missing: [String] = []
    for u in Array(UInt16(0x04)...0x38) + Array(UInt16(0xE0)...0xE7) where HIDKeymap.macKeyCode(forUsage: u) == nil {
        missing.append(String(format: "0x%02x", u))
    }
    check(missing.isEmpty, "keymap coverage \(missing)")
}

func policyChecks() {
    // Mode list of the BetterDisplay 16:9 virtual display on the M3 Pro host (plus 4:3 extras).
    var modes: [DisplayModeInfo] = []
    for (w, h) in [(800, 600), (1024, 768), (1280, 960), (1344, 1008), (1600, 1200)] { modes.append(.init(width: w, height: h, pixelWidth: w, pixelHeight: h)) }
    let sixteenNine = [960, 1024, 1280, 1344, 1408, 1472, 1536, 1600, 1664, 1728, 1792, 1856, 1920, 1984, 2048, 2112, 2176, 2240, 2304,
                       2368, 2432, 2496, 2560, 2624, 2688, 2752, 2816, 2880, 2944, 3008, 3072, 3136, 3200, 3264, 3328, 3392, 3456, 3520, 3584, 3648, 3712, 3840]
    for w in sixteenNine {
        let h = w * 9 / 16
        modes.append(.init(width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2))   // HiDPI
        if w % 128 == 0 || w == 1344 || w == 1408 || w == 1600 || w == 1664 || w == 1792 || w == 2176 || w == 2304 || w == 2432 || w == 2688 || w == 2816 || w == 2944 || w == 3200 || w == 3328 || w == 3456 || w == 3712 {
            modes.append(.init(width: w, height: h, pixelWidth: w, pixelHeight: h))      // 1x
        }
    }
    for w in [3968, 4096, 4224, 4352, 4480, 4608, 4736, 4864, 4992, 5120] { modes.append(.init(width: w, height: w * 9 / 16, pixelWidth: w, pixelHeight: w * 9 / 16)) }
    func one(_ w: Int, _ h: Int) -> DisplayModeInfo { .init(width: w, height: h, pixelWidth: w, pixelHeight: h) }
    func hi(_ w: Int, _ h: Int) -> DisplayModeInfo { .init(width: w, height: h, pixelWidth: w * 2, pixelHeight: h * 2) }
    func pick(_ p: DisplayModePreference, _ w: Int, _ h: Int, current: DisplayModeInfo? = nil, k: HighDPIViewerChoice = .retina, _ m: [DisplayModeInfo]? = nil) -> DisplayModeInfo? {
        DisplayModePolicy.choose(preference: p, viewerW: w, viewerH: h, modes: m ?? modes, current: current, highDPIChoice: k)
    }
    check(pick(.automatic, 2560, 1440) == one(2560, 1440), "policy: 1440p viewer -> 2560x1440 crisp (HiDPI off)")
    check(pick(.automatic, 3840, 2160) == hi(1920, 1080), "policy: 4K viewer -> looks like 1920x1080 HiDPI (retina)")
    check(pick(.automatic, 3840, 2160, k: .smooth) == hi(2560, 1440), "policy: 4K viewer, more-space choice -> looks like 2560x1440 HiDPI")
    check(pick(.automatic, 1920, 1080) == one(1920, 1080), "policy: 1080p viewer -> 1920x1080 crisp")
    check(pick(.crisp, 3840, 2160) == one(3840, 2160), "policy: crisp on 4K -> 3840x2160 1x")
    check(pick(.retina, 2560, 1440) == hi(1280, 720), "policy: retina on 1440p -> looks like 1280x720")
    check(pick(.smooth, 2560, 1440) == hi(1664, 936), "policy: smooth on 1440p -> looks like 1664x936 (3328px, downscaled)")
    check(pick(.automatic, 3440, 1440) == one(2560, 1440), "policy: ultrawide 3440x1440 -> largest fitting 2560x1440")
    check(pick(.crisp, 1920, 1200) == one(1920, 1080), "policy: 16:10 viewer -> largest fitting 1920x1080")
    check(pick(.crisp, 1600, 1200) == one(1600, 1200), "policy: 4:3 viewer -> matching aspect 1600x1200")
    check(pick(.crisp, 640, 480) == one(800, 600), "policy: tiny viewer -> smallest mode")
    check(pick(.automatic, 5120, 2880) == hi(2560, 1440), "policy: 5K viewer -> retina looks like 2560x1440")
    check(pick(.manual, 2560, 1440) == nil, "policy: manual -> no change")
    check(pick(.automatic, 0, 0) == nil, "policy: unknown viewer size -> no change")
    var cur = one(2560, 1440); cur.refreshRate = 60
    check(pick(.automatic, 2560, 1440, current: cur) == cur, "policy: already matching -> current mode (no switch)")
    let noHi = modes.filter { !$0.hiDPI }
    check(pick(.retina, 3840, 2160, noHi) == one(3840, 2160), "policy: no HiDPI modes -> falls back to crisp")
    let hz = [DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 60),
              DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440, refreshRate: 120)]
    check(pick(.crisp, 2560, 1440, hz)?.refreshRate == 120, "policy: prefers higher refresh")
    check(pick(.crisp, 2560, 1440, current: hz[0], hz)?.refreshRate == 60, "policy: keeps current refresh when it matches")
}

func registryChecks() {
    final class S { let id: Int; init(_ i: Int) { id = i } }
    let r = SessionRegistry<S>(maxPending: 2, maxPendingPerSource: 2)
    let a = S(1), b = S(2), c = S(3), d = S(4), e = S(5)
    check(r.admit(a, source: "10.0.0.1") == nil, "registry: admit first")
    check(r.current == nil, "registry: unauthenticated is not current")
    let ra = r.authenticated(a)
    check(ra.promoted && ra.replaced == nil && r.current === a, "registry: authenticated -> current")
    check(r.admit(b, source: "10.0.0.2") == nil && r.admit(c, source: "10.0.0.3") == nil, "registry: admit two pending")
    check(r.admit(d, source: "10.0.0.4") === b, "registry: full -> evicts oldest pending, never refuses")
    check(r.current === a, "registry: pending connections don't touch the active session")
    let x1 = S(10), x2 = S(11), x3 = S(12)
    let r2 = SessionRegistry<S>(maxPending: 8, maxPendingPerSource: 2)
    r2.admit(x1, source: "x"); r2.admit(x2, source: "x")
    check(r2.admit(x3, source: "x") === x1 && r2.pendingCount == 2, "registry: per-source cap evicts that source's oldest")
    r.ended(b)  // evicted / wrong password / auth timeout
    check(r.current === a && r.pendingCount == 2, "registry: failed auth leaves active session alone")
    let rc = r.authenticated(c)
    check(rc.promoted && rc.replaced === a && r.current === c, "registry: new viewer replaces old only after auth")
    check(!r.ended(a) && r.current === c, "registry: replaced session ending doesn't clear current")
    check(!r.authenticated(e).promoted, "registry: never-admitted session can't be promoted")
    check(r.ended(c) && r.current == nil, "registry: active session ending clears current")
}

/// Clipboard sync (PROTOCOL.md §5): wire format, line endings, echo suppression.
func clipboardTests() throws {
    print("clipboard:")
    // Reference bytes from PROTOCOL.md §5 (also checked by the Rust tests and mock_host.py --selftest).
    let textMsg = ClientMessage.clipboard(ClipboardData(seq: 1, text: "hi\n"))
    check(textMsg.encoded.hex == "5001000000010103000000" + "68690a", "Clipboard text reference bytes")
    check(HostMessage.clipboard(ClipboardData(seq: 1, text: "hi\n")).encoded == textMsg.encoded, "Clipboard same layout both directions")
    let caps = HostMessage.clipboardCaps(formats: ClipboardData.capsText | ClipboardData.capsPNG, maxBytes: UInt32(ClipboardData.maxBytes))
    check(caps.encoded.hex == "510300000000000001", "ClipboardCaps reference bytes")
    if case let .clipboardCaps(f, m) = try HostMessage.decode(caps.encoded) {
        check(f == 3 && m == 16 << 20, "ClipboardCaps decode")
    } else { check(false, "ClipboardCaps decode") }

    // Round trips.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3])
    for c in [ClipboardData(seq: 7, text: "héllo — 世界 🎉\nline2"), ClipboardData(seq: 8, png: png),
              ClipboardData(seq: UInt32.max, text: "", png: png), ClipboardData(seq: 9)] {
        if case let .clipboard(d) = try ClientMessage.decode(ClientMessage.clipboard(c).encoded) {
            check(d == c, "Clipboard c2s roundtrip seq \(c.seq)")
        } else { check(false, "Clipboard c2s decode seq \(c.seq)") }
        if case let .clipboard(d) = try HostMessage.decode(HostMessage.clipboard(c).encoded) {
            check(d == c, "Clipboard s2c roundtrip seq \(c.seq)")
        } else { check(false, "Clipboard s2c decode seq \(c.seq)") }
    }
    // A text bigger than the old u16 `str` limit survives.
    let big = String(repeating: "x", count: 100_000)
    if case let .clipboard(d) = try HostMessage.decode(HostMessage.clipboard(ClipboardData(seq: 1, text: big)).encoded) {
        check(d.text == big, "Clipboard text > 64 KiB")
    } else { check(false, "Clipboard big decode") }

    // Unknown formats skipped, duplicate formats: first wins, invalid UTF-8 replaced.
    var w = Data([0x50, 2, 0, 0, 0, 4])
    w += Data([9, 2, 0, 0, 0, 0xAA, 0xBB])        // unknown format 9
    w += Data([1, 2, 0, 0, 0, 0x6F, 0x6B])        // text "ok"
    w += Data([1, 1, 0, 0, 0, 0x78])              // duplicate text: ignored
    w += Data([2, 2, 0, 0, 0, 0xFF, 0xC0])        // png
    if case let .clipboard(d) = try ClientMessage.decode(w) {
        check(d.seq == 2 && d.text == "ok" && d.png == Data([0xFF, 0xC0]), "Clipboard unknown/duplicate formats")
    } else { check(false, "Clipboard unknown/duplicate decode") }
    if case let .clipboard(d) = try ClientMessage.decode(Data([0x50, 1, 0, 0, 0, 1, 1, 2, 0, 0, 0, 0xFF, 0x41])) {
        check(d.text == "\u{FFFD}A", "Clipboard invalid UTF-8 replaced")
    } else { check(false, "Clipboard invalid UTF-8 decode") }
    let enc = textMsg.encoded
    var truncatedRejected = true
    for n in 1..<enc.count where (try? ClientMessage.decode(enc.prefix(n))) != nil { truncatedRejected = false }
    check(truncatedRejected, "Clipboard truncation rejected")

    // Line endings.
    check(ClipboardText.toWire("a\r\nb\rc\nd") == "a\nb\nc\nd", "CRLF/CR -> LF")
    check(ClipboardText.toWire("plain\n") == "plain\n", "LF unchanged")
    check(ClipboardText.toWire("x\r\ny\r\n") == "x\ny\n", "CRLF-only text converted")

    // FNV-1a 64 known values.
    check(fnv1a64(Data()) == 0xcbf2_9ce4_8422_2325 && fnv1a64(Data("a".utf8)) == 0xaf63_dc4c_8601_ec8c, "FNV-1a 64")

    // Echo suppression.
    var g = ClipboardEchoGuard()
    let h1 = ClipboardEchoGuard.hash(format: 1, Data("one".utf8)), h2 = ClipboardEchoGuard.hash(ClipboardData(text: "two"))!
    check(h1 != ClipboardEchoGuard.hash(format: 2, Data("one".utf8)), "hash distinguishes text from image bytes")
    g.baseline(marker: 5)
    check(!g.changed(marker: 5), "guard: baseline content not sent")
    check(g.changed(marker: 6) && g.shouldSend(hash: h1, marker: 6), "guard: local change sent")
    check(!g.changed(marker: 6), "guard: same marker not re-sent")
    check(!g.shouldApply(hash: h1, marker: 6), "guard: echo of what we sent not re-applied while unchanged")
    check(g.shouldApply(hash: h2, marker: 6), "guard: different content applied")
    check(g.changed(marker: 7) && !g.shouldSend(hash: h1, marker: 7), "guard: identical content not re-sent")
    check(g.shouldApply(hash: h1, marker: 7), "guard: same content applied after a local change")
    g.didApply(hash: h2, marker: 9)              // remote "two" written locally -> marker 9
    check(!g.changed(marker: 9), "guard: own write not echoed")
    check(g.changed(marker: 10) && !g.shouldSend(hash: h2, marker: 10), "guard: re-write of received content not echoed")
    check(g.changed(marker: 11) && g.shouldSend(hash: h1, marker: 11), "guard: new local content after apply sent")
    g.didApply(hash: h1, marker: 12)             // peer sends back what we sent: applied, never re-sent
    check(!g.changed(marker: 12) && !g.shouldSend(hash: h1, marker: 12), "guard: ping-pong stops")
}

/// NSPasteboard read/write rules on a private named pasteboard (never the user's general one).
func pasteboardTests() {
    print("pasteboard (private):")
    let pb = NSPasteboard(name: NSPasteboard.Name("io.github.sudobrandino.glide.selftest.\(getpid())"))
    defer { pb.releaseGlobally() }
    var g = ClipboardEchoGuard()
    g.baseline(marker: pb.changeCount)

    // Received text: written, our own write is not echoed, read back identical (hash match).
    let remote = ClipboardData(seq: 1, text: "a\nb ✓")
    guard case let .success((prepared, tiff0)) = ClipboardPasteboard.prepare(remote) else { return check(false, "prepare text") }
    check(prepared == remote && tiff0 == nil, "prepare text")
    let m1 = ClipboardPasteboard.write(prepared, tiff: nil, to: pb)
    g.didApply(hash: ClipboardEchoGuard.hash(prepared), marker: m1)
    check(!g.changed(marker: pb.changeCount), "own pasteboard write not echoed")
    let back = ClipboardPasteboard.read(pb)
    check(back == .text("a\nb ✓") && back?.hash == ClipboardEchoGuard.hash(remote), "text read back, same hash")
    check(!g.shouldApply(hash: ClipboardEchoGuard.hash(remote), marker: pb.changeCount), "re-received same text not re-applied")

    // Another app copies CRLF text: detected and normalized.
    pb.clearContents(); pb.setString("x\r\ny", forType: .string)
    check(g.changed(marker: pb.changeCount), "external change detected")
    let ext = ClipboardPasteboard.read(pb)
    check(ext == .text("x\ny"), "CRLF -> LF on read")
    check(g.shouldSend(hash: ext!.hash!, marker: pb.changeCount), "external text would be sent")
    if case let .success(c) = ext!.message(seq: 2, maxBytes: ClipboardData.maxBytes) { check(c.text == "x\ny" && c.seq == 2, "text message") }
    else { check(false, "text message") }
    check((try? ext!.message(seq: 3, maxBytes: 2).get()) == nil, "oversized text refused (no truncation)")

    // Received image: PNG kept byte-for-byte + TIFF rendered; reading prefers the PNG.
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 16, bitsPerPixel: 32)!
    for y in 0..<3 { for x in 0..<4 { rep.setColor(NSColor(deviceRed: CGFloat(x) / 3, green: CGFloat(y) / 2, blue: 0.5, alpha: 1), atX: x, y: y) } }
    let png = rep.representation(using: .png, properties: [:])!
    guard case let .success((img, tiff)) = ClipboardPasteboard.prepare(ClipboardData(seq: 4, png: png)) else { return check(false, "prepare png") }
    check(tiff != nil, "TIFF rendered for received PNG")
    ClipboardPasteboard.write(img, tiff: tiff, to: pb)
    check(ClipboardPasteboard.read(pb) == .png(png), "image read back as the exact PNG")
    check(pb.data(forType: .tiff) != nil, "TIFF representation present")

    // TIFF-only image (e.g. older apps): converted to PNG with the same pixels.
    pb.clearContents(); pb.setData(rep.tiffRepresentation!, forType: .tiff)
    let t = ClipboardPasteboard.read(pb)
    check(t?.needsConversion == true, "TIFF-only content needs conversion")
    if case let .success(c)? = t?.message(seq: 5, maxBytes: ClipboardData.maxBytes), let p = c.png, let r = NSBitmapImageRep(data: p) {
        check(r.pixelsWide == 4 && r.pixelsHigh == 3 && p.starts(with: [0x89, 0x50, 0x4E, 0x47]), "TIFF -> PNG")
    } else { check(false, "TIFF -> PNG") }

    // Text wins over an image; empty text falls through to the image; transient is skipped.
    pb.clearContents(); pb.setString("cells", forType: .string); pb.setData(png, forType: .png)
    check(ClipboardPasteboard.read(pb) == .text("cells"), "text preferred over image")
    pb.clearContents(); pb.setString("", forType: .string); pb.setData(png, forType: .png)
    check(ClipboardPasteboard.read(pb) == .png(png), "empty text falls through to image")
    pb.clearContents(); pb.setString("otp", forType: .string); pb.setData(Data(), forType: ClipboardPasteboard.transientType)
    if case .skipped? = ClipboardPasteboard.read(pb) { check(true, "transient content skipped") } else { check(false, "transient content skipped") }
    pb.clearContents(); pb.setString("hunter2", forType: .string); pb.setString("", forType: ClipboardPasteboard.concealedType)
    if case .skipped? = ClipboardPasteboard.read(pb) { check(true, "concealed content skipped by default") } else { check(false, "concealed content skipped by default") }
    check(ClipboardPasteboard.read(pb, syncConcealed: true) == .text("hunter2"), "concealed content sent when syncConcealed")
    pb.clearContents()
    check(ClipboardPasteboard.read(pb) == nil, "empty pasteboard -> nothing")

    // Untrusted PNG: signature + IHDR checked before decoding.
    func pngHeader(_ w: UInt32, _ h: UInt32) -> Data {
        var d = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
        for v in [w, h] { d += withUnsafeBytes(of: v.bigEndian) { Data($0) } }
        return d + Data([8, 6, 0, 0, 0, 0, 0, 0, 0]) + Data(repeating: 0, count: 64)  // depth, RGBA, ..., bogus CRC + junk
    }
    check(ClipboardPNG.dimensions(png).map { $0.width == 4 && $0.height == 3 } == true, "IHDR dimensions of a real PNG")
    check(ClipboardPNG.refusal(png) == nil, "real PNG accepted")
    check(ClipboardPNG.refusal(pngHeader(100_000, 100_000))?.contains("too large") == true, "oversize IHDR (100000x100000) rejected")
    check(ClipboardPNG.refusal(pngHeader(UInt32(Int32.max), 1))?.contains("too large") == true, "oversize IHDR width rejected")
    check(ClipboardPNG.refusal(pngHeader(8192, 8192)) == nil && ClipboardPNG.refusal(pngHeader(8193, 8192)) != nil, "64 Mpx cap boundary")
    check(ClipboardPNG.refusal(pngHeader(0, 5)) != nil, "empty IHDR size rejected")
    check((try? ClipboardPasteboard.prepare(ClipboardData(seq: 9, png: pngHeader(100_000, 100_000))).get()) == nil, "prepare refuses oversize PNG")
    check((try? ClipboardPasteboard.prepare(ClipboardData(seq: 10, png: rep.tiffRepresentation!)).get()) == nil, "prepare refuses non-PNG image data (TIFF)")
    var badChunk = png; badChunk.replaceSubrange(12..<16, with: Data("IDAT".utf8))
    check(ClipboardPNG.dimensions(badChunk) == nil && ClipboardPNG.dimensions(png.prefix(20)) == nil, "IHDR missing/truncated rejected")

    // Invalid received PNG: refused alone, text kept when present.
    check((try? ClipboardPasteboard.prepare(ClipboardData(seq: 6, png: Data([1, 2, 3]))).get()) == nil, "invalid PNG refused")
    if case let .success((c, tf)) = ClipboardPasteboard.prepare(ClipboardData(seq: 7, text: "t", png: Data([1, 2, 3]))) {
        check(c.text == "t" && c.png == nil && tf == nil, "invalid PNG dropped, text kept")
    } else { check(false, "invalid PNG dropped, text kept") }
    check((try? ClipboardPasteboard.prepare(ClipboardData(seq: 8)).get()) == nil, "empty message ignored")
}

// MARK: Audio (§3.2)

/// Builds a linear-PCM CMSampleBuffer (what ScreenCaptureKit hands us) from per-channel samples.
func makeAudioBuffer(channels ch: [[Float]], rate: Double, ptsUs: Int64, planar: Bool, s16: Bool) throws -> CMSampleBuffer {
    let n = ch[0].count, nch = ch.count
    let bps = s16 ? 2 : 4
    var flags: AudioFormatFlags = (s16 ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked
    if planar { flags |= kAudioFormatFlagIsNonInterleaved }
    var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags,
                                           mBytesPerPacket: UInt32(planar ? bps : bps * nch), mFramesPerPacket: 1,
                                           mBytesPerFrame: UInt32(planar ? bps : bps * nch), mChannelsPerFrame: UInt32(nch),
                                           mBitsPerChannel: UInt32(bps * 8), mReserved: 0)
    var fmt: CMAudioFormatDescription?
    guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else {
        throw NSError(domain: "selftest", code: 1)
    }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(rate)), presentationTimeStamp: CMTime(value: ptsUs, timescale: 1_000_000), decodeTimeStamp: .invalid)
    var sb: CMSampleBuffer?
    guard CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: fmt,
                               sampleCount: n, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb) == noErr, let sb else {
        throw NSError(domain: "selftest", code: 2)
    }
    // Raw bytes per buffer.
    func bytes(_ values: [Float]) -> [UInt8] {
        if s16 { return values.flatMap { v in withUnsafeBytes(of: Int16(v * 32767).littleEndian) { Array($0) } } }
        return values.flatMap { v in withUnsafeBytes(of: v) { Array($0) } }
    }
    let buffers: [[UInt8]] = planar ? ch.map(bytes) : [bytes((0..<n).flatMap { f in ch.map { $0[f] } })]
    let abl = AudioBufferList.allocate(maximumBuffers: buffers.count)
    defer { for b in abl { b.mData?.deallocate() }; free(abl.unsafeMutablePointer) }
    for (i, b) in buffers.enumerated() {
        let p = UnsafeMutableRawPointer.allocate(byteCount: b.count, alignment: 16)
        p.copyMemory(from: b, byteCount: b.count)
        abl[i] = AudioBuffer(mNumberChannels: planar ? 1 : UInt32(nch), mDataByteSize: UInt32(b.count), mData: p)
    }
    let st = CMSampleBufferSetDataBufferFromAudioBufferList(sb, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, bufferList: abl.unsafePointer)
    guard st == noErr else { throw NSError(domain: "selftest", code: Int(st)) }
    return sb
}

func s16le(_ d: Data) -> [Int16] {
    stride(from: 0, to: d.count - 1, by: 2).map { Int16(bitPattern: UInt16(d[d.startIndex + $0]) | UInt16(d[d.startIndex + $0 + 1]) << 8) }
}

func audioTests() throws {
    // Wire encodings (docs/PROTOCOL.md §3.2 reference bytes; windows/src/protocol.rs checks the same).
    let cfg = AudioConfig(codec: .pcmS16, sampleRate: 48000, channels: 2, frameSamples: 480)
    check(HostMessage.audioConfig(cfg).encoded.hex == "600180bb000002e001", "AudioConfig encoding")
    if case let .audioConfig(c) = try HostMessage.decode(Data(hex: "600180bb000002e001")!) { check(c == cfg, "AudioConfig decode") } else { check(false, "AudioConfig decode") }
    let pcm = Data(hex: "0100ffffff7f0080")!
    let frameHex = "610700000040420f00000000000100ffffff7f0080"
    check(HostMessage.audioFrame(seq: 7, captureTimeUs: 1_000_000, pcm: pcm).encoded.hex == frameHex, "AudioFrame encoding")
    if case let .audioFrame(seq, t, p) = try HostMessage.decode(Data(hex: frameHex)!) {
        check(seq == 7 && t == 1_000_000 && s16le(p) == [1, -1, 32767, -32768], "AudioFrame decode")
    } else { check(false, "AudioFrame decode") }
    check(ClientMessage.audioEnable(false).encoded.hex == "6200", "AudioEnable encoding")
    if case let .audioEnable(on) = try ClientMessage.decode(Data(hex: "6201")!) { check(on, "AudioEnable decode") } else { check(false, "AudioEnable decode") }
    check(CodecCaps.audioPCM.rawValue == 0x200, "audio cap = bit 9")
    if case let .audioConfig(c) = try HostMessage.decode(HostMessage.audioConfig(.off).encoded) { check(c.codec == .off, "AudioConfig off roundtrip") }

    // Float -> s16 conversion: clipping, rounding, NaN.
    check(AudioPCM.s16(0) == 0 && AudioPCM.s16(1) == 32767 && AudioPCM.s16(-1) == -32767, "s16 full scale")
    check(AudioPCM.s16(2) == 32767 && AudioPCM.s16(-7) == -32767 && AudioPCM.s16(.infinity) == 32767, "s16 clipping")
    check(AudioPCM.s16(.nan) == 0 && AudioPCM.s16(0.5) == 16384 && AudioPCM.s16(-0.5) == -16384 && AudioPCM.s16(1.0 / 32767) == 1, "s16 rounding")

    // Chunking: ≤ max, near-equal, contiguous.
    check(AudioPCM.chunkRanges(frames: 1024, maxFrames: 480) == [0..<342, 342..<683, 683..<1024], "chunk 1024 by 480")
    check(AudioPCM.chunkRanges(frames: 480, maxFrames: 480) == [0..<480], "chunk exact")
    check(AudioPCM.chunkRanges(frames: 960, maxFrames: 480) == [0..<480, 480..<960], "chunk 2x")
    check(AudioPCM.chunkRanges(frames: 0, maxFrames: 480).isEmpty && AudioPCM.chunkRanges(frames: 7, maxFrames: 480) == [0..<7], "chunk small")
    var ok = true
    for n in 1...3000 {
        let r = AudioPCM.chunkRanges(frames: n, maxFrames: 480)
        let sizes = r.map(\.count)
        if r.first?.lowerBound != 0 || r.last?.upperBound != n || sizes.max()! > 480 || sizes.max()! - sizes.min()! > 1 || zip(r, r.dropFirst()).contains(where: { $0.upperBound != $1.lowerBound }) { ok = false }
    }
    check(ok, "chunk invariants 1..3000")

    // Real CMSampleBuffers through the packetizer (SCK delivers float32 planar stereo 48 kHz).
    let n = 1024
    let left = (0..<n).map { Float(sin(Double($0) * 2 * .pi * 440 / 48000) * 0.5) }
    let right = (0..<n).map { Float($0 % 7) / 7 - 0.5 }
    for (planar, s16) in [(true, false), (false, false), (true, true), (false, true)] {
        let what = "\(s16 ? "s16" : "f32") \(planar ? "planar" : "interleaved")"
        let sb = try makeAudioBuffer(channels: [left, right], rate: 48000, ptsUs: 5_000_000, planar: planar, s16: s16)
        let (c, packets) = try AudioPCM.packetize(sb)
        check(c == AudioConfig(codec: .pcmS16, sampleRate: 48000, channels: 2, frameSamples: 480), "packetize config (\(what))")
        check(packets.map(\.frames) == [342, 341, 341], "packetize split (\(what))")
        check(packets.map(\.captureUs) == [5_000_000, 5_007_125, 5_014_229], "packetize timestamps (\(what)) \(packets.map(\.captureUs))")
        let all = packets.flatMap { s16le($0.pcm) }
        let tol: Int = s16 ? 1 : 0
        var maxErr = 0
        for f in 0..<n {
            let l = s16 ? Int(Int16(left[f] * 32767)) : Int(AudioPCM.s16(left[f]))
            let r = s16 ? Int(Int16(right[f] * 32767)) : Int(AudioPCM.s16(right[f]))
            maxErr = max(maxErr, abs(Int(all[2 * f]) - l), abs(Int(all[2 * f + 1]) - r))
        }
        check(all.count == 2 * n && maxErr <= tol, "packetize samples interleaved L,R (\(what), max err \(maxErr))")
    }
    // Mono and an unsupported format.
    let mono = try makeAudioBuffer(channels: [Array(left[0..<100])], rate: 44100, ptsUs: 0, planar: true, s16: false)
    let (mc, mp) = try AudioPCM.packetize(mono)
    check(mc.channels == 1 && mc.sampleRate == 44100 && mc.frameSamples == 441 && mp.count == 1 && mp[0].pcm.count == 200, "packetize mono 44.1k")
    // Throughput: 10 s of stereo 48 kHz in 1024-frame buffers.
    let t0 = hostTimeMicros()
    let sb = try makeAudioBuffer(channels: [left, right], rate: 48000, ptsUs: 0, planar: true, s16: false)
    for _ in 0..<469 { _ = try AudioPCM.packetize(sb) }
    let ms = Double(hostTimeMicros() - t0) / 1000
    check(ms < 500, String(format: "packetize 10 s of audio in %.1f ms (%.3f ms per 21 ms buffer)", ms, ms / 469))
}

func trackerChecks() {
    let crisp = DisplayModeInfo(width: 2560, height: 1440, pixelWidth: 2560, pixelHeight: 1440)
    let retina = DisplayModeInfo(width: 1920, height: 1080, pixelWidth: 3840, pixelHeight: 2160)
    let other = DisplayModeInfo(width: 1600, height: 900, pixelWidth: 1600, pixelHeight: 900)
    // Live bug: the notification for our own switch arrives re-entrantly, before the switch returns.
    var t = DisplayChangeTracker(current: crisp)
    t.willSwitch(from: crisp, to: retina, now: 100)
    check(t.observe(current: retina, now: 100.01) == .ours, "tracker: re-entrant notification during our switch is ours")
    t.didSwitch(ok: true, actual: retina, now: 100.02)
    check(t.observe(current: retina, now: 100.3) == .ours, "tracker: later notification for our switch is ours")
    // Notification delivered while the display still reports the old mode.
    var t2 = DisplayChangeTracker(current: crisp)
    t2.willSwitch(from: crisp, to: retina, now: 10)
    check(t2.observe(current: crisp, now: 10.01) == .ours, "tracker: old mode mid-switch is ours")
    check(t2.observe(current: retina, now: 10.2) == .ours, "tracker: new mode after switch is ours")
    // After the window, steady state; a different mode is the user's.
    check(t2.observe(current: retina, now: 30) == .unchanged, "tracker: steady state unchanged")
    check(t2.observe(current: other, now: 31) == .manual, "tracker: user change after switch is manual")
    check(t2.observe(current: other, now: 32) == .unchanged, "tracker: user's mode becomes expected")
    // A mode that is neither old nor target is manual even inside the window.
    var t3 = DisplayChangeTracker(current: crisp)
    t3.willSwitch(from: crisp, to: retina, now: 0)
    check(t3.observe(current: other, now: 0.5) == .manual, "tracker: unrelated mode during switch is manual")
    // Switching back to the old mode by hand after the window is manual.
    var t4 = DisplayChangeTracker(current: crisp)
    t4.willSwitch(from: crisp, to: retina, now: 0)
    t4.didSwitch(ok: true, actual: retina, now: 0.1)
    check(t4.observe(current: crisp, now: 60) == .manual, "tracker: manual revert after window is manual")
    // Failed switch: the reported mode stays expected.
    var t5 = DisplayChangeTracker(current: crisp)
    t5.willSwitch(from: crisp, to: retina, now: 0)
    t5.didSwitch(ok: false, actual: crisp, now: 0.1)
    check(t5.observe(current: crisp, now: 0.2) == .unchanged, "tracker: failed switch keeps old mode expected")
    var t6 = DisplayChangeTracker(current: crisp)
    check(t6.observe(current: other, now: 1) == .manual, "tracker: change with no switch is manual")
}

do { try run() } catch { failures += 1; print("  FAIL threw \(error)") }
policyChecks()
registryChecks()
trackerChecks()

do { try clipboardTests() } catch { failures += 1; print("  FAIL clipboard threw \(error)") }
pasteboardTests()
do { try audioTests() } catch { failures += 1; print("  FAIL audio threw \(error)") }
print(failures == 0 ? "ALL TESTS PASSED" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
