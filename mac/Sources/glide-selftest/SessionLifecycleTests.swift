import CryptoKit
import Foundation
import GlideCore
import Network

// Host session lifecycle (review findings 4, 12, 13):
// - view size clamping (a 1x1 ViewSize used to make a 0x0 capture),
// - log coalescing for unauthenticated peers,
// - the start/stop serialization VideoPipeline is built on (SerialGate + StopEpoch): a stop that
//   arrives while a start is still awaiting leaves nothing running,
// - a rate-limited Glide v1 viewer goes through admission (no reply, refused like a v2 viewer).

func sessionLifecycleTests() throws {
    viewSizeTests()
    logCoalescerTests()
    captureLifecycleTests()
    try v1AdmissionTest()
}

private func viewSizeTests() {
    print("view size limits:")
    check(ViewSizeLimits.clamp(0, 1080) == nil && ViewSizeLimits.clamp(1920, 0) == nil, "view size: 0 = not reported")
    check(ViewSizeLimits.clamp(1, 1)! == (320, 200), "view size: 1x1 clamps to 320x200")
    check(ViewSizeLimits.clamp(2560, 1440)! == (2560, 1440), "view size: normal size unchanged")
    check(ViewSizeLimits.clamp(65535, 65535)! == (16384, 16384), "view size: u16 max clamps to 16384")
    // The original failure: maxWidth 1 (a 1-pixel-wide ViewSize) gave pw=1, ph=0, then 0x0 after `&= ~1`.
    check(ViewSizeLimits.captureSize(pixelW: 2560, pixelH: 1440, maxWidth: 1) == (320, 180), "capture size: tiny max width -> 320 wide, never 0x0")
    check(ViewSizeLimits.captureSize(pixelW: 5120, pixelH: 2880, maxWidth: 3840) == (3840, 2160), "capture size: downscaled, aspect kept")
    check(ViewSizeLimits.captureSize(pixelW: 2560, pixelH: 1440, maxWidth: 3840) == (2560, 1440), "capture size: smaller display unchanged")
    check(ViewSizeLimits.captureSize(pixelW: 2561, pixelH: 1441, maxWidth: 4000) == (2560, 1440), "capture size: rounded down to even")
    check(ViewSizeLimits.captureSize(pixelW: 1, pixelH: 0, maxWidth: 3840) == (2, 2), "capture size: degenerate display -> 2x2")
    check(ViewSizeLimits.captureSize(pixelW: 100_000, pixelH: 1, maxWidth: 3840) == (3840, 2), "capture size: extreme aspect keeps height >= 2")
}

private func logCoalescerTests() {
    print("log coalescer:")
    let c = LogCoalescer(window: 60, perKey: 3, total: 5, maxTracked: 64, maxListed: 4)
    let a = (0..<5).map { c.admit("10.0.0.1", now: Double($0)) }
    check(a.map(\.log) == [true, true, true, false, false] && a.allSatisfy { $0.summary == nil }, "coalescer: first lines per address, then suppressed")
    let b = (0..<3).map { c.admit("10.0.0.2", now: 10 + Double($0)) }
    check(b.map(\.log) == [true, true, false], "coalescer: total budget across addresses")
    check(c.flush(now: 30) == nil && c.pendingSummaryAt == 60, "coalescer: no summary before the window ends")
    let s = c.flush(now: 61) ?? ""
    check(s.hasPrefix("3 more log lines") && s.contains("2 from 10.0.0.1") && s.contains("1 from 10.0.0.2"), "coalescer: one summary line when the window ends: \(s)")
    check(c.flush(now: 200) == nil && c.pendingSummaryAt == nil, "coalescer: summary reported once")
    let fresh = c.admit("10.0.0.1", now: 62)
    check(fresh.log && fresh.summary == nil, "coalescer: new window logs again")

    // Without a flush, the next line after the window carries the summary.
    for i in 0..<4 { _ = c.admit("10.0.0.1", now: 63 + Double(i)) }
    let late = c.admit("10.0.0.3", now: 500)
    check(late.log && late.summary?.hasPrefix("2 more log lines") == true, "coalescer: summary rides on the next line: \(late.summary ?? "nil")")

    // Many addresses: memory stays bounded and the summary stays one line.
    // Security events: per-key budget only, so another peer's flood can't silence them.
    let ev = LogCoalescer(window: 60, perKey: 2, total: .max, subject: "pairing/authentication events")
    for i in 0..<500 { _ = ev.admit("10.0.0.\(i % 250)", now: 1) }  // 250 noisy keys, 2 each
    check(ev.admit("192.168.50.20", now: 2).log, "coalescer: a security event from a new address is logged despite other peers' events")
    check(ev.admit("192.168.50.20", now: 2).log && !ev.admit("192.168.50.20", now: 2).log, "coalescer: per-key event budget still applies")
    check(ev.flush(now: 70)?.contains("pairing/authentication events suppressed") == true, "coalescer: event summary names its subject")
    let m = LogCoalescer(window: 60, perKey: 0, total: 0, maxTracked: 2, maxListed: 1)
    for i in 0..<100 { _ = m.admit("10.1.0.\(i % 50)", now: 0) }
    let ms = m.flush(now: 60) ?? ""
    check(ms.hasPrefix("100 more log lines") && ms.contains("2 from 10.1.0.0") && ms.contains("98 from other addresses") && !ms.contains("\n"),
          "coalescer: per-key counts capped, rest lumped together: \(ms)")
}

private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
}

/// Waits (up to 10 s) for an async block from synchronous selftest code.
private func blocking(_ body: @escaping @Sendable () async -> Void) {
    let done = DispatchSemaphore(value: 0)
    Task { await body(); done.signal() }
    _ = done.wait(timeout: .now() + 10)
}

private func captureLifecycleTests() {
    print("capture lifecycle (SerialGate + StopEpoch):")
    let e = StopEpoch()
    let t1 = e.begin()!
    check(e.isCurrent(t1), "epoch: token current")
    e.requestStop()
    let t2 = e.begin()!
    check(!e.isCurrent(t1) && e.isCurrent(t2), "epoch: a stop invalidates earlier tokens only")
    e.close()
    check(!e.isCurrent(t2) && e.begin() == nil && e.isClosed, "epoch: close is final")

    // The gate runs operations one at a time, in order.
    let gate = SerialGate()
    let trace = Box<[String]>([])
    let active = Box(0), maxActive = Box(0)
    blocking {
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<4 {
                g.addTask {
                    try? await Task.sleep(nanoseconds: UInt64(i) * 10_000_000)  // ask in order 0, 1, 2, 3
                    await gate.run {
                        active.update { $0 += 1 }
                        maxActive.update { $0 = max($0, active.get()) }
                        trace.update { $0.append("in\(i)") }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                        trace.update { $0.append("out\(i)") }
                        active.update { $0 -= 1 }
                    }
                }
            }
        }
    }
    check(maxActive.get() == 1, "gate: never two operations at once")
    check(trace.get() == ["in0", "out0", "in1", "out1", "in2", "out2", "in3", "out3"], "gate: in call order \(trace.get())")

    // Finding 4, as VideoPipeline uses it: a stop (or shutdown) that arrives while a start is still
    // awaiting must leave nothing running, and a later start after shutdown does nothing.
    final class FakeCapture: @unchecked Sendable {
        let gate = SerialGate()
        let epoch = StopEpoch()
        let running = Box(false), leaked = Box(0)
        struct Stopped: Error {}
        func start(delayMs: UInt64) async throws {
            try await gate.run {
                guard let token = self.epoch.begin() else { throw Stopped() }
                if self.running.get() { return }
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)  // SCShareableContent, display appearing
                guard self.epoch.isCurrent(token) else { throw Stopped() }
                self.running.update { $0 = true }  // startCapture
                try? await Task.sleep(nanoseconds: 5_000_000)
                guard self.epoch.isCurrent(token) else { self.running.update { $0 = false }; throw Stopped() }
            }
        }
        func stop() async { epoch.requestStop(); await gate.run { self.running.update { $0 = false } } }
        func shutdown() async { epoch.close(); await gate.run { self.running.update { $0 = false } } }
    }
    let f = FakeCapture()
    let startResult = Box<String>("pending")
    blocking {
        async let started: Void = f.start(delayMs: 60)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await f.shutdown()  // the session ended while capture was starting
        do { try await started; startResult.update { $0 = "started" } } catch { startResult.update { $0 = "stopped" } }
    }
    check(startResult.get() == "stopped" && !f.running.get(), "lifecycle: shutdown during a start leaves nothing running")
    let after = Box<String>("pending")
    blocking { do { try await f.start(delayMs: 0); after.update { $0 = "started" } } catch { after.update { $0 = "refused" } } }
    check(after.get() == "refused" && !f.running.get(), "lifecycle: no start after shutdown")
    let g = FakeCapture()
    blocking {
        async let first: Void = g.start(delayMs: 60)
        try? await Task.sleep(nanoseconds: 10_000_000)
        await g.stop()  // re-capture: stop, then start again
        _ = try? await first
        try? await g.start(delayMs: 0)
    }
    check(g.running.get(), "lifecycle: stop during a start, then start again -> running")
}

/// Finding 12: the v1 path runs admission too, so a rate-limited v1 viewer is refused (no reply)
/// instead of always being answered.
private func v1AdmissionTest() throws {
    print("v1 viewer admission:")
    let q = DispatchQueue(label: "selftest.v1admission")
    let listener = try NWListener(using: SecureChannel.tcpParameters(), on: .any)
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    let hostResult = Box<Result<SecureChannel.HostAccepted, Error>?>(nil)
    let admitted = Box(0)
    let hostDone = DispatchSemaphore(value: 0)
    let key = Curve25519.KeyAgreement.PrivateKey()
    listener.newConnectionHandler = { conn in
        let ch = SecureChannel(connection: conn, queue: q)
        conn.stateUpdateHandler = { st in
            if case .ready = st {
                ch.acceptHandshake(identity: key, admission: {
                    admitted.update { $0 += 1 }
                    return (GlideHandshake.statusRateLimited, 0)
                }) { r in
                    hostResult.update { $0 = r }
                    ch.close()
                    hostDone.signal()
                }
            }
        }
        conn.start(queue: q)
    }
    listener.start(queue: q)
    _ = ready.wait(timeout: .now() + 5)
    let v1 = NWConnection(host: "127.0.0.1", port: listener.port!, using: .tcp)
    let reply = Box<Data?>(nil)
    let v1Done = DispatchSemaphore(value: 0)
    v1.stateUpdateHandler = { st in
        if case .ready = st {
            var hs = Data("GLD1".utf8); hs.append(contentsOf: [1, 0]); hs.append(Data(count: 48))
            v1.send(content: hs, completion: .contentProcessed { _ in })
            v1.receive(minimumIncompleteLength: 1, maximumLength: 70) { d, _, _, _ in reply.update { $0 = d }; v1Done.signal() }
        }
    }
    v1.start(queue: DispatchQueue(label: "selftest.v1admission.client"))
    _ = hostDone.wait(timeout: .now() + 5)
    _ = v1Done.wait(timeout: .now() + 5)
    var refused = false
    if case .failure(SecureChannel.HandshakeFailure.refused(GlideHandshake.statusRateLimited))? = hostResult.get() { refused = true }
    check(admitted.get() == 1 && refused, "rate-limited v1 viewer goes through admission and is refused")
    check((reply.get() ?? Data()).isEmpty, "rate-limited v1 viewer gets no reply")
    v1.cancel()
    listener.cancel()
}
