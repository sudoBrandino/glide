import Foundation

/// Tracks the active session and connections still authenticating. A new connection never affects
/// the active session until it authenticates (so an unauthenticated peer can't kick the viewer).
public final class SessionRegistry<S: AnyObject>: @unchecked Sendable {
    public let maxPending: Int
    public let maxPendingPerSource: Int
    private let lock = NSLock()
    private var pending: [(s: S, source: String)] = []
    public var current: S? { lock.lock(); defer { lock.unlock() }; return _current }
    private var _current: S?

    public init(maxPending: Int = 4, maxPendingPerSource: Int = 2) {
        self.maxPending = maxPending
        self.maxPendingPerSource = maxPendingPerSource
    }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Registers a new, unauthenticated connection from `source` (peer IP). Never refuses: when a
    /// limit is hit it evicts the oldest pending connection — from the same source if that source is
    /// at its per-source limit, otherwise the oldest overall — so a peer holding junk connections
    /// can't lock out a legitimate login. Returns the evicted session (the caller ends it), if any.
    @discardableResult
    public func admit(_ s: S, source: String) -> S? {
        lock.lock(); defer { lock.unlock() }
        var evicted: S?
        if pending.filter({ $0.source == source }).count >= maxPendingPerSource,
           let i = pending.firstIndex(where: { $0.source == source }) {
            evicted = pending.remove(at: i).s
        } else if pending.count >= maxPending {
            evicted = pending.removeFirst().s
        }
        pending.append((s, source))
        return evicted
    }

    /// `s` authenticated: it becomes the active session. Returns the session it replaces (the
    /// caller ends it), or nil. Ignored (returns nil, no change) if `s` isn't pending.
    @discardableResult
    public func authenticated(_ s: S) -> (promoted: Bool, replaced: S?) {
        lock.lock(); defer { lock.unlock() }
        guard let i = pending.firstIndex(where: { $0.s === s }) else { return (false, nil) }
        pending.remove(at: i)
        let old = _current
        _current = s
        return (true, old === s ? nil : old)
    }

    /// `s` ended (pending or active). Returns true if it was the active session.
    @discardableResult
    public func ended(_ s: S) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0.s === s }
        if _current === s { _current = nil; return true }
        return false
    }

    /// Everything (active + pending), e.g. to end all on pause.
    public var all: [S] {
        lock.lock(); defer { lock.unlock() }
        return (_current.map { [$0] } ?? []) + pending.map(\.s)
    }
}
