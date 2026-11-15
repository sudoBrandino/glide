import Foundation

/// Runs async operations one at a time, in the order they ask (VideoPipeline's start, stop and
/// restart, which await ScreenCaptureKit and must never interleave).
public actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    private func acquire() async {
        guard busy else { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }  // ownership is handed over by release()
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    /// Operations waiting for their turn (not counting the one running), for tests.
    public var queued: Int { waiters.count }

    public func run<T>(_ op: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await op()
    }
}

/// Lets a stop that arrives while a start is still awaiting (seconds, while a virtual display
/// appears or a display mode settles) cancel that start: the start takes a token, checks it after
/// every await and undoes what it already set up once the token is stale. `close()` is final:
/// every later start fails at once. Thread-safe.
public final class StopEpoch: @unchecked Sendable {
    public struct Token: Equatable, Sendable { fileprivate let epoch: UInt64 }

    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private var closedValue = false

    public init() {}

    /// A token for a start beginning now, or nil once closed.
    public func begin() -> Token? {
        lock.lock(); defer { lock.unlock() }
        return closedValue ? nil : Token(epoch: epoch)
    }

    /// False once a stop was requested (or the epoch closed) after `token` was taken.
    public func isCurrent(_ token: Token) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !closedValue && token.epoch == epoch
    }

    /// Invalidates every token taken so far.
    public func requestStop() {
        lock.lock(); epoch &+= 1; lock.unlock()
    }

    /// Invalidates every token and refuses new ones, for good.
    public func close() {
        lock.lock(); epoch &+= 1; closedValue = true; lock.unlock()
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closedValue }
}
