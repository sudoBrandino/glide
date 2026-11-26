import Foundation

/// Client audit events (docs/ENTERPRISE.md §9), batched to `POST /v1/audit`: at most 100 events
/// and 256 KiB per batch, sent a few seconds after the first queued event. A batch that failed
/// for a network error, `401`, `429` or `5xx` is retried later; one rejected with any other `4xx`
/// would be rejected again, so it is dropped and logged locally (§6.7). At most `maxQueued` events
/// wait (oldest dropped).
public final class AuditReporter: @unchecked Sendable {
    public static let maxBatch = 100
    public static let maxBatchBytes = 256 * 1024
    public static let maxQueued = 1000

    private let queue = DispatchQueue(label: "glide.cloud.audit")
    private var events: [AuditEvent] = []
    private var flushScheduled = false
    private var sending = false
    private let delay: TimeInterval
    /// Sends one batch; throws to keep the events for a retry. Settable for tests.
    public var send: (AuditBatch) async throws -> Void
    /// File names in `session.file_*` (org setting `audit_file_names`).
    public var includeFileNames = true
    /// Local log (dropped batches).
    public var log: (String) -> Void = { _ in }

    public init(delay: TimeInterval = 5, send: @escaping (AuditBatch) async throws -> Void) {
        self.delay = delay
        self.send = send
    }

    public func report(_ type: String, sessionId: String?, detail: [String: JSONValue], at date: Date = Date()) {
        guard AuditEvent.clientTypes.contains(type) else { return }
        let e = AuditEvent(type: type, ts: CloudTime.format(date), sessionId: sessionId, detail: .object(detail))
        guard ((try? JSONEncoder.cloud.encode(e))?.count ?? Int.max) + 32 <= Self.maxBatchBytes else { return }
        queue.async { [self] in
            events.append(e)
            if events.count > Self.maxQueued { events.removeFirst(events.count - Self.maxQueued) }
            scheduleFlush()
        }
    }

    // MARK: The §9 client events

    /// `session.file_sent` / `session.file_received` (`count`, `bytes`, `names?`).
    public func files(sent: Bool, sessionId: String, count: Int, bytes: UInt64, names: [String]) {
        var d: [String: JSONValue] = ["count": .int(count), "bytes": .number(Double(bytes))]
        if includeFileNames, !names.isEmpty { d["names"] = .array(names.prefix(100).map { .string($0) }) }
        report(sent ? "session.file_sent" : "session.file_received", sessionId: sessionId, detail: d)
    }

    /// `session.clipboard` (`direction`: `to_host`|`to_viewer`, `kind`: `text`|`image`, `bytes`).
    public func clipboard(sessionId: String, toHost: Bool, image: Bool, bytes: Int) {
        report("session.clipboard", sessionId: sessionId, detail: [
            "direction": .string(toHost ? "to_host" : "to_viewer"), "kind": .string(image ? "image" : "text"), "bytes": .int(bytes),
        ])
    }

    /// `session.local_end` (`by`: `host_user`|`viewer_user`).
    public func localEnd(sessionId: String, byHostUser: Bool) {
        report("session.local_end", sessionId: sessionId, detail: ["by": .string(byHostUser ? "host_user" : "viewer_user")])
    }

    public func error(code: String, message: String, sessionId: String? = nil) {
        report("client.error", sessionId: sessionId, detail: ["code": .string(code), "message": .string(String(message.prefix(500)))])
    }

    /// Sends what is queued now (e.g. before quitting); `done` after the attempt.
    public func flush(_ done: (() -> Void)? = nil) {
        queue.async { [self] in flushOnQueue(done) }
    }

    public var queuedCount: Int { queue.sync { events.count } }

    /// Splits `events` into batches within the count and size limits (oversized single events are
    /// dropped). Pure, for tests.
    public static func batches(_ events: [AuditEvent]) -> [AuditBatch] {
        var out: [AuditBatch] = []
        var cur: [AuditEvent] = []
        var size = 16
        let enc = JSONEncoder.cloud
        for e in events {
            let n = ((try? enc.encode(e))?.count ?? 0) + 1
            if n + 16 > maxBatchBytes { continue }
            if cur.count == maxBatch || size + n > maxBatchBytes {
                out.append(AuditBatch(events: cur))
                cur = []
                size = 16
            }
            cur.append(e)
            size += n
        }
        if !cur.isEmpty { out.append(AuditBatch(events: cur)) }
        return out
    }

    /// A `4xx` other than `401` and `429`: sending the batch again can't succeed.
    public static func isRejected(_ e: CloudError) -> Bool {
        guard let st = e.status else { return false }
        return (400..<500).contains(st) && st != 401 && st != 429
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + delay) { [self] in
            flushScheduled = false
            flushOnQueue(nil)
        }
    }

    private func flushOnQueue(_ done: (() -> Void)?) {
        guard !sending, !events.isEmpty else { done?(); return }
        guard let first = Self.batches(events).first else { events = []; done?(); return }
        sending = true
        let n = first.events.count
        let send = self.send
        Task {
            var ok = true
            var drop: CloudError?
            do { try await send(first) } catch {
                ok = false
                if let e = error as? CloudError, Self.isRejected(e) { drop = e }
            }
            queue.async { [self] in
                sending = false
                if let e = drop {
                    log("audit: Glide Cloud rejected \(n) event(s) (\(e)); dropped: \(first.events.map(\.type).joined(separator: ", "))")
                    events.removeFirst(min(n, events.count))
                    if !events.isEmpty { scheduleFlush() }
                } else if ok {
                    events.removeFirst(min(n, events.count))
                    if !events.isEmpty { scheduleFlush() }
                } else {
                    // Retry later (the cloud may be unreachable); keep the order.
                    queue.asyncAfter(deadline: .now() + 30) { [self] in scheduleFlush() }
                }
                done?()
            }
        }
    }
}
