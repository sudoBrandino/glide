import Foundation

/// When the host dials the PC itself (host.json `connect`, PROTOCOL.md §0 and §2.5). Pure logic so
/// the self-test can check it; `Server.dial` in glide-host applies it.
public enum DialPolicy {
    public enum Action: Equatable {
        /// Open a connection to the PC now.
        case dial
        /// Paused from the menu: stop the dial loop (resuming restarts it).
        case stop
        /// A viewer is connected (it dialed in, or an earlier dial is streaming): check again later.
        case waitForSession
        /// No viewer is paired and the pairing window is closed: the PC could only be refused
        /// (unknown viewer, or pairing closed), and each refusal grows the PC's per-address backoff.
        /// Check again later; opening the pairing window dials right away (`Server.kickDialer`).
        case waitForPairing
    }

    /// Redial / idle-check interval while nothing failed.
    public static let interval: TimeInterval = 2
    public static let maxDelay: TimeInterval = 60

    public static func next(paused: Bool, sessionActive: Bool, pairedViewers: Int, pairingOpen: Bool) -> Action {
        if paused { return .stop }
        if sessionActive { return .waitForSession }
        if pairedViewers == 0 && !pairingOpen { return .waitForPairing }
        return .dial
    }

    /// Delay before the next dial after `failures` consecutive dialed sessions that ended without
    /// authenticating: 2 s, then doubling from the second failure up to 60 s.
    public static func redialDelay(failures: Int) -> TimeInterval {
        guard failures > 1 else { return interval }
        return min(interval * pow(2, Double(min(failures - 1, 5))), maxDelay)
    }
}
