import Foundation

// Glide Cloud wire formats (docs/ENTERPRISE.md §6–7): the device API bodies, the hub's JSON
// frames and the relay's control frames. Field names are the spec's (snake_case) through explicit
// coding keys. Clients ignore unknown fields; an unknown or missing value in a security-relevant
// field decodes to its most restrictive meaning.

// MARK: Permissions (§6.3)

/// Which way clipboard or file data may flow, from the data's point of view.
public enum DataDirection: String, Codable, Equatable, Sendable, CaseIterable {
    case both
    case toHost = "to_host"
    case toViewer = "to_viewer"
    case off

    /// Unknown values mean `off`.
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = DataDirection(rawValue: s) ?? .off
    }

    public var toHostAllowed: Bool { self == .both || self == .toHost }
    public var toViewerAllowed: Bool { self == .both || self == .toViewer }
}

/// `{ "control": true, "clipboard": "both", "files": "both", "audio": true }`. Missing fields are
/// the most restrictive value (view only, off, no audio).
public struct CloudPermissions: Codable, Equatable, Sendable {
    public var control: Bool
    public var clipboard: DataDirection
    public var files: DataDirection
    public var audio: Bool

    public init(control: Bool, clipboard: DataDirection, files: DataDirection, audio: Bool) {
        self.control = control; self.clipboard = clipboard; self.files = files; self.audio = audio
    }

    public static let full = CloudPermissions(control: true, clipboard: .both, files: .both, audio: true)
    public static let none = CloudPermissions(control: false, clipboard: .off, files: .off, audio: false)

    enum CodingKeys: String, CodingKey { case control, clipboard, files, audio }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        control = (try? c.decodeIfPresent(Bool.self, forKey: .control)) ?? false
        clipboard = (try? c.decodeIfPresent(DataDirection.self, forKey: .clipboard)) ?? .off
        files = (try? c.decodeIfPresent(DataDirection.self, forKey: .files)) ?? .off
        audio = (try? c.decodeIfPresent(Bool.self, forKey: .audio)) ?? false
    }

    /// "Full control · clipboard both ways · files to this Mac · audio" for menus and lists.
    public var summary: String {
        func dir(_ d: DataDirection, _ what: String) -> String? {
            switch d {
            case .both: return "\(what) both ways"
            case .toHost: return "\(what) to host"
            case .toViewer: return "\(what) to viewer"
            case .off: return nil
            }
        }
        return ([control ? "Full control" : "View only", dir(clipboard, "clipboard"), dir(files, "files"), audio ? "audio" : nil]
            .compactMap { $0 }).joined(separator: " · ")
    }
}

/// `"none"` | `"required"`; anything else means required.
public enum ApprovalMode: String, Codable, Equatable, Sendable {
    case none, required
    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        self = ApprovalMode(rawValue: s) ?? .required
    }
}

// MARK: Org settings (§7)

public struct OrgSettings: Codable, Equatable, Sendable {
    public var lanMode: Bool
    public var allowLocalPairing: Bool
    public var ownerAccess: Bool
    public var userSessionHours: Int
    public var sessionMaxMinutes: Int
    public var auditFileNames: Bool
    public var auditRetentionDays: Int
    public var minAppVersion: String?

    public init(lanMode: Bool = true, allowLocalPairing: Bool = true, ownerAccess: Bool = true, userSessionHours: Int = 12,
                sessionMaxMinutes: Int = 480, auditFileNames: Bool = true, auditRetentionDays: Int = 365, minAppVersion: String? = nil) {
        self.lanMode = lanMode; self.allowLocalPairing = allowLocalPairing; self.ownerAccess = ownerAccess
        self.userSessionHours = userSessionHours; self.sessionMaxMinutes = sessionMaxMinutes; self.auditFileNames = auditFileNames
        self.auditRetentionDays = auditRetentionDays; self.minAppVersion = minAppVersion
    }

    enum CodingKeys: String, CodingKey {
        case lanMode = "lan_mode", allowLocalPairing = "allow_local_pairing", ownerAccess = "owner_access"
        case userSessionHours = "user_session_hours", sessionMaxMinutes = "session_max_minutes"
        case auditFileNames = "audit_file_names", auditRetentionDays = "audit_retention_days", minAppVersion = "min_app_version"
    }

    /// Missing keys take the §7 defaults; a key of the wrong type throws (the frame is ignored).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OrgSettings()
        lanMode = try c.decodeIfPresent(Bool.self, forKey: .lanMode) ?? d.lanMode
        allowLocalPairing = try c.decodeIfPresent(Bool.self, forKey: .allowLocalPairing) ?? d.allowLocalPairing
        ownerAccess = try c.decodeIfPresent(Bool.self, forKey: .ownerAccess) ?? d.ownerAccess
        userSessionHours = try c.decodeIfPresent(Int.self, forKey: .userSessionHours) ?? d.userSessionHours
        sessionMaxMinutes = try c.decodeIfPresent(Int.self, forKey: .sessionMaxMinutes) ?? d.sessionMaxMinutes
        auditFileNames = try c.decodeIfPresent(Bool.self, forKey: .auditFileNames) ?? d.auditFileNames
        auditRetentionDays = try c.decodeIfPresent(Int.self, forKey: .auditRetentionDays) ?? d.auditRetentionDays
        minAppVersion = try c.decodeIfPresent(String.self, forKey: .minAppVersion)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lanMode, forKey: .lanMode)
        try c.encode(allowLocalPairing, forKey: .allowLocalPairing)
        try c.encode(ownerAccess, forKey: .ownerAccess)
        try c.encode(userSessionHours, forKey: .userSessionHours)
        try c.encode(sessionMaxMinutes, forKey: .sessionMaxMinutes)
        try c.encode(auditFileNames, forKey: .auditFileNames)
        try c.encode(auditRetentionDays, forKey: .auditRetentionDays)
        try c.encode(minAppVersion, forKey: .minAppVersion)  // explicit null, like the spec's example
    }
}

// MARK: Shared objects

public struct OrgRef: Codable, Equatable, Sendable {
    public var id: String
    public var slug: String
    public var name: String
    public init(id: String, slug: String, name: String) { self.id = id; self.slug = slug; self.name = name }
    enum CodingKeys: String, CodingKey { case id, slug, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        slug = try c.decodeIfPresent(String.self, forKey: .slug) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? slug
    }
}

public struct CloudUser: Codable, Equatable, Sendable {
    public var id: String
    public var email: String
    public var name: String
    public var groups: [String]?
    public init(id: String, email: String, name: String, groups: [String]? = nil) {
        self.id = id; self.email = email; self.name = name; self.groups = groups
    }
    enum CodingKeys: String, CodingKey { case id, email, name, groups }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? ""
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? ""
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        groups = try c.decodeIfPresent([String].self, forKey: .groups)
    }

    /// "Ada Lovelace (ada@example.com)", control characters removed.
    public var label: String {
        let n = PairedViewer.displayName(name.isEmpty ? email : name)
        let e = ManagedConfig.clean(email, max: 120)
        return e.isEmpty || n == e ? n : "\(n) (\(e))"
    }
}

public enum DeviceKind: String, Codable, Sendable { case host, viewer }

// MARK: Device API (§6.2)

public struct EnrollRequest: Codable, Equatable, Sendable {
    public var enrollmentToken: String
    public var kind: DeviceKind
    /// 64 hex chars.
    public var publicKey: String
    public var name: String
    public var platform: String
    public var osVersion: String
    public var appVersion: String
    public var tags: [String]?

    public init(enrollmentToken: String, kind: DeviceKind, publicKey: String, name: String, platform: String = "macos",
                osVersion: String, appVersion: String, tags: [String]?) {
        self.enrollmentToken = enrollmentToken; self.kind = kind; self.publicKey = publicKey; self.name = name
        self.platform = platform; self.osVersion = osVersion; self.appVersion = appVersion; self.tags = tags
    }

    enum CodingKeys: String, CodingKey {
        case enrollmentToken = "enrollment_token", kind, publicKey = "public_key", name, platform
        case osVersion = "os_version", appVersion = "app_version", tags
    }
}

public struct EnrollResponse: Codable, Equatable, Sendable {
    public var deviceId: String
    public var deviceToken: String
    public var org: OrgRef
    public var settings: OrgSettings
    enum CodingKeys: String, CodingKey { case deviceId = "device_id", deviceToken = "device_token", org, settings }
}

/// `GET /v1/device`.
public struct DeviceInfo: Codable, Equatable, Sendable {
    public var deviceId: String
    public var kind: DeviceKind?
    public var name: String
    public var tags: [String]
    public var org: OrgRef
    public var settings: OrgSettings
    enum CodingKeys: String, CodingKey { case deviceId = "device_id", kind, name, tags, org, settings }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try c.decode(String.self, forKey: .deviceId)
        kind = try? c.decodeIfPresent(DeviceKind.self, forKey: .kind)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        org = try c.decode(OrgRef.self, forKey: .org)
        settings = try c.decodeIfPresent(OrgSettings.self, forKey: .settings) ?? OrgSettings()
    }
}

public struct HeartbeatRequest: Codable, Equatable, Sendable {
    public var appVersion: String
    public var osVersion: String
    public var name: String?
    public init(appVersion: String, osVersion: String, name: String? = nil) { self.appVersion = appVersion; self.osVersion = osVersion; self.name = name }
    enum CodingKeys: String, CodingKey { case appVersion = "app_version", osVersion = "os_version", name }
}

/// One client audit event (§9): `{type, ts, session_id?, detail}`.
public struct AuditEvent: Codable, Equatable, Sendable {
    public var type: String
    public var ts: String
    public var sessionId: String?
    public var detail: JSONValue
    public init(type: String, ts: String, sessionId: String?, detail: JSONValue) {
        self.type = type; self.ts = ts; self.sessionId = sessionId; self.detail = detail
    }
    enum CodingKeys: String, CodingKey { case type, ts, sessionId = "session_id", detail }

    /// The only types a client may report (§9).
    public static let clientTypes: Set<String> = ["session.file_sent", "session.file_received", "session.clipboard", "session.local_end", "client.error"]
}

public struct AuditBatch: Codable, Equatable, Sendable {
    public var events: [AuditEvent]
    public init(events: [AuditEvent]) { self.events = events }
}

public struct DeviceAuthStart: Codable, Equatable, Sendable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURI: String
    public var verificationURIComplete: String
    public var interval: Int
    public var expiresIn: Int
    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code", userCode = "user_code", verificationURI = "verification_uri"
        case verificationURIComplete = "verification_uri_complete", interval, expiresIn = "expires_in"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceCode = try c.decode(String.self, forKey: .deviceCode)
        userCode = try c.decode(String.self, forKey: .userCode)
        verificationURI = try c.decode(String.self, forKey: .verificationURI)
        verificationURIComplete = try c.decodeIfPresent(String.self, forKey: .verificationURIComplete) ?? verificationURI
        interval = try c.decodeIfPresent(Int.self, forKey: .interval) ?? 5
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 600
    }
}

public struct DeviceTokenRequest: Codable, Equatable, Sendable {
    public var deviceCode: String
    public init(deviceCode: String) { self.deviceCode = deviceCode }
    enum CodingKeys: String, CodingKey { case deviceCode = "device_code" }
}

public struct DeviceTokenResponse: Codable, Equatable, Sendable {
    public var userToken: String
    public var expiresIn: Int
    public var user: CloudUser
    enum CodingKeys: String, CodingKey { case userToken = "user_token", expiresIn = "expires_in", user }
}

public struct MeResponse: Codable, Equatable, Sendable {
    public var user: CloudUser
    public var org: OrgRef
}

/// One entry of `GET /v1/hosts`.
public struct CloudHost: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var platform: String
    public var tags: [String]
    public var online: Bool
    public var lastSeen: String?
    public var permissions: CloudPermissions
    public var approval: ApprovalMode
    enum CodingKeys: String, CodingKey { case id, name, platform, tags, online, lastSeen = "last_seen", permissions, approval }
    public init(id: String, name: String, platform: String, tags: [String], online: Bool, lastSeen: String?, permissions: CloudPermissions, approval: ApprovalMode) {
        self.id = id; self.name = name; self.platform = platform; self.tags = tags; self.online = online
        self.lastSeen = lastSeen; self.permissions = permissions; self.approval = approval
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? id
        platform = try c.decodeIfPresent(String.self, forKey: .platform) ?? ""
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        online = try c.decodeIfPresent(Bool.self, forKey: .online) ?? false
        lastSeen = try c.decodeIfPresent(String.self, forKey: .lastSeen)
        permissions = try c.decodeIfPresent(CloudPermissions.self, forKey: .permissions) ?? .none
        approval = try c.decodeIfPresent(ApprovalMode.self, forKey: .approval) ?? .required
    }
}

public struct HostsResponse: Codable, Equatable, Sendable {
    public var hosts: [CloudHost]
}

public struct SessionRequest: Codable, Equatable, Sendable {
    public var hostId: String
    public var viewOnly: Bool?
    public init(hostId: String, viewOnly: Bool? = nil) { self.hostId = hostId; self.viewOnly = viewOnly }
    enum CodingKeys: String, CodingKey { case hostId = "host_id", viewOnly = "view_only" }
}

public struct SessionHostInfo: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    /// 64 hex chars: the key the viewer pins for `relay:<session_id>`.
    public var publicKey: String
    enum CodingKeys: String, CodingKey { case id, name, publicKey = "public_key" }
}

/// `201` of `POST /v1/sessions`.
public struct SessionResponse: Codable, Equatable, Sendable {
    public var sessionId: String
    public var relayURL: String
    public var ticket: String
    public var host: SessionHostInfo
    public var permissions: CloudPermissions
    public var approvalRequired: Bool
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", relayURL = "relay_url", ticket, host, permissions
        case approvalRequired = "approval_required", expiresAt = "expires_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        relayURL = try c.decode(String.self, forKey: .relayURL)
        ticket = try c.decode(String.self, forKey: .ticket)
        host = try c.decode(SessionHostInfo.self, forKey: .host)
        permissions = try c.decodeIfPresent(CloudPermissions.self, forKey: .permissions) ?? .none
        approvalRequired = try c.decodeIfPresent(Bool.self, forKey: .approvalRequired) ?? false
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}

/// `{ "error": { "code": "host_offline", "message": "The host is not connected." } }`
public struct CloudErrorEnvelope: Codable, Equatable, Sendable {
    public struct Body: Codable, Equatable, Sendable {
        public var code: String
        public var message: String
        public init(code: String, message: String) { self.code = code; self.message = message }
        enum CodingKeys: String, CodingKey { case code, message }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            code = try c.decodeIfPresent(String.self, forKey: .code) ?? "unknown"
            message = try c.decodeIfPresent(String.self, forKey: .message) ?? ""
        }
    }
    public var error: Body
}

// MARK: Hub (§6.4)

public struct OfferViewer: Codable, Equatable, Sendable {
    public var deviceId: String
    public var name: String
    public var publicKey: String
    enum CodingKeys: String, CodingKey { case deviceId = "device_id", name, publicKey = "public_key" }
}

public struct SessionOffer: Codable, Equatable, Sendable {
    public var sessionId: String
    public var viewer: OfferViewer
    public var user: CloudUser
    public var permissions: CloudPermissions
    public var approval: ApprovalMode
    public var relayURL: String
    public var ticket: String
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id", viewer, user, permissions, approval, relayURL = "relay_url", ticket, expiresAt = "expires_at"
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        viewer = try c.decode(OfferViewer.self, forKey: .viewer)
        user = try c.decode(CloudUser.self, forKey: .user)
        permissions = try c.decodeIfPresent(CloudPermissions.self, forKey: .permissions) ?? .none
        approval = try c.decodeIfPresent(ApprovalMode.self, forKey: .approval) ?? .required
        relayURL = try c.decode(String.self, forKey: .relayURL)
        ticket = try c.decode(String.self, forKey: .ticket)
        expiresAt = try c.decodeIfPresent(String.self, forKey: .expiresAt)
    }
}

/// Server → device hub frames.
public enum HubServerFrame: Equatable, Sendable {
    case hello(deviceId: String, settings: OrgSettings, serverTime: String?)
    case sessionOffer(SessionOffer)
    case sessionCancel(sessionId: String, reason: String)
    case settings(OrgSettings)
    case revoked(reason: String)
    case ping(t: JSONValue?)
    /// A type this client doesn't know (ignored).
    case unknown(String)

    private struct Head: Decodable { let type: String }
    private struct Hello: Decodable {
        let device_id: String
        let settings: OrgSettings
        let server_time: String?
    }
    private struct Cancel: Decodable { let session_id: String; let reason: String? }
    private struct Settings: Decodable { let settings: OrgSettings }
    private struct Revoked: Decodable { let reason: String? }
    private struct Ping: Decodable { let t: JSONValue? }

    public static func decode(_ text: String) throws -> HubServerFrame {
        let d = Data(text.utf8)
        let dec = JSONDecoder()
        let type = try dec.decode(Head.self, from: d).type
        switch type {
        case "hello":
            let h = try dec.decode(Hello.self, from: d)
            return .hello(deviceId: h.device_id, settings: h.settings, serverTime: h.server_time)
        case "session_offer": return .sessionOffer(try dec.decode(SessionOffer.self, from: d))
        case "session_cancel":
            let c = try dec.decode(Cancel.self, from: d)
            return .sessionCancel(sessionId: c.session_id, reason: c.reason ?? "")
        case "settings": return .settings(try dec.decode(Settings.self, from: d).settings)
        case "revoked": return .revoked(reason: (try? dec.decode(Revoked.self, from: d).reason) ?? "")
        case "ping": return .ping(t: (try? dec.decode(Ping.self, from: d))?.t)
        default: return .unknown(type)
        }
    }
}

/// Device → server hub frames.
public enum HubClientFrame: Equatable, Sendable {
    /// `reason`: "declined", "busy", "timeout" or "policy".
    case sessionAnswer(sessionId: String, accept: Bool, reason: String?)
    /// `state`: "connected" or "ended".
    case sessionState(sessionId: String, state: String, detail: String?)
    case pong(t: JSONValue?)

    public var json: String {
        var o: [String: JSONValue] = [:]
        switch self {
        case let .sessionAnswer(id, accept, reason):
            o = ["type": .string("session_answer"), "session_id": .string(id), "accept": .bool(accept)]
            if let reason { o["reason"] = .string(reason) }
        case let .sessionState(id, state, detail):
            o = ["type": .string("session_state"), "session_id": .string(id), "state": .string(state)]
            if let detail { o["detail"] = .string(detail) }
        case let .pong(t):
            o = ["type": .string("pong"), "t": t ?? .null]
        }
        return JSONValue.object(o).description
    }
}

// MARK: Relay (§6.5)

/// Relay → client text frames.
public enum RelayControl: Equatable, Sendable {
    case waiting, peerJoined, peerLeft
    case unknown(String)

    public static func decode(_ text: String) -> RelayControl? {
        struct Head: Decodable { let type: String }
        guard let h = try? JSONDecoder().decode(Head.self, from: Data(text.utf8)) else { return nil }
        switch h.type {
        case "waiting": return .waiting
        case "peer_joined": return .peerJoined
        case "peer_left": return .peerLeft
        default: return .unknown(h.type)
        }
    }
}

/// WebSocket close codes the relay uses.
public enum RelayCloseCode {
    public static let normal = 1000
    public static let ticketInvalid = 4001
    public static let protocolViolation = 4002
    public static let endedByAdmin = 4003
    public static let peerDidNotJoin = 4004
    public static let timeLimit = 4005

    public static func text(_ code: Int?) -> String {
        switch code {
        case normal: return "the session ended"
        case ticketInvalid: return "the relay refused the session ticket (expired?)"
        case protocolViolation: return "relay protocol violation"
        case endedByAdmin: return "ended by an administrator"
        case peerDidNotJoin: return "the other side did not join"
        case timeLimit: return "the session time limit was reached"
        case let c?: return "the relay closed the connection (\(c))"
        case nil: return "the relay connection was lost"
        }
    }
}

/// Opaque ID check (`ses_`, `dev_`… + base32): only these characters ever go into a URL path.
public enum CloudID {
    public static func isValid(_ s: String, prefix: String? = nil) -> Bool {
        guard !s.isEmpty, s.count <= 64 else { return false }
        if let prefix, !s.hasPrefix(prefix) { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "_" || $0 == "-" }
    }
}
