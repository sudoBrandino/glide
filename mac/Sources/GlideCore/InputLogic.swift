import CoreGraphics
import Foundation

// Pure input logic used by the host's InputInjector, kept free of CGEvent posting so that
// glide-selftest can check it (PROTOCOL.md §3 and §3.5).

/// Viewer coordinates -> global display points.
public enum PointerMapping {
    /// How far inside the display's right/bottom edge the pointer may go. `maxX` itself belongs to
    /// the neighbouring display; 0.25 pt is inside the last pixel at both 1x and 2x.
    public static let edgeInset: CGFloat = 0.25

    /// `x`, `y` normalized over the display: 0 = left/top edge, 1 = right/bottom edge (§3), so the
    /// point is `origin + v·size`, clamped inside the display. (The pre-fix mapping used
    /// `v·(size-1)`, which pulled every point up to 1 pt toward the origin and made the last
    /// point row/column — Dock trigger, right-side hot corners — unreachable.)
    public static func point(x: Float, y: Float, in b: CGRect) -> CGPoint {
        CGPoint(x: axis(x, b.minX, b.width), y: axis(y, b.minY, b.height))
    }

    /// Relative motion (§3.5 MouseDelta): `p` moved by `dx`, `dy` points, clamped to the display.
    public static func offset(_ p: CGPoint, dx: CGFloat, dy: CGFloat, in b: CGRect) -> CGPoint {
        CGPoint(x: clamp(p.x + dx, b.minX, b.width), y: clamp(p.y + dy, b.minY, b.height))
    }

    private static func axis(_ v: Float, _ origin: CGFloat, _ size: CGFloat) -> CGFloat {
        let n = v.isFinite ? min(max(CGFloat(v), 0), 1) : 0.5
        return clamp(origin + n * size, origin, size)
    }

    private static func clamp(_ v: CGFloat, _ origin: CGFloat, _ size: CGFloat) -> CGFloat {
        min(max(v, origin), origin + max(size - edgeInset, 0))
    }
}

/// Double/triple-click counting for injected mouse events (`kCGMouseEventClickState`).
public struct ClickCounter {
    /// Seconds between downs (the Mac's double-click setting, `NSEvent.doubleClickInterval`).
    public var interval: TimeInterval
    /// Max distance in points between the downs of one multi-click.
    public var slop: CGFloat
    private var last: (button: UInt8, time: TimeInterval, pos: CGPoint, count: Int64)?

    public init(interval: TimeInterval, slop: CGFloat = 5) {
        self.interval = interval
        self.slop = slop
    }

    /// A button went down: its click count (1, 2, 3, ...).
    public mutating func down(button: UInt8, at pos: CGPoint, time: TimeInterval) -> Int64 {
        var count: Int64 = 1
        if let l = last, l.button == button, time - l.time >= 0, time - l.time < interval,
           abs(l.pos.x - pos.x) <= slop, abs(l.pos.y - pos.y) <= slop {
            count = l.count + 1
        }
        last = (button, time, pos, count)
        return count
    }

    /// The click count for the matching up and for drags with `button` held.
    public func count(button: UInt8) -> Int64 {
        guard let l = last, l.button == button else { return 1 }
        return l.count
    }

    public mutating func reset() { last = nil }
}

/// Turns viewer scrolls (notches, §3 / §3.5) into Mac scroll events.
///
/// - Discrete wheel notches become line scrolls (`linesPerNotch` per notch), which applications
///   treat as a real mouse wheel (their own smooth scrolling, line steps in terminals).
/// - Precise input (touchpad, high-resolution wheel) becomes pixel scrolls wrapped in a gesture:
///   `began` on the first event, `changed` after, and `ended` once no precise event arrived for
///   `gestureTimeout` (the caller polls `tick`).
///
/// Output wheel values use CoreGraphics signs: `wheel1 > 0` scrolls up, `wheel2 > 0` scrolls
/// **left**. The protocol's `dx > 0` scrolls right, so `wheel2 = -dx`.
public struct ScrollConverter {
    public enum Phase: Int64, Sendable { case began = 1, changed = 2, ended = 4 }  // kCGScrollPhase*

    public enum Output: Equatable, Sendable {
        case lines(wheel1: Int32, wheel2: Int32)
        case pixels(wheel1: Int32, wheel2: Int32, phase: Phase)
    }

    public var pixelsPerNotch: Double = 48
    public var linesPerNotch: Double = 3
    public var gestureTimeout: TimeInterval = 0.1
    public private(set) var inGesture = false
    private var lastPrecise: TimeInterval = 0
    private var pixelRest = (x: 0.0, y: 0.0)
    private var lineRest = (x: 0.0, y: 0.0)

    public init() {}

    /// Source inference for legacy `MouseWheel` (0x12): fractional notches come from a touchpad or a
    /// high-resolution wheel. While a precise gesture runs, everything continues it.
    public func inferPrecise(dx: Float, dy: Float) -> Bool {
        func fractional(_ v: Float) -> Bool { abs(v - v.rounded()) > 1e-4 }
        return inGesture || fractional(dx) || fractional(dy)
    }

    /// One scroll from the viewer. Returns the events to post, in order.
    public mutating func scroll(precise: Bool, dx: Float, dy: Float, now: TimeInterval) -> [Output] {
        guard dx.isFinite, dy.isFinite else { return [] }
        var out: [Output] = []
        if precise {
            pixelRest.x += Double(-dx) * pixelsPerNotch
            pixelRest.y += Double(dy) * pixelsPerNotch
            let w1 = Self.take(&pixelRest.y), w2 = Self.take(&pixelRest.x)
            if !inGesture {
                inGesture = true
                out.append(.pixels(wheel1: w1, wheel2: w2, phase: .began))
            } else if w1 != 0 || w2 != 0 {
                out.append(.pixels(wheel1: w1, wheel2: w2, phase: .changed))
            }
            lastPrecise = now
        } else {
            if let e = end() { out.append(e) }
            lineRest.x += Double(-dx) * linesPerNotch
            lineRest.y += Double(dy) * linesPerNotch
            let w1 = Self.take(&lineRest.y), w2 = Self.take(&lineRest.x)
            if w1 != 0 || w2 != 0 { out.append(.lines(wheel1: w1, wheel2: w2)) }
        }
        return out
    }

    /// Ends the gesture once it has been idle for `gestureTimeout`.
    public mutating func tick(now: TimeInterval) -> Output? {
        guard inGesture, now - lastPrecise >= gestureTimeout else { return nil }
        return end()
    }

    /// Ends a running gesture now (discrete scroll, ReleaseAll, disconnect).
    public mutating func end() -> Output? {
        guard inGesture else { return nil }
        inGesture = false
        pixelRest = (0, 0)
        return .pixels(wheel1: 0, wheel2: 0, phase: .ended)
    }

    /// Whole units out of an accumulator, keeping the fraction (bounded to the Int32 range).
    private static func take(_ v: inout Double) -> Int32 {
        let whole = max(min(v.rounded(.towardZero), Double(Int32.max)), Double(Int32.min))
        v -= whole
        if abs(v) >= 1 { v = 0 }  // only after clamping a huge value
        return Int32(whole)
    }
}

/// Fractional deltas carried over between integer CGEvent delta fields.
public struct DeltaAccumulator {
    private var rest = (x: 0.0, y: 0.0)
    public init() {}
    public mutating func add(dx: Double, dy: Double) -> (dx: Int64, dy: Int64) {
        guard dx.isFinite, dy.isFinite, abs(dx) < 1e9, abs(dy) < 1e9 else { return (0, 0) }
        rest.x += dx
        rest.y += dy
        let ix = rest.x.rounded(.towardZero), iy = rest.y.rounded(.towardZero)
        rest.x -= ix
        rest.y -= iy
        return (Int64(ix), Int64(iy))
    }
    public mutating func reset() { rest = (0, 0) }
}
