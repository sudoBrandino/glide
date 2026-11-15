import Foundation

/// Bounds the log lines that peers can cause before they authenticate. Anyone who can reach the
/// port can open connections, and each one used to log two or three lines, even while rate-limited.
///
/// Within each window (60 s by default), a key (the peer's address bucket) may log `perKey` lines,
/// and all keys together `total` lines. Later lines are counted instead. When the window is over,
/// one summary line reports what was suppressed: "N more ... from X". Memory is bounded too:
/// suppressed counts are kept per key for the first `maxTracked` keys, the rest are lumped together.
/// Thread-safe. Times are seconds on any monotonic clock.
public final class LogCoalescer: @unchecked Sendable {
    public let window: TimeInterval
    public let perKey: Int
    public let total: Int
    public let maxTracked: Int
    /// Keys named in a summary line (the most frequent first); the rest are counted as "other".
    public let maxListed: Int

    private let lock = NSLock()
    private var windowStart: TimeInterval?
    private var logged: [String: Int] = [:]
    private var loggedTotal = 0
    private var suppressed: [String: Int] = [:]
    private var suppressedOther = 0

    public init(window: TimeInterval = 60, perKey: Int = 6, total: Int = 30, maxTracked: Int = 64, maxListed: Int = 4) {
        self.window = window
        self.perKey = perKey
        self.total = total
        self.maxTracked = maxTracked
        self.maxListed = maxListed
    }

    public struct Decision: Equatable {
        /// Log the line.
        public let log: Bool
        /// Log this first: what the previous window suppressed.
        public let summary: String?
    }

    /// Whether a line for `key` may be logged at `now`.
    public func admit(_ key: String, now: TimeInterval) -> Decision {
        lock.lock(); defer { lock.unlock() }
        var summary: String?
        if let start = windowStart, now >= start + window { summary = rollLocked() }
        if windowStart == nil { windowStart = now }
        let n = logged[key, default: 0]
        if n < perKey && loggedTotal < total {
            logged[key] = n + 1
            loggedTotal += 1
            return Decision(log: true, summary: summary)
        }
        if suppressed[key] != nil || suppressed.count < maxTracked {
            suppressed[key, default: 0] += 1
        } else {
            suppressedOther += 1
        }
        return Decision(log: false, summary: summary)
    }

    /// The summary of a window that is over (and starts afresh), or nil if the window isn't over or
    /// suppressed nothing. Call it some time after a suppressed line, so the count isn't held back
    /// until the next connection.
    public func flush(now: TimeInterval) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let start = windowStart, now >= start + window else { return nil }
        return rollLocked()
    }

    /// When the current window ends, if it has suppressed lines to report (nil otherwise).
    public var pendingSummaryAt: TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let start = windowStart, !suppressed.isEmpty || suppressedOther > 0 else { return nil }
        return start + window
    }

    private func rollLocked() -> String? {
        defer {
            windowStart = nil
            logged = [:]; loggedTotal = 0
            suppressed = [:]; suppressedOther = 0
        }
        let count = suppressed.values.reduce(0, +) + suppressedOther
        guard count > 0 else { return nil }
        let ranked = suppressed.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var parts = ranked.prefix(maxListed).map { "\($0.value) from \($0.key)" }
        let other = ranked.dropFirst(maxListed).reduce(suppressedOther) { $0 + $1.value }
        if other > 0 { parts.append("\(other) from other addresses") }
        return "\(count) more log line\(count == 1 ? "" : "s") about unauthenticated connections suppressed (\(Int(window)) s window): "
            + parts.joined(separator: ", ")
    }
}
