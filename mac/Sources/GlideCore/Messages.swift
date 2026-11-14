import Foundation

public enum Codec: UInt8 { case hevc = 1, h264 = 2 }
public enum Chroma: UInt8 { case yuv420 = 0, yuv444 = 1 }
public enum StreamMode: UInt8 { case fast = 0, sharp = 1, hybrid = 2 }

/// Changed region of a base-layer frame, in encoded pixels.
public struct FrameRect: Equatable, Sendable {
    public var x, y, w, h: UInt16
    public init(x: UInt16, y: UInt16, w: UInt16, h: UInt16) { self.x = x; self.y = y; self.w = w; self.h = h }
}

public struct CodecCaps: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let hevc420 = CodecCaps(rawValue: 1 << 0)
    public static let hevc444 = CodecCaps(rawValue: 1 << 1)
    public static let h264 = CodecCaps(rawValue: 1 << 2)
    /// Bits 0-7: video codecs. Bits 8+: non-video features.
    public static let codecMask = CodecCaps(rawValue: 0xFF)
    /// Clipboard sync (PROTOCOL.md §5).
    public static let clipboard = CodecCaps(rawValue: 1 << 8)
    /// Viewer plays PCM s16le audio (§3.2).
    public static let audioPCM = CodecCaps(rawValue: 1 << 9)
    /// Reserved: Opus audio.
    public static let audioOpus = CodecCaps(rawValue: 1 << 10)
    /// File transfer, both directions (§6).
    public static let files = CodecCaps(rawValue: 1 << 11)
    /// Display selection: DisplayList / DisplayChanged / SelectDisplay (§3.5).
    public static let displays = CodecCaps(rawValue: 1 << 13)
    /// Input extensions: the viewer understands InputCaps and sends §3.6 messages.
    public static let inputExt = CodecCaps(rawValue: 1 << 12)
}

/// InputCaps flags (PROTOCOL.md §3.6): which input-extension messages the host accepts.
public struct InputCaps: OptionSet, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let scroll = InputCaps(rawValue: 1 << 0)
    public static let relative = InputCaps(rawValue: 1 << 1)
    public static let locks = InputCaps(rawValue: 1 << 2)
    public static let consumer = InputCaps(rawValue: 1 << 3)
    public static let all: InputCaps = [.scroll, .relative, .locks, .consumer]
}

/// `0x19` KeyExtra bodies (§3.6).
public enum KeyExtra: Equatable, Sendable {
    /// Lock-key state: bit0 Caps Lock, bit1 Num Lock, bit2 Scroll Lock.
    case lockState(UInt8)
    /// HID Consumer page (0x0C) usage.
    case consumerKey(usage: UInt16, down: Bool)
    /// A kind this host doesn't know: ignored.
    case unknown(kind: UInt8)

    public static let capsLock: UInt8 = 1, numLock: UInt8 = 2, scrollLock: UInt8 = 4
}

/// One file of a FileOffer (PROTOCOL.md §6). `path` is '/'-separated and relative; receivers sanitize it.
public struct FileEntry: Equatable, Sendable {
    public var path: String
    public var size: UInt64
    /// Modification time, ms since the Unix epoch (0 = unknown).
    public var mtimeMs: Int64
    public init(path: String, size: UInt64, mtimeMs: Int64) { self.path = path; self.size = size; self.mtimeMs = mtimeMs }
}

/// File-transfer messages (§6, types 0x70-0x7F), carried by both ClientMessage and HostMessage.
public enum FileMessage: Equatable, Sendable {
    /// 0x70 H->C. `flags`: FileMessage.capsReceive | capsSend.
    case caps(flags: UInt32, maxTotalBytes: UInt64, maxFiles: UInt32)
    case offer(id: UInt32, totalBytes: UInt64, files: [FileEntry])
    /// status 0 = accepted, else a decline reason (FileStatus).
    case answer(id: UInt32, status: UInt8, detail: String)
    case chunk(id: UInt32, index: UInt32, offset: UInt64, data: Data)
    case end(id: UInt32, index: UInt32, sha256: Data)
    case ack(id: UInt32, bytes: UInt64)
    case cancel(id: UInt32, reason: UInt8, detail: String)
    case done(id: UInt32, files: UInt32)
    /// 0x78 C->H: send the files on the pasteboard.
    case pull
    /// 0x79 H->C: 0 = an offer follows.
    case pullResult(status: UInt8, detail: String)

    public static let capsReceive: UInt32 = 1 << 0
    public static let capsSend: UInt32 = 1 << 1
    /// Largest FileChunk payload.
    public static let chunkMax = 256 * 1024
    /// A sender keeps at most this many chunk bytes unacknowledged (protocol maximum).
    public static let window: UInt64 = 1 << 20
    /// The window Glide's senders use: ≤ 512 KiB of file data ahead of a video frame / input
    /// event anywhere in the pipe (~4 ms at 1 Gbit/s).
    public static let sendWindow: UInt64 = 512 << 10
    /// Unwritten chunk bytes a receiver tolerates before cancelling (sender ignored the window).
    public static let receiveQueueMax: UInt64 = 4 << 20
    /// Host-chosen transfer ids have bit 31 set.
    public static let hostIdBit: UInt32 = 0x8000_0000

    func write(_ w: inout ByteWriter) {
        switch self {
        case let .caps(f, t, n): w.u8(0x70); w.u32(f); w.u64(t); w.u32(n)
        case let .offer(id, total, files):
            w.u8(0x71); w.u32(id); w.u64(total); w.u32(UInt32(files.count))
            for f in files { w.str(f.path); w.u64(f.size); w.u64(UInt64(bitPattern: f.mtimeMs)) }
        case let .answer(id, st, d): w.u8(0x72); w.u32(id); w.u8(st); w.str(d)
        case let .chunk(id, idx, off, data): w.u8(0x73); w.u32(id); w.u32(idx); w.u64(off); w.bytes(data)
        case let .end(id, idx, sha): w.u8(0x74); w.u32(id); w.u32(idx); w.bytes(sha)
        case let .ack(id, n): w.u8(0x75); w.u32(id); w.u64(n)
        case let .cancel(id, r, d): w.u8(0x76); w.u32(id); w.u8(r); w.str(d)
        case let .done(id, n): w.u8(0x77); w.u32(id); w.u32(n)
        case .pull: w.u8(0x78)
        case let .pullResult(st, d): w.u8(0x79); w.u8(st); w.str(d)
        }
    }

    public var encoded: Data {
        var w: ByteWriter
        if case let .chunk(_, _, _, data) = self { w = ByteWriter(capacity: data.count + 17) } else { w = ByteWriter() }
        write(&w)
        return w.data
    }

    static func read(type t: UInt8, _ r: inout ByteReader) throws -> FileMessage {
        switch t {
        case 0x70: return .caps(flags: try r.u32(), maxTotalBytes: try r.u64(), maxFiles: try r.u32())
        case 0x71:
            let id = try r.u32(), total = try r.u64(), n = Int(try r.u32())
            // Each entry is at least 18 bytes: don't trust `n` for the allocation.
            guard n <= r.remaining / 18 else { throw WireError.truncated }
            var files: [FileEntry] = []
            files.reserveCapacity(n)
            for _ in 0..<n {
                let p = try r.str()  // invalid UTF-8 is replaced (U+FFFD), never fatal
                files.append(FileEntry(path: p, size: try r.u64(), mtimeMs: Int64(bitPattern: try r.u64())))
            }
            return .offer(id: id, totalBytes: total, files: files)
        case 0x72: return .answer(id: try r.u32(), status: try r.u8(), detail: try r.str())
        case 0x73: return .chunk(id: try r.u32(), index: try r.u32(), offset: try r.u64(), data: r.rest())
        case 0x74: return .end(id: try r.u32(), index: try r.u32(), sha256: try r.bytes(32))
        case 0x75: return .ack(id: try r.u32(), bytes: try r.u64())
        case 0x76: return .cancel(id: try r.u32(), reason: try r.u8(), detail: try r.str())
        case 0x77: return .done(id: try r.u32(), files: try r.u32())
        case 0x78: return .pull
        case 0x79: return .pullResult(status: try r.u8(), detail: try r.str())
        default: throw WireError.unknownMessage(t)
        }
    }

    public static func decode(_ d: Data) throws -> FileMessage {
        var r = ByteReader(d)
        let t = try r.u8()
        return try read(type: t, &r)
    }
}

/// One clipboard snapshot (PROTOCOL.md §5): `u32 seq`, `u8 count`, count x (`u8 format`, `u32 len`, bytes).
public struct ClipboardData: Equatable, Sendable {
    public static let formatText: UInt8 = 1
    public static let formatPNG: UInt8 = 2
    /// `ClipboardCaps.formats` bits.
    public static let capsText: UInt32 = 1 << 0
    public static let capsPNG: UInt32 = 1 << 1
    /// Max total item payload (CLIPBOARD_MAX).
    public static let maxBytes = 16 * 1024 * 1024

    public var seq: UInt32
    /// UTF-8 text with LF line endings.
    public var text: String?
    /// A complete PNG file.
    public var png: Data?

    public init(seq: UInt32 = 0, text: String? = nil, png: Data? = nil) {
        self.seq = seq; self.text = text; self.png = png
    }

    public var isEmpty: Bool { text == nil && png == nil }
    /// Sum of item payload lengths (what the 16 MiB limit applies to).
    public var payloadBytes: Int { (text?.utf8.count ?? 0) + (png?.count ?? 0) }

    func write(_ w: inout ByteWriter) {
        w.u32(seq)
        w.u8(UInt8((text != nil ? 1 : 0) + (png != nil ? 1 : 0)))
        if let text { let b = Data(text.utf8); w.u8(Self.formatText); w.u32(UInt32(b.count)); w.bytes(b) }
        if let png { w.u8(Self.formatPNG); w.u32(UInt32(png.count)); w.bytes(png) }
    }

    static func read(_ r: inout ByteReader) throws -> ClipboardData {
        var c = ClipboardData(seq: try r.u32())
        let n = try r.u8()
        for _ in 0..<n {
            let fmt = try r.u8(), len = Int(try r.u32())
            let b = try r.bytes(len)
            switch fmt {
            case formatText where c.text == nil: c.text = String(decoding: b, as: UTF8.self)
            case formatPNG where c.png == nil: c.png = b
            default: break  // unknown format or duplicate: skip
            }
        }
        return c
    }
}

public struct VideoConfig: Equatable {
    public var width: UInt16
    public var height: UInt16
    public var codec: Codec
    public var chroma: Chroma
    public var color: UInt8 = 0
    public var scale: Float

    public init(width: UInt16, height: UInt16, codec: Codec, chroma: Chroma, color: UInt8 = 0, scale: Float) {
        self.width = width; self.height = height; self.codec = codec; self.chroma = chroma; self.color = color; self.scale = scale
    }

    func write(_ w: inout ByteWriter) {
        w.u16(width); w.u16(height); w.u8(codec.rawValue); w.u8(chroma.rawValue); w.u8(color); w.f32(scale)
    }

    static func read(_ r: inout ByteReader) throws -> VideoConfig {
        let w = try r.u16(), h = try r.u16()
        guard let c = Codec(rawValue: try r.u8()), let ch = Chroma(rawValue: try r.u8()) else { throw WireError.truncated }
        let color = try r.u8()
        return VideoConfig(width: w, height: h, codec: c, chroma: ch, color: color, scale: try r.f32())
    }
}

/// "Unknown" marker for FrameTiming / LatencyReport fields (PROTOCOL.md §3.4).
public let timingUnknown: UInt32 = .max

/// `FrameTiming` (0x81, §3.4): host pipeline stamps of one VideoFrame, as µs after `captureUs`.
public struct FrameTiming: Equatable, Sendable {
    public var frameId: UInt32
    public var captureUs: UInt64
    public var flags: UInt8
    public var callback: UInt32, submit: UInt32, encoded: UInt32, enqueued: UInt32, sent: UInt32

    public init(frameId: UInt32, captureUs: UInt64, flags: UInt8, callback: UInt32 = timingUnknown, submit: UInt32 = timingUnknown,
                encoded: UInt32 = timingUnknown, enqueued: UInt32 = timingUnknown, sent: UInt32 = timingUnknown) {
        self.frameId = frameId; self.captureUs = captureUs; self.flags = flags
        self.callback = callback; self.submit = submit; self.encoded = encoded; self.enqueued = enqueued; self.sent = sent
    }

    /// Offset of absolute host time `t` (µs) after the capture, or `timingUnknown`.
    public static func delta(_ t: UInt64?, from cap: UInt64) -> UInt32 {
        guard let t else { return timingUnknown }
        return t <= cap ? 0 : UInt32(min(t - cap, UInt64(timingUnknown - 1)))
    }

    func write(_ w: inout ByteWriter) {
        w.u32(frameId); w.u64(captureUs); w.u8(flags)
        w.u32(callback); w.u32(submit); w.u32(encoded); w.u32(enqueued); w.u32(sent)
    }

    static func read(_ r: inout ByteReader) throws -> FrameTiming {
        FrameTiming(frameId: try r.u32(), captureUs: try r.u64(), flags: try r.u8(), callback: try r.u32(), submit: try r.u32(),
                    encoded: try r.u32(), enqueued: try r.u32(), sent: try r.u32())
    }
}

/// `LatencyReport` (0x82, §3.4): the viewer's p50 breakdown (µs) over its last ~2 s.
public struct LatencyReport: Equatable, Sendable {
    public var samples: UInt16
    /// bit0: `totalUs` ends at scan-out (else at the Present call); bit1: ground truth valid.
    public var flags: UInt8
    public var hostUs: UInt32, networkUs: UInt32, queueUs: UInt32, decodeUs: UInt32, renderUs: UInt32, scanoutUs: UInt32, totalUs: UInt32
    public var groundTruthUs: UInt32

    public init(samples: UInt16, flags: UInt8, hostUs: UInt32, networkUs: UInt32, queueUs: UInt32, decodeUs: UInt32, renderUs: UInt32,
                scanoutUs: UInt32, totalUs: UInt32, groundTruthUs: UInt32) {
        self.samples = samples; self.flags = flags; self.hostUs = hostUs; self.networkUs = networkUs; self.queueUs = queueUs
        self.decodeUs = decodeUs; self.renderUs = renderUs; self.scanoutUs = scanoutUs; self.totalUs = totalUs; self.groundTruthUs = groundTruthUs
    }

    /// One log line, e.g. `n=118 p50 ms: host 11.0 net 1.2 … total(glass) 21.6`.
    public var summary: String {
        func f(_ v: UInt32) -> String { v == timingUnknown ? "-" : String(format: "%.1f", Double(v) / 1000) }
        return "n=\(samples) p50 ms: host \(f(hostUs)) net \(f(networkUs)) queue \(f(queueUs)) decode \(f(decodeUs)) render \(f(renderUs)) scanout \(f(scanoutUs)) total(\(flags & 1 != 0 ? "glass" : "to present")) \(f(totalUs))"
            + (flags & 2 != 0 ? " ground-truth \(f(groundTruthUs))" : "")
    }
}

/// Client -> Host messages.
public enum ClientMessage {
    case hello(version: UInt16, caps: CodecCaps, viewW: UInt16, viewH: UInt16, mode: StreamMode, maxFps: UInt8, name: String)
    case mouseMove(x: Float, y: Float)
    case mouseButton(button: UInt8, down: Bool)
    case mouseWheel(dx: Float, dy: Float)
    case key(usage: UInt16, down: Bool)
    case releaseAll
    case viewSize(w: UInt16, h: UInt16)
    case requestKeyframe
    case setMode(mode: StreamMode, bitrateKbps: UInt32, maxFps: UInt8)
    case ping(clientTimeUs: UInt64)
    case clipboard(ClipboardData)
    case audioEnable(Bool)
    /// Pairing (§2.4): the user compared the codes (true = they match).
    case pairConfirm(Bool)
    case file(FileMessage)
    /// §3.4: `flags` bit0 = send FrameTiming for every VideoFrame.
    case latencyEnable(flags: UInt8)
    case latencyReport(LatencyReport)
    /// Mac display-mode preference for this session (`DisplayModePreference.wireValue`, §3.3).
    case setDisplayPreference(mode: UInt8)
    /// §3.5: stream display `id` (0 = the host's default).
    case selectDisplay(id: UInt32)
    /// §3.6: notches like mouseWheel; `precise` = touchpad / high-resolution wheel.
    case scroll(precise: Bool, dx: Float, dy: Float)
    /// §3.6: relative motion in device counts (pointer-lock mode).
    case mouseDelta(dx: Int16, dy: Int16)
    /// §3.6 `0x19`.
    case keyExtra(KeyExtra)

    public var encoded: Data {
        var w = ByteWriter()
        switch self {
        case let .hello(version, caps, vw, vh, mode, fps, name):
            w.u8(0x01); w.u16(version); w.u32(caps.rawValue); w.u16(vw); w.u16(vh); w.u8(mode.rawValue); w.u8(fps); w.str(name)
        case let .mouseMove(x, y): w.u8(0x10); w.f32(x); w.f32(y)
        case let .mouseButton(b, d): w.u8(0x11); w.u8(b); w.u8(d ? 1 : 0)
        case let .mouseWheel(dx, dy): w.u8(0x12); w.f32(dx); w.f32(dy)
        case let .key(u, d): w.u8(0x13); w.u16(u); w.u8(d ? 1 : 0)
        case .releaseAll: w.u8(0x14)
        case let .viewSize(vw, vh): w.u8(0x15); w.u16(vw); w.u16(vh)
        case .requestKeyframe: w.u8(0x20)
        case let .setMode(m, br, fps): w.u8(0x21); w.u8(m.rawValue); w.u32(br); w.u8(fps)
        case let .ping(t): w.u8(0x30); w.u64(t)
        case let .clipboard(c): w = ByteWriter(capacity: c.payloadBytes + 32); w.u8(0x50); c.write(&w)
        case let .audioEnable(on): w.u8(0x62); w.u8(on ? 1 : 0)
        case let .pairConfirm(ok): w.u8(0x0A); w.u8(ok ? 1 : 0)
        case let .file(m): return m.encoded
        case let .latencyEnable(f): w.u8(0x80); w.u8(f)
        case let .latencyReport(r):
            w.u8(0x82); w.u16(r.samples); w.u8(r.flags)
            for v in [r.hostUs, r.networkUs, r.queueUs, r.decodeUs, r.renderUs, r.scanoutUs, r.totalUs, r.groundTruthUs] { w.u32(v) }
        case let .setDisplayPreference(m): w.u8(0x16); w.u8(m)
        case let .selectDisplay(id): w.u8(0x1A); w.u32(id)
        case let .scroll(precise, dx, dy): w.u8(0x17); w.u8(precise ? 1 : 0); w.f32(dx); w.f32(dy)
        case let .mouseDelta(dx, dy): w.u8(0x18); w.u16(UInt16(bitPattern: dx)); w.u16(UInt16(bitPattern: dy))
        case let .keyExtra(k):
            w.u8(0x19)
            switch k {
            case let .lockState(l): w.u8(0); w.u8(l)
            case let .consumerKey(u, d): w.u8(1); w.u16(u); w.u8(d ? 1 : 0)
            case let .unknown(kind): w.u8(kind)
            }
        }
        return w.data
    }

    /// Largest |MouseWheel| delta accepted, in notches (PROTOCOL.md §3). Real viewers send a few.
    public static let maxWheelNotches: Float = 10_000
    /// Largest |MouseMove| coordinate accepted (normalized 0..1; the host clamps what is in range).
    public static let maxMouseCoordinate: Float = 1_000

    /// An input `f32` from the viewer: NaN, ±inf and absurd magnitudes are malformed (§3), so they
    /// never reach float-to-integer conversions in input injection (which trap on them).
    static func inputF32(_ r: inout ByteReader, limit: Float) throws -> Float {
        let v = try r.f32()
        guard v.isFinite, abs(v) <= limit else { throw WireError.malformed("input value \(v) out of range") }
        return v
    }

    public static func decode(_ d: Data) throws -> ClientMessage {
        var r = ByteReader(d)
        let t = try r.u8()
        switch t {
        case 0x01:
            let v = try r.u16(), caps = CodecCaps(rawValue: try r.u32()), vw = try r.u16(), vh = try r.u16()
            let mode = StreamMode(rawValue: try r.u8()) ?? .fast
            return .hello(version: v, caps: caps, viewW: vw, viewH: vh, mode: mode, maxFps: try r.u8(), name: try r.str())
        case 0x10: return .mouseMove(x: try inputF32(&r, limit: maxMouseCoordinate), y: try inputF32(&r, limit: maxMouseCoordinate))
        case 0x11: return .mouseButton(button: try r.u8(), down: try r.u8() != 0)
        case 0x12: return .mouseWheel(dx: try inputF32(&r, limit: maxWheelNotches), dy: try inputF32(&r, limit: maxWheelNotches))
        case 0x13: return .key(usage: try r.u16(), down: try r.u8() != 0)
        case 0x14: return .releaseAll
        case 0x15: return .viewSize(w: try r.u16(), h: try r.u16())
        case 0x20: return .requestKeyframe
        case 0x21: return .setMode(mode: StreamMode(rawValue: try r.u8()) ?? .fast, bitrateKbps: try r.u32(), maxFps: try r.u8())
        case 0x30: return .ping(clientTimeUs: try r.u64())
        case 0x50: return .clipboard(try ClipboardData.read(&r))
        case 0x62: return .audioEnable(try r.u8() != 0)
        case 0x0A: return .pairConfirm(try r.u8() != 0)
        case 0x70...0x79: return .file(try FileMessage.read(type: t, &r))
        case 0x80: return .latencyEnable(flags: try r.u8())
        case 0x82:
            let n = try r.u16(), f = try r.u8()
            return .latencyReport(LatencyReport(samples: n, flags: f, hostUs: try r.u32(), networkUs: try r.u32(), queueUs: try r.u32(), decodeUs: try r.u32(),
                                                renderUs: try r.u32(), scanoutUs: try r.u32(), totalUs: try r.u32(), groundTruthUs: try r.u32()))
        case 0x16: return .setDisplayPreference(mode: try r.u8())
        case 0x1A: return .selectDisplay(id: try r.u32())
        case 0x17: return .scroll(precise: try r.u8() & 1 != 0, dx: try r.f32(), dy: try r.f32())
        case 0x18: return .mouseDelta(dx: Int16(bitPattern: try r.u16()), dy: Int16(bitPattern: try r.u16()))
        case 0x19:
            switch try r.u8() {
            case 0: return .keyExtra(.lockState(try r.u8()))
            case 1: return .keyExtra(.consumerKey(usage: try r.u16(), down: try r.u8() != 0))
            case let k: return .keyExtra(.unknown(kind: k))
            }
        default: throw WireError.unknownMessage(t)
        }
    }
}

/// Host -> Client messages.
public enum HostMessage {
    /// Auth phase result (§2.4); nonzero closes the connection.
    case authResult(AuthCode)
    /// Pairing: the host's nonce n_h, opening the msg2 commitment (§2.4).
    case pairReveal(nonce: Data)
    case serverHello(version: UInt16, hostName: String, config: VideoConfig)
    case videoConfig(VideoConfig)
    case sharpLayerConfig(VideoConfig)
    case pong(clientTimeUs: UInt64, hostTimeUs: UInt64)
    case videoFrame(frameId: UInt32, captureTimeUs: UInt64, keyframe: Bool, refresh: Bool = false, sharp: Bool = false, rects: [FrameRect]? = nil, data: Data)
    case cursorPos(x: Float, y: Float, visible: Bool)
    case cursorShape(id: UInt32, w: UInt16, h: UInt16, hotX: UInt16, hotY: UInt16, bgra: Data)
    case cursorShapeRef(id: UInt32)
    case clipboard(ClipboardData)
    /// `formats`: ClipboardData.capsText | capsPNG; `maxBytes`: largest payload the host accepts.
    case clipboardCaps(formats: UInt32, maxBytes: UInt32)
    case audioConfig(AudioConfig)
    /// `pcm`: interleaved s16le samples (codec 1).
    case audioFrame(seq: UInt32, captureTimeUs: UInt64, pcm: Data)
    case file(FileMessage)
    /// §3.4, only after the viewer's LatencyEnable.
    case frameTiming(FrameTiming)
    /// Current display preference (`DisplayModePreference.wireValue`) and mode: "looks like" size in
    /// points, `hidpi` = Retina backing (§3.3). Sent after ServerHello and whenever it changes.
    case displayInfo(preference: UInt8, modeW: UInt16, modeH: UInt16, hidpi: Bool)
    /// §3.5 (caps bit 13 only): the Mac's displays in list order; `selected` 0 = following the default.
    case displayList(streamed: UInt32, selected: UInt32, displays: [DisplayDescriptor])
    /// §3.5 (caps bit 13 only): `reason` is a `DisplayChangeReason` raw value.
    case displayChanged(id: UInt32, reason: UInt8, requested: UInt32)
    /// §3.6, only to viewers with caps bit 12, after ServerHello.
    case inputCaps(InputCaps)

    public var encoded: Data {
        var w = ByteWriter()
        switch self {
        case let .authResult(c): w.u8(0x08); w.u8(c.rawValue)
        case let .pairReveal(n): w.u8(0x09); w.bytes(n)
        case let .serverHello(v, name, cfg): w.u8(0x02); w.u16(v); w.str(name); cfg.write(&w)
        case let .videoConfig(cfg): w.u8(0x03); cfg.write(&w)
        case let .sharpLayerConfig(cfg): w.u8(0x04); cfg.write(&w)
        case let .pong(c, h): w.u8(0x31); w.u64(c); w.u64(h)
        case let .videoFrame(id, t, key, refresh, sharp, rects, data):
            w = ByteWriter(capacity: data.count + 16 + (rects?.count ?? 0) * 8)
            let flags: UInt8 = (key ? 1 : 0) | (refresh ? 2 : 0) | (sharp ? 4 : 0) | (rects != nil ? 8 : 0)
            w.u8(0x40); w.u32(id); w.u64(t); w.u8(flags)
            if let rects {
                w.u16(UInt16(rects.count))
                for r in rects { w.u16(r.x); w.u16(r.y); w.u16(r.w); w.u16(r.h) }
            }
            w.bytes(data)
        case let .cursorPos(x, y, vis): w.u8(0x41); w.f32(x); w.f32(y); w.u8(vis ? 1 : 0)
        case let .cursorShape(id, cw, ch, hx, hy, bgra):
            w = ByteWriter(capacity: bgra.count + 16)
            w.u8(0x42); w.u32(id); w.u16(cw); w.u16(ch); w.u16(hx); w.u16(hy); w.bytes(bgra)
        case let .cursorShapeRef(id): w.u8(0x43); w.u32(id)
        case let .clipboard(c): w = ByteWriter(capacity: c.payloadBytes + 32); w.u8(0x50); c.write(&w)
        case let .clipboardCaps(f, m): w.u8(0x51); w.u32(f); w.u32(m)
        case let .audioConfig(c): w.u8(0x60); c.write(&w)
        case let .audioFrame(seq, t, pcm):
            w = ByteWriter(capacity: pcm.count + 13)
            w.u8(0x61); w.u32(seq); w.u64(t); w.bytes(pcm)
        case let .file(m): return m.encoded
        case let .frameTiming(ft): w.u8(0x81); ft.write(&w)
        case let .displayInfo(p, mw, mh, hi): w.u8(0x05); w.u8(p); w.u16(mw); w.u16(mh); w.u8(hi ? 1 : 0)
        case let .displayList(streamed, selected, ds):
            w.u8(0x06); w.u32(streamed); w.u32(selected)
            let list = ds.prefix(255)
            w.u8(UInt8(list.count))
            for d in list { d.write(&w) }
        case let .displayChanged(id, reason, requested): w.u8(0x07); w.u32(id); w.u8(reason); w.u32(requested)
        case let .inputCaps(c): w.u8(0x44); w.u32(c.rawValue)
        }
        return w.data
    }

    public static func decode(_ d: Data) throws -> HostMessage {
        var r = ByteReader(d)
        let t = try r.u8()
        switch t {
        case 0x08: return .authResult(AuthCode(rawValue: try r.u8()) ?? .unknownViewer)
        case 0x09: return .pairReveal(nonce: try r.bytes(32))
        case 0x02:
            let v = try r.u16(), name = try r.str()
            return .serverHello(version: v, hostName: name, config: try VideoConfig.read(&r))
        case 0x03: return .videoConfig(try VideoConfig.read(&r))
        case 0x04: return .sharpLayerConfig(try VideoConfig.read(&r))
        case 0x31: return .pong(clientTimeUs: try r.u64(), hostTimeUs: try r.u64())
        case 0x40:
            let id = try r.u32(), ts = try r.u64(), flags = try r.u8()
            var rects: [FrameRect]?
            if flags & 8 != 0 {
                let n = Int(try r.u16())
                rects = try (0..<n).map { _ in FrameRect(x: try r.u16(), y: try r.u16(), w: try r.u16(), h: try r.u16()) }
            }
            return .videoFrame(frameId: id, captureTimeUs: ts, keyframe: flags & 1 != 0, refresh: flags & 2 != 0, sharp: flags & 4 != 0, rects: rects, data: r.rest())
        case 0x41: return .cursorPos(x: try r.f32(), y: try r.f32(), visible: try r.u8() != 0)
        case 0x42:
            let id = try r.u32(), cw = try r.u16(), ch = try r.u16(), hx = try r.u16(), hy = try r.u16()
            return .cursorShape(id: id, w: cw, h: ch, hotX: hx, hotY: hy, bgra: try r.bytes(Int(cw) * Int(ch) * 4))
        case 0x43: return .cursorShapeRef(id: try r.u32())
        case 0x50: return .clipboard(try ClipboardData.read(&r))
        case 0x51: return .clipboardCaps(formats: try r.u32(), maxBytes: try r.u32())
        case 0x60: return .audioConfig(try AudioConfig.read(&r))
        case 0x61: return .audioFrame(seq: try r.u32(), captureTimeUs: try r.u64(), pcm: r.rest())
        case 0x70...0x79: return .file(try FileMessage.read(type: t, &r))
        case 0x81: return .frameTiming(try FrameTiming.read(&r))
        case 0x05: return .displayInfo(preference: try r.u8(), modeW: try r.u16(), modeH: try r.u16(), hidpi: try r.u8() != 0)
        case 0x06:
            let streamed = try r.u32(), selected = try r.u32(), n = Int(try r.u8())
            return .displayList(streamed: streamed, selected: selected, displays: try (0..<n).map { _ in try DisplayDescriptor.read(&r) })
        case 0x07: return .displayChanged(id: try r.u32(), reason: try r.u8(), requested: try r.u32())
        case 0x44: return .inputCaps(InputCaps(rawValue: try r.u32()))
        default: throw WireError.unknownMessage(t)
        }
    }
}
