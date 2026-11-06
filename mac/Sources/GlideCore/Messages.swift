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
        }
        return w.data
    }

    public static func decode(_ d: Data) throws -> ClientMessage {
        var r = ByteReader(d)
        let t = try r.u8()
        switch t {
        case 0x01:
            let v = try r.u16(), caps = CodecCaps(rawValue: try r.u32()), vw = try r.u16(), vh = try r.u16()
            let mode = StreamMode(rawValue: try r.u8()) ?? .fast
            return .hello(version: v, caps: caps, viewW: vw, viewH: vh, mode: mode, maxFps: try r.u8(), name: try r.str())
        case 0x10: return .mouseMove(x: try r.f32(), y: try r.f32())
        case 0x11: return .mouseButton(button: try r.u8(), down: try r.u8() != 0)
        case 0x12: return .mouseWheel(dx: try r.f32(), dy: try r.f32())
        case 0x13: return .key(usage: try r.u16(), down: try r.u8() != 0)
        case 0x14: return .releaseAll
        case 0x15: return .viewSize(w: try r.u16(), h: try r.u16())
        case 0x20: return .requestKeyframe
        case 0x21: return .setMode(mode: StreamMode(rawValue: try r.u8()) ?? .fast, bitrateKbps: try r.u32(), maxFps: try r.u8())
        case 0x30: return .ping(clientTimeUs: try r.u64())
        case 0x50: return .clipboard(try ClipboardData.read(&r))
        case 0x62: return .audioEnable(try r.u8() != 0)
        default: throw WireError.unknownMessage(t)
        }
    }
}

/// Host -> Client messages.
public enum HostMessage {
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

    public var encoded: Data {
        var w = ByteWriter()
        switch self {
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
        }
        return w.data
    }

    public static func decode(_ d: Data) throws -> HostMessage {
        var r = ByteReader(d)
        let t = try r.u8()
        switch t {
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
        default: throw WireError.unknownMessage(t)
        }
    }
}
