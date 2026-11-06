import Foundation
import GlideCore
import Network

/// Shared, thread-safe host state for the menu-bar UI. Writers: Server, Session. Reader: StatusMenu.
final class HostStatus: @unchecked Sendable {
    static let shared = HostStatus()

    enum Phase: String { case idle, dialing, connected, paused, error }

    struct Viewer {
        var sessionId: Int
        var name: String
        var address: String
        var viewW: Int, viewH: Int
        var video: VideoConfig?
        var hybrid = false
        var captureError: String?
        var fps: Double?, mbps: Double?, encodeMs: Double?
        var statsAt: Date?
    }

    struct Snapshot {
        /// "dial" (host dials the viewer) or "listen".
        var dialTarget: String?
        var listenPort: UInt16?
        var dialDetail: String?   // e.g. "waiting: connection refused"
        var paused = false
        var serverError: String?
        var viewer: Viewer?

        var phase: Phase {
            if paused { return .paused }
            if let v = viewer { return v.captureError == nil ? .connected : .error }
            if serverError != nil { return .error }
            return dialTarget != nil ? .dialing : .idle
        }
    }

    private let lock = NSLock()
    private var s = Snapshot()
    private var notifyScheduled = false
    /// Called on the main queue (coalesced) after any change.
    var onChange: (() -> Void)?

    var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }

    func update(_ f: (inout Snapshot) -> Void) {
        lock.lock()
        f(&s)
        let schedule = !notifyScheduled
        notifyScheduled = true
        lock.unlock()
        if schedule {
            DispatchQueue.main.async {
                self.lock.lock(); self.notifyScheduled = false; self.lock.unlock()
                self.onChange?()
            }
        }
    }

    /// Updates the viewer only if it still belongs to session `id`.
    private func updateViewer(_ id: Int, _ f: @escaping (inout Viewer) -> Void) {
        update { s in if s.viewer?.sessionId == id { f(&s.viewer!) } }
    }

    // MARK: Session hooks

    func sessionAuthed(id: Int, name: String, endpoint: NWEndpoint, viewW: Int, viewH: Int) {
        var addr = "\(endpoint)"
        if case let .hostPort(host, _) = endpoint {
            addr = "\(host)"
            if let pct = addr.firstIndex(of: "%") { addr = String(addr[..<pct]) }  // drop IPv6 scope
        }
        update { $0.viewer = Viewer(sessionId: id, name: name, address: addr, viewW: viewW, viewH: viewH); $0.dialDetail = nil }
    }
    func sessionEnded(id: Int) { update { s in if s.viewer?.sessionId == id { s.viewer = nil } } }
    func viewSize(id: Int, w: Int, h: Int) { updateViewer(id) { $0.viewW = w; $0.viewH = h } }
    func video(id: Int, config: VideoConfig, hybrid: Bool) { updateViewer(id) { $0.video = config; $0.hybrid = hybrid } }
    func captureError(id: Int, _ e: String?) { updateViewer(id) { $0.captureError = e } }
    func stats(id: Int, fps: Double, mbps: Double, encodeMs: Double) {
        updateViewer(id) { $0.fps = fps; $0.mbps = mbps; $0.encodeMs = encodeMs; $0.statsAt = Date() }
    }
}
