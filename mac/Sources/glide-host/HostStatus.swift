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
        /// SCK frame PTS -> capture callback, p50 ms.
        var captureMs: Double?
        /// The viewer's latest latency report (PROTOCOL.md §3.4).
        var latency: LatencyReport?
        var statsAt: Date?
        /// "on", "muted" or "off"; nil when the viewer doesn't take audio (PROTOCOL.md §3.2).
        var audio: String?
        /// The viewer negotiated file transfer (§6).
        var files = false
    }

    /// A finished (or failed) file transfer, for the menu's Recent Transfers.
    struct Transfer {
        var incoming: Bool
        var files: Int
        var bytes: UInt64
        /// Received top-level items (revealed in Finder from the menu).
        var items: [URL]
        var ok: Bool
        var text: String?
        var date: Date
    }

    struct Snapshot {
        /// "dial" (host dials the viewer) or "listen".
        var dialTarget: String?
        var listenPort: UInt16?
        var dialDetail: String?   // e.g. "waiting: connection refused"
        var paused = false
        var serverError: String?
        var viewer: Viewer?
        /// Security v2: pairing window open until this time.
        var pairingUntil: Date?
        /// Name of the viewer currently waiting for code confirmation.
        var pairingWith: String?
        /// Last notable security event (rejected viewer, paired, v1 viewer), shown in the menu.
        var note: Note?
        var pairedViewers: [PairedViewer] = []
        /// This Mac's key fingerprint (shown in the Paired Viewers submenu).
        var hostFingerprint: String?
        /// Newest first, at most 8.
        var transfers: [Transfer] = []

        var phase: Phase {
            if paused { return .paused }
            if let v = viewer { return v.captureError == nil ? .connected : .error }
            if serverError != nil { return .error }
            return dialTarget != nil ? .dialing : .idle
        }
    }

    struct Note: Equatable {
        var text: String
        var at: Date
        var warning: Bool
        var count = 1
    }

    private let lock = NSLock()
    private var s = Snapshot()
    private var notifyScheduled = false
    /// Called on the main queue (coalesced) after any change.
    var onChange: (() -> Void)?
    /// Live file-transfer progress of the active session (set by Session).
    var fileProgress: (() -> [FileTransferEngine.Progress])?

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
    /// Records a security note; repeats of the same text bump a counter instead of replacing it.
    func note(_ text: String, warning: Bool) {
        update { s in
            if var n = s.note, n.text == text { n.count += 1; n.at = Date(); s.note = n }
            else { s.note = Note(text: text, at: Date(), warning: warning) }
        }
    }

    func sessionEnded(id: Int) { update { s in if s.viewer?.sessionId == id { s.viewer = nil } } }
    func viewSize(id: Int, w: Int, h: Int) { updateViewer(id) { $0.viewW = w; $0.viewH = h } }
    func video(id: Int, config: VideoConfig, hybrid: Bool) { updateViewer(id) { $0.video = config; $0.hybrid = hybrid } }
    func audio(id: Int, _ state: String?) { updateViewer(id) { $0.audio = state } }
    func captureError(id: Int, _ e: String?) { updateViewer(id) { $0.captureError = e } }
    func files(id: Int, _ on: Bool) { updateViewer(id) { $0.files = on } }
    func addTransfer(_ t: Transfer) { update { s in s.transfers.insert(t, at: 0); if s.transfers.count > 8 { s.transfers.removeLast() } } }
    func stats(id: Int, fps: Double, mbps: Double, encodeMs: Double, captureMs: Double? = nil) {
        updateViewer(id) { $0.fps = fps; $0.mbps = mbps; $0.encodeMs = encodeMs; $0.captureMs = captureMs; $0.statsAt = Date() }
    }
    func viewerLatency(id: Int, _ r: LatencyReport) { updateViewer(id) { $0.latency = r } }
}
