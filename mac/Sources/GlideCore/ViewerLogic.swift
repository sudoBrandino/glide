import CoreGraphics
import Foundation

// The Mac viewer's (glide-viewer) pure logic, unit-tested by glide-selftest: Mac key codes to
// USB HID usages with the modifier remap, pointer normalization over the drawn video, scroll
// conversion, ClientHello contents, reconnect timing and status texts.

/// macOS virtual key code (kVK_*) -> USB HID Keyboard page (0x07) usage: the inverse of
/// `HIDKeymap`, so a key typed here lands on the same key at the host.
public enum MacKeymap {
    /// Mac key codes several HID usages map to: which usage this viewer sends.
    static let preferred: [UInt16: UInt16] = [
        0x2A: 0x31,  // backslash (0x32 non-US # shares the Mac key)
        0x69: 0x46,  // F13 position = Print Screen
        0x6B: 0x47,  // F14 position = Scroll Lock
        0x71: 0x48,  // F15 position = Pause
        0x72: 0x49,  // Help position = Insert
        0x5F: 0x85,  // JIS keypad comma
        0x68: 0x90,  // Kana = LANG1
        0x66: 0x91,  // Eisu = LANG2
    ]

    static let table: [UInt16: UInt16] = {
        var t: [UInt16: UInt16] = [:]
        for usage in HIDKeymap.table.keys.sorted() {
            guard let code = HIDKeymap.table[usage], t[code] == nil else { continue }
            t[code] = usage
        }
        for (code, usage) in MacKeymap.preferred { t[code] = usage }
        return t
    }()

    /// Mac key codes with a usage (for tests).
    public static var mappedKeyCodes: [UInt16] { table.keys.sorted() }

    /// The HID usage for a Mac key code, without remapping. `iso`: this Mac's keyboard is ISO,
    /// where macOS swaps the key left of 1 (kVK_ISO_Section) and the extra key left of Z
    /// (kVK_ANSI_Grave) relative to their HID usages (see `HIDKeymap.macKeyCode`).
    public static func usage(forMacKeyCode code: UInt16, iso: Bool = false) -> UInt16? {
        if iso {
            switch code {
            case 0x0A: return 0x35
            case 0x32: return 0x64
            default: break
            }
        }
        return table[code]
    }

    /// docs/WINDOWS_HOST.md "Keyboard mapping": Command -> Control, Control -> Windows (GUI),
    /// Option -> Alt (already Alt). Other usages pass through.
    public static func remap(_ usage: UInt16) -> UInt16 {
        switch usage {
        case 0xE3: return 0xE0  // left Command -> left Control
        case 0xE7: return 0xE4  // right Command -> right Control
        case 0xE0: return 0xE3  // left Control -> left GUI
        case 0xE4: return 0xE7  // right Control -> right GUI
        default: return usage
        }
    }

    /// The usage to send for a Mac key code.
    public static func hidUsage(forMacKeyCode code: UInt16, iso: Bool = false, remap doRemap: Bool) -> UInt16? {
        guard let u = usage(forMacKeyCode: code, iso: iso) else { return nil }
        return doRemap ? remap(u) : u
    }

    public static let capsLockKeyCode: UInt16 = 0x39

    // Device-dependent modifier bits (IOKit NX_DEVICE*KEYMASK), present in NSEvent.modifierFlags
    // and CGEventFlags raw values, plus the device-independent masks.
    static let lCtl: UInt64 = 0x0001, lShift: UInt64 = 0x0002, rShift: UInt64 = 0x0004, lCmd: UInt64 = 0x0008
    static let rCmd: UInt64 = 0x0010, lAlt: UInt64 = 0x0020, rAlt: UInt64 = 0x0040, rCtl: UInt64 = 0x2000
    static let shiftMask: UInt64 = 0x20000, controlMask: UInt64 = 0x40000, optionMask: UInt64 = 0x80000, commandMask: UInt64 = 0x100000

    /// For a flags-changed event of modifier key `code`: is that key now down? nil = not a
    /// modifier this tracks (Caps Lock and Fn are not). Uses the left/right device bits, falling
    /// back to the generic mask when an event carries no device bits for that modifier.
    public static func modifierIsDown(keyCode code: UInt16, flags: UInt64) -> Bool? {
        func side(_ bit: UInt64, _ pair: UInt64, _ generic: UInt64) -> Bool {
            flags & pair != 0 ? flags & bit != 0 : flags & generic != 0
        }
        switch code {
        case 0x38: return side(lShift, lShift | rShift, shiftMask)
        case 0x3C: return side(rShift, lShift | rShift, shiftMask)
        case 0x3B: return side(lCtl, lCtl | rCtl, controlMask)
        case 0x3E: return side(rCtl, lCtl | rCtl, controlMask)
        case 0x3A: return side(lAlt, lAlt | rAlt, optionMask)
        case 0x3D: return side(rAlt, lAlt | rAlt, optionMask)
        case 0x37: return side(lCmd, lCmd | rCmd, commandMask)
        case 0x36: return side(rCmd, lCmd | rCmd, commandMask)
        default: return nil
        }
    }
}

/// Pointer position -> `MouseMove` coordinates (PROTOCOL.md §3).
public enum PointerMath {
    /// The rectangle `content` occupies when fitted (aspect kept, centered) in `bounds`.
    public static func fitRect(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0, bounds.width > 0, bounds.height > 0 else { return bounds }
        let s = min(bounds.width / content.width, bounds.height / content.height)
        let w = content.width * s, h = content.height * s
        return CGRect(x: bounds.minX + (bounds.width - w) / 2, y: bounds.minY + (bounds.height - h) / 2, width: w, height: h)
    }

    /// `p` (view points, y down) over the drawn video `rect` (view points), on a screen with
    /// `scale` physical pixels per point: the center of the physical pixel under the pointer,
    /// `(px + 0.5) / rect_width_px`, clamped to 0...1 over letterbox bars.
    public static func normalize(_ p: CGPoint, in rect: CGRect, scale: CGFloat) -> (x: Float, y: Float) {
        func axis(_ v: CGFloat, _ origin: CGFloat, _ size: CGFloat) -> Float {
            let sizePx = (size * scale).rounded()
            guard sizePx >= 1 else { return 0.5 }
            let px = ((v - origin) * scale).rounded(.down)
            return Float(min(max((px + 0.5) / sizePx, 0), 1))
        }
        return (axis(p.x, rect.minX, rect.width), axis(p.y, rect.minY, rect.height))
    }
}

/// NSEvent scroll deltas -> `MouseWheel` notches. Quantized to Windows `WHEEL_DELTA` units
/// (1/120 notch) with the remainder carried, so slow touchpad motion still adds up.
public struct ScrollAccumulator {
    /// Touchpad / precise points per notch (the host scrolls 48 px per precise notch, §3.6).
    public var pointsPerNotch: Double = 48
    private var rest = (x: 0.0, y: 0.0)

    public init() {}

    /// `dx`, `dy`: NSEvent `scrollingDeltaX/Y` (points when `precise`, else lines ≈ notches).
    /// Mac deltas say where content moves (natural scrolling already applied): positive Y =
    /// content down = scroll up, which is `MouseWheel` dy > 0; positive X = content right = scroll
    /// left, so dx is negated. nil when nothing reaches 1/120 notch yet.
    public mutating func add(dx: Double, dy: Double, precise: Bool) -> (dx: Float, dy: Float)? {
        guard dx.isFinite, dy.isFinite else { return nil }
        let k = precise ? 1 / pointsPerNotch : 1
        rest.x += -dx * k
        rest.y += dy * k
        let qx = (rest.x * 120).rounded(.towardZero), qy = (rest.y * 120).rounded(.towardZero)
        guard qx != 0 || qy != 0 else { return nil }
        rest.x -= qx / 120
        rest.y -= qy / 120
        let lim = Double(ClientMessage.maxWheelNotches) / 2
        return (Float(min(max(qx / 120, -lim), lim)), Float(min(max(qy / 120, -lim), lim)))
    }

    public mutating func reset() { rest = (0, 0) }
}

/// The viewer's ClientHello (PROTOCOL.md §3): HEVC 4:2:0 and H.264, no feature bits, fast mode.
public enum ViewerHello {
    public static let caps: CodecCaps = [.hevc420, .h264]

    public static func message(viewW: Int, viewH: Int, maxFps: Int, name: String) -> ClientMessage {
        .hello(version: GlideHandshake.version, caps: caps, viewW: UInt16(clamping: max(viewW, 0)), viewH: UInt16(clamping: max(viewH, 0)),
               mode: .fast, maxFps: UInt8(clamping: max(maxFps, 1)), name: name)
    }
}

/// Redial delays after a lost or failed connection: 1 s doubling to 30 s; reset by a session.
public struct ReconnectBackoff: Equatable {
    public static let first: TimeInterval = 1
    public static let max: TimeInterval = 30
    public private(set) var failures = 0
    public init() {}

    public mutating func next() -> TimeInterval {
        let d = Swift.min(ReconnectBackoff.first * pow(2, Double(Swift.min(failures, 10))), ReconnectBackoff.max)
        failures += 1
        return d
    }

    public mutating func reset() { failures = 0 }
}

/// User-facing texts for handshake and auth outcomes (PROTOCOL.md §1.2, §2.2).
public enum ViewerStatusText {
    public static func refused(status: UInt16, version: UInt16, host: String) -> String {
        switch status {
        case GlideHandshake.statusUnsupportedVersion:
            return "\(host) speaks Glide protocol v\(version); this viewer speaks v\(GlideHandshake.version). Update the older side."
        case GlideHandshake.statusPaused: return "\(host) is paused (not accepting viewers)."
        case GlideHandshake.statusRateLimited: return "\(host) is rate-limiting this Mac after failed attempts; retrying."
        default: return "\(host) refused the connection (status \(status))."
        }
    }

    public static func authResult(_ code: AuthCode, host: String) -> String {
        switch code {
        case .ok: return "Paired with \(host)."
        case .unknownViewer: return "\(host) doesn't recognize this Mac. On the PC choose Pair New Mac…; a code will appear here."
        case .pairingClosed: return pairingClosed(host: host)
        case .declined: return "Pairing was declined on the PC."
        case .timeout: return "Pairing timed out (nobody confirmed the code on the PC)."
        case .busy: return "\(host) is busy pairing another viewer; try again."
        }
    }

    public static func pairingClosed(host: String) -> String {
        "Not paired with \(host) yet, and it isn't accepting pairing. On the PC choose Pair New Mac…; a code will appear here."
    }

    public static func hostKeyChanged(host: String, presented: Data) -> String {
        "HOST KEY CHANGED for \(host) (now \(GlideHandshake.fingerprint(presented))). This could be an impersonation attempt. "
            + "If you reset or reinstalled Glide on the PC, unpair it in Connections (or run glide-viewer --forget \(host)), then pair again."
    }
}
