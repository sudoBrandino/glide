import Foundation

/// The host's authorization for one managed session (docs/ENTERPRISE.md §6.3): which viewer key
/// may complete a Noise handshake, for whom, with which permissions, until when. In memory only:
/// it is never written to `pairedViewers` or anywhere else.
public struct SessionGrant: Equatable, Sendable {
    public var sessionId: String
    public var viewerKey: Data
    public var viewerName: String
    public var user: CloudUser
    public var permissions: CloudPermissions
    public var expiresAt: Date

    public init(sessionId: String, viewerKey: Data, viewerName: String, user: CloudUser, permissions: CloudPermissions, expiresAt: Date) {
        self.sessionId = sessionId; self.viewerKey = viewerKey; self.viewerName = viewerName; self.user = user
        self.permissions = permissions; self.expiresAt = expiresAt
    }

    /// From an accepted offer. The grant lives until the offer's `expires_at`, at most
    /// `maxLifetime` (the relay ticket's 120 s) from now, so a stale grant can't be claimed later.
    public init?(offer o: SessionOffer, now: Date = Date(), maxLifetime: TimeInterval = 120) {
        guard o.viewer.publicKey.count == 64, let key = Data(hex: o.viewer.publicKey), key.count == 32 else { return nil }
        let cap = now.addingTimeInterval(maxLifetime)
        let exp = CloudTime.parse(o.expiresAt).map { min($0, cap) } ?? cap
        self.init(sessionId: o.sessionId, viewerKey: key, viewerName: PairedViewer.displayName(o.viewer.name), user: o.user,
                  permissions: o.permissions, expiresAt: exp)
    }
}

/// The live grants. Each is claimed at most once, only for its own session, only by its viewer
/// key and only before it expires; claiming removes it. Thread-safe; times are passed in for tests.
public final class GrantStore: @unchecked Sendable {
    private let lock = NSLock()
    private var grants: [String: SessionGrant] = [:]

    public init() {}

    public func add(_ g: SessionGrant) {
        lock.lock(); grants[g.sessionId] = g; lock.unlock()
    }

    /// The grant for `sessionId` if `viewerKey` is its key and it hasn't expired, removing it
    /// (single use). A wrong key also removes it: the relay delivered someone else.
    public func claim(sessionId: String, viewerKey: Data, now: Date = Date()) -> SessionGrant? {
        lock.lock(); defer { lock.unlock() }
        purge(now)
        guard let g = grants.removeValue(forKey: sessionId) else { return nil }
        return g.viewerKey == viewerKey ? g : nil
    }

    /// Withdraws a grant (session cancelled, revoked, relay closed before the handshake).
    public func revoke(_ sessionId: String) { lock.lock(); grants[sessionId] = nil; lock.unlock() }

    public func revokeAll() { lock.lock(); grants = [:]; lock.unlock() }

    public func isLive(_ sessionId: String, now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        purge(now)
        return grants[sessionId] != nil
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return grants.count }

    private func purge(_ now: Date) { grants = grants.filter { $0.value.expiresAt > now } }
}

/// The viewer's pin for a managed session: the host key the cloud named, for target
/// `relay:<session_id>`, in memory only (never in viewer.json).
public struct RelayPin: Equatable, Sendable {
    public var sessionId: String
    public var hostKey: Data
    public var hostName: String

    public init?(_ r: SessionResponse) {
        guard CloudID.isValid(r.sessionId), r.host.publicKey.count == 64, let k = Data(hex: r.host.publicKey), k.count == 32 else { return nil }
        sessionId = r.sessionId
        hostKey = k
        hostName = PairedViewer.displayName(r.host.name)
    }

    public var target: String { "relay:\(sessionId)" }
}

/// The host's decision after an authenticated msg3 (PROTOCOL.md §2.3 rule 3, ENTERPRISE.md §3.1):
/// a connection bridged for a managed session is accepted only for that session's granted key
/// (no pairing, nothing pinned); a LAN connection only for a paired key or through pairing, and
/// never because of a grant.
public enum HostAuthDecision: Equatable, Sendable {
    /// Managed session: accept without pairing. The grant is consumed; it is never pinned.
    case granted(SessionGrant)
    /// LAN: the key is in `pairedViewers`.
    case paired
    /// LAN: pairing may start (the window was open and is now claimed).
    case pair
    case reject(AuthCode)
}

public enum HostAuth {
    /// - relaySessionId: the managed session this connection was bridged for; nil for LAN.
    /// - claimPairing: claims the pairing window (only called for a LAN pair request).
    public static func decide(viewerKey: Data, pairRequest: Bool, relaySessionId: String?, grants: GrantStore,
                              isPaired: (Data) -> Bool, claimPairing: () -> PairingWindow.Claim, now: Date = Date()) -> HostAuthDecision {
        if let sid = relaySessionId {
            guard !pairRequest else {
                // Pairing never runs over the relay: the cloud names the key.
                grants.revoke(sid)
                return .reject(.pairingClosed)
            }
            if let g = grants.claim(sessionId: sid, viewerKey: viewerKey, now: now) { return .granted(g) }
            return .reject(.unknownViewer)
        }
        if pairRequest {
            switch claimPairing() {
            case .granted: return .pair
            case .closed: return .reject(.pairingClosed)
            case .busy: return .reject(.busy)
            }
        }
        return isPaired(viewerKey) ? .paired : .reject(.unknownViewer)
    }
}
