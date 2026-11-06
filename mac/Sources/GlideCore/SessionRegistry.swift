import Foundation

/// Tracks the active session and connections still authenticating. A new connection never affects
/// the active session until it authenticates (so an unauthenticated peer can't kick the viewer).
public final class SessionRegistry<S: AnyObject>: @unchecked Sendable {
    public let maxPending: Int
    private let lock = NSLock()
    private var pending: [S] = []
    public var current: S? { lock.lock(); defer { lock.unlock() }; return _current }
    private var _current: S?

    public init(maxPending: Int = 4) { self.maxPending = maxPending }

    public var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

    /// Registers a new, unauthenticated connection. False = too many pending; reject it.
    public func admit(_ s: S) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard pending.count < maxPending else { return false }
        pending.append(s)
        return true
    }

    /// `s` authenticated: it becomes the active session. Returns the session it replaces (the
    /// caller ends it), or nil. Ignored (returns nil, no change) if `s` isn't pending.
    @discardableResult
    public func authenticated(_ s: S) -> (promoted: Bool, replaced: S?) {
        lock.lock(); defer { lock.unlock() }
        guard let i = pending.firstIndex(where: { $0 === s }) else { return (false, nil) }
        pending.remove(at: i)
        let old = _current
        _current = s
        return (true, old === s ? nil : old)
    }

    /// `s` ended (pending or active). Returns true if it was the active session.
    @discardableResult
    public func ended(_ s: S) -> Bool {
        lock.lock(); defer { lock.unlock() }
        pending.removeAll { $0 === s }
        if _current === s { _current = nil; return true }
        return false
    }

    /// Everything (active + pending), e.g. to end all on pause.
    public var all: [S] {
        lock.lock(); defer { lock.unlock() }
        return (_current.map { [$0] } ?? []) + pending
    }
}
