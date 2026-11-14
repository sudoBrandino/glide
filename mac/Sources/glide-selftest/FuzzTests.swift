import CryptoKit
import Darwin
import Foundation
import GlideCore

// Seeded mutation fuzzing of every decoder that sees peer bytes (the Swift counterpart of
// windows/src/fuzz_tests.rs). Corpus: the records, handshake flights and payloads in
// docs/test-vectors*.json, the messages and paths in docs/file-transfer-vectors.json, and the
// reference encodings of PROTOCOL.md §3–6. Each input is mutated (bit flips, boundary integers,
// truncation, insertion, splicing) and fed to the decoders; the property is "throws or returns",
// never a trap. Decoded values must re-encode to something that decodes again, and sanitized file
// names must be safe. Deterministic: GLIDE_FUZZ_SEED / GLIDE_FUZZ_ITERS reproduce or extend a run.

/// SplitMix64: tiny, seedable, identical on every platform.
struct FuzzRNG {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func byte() -> UInt8 { UInt8(truncatingIfNeeded: next()) }
}

/// Integers at the edges of every field width (lengths, counts, sizes, offsets).
private let boundaryInts: [UInt64] = [0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0xFFFF, 0x1_0000,
                                      0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x1_0000_0000,
                                      0x7FFF_FFFF_FFFF_FFFF, 0x8000_0000_0000_0000, 0xFFFF_FFFF_FFFF_FFFF]
/// f32 specials (NaN, ±inf, huge, denormal) for coordinates and deltas.
private let boundaryFloats: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                       .leastNonzeroMagnitude, 1e30, -1e30, 3e9, -3e9, 0, -0.0, 1]

func mutate(_ input: Data, _ rng: inout FuzzRNG, corpus: [Data]) -> Data {
    var b = [UInt8](input)
    for _ in 0...rng.below(4) {
        switch rng.below(10) {
        case 0 where !b.isEmpty:  // flip one bit
            let i = rng.below(b.count); b[i] ^= 1 << UInt8(rng.below(8))
        case 1 where !b.isEmpty:  // random byte
            b[rng.below(b.count)] = rng.byte()
        case 2 where !b.isEmpty:  // boundary integer, LE, of width 1/2/4/8
            let width = [1, 2, 4, 8][rng.below(4)], v = boundaryInts[rng.below(boundaryInts.count)]
            let at = rng.below(b.count)
            for k in 0..<width where at + k < b.count { b[at + k] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(k))) }
        case 3 where !b.isEmpty:  // special f32
            let bits = boundaryFloats[rng.below(boundaryFloats.count)].bitPattern, at = rng.below(b.count)
            for k in 0..<4 where at + k < b.count { b[at + k] = UInt8(truncatingIfNeeded: bits >> (8 * UInt32(k))) }
        case 4:  // truncate
            b = Array(b.prefix(rng.below(b.count + 1)))
        case 5:  // insert random bytes
            let at = rng.below(b.count + 1)
            b.insert(contentsOf: (0..<(1 + rng.below(16))).map { _ in rng.byte() }, at: at)
        case 6 where !b.isEmpty:  // delete a range
            let at = rng.below(b.count), n = 1 + rng.below(Swift.min(16, b.count - at))
            b.removeSubrange(at ..< at + n)
        case 7 where !b.isEmpty:  // duplicate a range
            let at = rng.below(b.count), n = 1 + rng.below(Swift.min(32, b.count - at))
            b.insert(contentsOf: b[at ..< at + n], at: rng.below(b.count + 1))
        case 8 where !corpus.isEmpty:  // splice another corpus entry's tail
            let o = [UInt8](corpus[rng.below(corpus.count)])
            b = Array(b.prefix(rng.below(b.count + 1))) + o.suffix(rng.below(o.count + 1))
        case 9 where !b.isEmpty:  // change the message type, keep the body
            b[0] = rng.byte()
        default:
            b.append(rng.byte())
        }
    }
    return Data(b)
}

// Which iteration is running, for the crash report (a trap kills the process; rerun with the seed).
private var fuzzSeed: UInt64 = 0
private var fuzzStage: UnsafePointer<CChar>?
private var fuzzIteration = 0

private func installCrashReporter() {
    for sig in [SIGTRAP, SIGILL, SIGSEGV, SIGBUS, SIGABRT] {
        signal(sig) { s in
            func put(_ p: UnsafePointer<CChar>) { _ = write(2, p, strlen(p)) }
            func putNum(_ v: UInt64) {
                var buf = [CChar](repeating: 0, count: 24); var i = 22; var x = v
                repeat { buf[i] = CChar(48 + Int(x % 10)); x /= 10; i -= 1 } while x > 0
                buf.withUnsafeBufferPointer { put($0.baseAddress! + i + 1) }
            }
            put("\n  FAIL fuzz: crashed (signal "); putNum(UInt64(s)); put(") in stage ")
            if let st = fuzzStage { put(st) }
            put(", iteration "); putNum(UInt64(fuzzIteration)); put("; reproduce with GLIDE_FUZZ_SEED=")
            putNum(fuzzSeed); put("\n")
            signal(s, SIG_DFL); raise(s)
        }
    }
}

private func loadJSON(_ path: String) -> [String: Any]? {
    guard let d = FileManager.default.contents(atPath: path) else { return nil }
    return (try? JSONSerialization.jsonObject(with: d)) as? [String: Any]
}

/// Every sanitized component must be safe to use as one path element on macOS and Windows.
func componentIsSafe(_ c: String) -> Bool {
    let bad = Set("/\\:*?\"<>|".unicodeScalars.map(\.value))
    guard !c.isEmpty, c != ".", c != "..", c.utf8.count <= FileNames.maxComponentBytes + 1 else { return false }  // +1: step 5 "_"
    guard let last = c.unicodeScalars.last, last != ".", last != " " else { return false }
    return !c.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || bad.contains($0.value) }
}

func fuzzTests(vectorsDir docs: URL) {
    print("fuzz (seeded mutation of the vectors):")
    let env = ProcessInfo.processInfo.environment
    fuzzSeed = env["GLIDE_FUZZ_SEED"].flatMap { UInt64($0) } ?? 0x6C69_6465_2D66_757A  // "lide-fuz"
    let iters = env["GLIDE_FUZZ_ITERS"].flatMap { Int($0) } ?? 4000
    var rng = FuzzRNG(state: fuzzSeed)
    installCrashReporter()

    // MARK: corpus
    var records: [Data] = []                                     // record plaintexts (both directions)
    var flights: [(preamble: Data, msg1: Data, msg2: Data, msg3: Data, payload2: Data, payload3: Data)] = []
    var recordBodies: [Data] = []
    for name in ["test-vectors.json", "test-vectors-rust.json"] {
        guard let doc = loadJSON(docs.appendingPathComponent(name).path) else { check(false, "fuzz: load \(name)"); return }
        for s in doc["sessions"] as? [[String: Any]] ?? [] {
            let hex = { (k: String) in Data(hex: s[k] as? String ?? "") ?? Data() }
            for r in s["records"] as? [[String: String]] ?? [] {
                records.append(Data(hex: r["plaintext"] ?? "") ?? Data())
                recordBodies.append((Data(hex: r["record"] ?? "") ?? Data()).dropFirst(4))
            }
            flights.append((hex("client_preamble"), hex("msg1"), hex("msg2"), hex("msg3"), hex("msg2_payload"), hex("msg3_payload")))
        }
    }
    var paths: [String] = []
    if let ft = loadJSON(docs.appendingPathComponent("file-transfer-vectors.json").path) {
        for m in ft["messages"] as? [[String: Any]] ?? [] { if let h = m["hex"] as? String, let d = Data(hex: h) { records.append(d) } }
        for p in ft["paths"] as? [[String: Any]] ?? [] { if let s = p["in"] as? String { paths.append(s) } }
    } else { check(false, "fuzz: load file-transfer-vectors.json") }
    if let dv = loadJSON(docs.appendingPathComponent("display-vectors.json").path) {
        for m in dv["messages"] as? [[String: Any]] ?? [] { if let h = m["hex"] as? String, let d = Data(hex: h) { records.append(d) } }
    } else { check(false, "fuzz: load display-vectors.json") }
    // Reference encodings from PROTOCOL.md §3–5, plus one of every message type both sides send.
    let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8) + Data([0, 0, 0, 4, 0, 0, 0, 3, 8, 6, 0, 0, 0, 0, 0, 0, 0])
    let host: [HostMessage] = [
        .authResult(.ok), .pairReveal(nonce: Data(count: 32)),
        .videoConfig(VideoConfig(width: 1920, height: 1080, codec: .hevc, chroma: .yuv420, scale: 2)),
        .sharpLayerConfig(VideoConfig(width: 1920, height: 1080, codec: .hevc, chroma: .yuv444, scale: 2)),
        .pong(clientTimeUs: 1, hostTimeUs: 2),
        .videoFrame(frameId: 7, captureTimeUs: 9, keyframe: false, rects: [FrameRect(x: 0, y: 16, w: 32, h: 48)], data: Data([0, 0, 0, 1, 0x26, 1])),
        .cursorPos(x: 0.5, y: 0.5, visible: true), .cursorShape(id: 3, w: 2, h: 2, hotX: 1, hotY: 1, bgra: Data(count: 16)),
        .cursorShapeRef(id: 3), .clipboard(ClipboardData(seq: 1, text: "hi\n", png: png)),
        .clipboardCaps(formats: 3, maxBytes: 16 << 20),
        .audioFrame(seq: 7, captureTimeUs: 1_000_000, pcm: Data([1, 0, 0xFF, 0xFF])),
        .frameTiming(FrameTiming(frameId: 7, captureUs: 1_000_000, flags: 1, callback: 1500)),
        .displayInfo(preference: 0, modeW: 1920, modeH: 1080, hidpi: true),
    ]
    let client: [ClientMessage] = [
        .mouseMove(x: 0.25, y: 0.75), .mouseButton(button: 0, down: true), .mouseWheel(dx: 0, dy: 1),
        .key(usage: 4, down: true), .releaseAll, .viewSize(w: 3840, h: 2160), .requestKeyframe,
        .setMode(mode: .hybrid, bitrateKbps: 0, maxFps: 60), .ping(clientTimeUs: 5), .audioEnable(false),
        .latencyEnable(flags: 1), .setDisplayPreference(mode: 3),
        .latencyReport(LatencyReport(samples: 120, flags: 1, hostUs: 1, networkUs: 2, queueUs: 3, decodeUs: 4, renderUs: 5, scanoutUs: 6, totalUs: 7, groundTruthUs: .max)),
        .file(.offer(id: 1, totalBytes: 5, files: [FileEntry(path: "Photos/a.txt", size: 5, mtimeMs: 1)])),
    ]
    records += host.map(\.encoded) + client.map(\.encoded)
    records += ["6001" + "80bb0000" + "02" + "e001", "05048007380401"].compactMap { Data(hex: $0) }
    check(records.count > 40 && flights.count >= 4, "fuzz: corpus of \(records.count) messages, \(flights.count) handshakes, \(paths.count) paths")

    // MARK: messages (ClientMessage on the host, HostMessage in glide-probe; FileOffers.validate on offers)
    fuzzStage = UnsafePointer(strdup("messages"))
    var decoded = 0, reencodeOK = true, namesOK = true
    let limits = FileLimits()
    for i in 0..<(iters * 8) {
        fuzzIteration = i
        let m = mutate(records[rng.below(records.count)], &rng, corpus: records)
        if let c = try? ClientMessage.decode(m) {
            decoded += 1
            if (try? ClientMessage.decode(c.encoded)) == nil { reencodeOK = false; print("    client re-encode failed: \(m.hex)") }
            switch c {
            case let .mouseMove(x, y): if !x.isFinite || !y.isFinite { reencodeOK = false }
            case let .mouseWheel(dx, dy):
                if !dx.isFinite || !dy.isFinite || abs(dx) > ClientMessage.maxWheelNotches || abs(dy) > ClientMessage.maxWheelNotches { reencodeOK = false }
            case let .file(.offer(id, total, files)):
                if case let .success(rel) = FileOffers.validate(id: id, total: total, files: files, limits: limits, fromHost: false) {
                    for comps in rel where comps.isEmpty || comps.count > FileNames.maxDepth || !comps.allSatisfy(componentIsSafe) {
                        namesOK = false; print("    unsafe accepted path: \(comps)")
                    }
                }
            case let .clipboard(cd): if let p = cd.png { _ = ClipboardPNG.refusal(p) }
            default: break
            }
        }
        if let h = try? HostMessage.decode(m) {
            decoded += 1
            if (try? HostMessage.decode(h.encoded)) == nil { reencodeOK = false; print("    host re-encode failed: \(m.hex)") }
            if case let .clipboard(cd) = h, let p = cd.png { _ = ClipboardPNG.refusal(p) }
        }
        _ = try? FileMessage.decode(m)
    }
    check(decoded > iters, "fuzz: \(iters * 8) mutated messages, \(decoded) decoded, no trap")
    check(reencodeOK, "fuzz: every decoded message re-encodes to a decodable one; input floats finite and bounded")
    check(namesOK, "fuzz: every accepted offer path sanitizes to safe components")

    // MARK: handshake (host engine on msg1/msg3, viewer engine on msg2, payload decoders, records)
    fuzzStage = UnsafePointer(strdup("handshake"))
    let identity = Curve25519.KeyAgreement.PrivateKey(), eph = Curve25519.KeyAgreement.PrivateKey()
    let msgCorpus = flights.flatMap { [$0.preamble, $0.msg1, $0.msg2, $0.msg3] }
    var hsOK = 0
    for i in 0..<iters {
        fuzzIteration = i
        let f = flights[rng.below(flights.count)]
        let pre = rng.below(4) == 0 ? mutate(f.preamble, &rng, corpus: msgCorpus) : f.preamble
        _ = try? GlideHandshake.parseClientPreamble(pre)
        _ = try? GlideHandshake.parseHostPreamble(mutate(GlideHandshake.hostPreamble(status: 0), &rng, corpus: msgCorpus))
        _ = try? GlideHandshake.HostInfo.decode(mutate(f.payload2, &rng, corpus: msgCorpus))
        _ = try? GlideHandshake.ViewerInfo.decode(mutate(f.payload3, &rng, corpus: msgCorpus))
        // Host: mutated msg1, or a real msg1 then a mutated msg3 (well-formed Noise, wrong peer).
        if let h = try? GlideHandshake.Host(identity: identity, preamble: pre, msg1: rng.below(2) == 0 ? mutate(f.msg1, &rng, corpus: msgCorpus) : f.msg1, ephemeral: eph) {
            if (try? h.writeMsg2(flags: 1)) != nil, (try? h.readMsg3(mutate(f.msg3, &rng, corpus: msgCorpus))) != nil { hsOK += 1 }
        }
        // Viewer: a mutated msg2 after its own msg1.
        let v = GlideHandshake.Viewer(identity: identity, name: "fuzz")
        _ = v.firstFlight()
        _ = try? v.readMsg2(mutate(f.msg2, &rng, corpus: msgCorpus), preambleVersion: 2)
        // Records: any mutation must fail authentication.
        if let body = recordBodies.randomElement(using: &rng) {
            let m = mutate(body, &rng, corpus: recordBodies)
            if m != body, (try? RecordCipher(key: SymmetricKey(size: .bits256)).open(m)) != nil { hsOK = -1_000_000 }
        }
    }
    check(hsOK >= 0, "fuzz: \(iters) mutated handshakes/records, no trap, no forged record accepted")

    // MARK: file names: mutated vector paths and random strings over a hostile alphabet
    fuzzStage = UnsafePointer(strdup("paths"))
    let alphabet = ["/", "\\", ".", "..", ":", " ", "\u{0}", "\u{1F}", "\u{7F}", "C:", "con", "CON.txt", "lpt\u{00B9}", "a", "é", "e\u{301}",
                    "\u{202E}", "\u{200B}", "\u{FEFF}", "*", "?", "\"", "<", ">", "|", "~", "%2e", String(repeating: "x", count: 120), "日本", "😀"]
    var pathsOK = true, refusedTraversal = true
    for i in 0..<(iters * 2) {
        fuzzIteration = i
        let p: String
        if rng.below(2) == 0, !paths.isEmpty {
            p = String(decoding: mutate(Data(paths[rng.below(paths.count)].utf8), &rng, corpus: paths.map { Data($0.utf8) }), as: UTF8.self)
        } else {
            p = (0..<(1 + rng.below(12))).map { _ in alphabet[rng.below(alphabet.count)] }.joined()
        }
        guard let comps = try? FileNames.sanitizePath(p) else { continue }
        if comps.isEmpty || comps.count > FileNames.maxDepth || !comps.allSatisfy(componentIsSafe) { pathsOK = false; print("    unsafe: \(p.debugDescription) -> \(comps)") }
        let raw = p.split(separator: "/", omittingEmptySubsequences: false)
        if p.hasPrefix("/") || p.hasPrefix("\\") || raw.contains("..") || raw.contains(".") || raw.contains("") { refusedTraversal = false; print("    accepted: \(p.debugDescription)") }
        for c in comps { _ = FileNames.withSuffix(c, 2 + rng.below(9998), isDir: rng.below(2) == 0) }
    }
    check(pathsOK, "fuzz: \(iters * 2) hostile paths sanitize to safe components")
    check(refusedTraversal, "fuzz: absolute, '.', '..' and empty components are always refused")

    // MARK: PNG headers (decompression-bomb check)
    fuzzStage = UnsafePointer(strdup("png"))
    var pngOK = true
    for i in 0..<iters {
        fuzzIteration = i
        let m = mutate(png, &rng, corpus: [png])
        if ClipboardPNG.refusal(m) == nil, let (w, h) = ClipboardPNG.dimensions(m), w == 0 || h == 0 || w * h > ClipboardPNG.maxPixels { pngOK = false }
    }
    check(pngOK, "fuzz: \(iters) mutated PNG headers, none over 64 Mpx accepted")
    fuzzStage = nil
}

extension Array {
    func randomElement(using rng: inout FuzzRNG) -> Element? { isEmpty ? nil : self[rng.below(count)] }
}

/// Input floats from the viewer (PROTOCOL.md §3): NaN, ±inf and absurd wheel deltas are dropped at
/// decode, before InputInjector converts them to integers (Int32(NaN) traps and would crash the host).
func inputValidationTests() {
    print("input validation:")
    func wheel(_ dx: Float, _ dy: Float) -> Data { ClientMessage.mouseWheel(dx: dx, dy: dy).encoded }
    func move(_ x: Float, _ y: Float) -> Data { ClientMessage.mouseMove(x: x, y: y).encoded }
    check((try? ClientMessage.decode(wheel(0, 1))) != nil && (try? ClientMessage.decode(wheel(-2.5, 0.25))) != nil, "ordinary wheel deltas decode")
    check((try? ClientMessage.decode(wheel(.nan, 0))) == nil && (try? ClientMessage.decode(wheel(0, .infinity))) == nil, "NaN / inf wheel delta is malformed")
    check((try? ClientMessage.decode(wheel(0, 1e30))) == nil && (try? ClientMessage.decode(wheel(-10_001, 0))) == nil, "wheel delta over 10000 notches is malformed")
    check((try? ClientMessage.decode(wheel(10_000, -10_000))) != nil, "wheel delta of exactly 10000 notches decodes")
    check((try? ClientMessage.decode(move(0.5, 1.2))) != nil, "out-of-range but finite mouse position decodes (clamped by the host)")
    check((try? ClientMessage.decode(move(.nan, 0.5))) == nil && (try? ClientMessage.decode(move(0.5, -.infinity))) == nil, "NaN / inf mouse position is malformed")
    do { _ = try ClientMessage.decode(wheel(.nan, 0)); check(false, "NaN wheel must throw") }
    catch WireError.malformed { check(true, "NaN wheel throws WireError.malformed") } catch { check(false, "NaN wheel threw \(error)") }
}

/// Hardening regressions in the file-name rules (§6.3) and offer validation.
func fileHardeningTests() {
    print("file name hardening:")
    for (input, bad) in [(String(repeating: " ", count: 197).prefixed("CON") + "xyz", "CON"),
                         (String(repeating: " ", count: 193).prefixed("NUL") + "abcdefgh.txt", "NUL")] {
        let out = FileNames.sanitizeComponent(input)
        let base = String(out.prefix { $0 != "." }).trimmingCharacters(in: .init(charactersIn: " ")).uppercased()
        check(base != bad && out.hasPrefix("_") && out.utf8.count <= 201, "cut name can't become device name \(bad) (\(out.utf8.count) bytes)")
    }
    func v(_ paths: [String]) -> Bool {
        if case .success = FileOffers.validate(id: 1, total: 0, files: paths.map { FileEntry(path: $0, size: 0, mtimeMs: 0) }, limits: FileLimits(), fromHost: false) { return true }
        return false
    }
    check(!v(["a", "A/b"]) && !v(["x/y/z", "X/Y"]), "file/folder conflicts detected (case-insensitive)")
    check(v(["a b", "a/c", "a.txt"]) && v(["ab", "a/b"]) && v(["a/b", "a/c", "d"]), "no false file/folder conflicts")
    // 10 000 files × 32 components × 120 bytes: linear-ish, not gigabytes of prefix strings.
    let comp = String(repeating: "x", count: 120)
    var files = (0..<10_000).map { FileEntry(path: String(format: "%05d", $0) + String(repeating: "/" + comp, count: 31), size: 0, mtimeMs: 0) }
    files.append(FileEntry(path: "00000" + String(repeating: "/" + comp, count: 30), size: 0, mtimeMs: 0))
    let t0 = Date()
    let r = FileOffers.validate(id: 1, total: 0, files: files, limits: FileLimits(maxTotalBytes: 1, maxFiles: 20_000), fromHost: false)
    if case let .failure(f) = r { check(f.status == FileStatus.badName, "hostile 10 000-file offer refused as a conflict in \(String(format: "%.2f", Date().timeIntervalSince(t0))) s") }
    else { check(false, "hostile offer must be refused") }
}

private extension String {
    func prefixed(_ p: String) -> String { p + self }
}
