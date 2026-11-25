import Foundation

// What Glide Cloud's settings and a session's permissions mean for the apps (docs/ENTERPRISE.md
// §6.3, §6.4, §7). Pure decisions, applied by glide-host and glide-viewer, checked by
// glide-selftest.

/// The effect of the org settings plus the local managed override on this device.
public struct ManagedPolicy: Equatable, Sendable {
    /// Listen on and dial the LAN port.
    public var lanAllowed: Bool
    /// The LAN pairing window may be opened.
    public var localPairingAllowed: Bool
    /// This app is older than `min_app_version`: no managed sessions.
    public var updateRequired: Bool
    /// The org's `min_app_version` (for the message).
    public var minAppVersion: String?
    /// Report file names in audit events.
    public var auditFileNames: Bool

    /// Settings nil = not enrolled (or not yet known): only the local override applies.
    public init(settings: OrgSettings?, disableLANMode: Bool, appVersion: String) {
        let s = settings
        lanAllowed = !disableLANMode && (s?.lanMode ?? true)
        // Pairing is a LAN feature: without LAN mode there is nothing to pair over.
        localPairingAllowed = lanAllowed && (s?.allowLocalPairing ?? true)
        minAppVersion = s?.minAppVersion
        updateRequired = s?.minAppVersion.map { AppVersion.compare(appVersion, $0) < 0 } ?? false
        auditFileNames = s?.auditFileNames ?? true
    }

    /// Why LAN mode is off, for the UI ("Turned off by ORG", or the local setting).
    public static func lanOffReason(settings: OrgSettings?, disableLANMode: Bool, orgName: String?) -> String? {
        if disableLANMode { return "turned off by this Mac's managed settings (DisableLANMode)" }
        if settings?.lanMode == false { return "turned off by \(orgName ?? "your organization")" }
        return nil
    }
}

/// LAN mode enforced where connections are admitted, not only when it is turned off (§7): a LAN
/// connection already accepted by the listener, or a dial already in flight, must not slip in.
public enum LANGate {
    /// A connection may be adopted / authenticated: a managed (relayed) one always, a LAN one only
    /// while LAN mode is on.
    public static func admits(relaySessionId: String?, lanAllowed: Bool) -> Bool {
        relaySessionId != nil || lanAllowed
    }

    /// A dial that just connected is adopted only if it is still the current dial (the target
    /// wasn't changed or stopped meanwhile) and LAN mode is still on.
    public static func adoptsDialed(generation: Int, current: Int, lanAllowed: Bool) -> Bool {
        generation == current && lanAllowed
    }
}

/// Dotted numeric versions ("0.3.1", "1.0", "0.4.0-beta.2": the suffix is ignored).
public enum AppVersion {
    public static func components(_ v: String) -> [Int] {
        let core = v.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == "-" || $0 == "+" || $0 == " " }).first.map(String.init) ?? ""
        let trimmed = core.hasPrefix("v") || core.hasPrefix("V") ? String(core.dropFirst()) : core
        return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// -1, 0 or 1.
    public static func compare(_ a: String, _ b: String) -> Int {
        let x = components(a), y = components(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}

/// Permission enforcement (§6.3). LAN sessions have no permissions object and are unrestricted;
/// a managed session enforces on both sides what it sends and what it accepts.
public enum ManagedPermissions {
    // MARK: Host side

    /// Input (and anything that changes the host) needs `control`.
    public static func hostAcceptsInput(_ p: CloudPermissions) -> Bool { p.control }
    /// Viewer → host clipboard: control and a to-host direction.
    public static func hostAcceptsClipboard(_ p: CloudPermissions) -> Bool { p.control && p.clipboard.toHostAllowed }
    /// Host → viewer clipboard.
    public static func hostSendsClipboard(_ p: CloudPermissions) -> Bool { p.clipboard.toViewerAllowed }
    /// Viewer → host files (the viewer's offers): control and a to-host direction.
    public static func hostAcceptsFiles(_ p: CloudPermissions) -> Bool { p.control && p.files.toHostAllowed }
    /// Host → viewer files (menu, or the viewer's pull of copied files).
    public static func hostSendsFiles(_ p: CloudPermissions) -> Bool { p.files.toViewerAllowed }
    public static func hostSendsAudio(_ p: CloudPermissions) -> Bool { p.audio }

    /// Whether the host processes `m` from the viewer. Dropped messages are ignored silently
    /// (file offers are declined by the transfer engine, whose `receive` is off). ReleaseAll is
    /// always accepted: it only lets go of keys. SetDisplayPreference changes this Mac's display
    /// mode, so it needs control.
    public static func hostAccepts(_ m: ClientMessage, _ p: CloudPermissions) -> Bool {
        switch m {
        case .mouseMove, .mouseButton, .mouseWheel, .key, .scroll, .mouseDelta, .keyExtra, .setDisplayPreference:
            return hostAcceptsInput(p)
        case .releaseAll:
            return true
        case .clipboard:
            return hostAcceptsClipboard(p)
        case let .file(f):
            return hostAcceptsFile(f, p)
        case .audioEnable:
            return true  // the host only sends audio when `audio` allows it; muting is harmless
        case .hello, .viewSize, .requestKeyframe, .setMode, .ping, .pairConfirm, .latencyEnable, .latencyReport, .selectDisplay:
            return true
        }
    }

    /// File messages from the viewer: its offers and data need to-host; the viewer's answers to the
    /// host's transfers, and the pull request, need to-viewer.
    public static func hostAcceptsFile(_ f: FileMessage, _ p: CloudPermissions) -> Bool {
        switch f {
        case .offer, .chunk, .end: return hostAcceptsFiles(p)
        case .pull, .answer, .ack, .done: return hostSendsFiles(p)
        case .cancel: return true  // stopping a transfer is always allowed
        case .caps, .pullResult: return false  // host → viewer only
        }
    }

    /// FileCaps flags the host advertises for these permissions (and its own settings).
    public static func hostFileCapsFlags(_ p: CloudPermissions?, receiveSetting: Bool) -> UInt32 {
        guard let p else { return (receiveSetting ? FileMessage.capsReceive : 0) | FileMessage.capsSend }
        return (receiveSetting && hostAcceptsFiles(p) ? FileMessage.capsReceive : 0) | (hostSendsFiles(p) ? FileMessage.capsSend : 0)
    }

    // MARK: Viewer side

    /// Whether the viewer may send `m` to the host.
    public static func viewerMaySend(_ m: ClientMessage, _ p: CloudPermissions) -> Bool {
        switch m {
        case .mouseMove, .mouseButton, .mouseWheel, .key, .scroll, .mouseDelta, .keyExtra, .setDisplayPreference:
            return p.control
        case .releaseAll: return true
        case .clipboard: return p.control && p.clipboard.toHostAllowed
        case let .file(f):
            switch f {
            case .offer, .chunk, .end: return p.control && p.files.toHostAllowed
            case .pull, .answer, .ack, .done: return p.files.toViewerAllowed
            case .cancel: return true
            case .caps, .pullResult: return false
            }
        case .audioEnable(let on): return !on || p.audio
        case .hello, .viewSize, .requestKeyframe, .setMode, .ping, .pairConfirm, .latencyEnable, .latencyReport, .selectDisplay:
            return true
        }
    }

    /// Whether the viewer processes `m` from the host.
    public static func viewerAccepts(_ m: HostMessage, _ p: CloudPermissions) -> Bool {
        switch m {
        case .clipboard, .clipboardCaps: return p.clipboard.toViewerAllowed
        case .audioConfig, .audioFrame: return p.audio
        case let .file(f):
            switch f {
            case .offer, .chunk, .end: return p.files.toViewerAllowed
            case .answer, .ack, .done: return p.control && p.files.toHostAllowed
            case .caps, .pullResult: return p.files != .off
            case .cancel: return true
            case .pull: return false
            }
        default: return true
        }
    }

    /// ClientHello caps a viewer may advertise for these permissions (drops what it may not use).
    public static func viewerCaps(_ caps: CodecCaps, _ p: CloudPermissions) -> CodecCaps {
        var c = caps
        func usable(_ d: DataDirection) -> Bool { d.toViewerAllowed || (p.control && d.toHostAllowed) }
        if !usable(p.clipboard) { c.remove(.clipboard) }
        if !usable(p.files) { c.remove(.files) }
        if !p.audio { c.remove(.audioPCM); c.remove(.audioOpus) }
        return c
    }
}

/// How the host answers a `session_offer` (§6.4).
public enum OfferDecision: Equatable, Sendable {
    case accept
    /// Show the approval prompt (Decline default, Accept after 1 s, auto-decline after 50 s).
    case prompt
    /// `reason`: "declined", "busy", "timeout" or "policy".
    case decline(String)

    public static let promptTimeout: TimeInterval = 50
    public static let acceptDelay: TimeInterval = 1

    /// - busy: a viewer session (LAN or managed) is active or another offer is being prompted.
    /// - paused: the host refuses connections (menu bar → Pause).
    public static func decide(_ o: SessionOffer, cloudURL: URL, busy: Bool, paused: Bool, updateRequired: Bool, now: Date = Date()) -> OfferDecision {
        if updateRequired { return .decline("policy") }
        guard CloudID.isValid(o.sessionId), let key = Data(hex: o.viewer.publicKey), key.count == 32, o.viewer.publicKey.count == 64,
              !o.ticket.isEmpty, RelayEndpoint.url(o.relayURL, ticket: o.ticket, sessionId: o.sessionId, cloudURL: cloudURL) != nil else {
            return .decline("policy")
        }
        if let exp = CloudTime.parse(o.expiresAt), exp <= now { return .decline("timeout") }
        if paused { return .decline("declined") }
        switch o.approval {
        case .none: return busy ? .decline("busy") : .accept
        case .required: return .prompt
        }
    }
}

/// The relay socket URL: `relay_url` + `?ticket=` (§6.2, §6.5). The relay must be on the cloud's
/// own host (wss, or ws for a loopback development cloud) and its path must end in the session
/// id: a ticket is never sent anywhere else.
public enum RelayEndpoint {
    public static func url(_ relayURL: String, ticket: String, sessionId: String, cloudURL: URL) -> URL? {
        guard var c = URLComponents(string: relayURL), let scheme = c.scheme?.lowercased(), let host = c.host?.lowercased(),
              let cloudHost = cloudURL.host?.lowercased(), host == cloudHost, c.user == nil, c.password == nil else { return nil }
        let cloudSecure = cloudURL.scheme?.lowercased() == "https"
        switch scheme {
        case "wss": break
        case "ws" where !cloudSecure && ManagedConfig.isLoopback(host): break
        default: return nil
        }
        guard CloudID.isValid(sessionId), c.path.hasSuffix("/" + sessionId), (c.port ?? defaultPort(scheme)) == (cloudURL.port ?? defaultPort(cloudURL.scheme ?? "")) else { return nil }
        var items = (c.queryItems ?? []).filter { $0.name != "ticket" }
        items.append(URLQueryItem(name: "ticket", value: ticket))
        c.queryItems = items
        // `+` is legal in a query but some servers read it as a space: encode it.
        c.percentEncodedQuery = c.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return c.url
    }

    static func defaultPort(_ scheme: String) -> Int {
        switch scheme.lowercased() {
        case "https", "wss": return 443
        default: return 80
        }
    }

    /// `https://cloud/v1/hub` → `wss://cloud/v1/hub`.
    public static func webSocketURL(_ cloudURL: URL, path: String) -> URL? {
        guard var c = URLComponents(url: cloudURL, resolvingAgainstBaseURL: false) else { return nil }
        c.scheme = c.scheme?.lowercased() == "https" ? "wss" : "ws"
        c.path = (c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path) + path
        return c.url
    }
}

/// Exponential backoff with jitter (§6.4: 1 s doubling to 60 s, ±20 %).
public struct CloudBackoff: Sendable {
    public var initial: TimeInterval
    public var max: TimeInterval
    public var jitter: Double
    public private(set) var attempt = 0

    public init(initial: TimeInterval = 1, max: TimeInterval = 60, jitter: Double = 0.2) {
        self.initial = initial; self.max = max; self.jitter = jitter
    }

    /// The next delay; `random` in [0, 1) (injectable for tests).
    public mutating func next(random: Double = Double.random(in: 0..<1)) -> TimeInterval {
        let base = Swift.min(initial * pow(2, Double(Swift.min(attempt, 16))), max)
        attempt += 1
        return base * (1 - jitter + 2 * jitter * random)
    }

    public mutating func reset() { attempt = 0 }
}
