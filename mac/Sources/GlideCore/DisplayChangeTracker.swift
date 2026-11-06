import Foundation

/// Tells Glide's own display-mode switches apart from the user's (pure state machine).
///
/// Call `willSwitch` BEFORE configuring the display: the screen-parameters notification can be
/// delivered re-entrantly, inside CGCompleteDisplayConfiguration, i.e. before the switch call returns.
public struct DisplayChangeTracker: Sendable {
    public enum Verdict: Equatable, Sendable {
        /// Still the mode we expect (or no prior knowledge).
        case unchanged
        /// Part of our own in-flight switch (old or new mode, inside the window).
        case ours
        /// Changed to something we didn't ask for.
        case manual
    }

    /// The mode we believe is (or is about to be) current.
    public private(set) var expected: DisplayModeInfo?
    private var previous: DisplayModeInfo?
    private var target: DisplayModeInfo?
    private var switchStartedAt: TimeInterval = 0
    /// How long notifications showing the old or new mode count as part of our switch.
    public var window: TimeInterval

    public init(current: DisplayModeInfo?, window: TimeInterval = 5) {
        expected = current
        self.window = window
    }

    /// The mode is known to be `current` (e.g. session start); forget any switch in flight.
    public mutating func reset(current: DisplayModeInfo?) {
        expected = current; previous = nil; target = nil
    }

    /// Record our switch from `from` to `to` before touching the display.
    public mutating func willSwitch(from: DisplayModeInfo?, to: DisplayModeInfo, now: TimeInterval) {
        previous = from ?? expected
        target = to
        expected = to
        switchStartedAt = now
    }

    /// Our switch call returned. On failure, `actual` (the mode the display reports) becomes expected.
    public mutating func didSwitch(ok: Bool, actual: DisplayModeInfo?, now: TimeInterval) {
        if !ok { expected = actual; target = nil; previous = nil }
    }

    /// A screen-parameters notification arrived and the display now reports `current`.
    /// Manual = differs from both the expected (target) mode and, during our switch, the mode we left.
    public mutating func observe(current: DisplayModeInfo?, now: TimeInterval) -> Verdict {
        guard let current else { return .unchanged }
        if target != nil, now - switchStartedAt > window { target = nil; previous = nil }
        if let exp = expected, current.sameSize(exp) { return target == nil ? .unchanged : .ours }
        // Mid-switch the display may still report the old mode.
        if target != nil, let p = previous, current.sameSize(p) { return .ours }
        guard expected != nil else { expected = current; return .unchanged }
        expected = current
        target = nil; previous = nil
        return .manual
    }
}
