import AppKit
import Foundation
import GlideCore

/// Bidirectional clipboard sync for one authenticated session (PROTOCOL.md §5).
///
/// Local -> viewer: polls `NSPasteboard.general.changeCount` at 4 Hz on the main thread and sends
/// text (preferred) or an image as PNG. Viewer -> local: writes text and/or PNG (+ TIFF for older
/// apps). `ClipboardEchoGuard` keeps our own writes from being sent back. Pasteboard reads/writes
/// and guard state are main-thread only; image conversion runs on a utility queue.
/// The reading/writing rules live in GlideCore (`ClipboardPasteboard`, selftested).
final class ClipboardSync: @unchecked Sendable {
    private let sessionId: Int
    private let sendMessage: (ClipboardData) -> Void
    private let work = DispatchQueue(label: "glide.clipboard", qos: .utility)

    // Main-thread state.
    private var echo = ClipboardEchoGuard()
    private var timer: Timer?
    private var seq: UInt32 = 0
    private var stopped = false

    init(sessionId: Int, send: @escaping (ClipboardData) -> Void) {
        self.sessionId = sessionId
        self.sendMessage = send
    }

    private func log(_ s: String) { glideLog("session \(sessionId): clipboard: \(s)") }

    /// Begin watching. The pasteboard's current content is not sent, only later changes.
    func start() {
        DispatchQueue.main.async { [self] in
            guard !stopped, timer == nil else { return }
            echo.baseline(marker: NSPasteboard.general.changeCount)
            let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
            t.tolerance = 0.05
            RunLoop.main.add(t, forMode: .common)
            timer = t
            log("sync on" + Self.accessNote())
        }
    }

    /// macOS 15.4+ pasteboard privacy: reading the general pasteboard from a background process
    /// can raise an "allow paste" alert or be denied (System Settings > Privacy & Security).
    /// Writing is never restricted, so only Mac -> viewer is affected.
    private static func accessNote() -> String {
        guard #available(macOS 15.4, *) else { return "" }
        switch NSPasteboard.general.accessBehavior {
        case .alwaysDeny: return " — WARNING: pasteboard access is set to Deny for this app; Mac -> viewer copies will not sync (allow it in System Settings > Privacy & Security)"
        case .ask: return " (pasteboard access: ask — macOS may show an allow-paste alert on the Mac's screen)"
        case .alwaysAllow: return " (pasteboard access: always allow)"
        default: return " (pasteboard access: default — the first Mac copy may trigger an allow-paste alert on the Mac's screen)"
        }
    }

    func stop() {
        DispatchQueue.main.async { [self] in
            stopped = true
            timer?.invalidate()
            timer = nil
        }
    }

    // MARK: Local -> viewer

    private func poll() {
        let pb = NSPasteboard.general
        let marker = pb.changeCount
        guard !stopped, echo.changed(marker: marker) else { return }
        let t0 = Date()
        let content = ClipboardPasteboard.read(pb)
        if Date().timeIntervalSince(t0) > 0.5 {
            log(String(format: "reading the pasteboard took %.1f s (privacy alert or huge content?)", Date().timeIntervalSince(t0)))
        }
        guard let content else { return }
        if case let .skipped(why) = content { return log(why) }
        guard let hash = content.hash, echo.shouldSend(hash: hash, marker: marker) else { return }
        let seq = nextSeq()
        let finish = { [weak self] in
            guard let self else { return }
            switch content.message(seq: seq, maxBytes: ClipboardData.maxBytes) {
            case let .success(c):
                if self.stopped { return }
                self.log("-> viewer: \(c.summary)")
                self.sendMessage(c)
            case let .failure(r): self.log(r.reason)
            }
        }
        if content.needsConversion { work.async(execute: finish) } else { finish() }
    }

    private func nextSeq() -> UInt32 {
        seq &+= 1
        if seq == 0 { seq = 1 }
        return seq
    }

    // MARK: Viewer -> local

    /// Apply a clipboard received from the viewer. Callable from any thread.
    func apply(_ c: ClipboardData) {
        work.async { [self] in
            switch ClipboardPasteboard.prepare(c) {
            case let .failure(r): log("\(r.reason) (seq \(c.seq))")
            case let .success((data, tiff)):
                DispatchQueue.main.async { [self] in
                    guard !stopped else { return }
                    let pb = NSPasteboard.general
                    let hash = ClipboardEchoGuard.hash(data)
                    guard echo.shouldApply(hash: hash, marker: pb.changeCount) else {
                        return log("<- viewer: \(data.summary) already on the pasteboard, kept as is")
                    }
                    echo.didApply(hash: hash, marker: ClipboardPasteboard.write(data, tiff: tiff, to: pb))
                    log("<- viewer: \(data.summary)")
                }
            }
        }
    }
}

/// The host's global `log` (Encoder.swift), reachable from inside a type that defines its own `log`.
private func glideLog(_ s: String) { log(s) }
