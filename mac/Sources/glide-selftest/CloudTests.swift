import Foundation
import GlideCore
import Network

// Glide Cloud client logic (docs/ENTERPRISE.md): managed config, wire formats, policy and
// permissions, backoff, grants, the enrollment file, the relay bridge over a fake socket, the hub
// client, audit batching and the enroll → hub → revoke flow with fake transports.

/// Polls `cond` for up to `timeout` seconds.
func waitUntil(_ timeout: TimeInterval = 3, _ cond: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end { if cond() { return true }; usleep(5_000) }
    return cond()
}

/// In-memory WebSocket: the test pushes what the server "sends" and reads what the client sent.
final class FakeSocket: CloudWebSocket, @unchecked Sendable {
    let lock = NSLock()
    private var inbox: [Result<WSMessage, Error>] = []
    private var waiting: ((Result<WSMessage, Error>) -> Void)?
    private(set) var sentMessages: [WSMessage] = []
    private(set) var closedWith: Int?
    private(set) var started = false
    var upgradeStatus: Int?
    var closeCode: Int?
    let request: URLRequest?

    init(request: URLRequest? = nil) { self.request = request }

    func start() { lock.withLock { started = true } }

    func send(_ m: WSMessage, completion: @escaping (Error?) -> Void) {
        let closed = lock.withLock { () -> Bool in
            if closedWith == nil { sentMessages.append(m) }
            return closedWith != nil
        }
        DispatchQueue.global().async { completion(closed ? CloudError.transport("closed") : nil) }
    }

    func receive(_ completion: @escaping (Result<WSMessage, Error>) -> Void) {
        lock.lock()
        if !inbox.isEmpty {
            let r = inbox.removeFirst()
            lock.unlock()
            DispatchQueue.global().async { completion(r) }
        } else if closedWith != nil {
            lock.unlock()
            DispatchQueue.global().async { completion(.failure(CloudError.transport("closed"))) }
        } else {
            waiting = completion
            lock.unlock()
        }
    }

    func push(_ r: Result<WSMessage, Error>) {
        lock.lock()
        if let w = waiting {
            waiting = nil
            lock.unlock()
            DispatchQueue.global().async { w(r) }
        } else {
            inbox.append(r)
            lock.unlock()
        }
    }

    func pushText(_ s: String) { push(.success(.text(s))) }

    /// The server closes (or the upgrade fails with `status`).
    func fail(status: Int? = nil, code: Int? = nil) {
        lock.withLock { upgradeStatus = status; closeCode = code }
        push(.failure(CloudError.transport("closed by server")))
    }

    func close(code: Int) {
        lock.lock()
        if closedWith == nil { closedWith = code }
        let w = waiting
        waiting = nil
        lock.unlock()
        if let w { DispatchQueue.global().async { w(.failure(CloudError.transport("closed"))) } }
    }

    var sent: [WSMessage] { lock.withLock { sentMessages } }
    var sentTexts: [String] { sent.compactMap { if case let .text(t) = $0 { return t } else { return nil } } }
    var sentBinary: Data { sent.reduce(into: Data()) { if case let .binary(d) = $1 { $0.append(d) } } }
    var closed: Int? { lock.withLock { closedWith } }
}

/// HTTP transport answering from a handler; records requests.
final class FakeTransport: CloudHTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var handler: (URLRequest) -> (Int, String)

    init(_ handler: @escaping (URLRequest) -> (Int, String)) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (status, body) = lock.withLock { () -> (Int, String) in
            requests.append(request)
            return handler(request)
        }
        let r = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), r)
    }

    var all: [URLRequest] { lock.withLock { requests } }
}

/// Runs `body` to completion on a detached task and waits for it.
func blocking<T>(_ body: @escaping () async throws -> T) -> Result<T, Error> {
    let sem = DispatchSemaphore(value: 0)
    var out: Result<T, Error>!
    Task.detached {
        do { out = .success(try await body()) } catch { out = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return out
}

func cloudTests() throws {
    print("glide cloud:")
    try managedConfigTests()
    try cloudWireTests()
    cloudPolicyTests()
    permissionTests()
    backoffTests()
    grantTests()
    try enrollmentStoreTests()
    try cloudClientTests()
    hubClientTests()
    auditTests()
    bridgeTests()
    try cloudDeviceTests()
}

// MARK: Managed config (§11.1)

func managedConfigTests() throws {
    let k = ManagedConfig.keys
    let full = ManagedConfig.read(DictionarySource([
        k.cloudURL: "https://glide.example.com/", k.enrollmentToken: " enr_abc123 ", k.deviceName: "Front Desk\u{7}",
        k.tags: ["staff-macs", "Staff-Macs", "lobby", ""], k.disableLANMode: true,
    ]))
    check(full.cloudURL?.absoluteString == "https://glide.example.com" && full.enrollmentToken == "enr_abc123" && full.isCloudConfigured,
          "config: CloudURL (trailing slash dropped) and EnrollmentToken (trimmed)")
    check(full.deviceName == "Front Desk" && full.tags == ["staff-macs", "lobby"] && full.disableLANMode,
          "config: DeviceName cleaned, Tags deduplicated (case-insensitive), DisableLANMode")
    let none = ManagedConfig.read(DictionarySource([:]))
    check(none == ManagedConfig() && !none.isCloudConfigured && !none.disableLANMode, "config: empty domain = unmanaged, LAN allowed")
    let http = ManagedConfig.read(DictionarySource([k.cloudURL: "http://glide.example.com", k.enrollmentToken: "t"]))
    check(http.cloudURL == nil && !http.isCloudConfigured && !http.problems.isEmpty, "config: plain http to a network host is refused")
    let loop = ManagedConfig.read(DictionarySource([k.cloudURL: "http://127.0.0.1:8787", k.enrollmentToken: "t"]))
    check(loop.cloudURL?.absoluteString == "http://127.0.0.1:8787", "config: plain http allowed only for a loopback development cloud")
    for bad in ["https://user:pw@glide.example.com", "https://glide.example.com/?x=1", "ftp://glide.example.com", "glide.example.com", "https://"] {
        check(ManagedConfig.read(DictionarySource([k.cloudURL: bad])).cloudURL == nil, "config: CloudURL \(bad) refused")
    }
    let badTok = ManagedConfig.read(DictionarySource([k.cloudURL: "https://g.example.com", k.enrollmentToken: "two words"]))
    check(badTok.enrollmentToken == nil && !badTok.isCloudConfigured, "config: a token with spaces is refused")
    check(ManagedConfig.read(DictionarySource([k.disableLANMode: NSNumber(value: 1)])).disableLANMode
          && ManagedConfig.read(DictionarySource([k.disableLANMode: "YES"])).disableLANMode
          && !ManagedConfig.read(DictionarySource([k.disableLANMode: 0])).disableLANMode, "config: DisableLANMode as bool, number or string")
    check(ManagedConfig.read(DictionarySource([k.tags: "single"])).tags == ["single"], "config: a single string in Tags is one tag")
    check(ManagedConfig.read(DictionarySource([k.cloudURL: 42])).problems.count == 1, "config: wrong type reported, not fatal")
    // The real domain reads without crashing (and is normally empty on a developer Mac).
    _ = ManagedConfig.read(PreferencesSource(domain: "dev.brandino.glide.selftest.\(getpid())"))
    check(PreferencesSource.domain == "dev.brandino.glide", "config: preference domain dev.brandino.glide")
}

// MARK: Wire formats (§6–7), examples copied from ENTERPRISE.md

func cloudWireTests() throws {
    let dec = JSONDecoder()
    func roundTrip<T: Codable & Equatable>(_ v: T) -> Bool {
        guard let d = try? JSONEncoder.cloud.encode(v), let back = try? dec.decode(T.self, from: d) else { return false }
        return back == v
    }
    // §6: error envelope, verbatim.
    let errJSON = #"{ "error": { "code": "host_offline", "message": "The host is not connected." } }"#
    let env = try dec.decode(CloudErrorEnvelope.self, from: Data(errJSON.utf8))
    check(env.error.code == "host_offline" && env.error.message == "The host is not connected." && roundTrip(env), "wire: error envelope (§6 example)")
    let ce = CloudClient.error(status: 409, body: Data(errJSON.utf8))
    check(ce == .http(status: 409, code: "host_offline", message: "The host is not connected.") && ce.sessionText.contains("not connected"),
          "wire: error envelope -> CloudError with code")
    check(CloudClient.error(status: 502, body: Data("<html>".utf8)).code == "http_502", "wire: non-JSON error body -> http_<status>")

    // §6.3 permissions, verbatim.
    let permJSON = #"{ "control": true, "clipboard": "both", "files": "both", "audio": true }"#
    let perm = try dec.decode(CloudPermissions.self, from: Data(permJSON.utf8))
    check(perm == .full && roundTrip(perm), "wire: permissions (§6.3 example) = full")
    // §8 policy example's permissions object.
    let polJSON = #"""
    {
      "id": "pol_…",
      "name": "IT support",
      "enabled": true,
      "users": { "groups": ["it-helpdesk"], "emails": [] },
      "hosts": { "tags": ["staff-macs"], "device_ids": [] },
      "permissions": { "control": true, "clipboard": "both", "files": "to_host", "audio": false },
      "approval": "required",
      "session_max_minutes": 60
    }
    """#
    struct PolicyPerms: Decodable { let permissions: CloudPermissions; let approval: ApprovalMode }
    let pol = try dec.decode(PolicyPerms.self, from: Data(polJSON.utf8))
    check(pol.permissions == CloudPermissions(control: true, clipboard: .both, files: .toHost, audio: false) && pol.approval == .required,
          "wire: §8 policy example permissions and approval")
    let weird = try dec.decode(CloudPermissions.self, from: Data(#"{"clipboard":"sideways","files":"to_viewer","extra":1}"#.utf8))
    check(weird == CloudPermissions(control: false, clipboard: .off, files: .toViewer, audio: false),
          "wire: unknown direction -> off, missing control/audio -> false, unknown fields ignored")
    check(try dec.decode(ApprovalMode.self, from: Data(#""maybe""#.utf8)) == .required, "wire: unknown approval -> required")

    // §7 settings, verbatim.
    let setJSON = #"""
    {
      "lan_mode": true,
      "allow_local_pairing": true,
      "owner_access": true,
      "user_session_hours": 12,
      "session_max_minutes": 480,
      "audit_file_names": true,
      "audit_retention_days": 365,
      "min_app_version": null
    }
    """#
    let st = try dec.decode(OrgSettings.self, from: Data(setJSON.utf8))
    check(st == OrgSettings() && roundTrip(st), "wire: org settings (§7 example) = defaults")
    let stEnc = String(decoding: try JSONEncoder.cloud.encode(st), as: UTF8.self)
    check(stEnc.contains(#""min_app_version":null"#) && stEnc.contains(#""lan_mode":true"#), "wire: settings encode with snake_case and explicit null")
    let partial = try dec.decode(OrgSettings.self, from: Data(#"{"lan_mode":false,"min_app_version":"0.5.0","new_field":[1]}"#.utf8))
    check(!partial.lanMode && partial.allowLocalPairing && partial.minAppVersion == "0.5.0", "wire: partial settings take §7 defaults")
    check((try? dec.decode(OrgSettings.self, from: Data(#"{"lan_mode":"no"}"#.utf8))) == nil, "wire: a settings value of the wrong type is rejected")

    // §6.2 bodies (field names from the table).
    let enroll = EnrollRequest(enrollmentToken: "enr_tok", kind: .host, publicKey: String(repeating: "ab", count: 32), name: "Mac",
                               osVersion: "15.1.0", appVersion: "0.3.1", tags: ["lobby"])
    let enrollEnc = String(decoding: try JSONEncoder.cloud.encode(enroll), as: UTF8.self)
    check(enrollEnc == #"{"app_version":"0.3.1","enrollment_token":"enr_tok","kind":"host","name":"Mac","os_version":"15.1.0","platform":"macos","public_key":"\#(String(repeating: "ab", count: 32))","tags":["lobby"]}"#,
          "wire: POST /v1/enroll body")
    let enrollResp = try dec.decode(EnrollResponse.self, from: Data(#"{"device_id":"dev_01","device_token":"gd_\#(String(repeating: "A", count: 43))","org":{"id":"org_1","slug":"example","name":"Example Corp"},"settings":\#(setJSON)}"#.utf8))
    check(enrollResp.deviceId == "dev_01" && enrollResp.org.name == "Example Corp" && enrollResp.deviceToken.hasPrefix("gd_") && roundTrip(enrollResp),
          "wire: enroll 201 response")
    let dev = try dec.decode(DeviceInfo.self, from: Data(#"{"device_id":"dev_01","kind":"viewer","name":"MacBook","tags":["a"],"org":{"id":"org_1","slug":"ex","name":"Ex"},"settings":{"lan_mode":false}}"#.utf8))
    check(dev.kind == .viewer && dev.tags == ["a"] && !dev.settings.lanMode, "wire: GET /v1/device")
    check(String(decoding: try JSONEncoder.cloud.encode(HeartbeatRequest(appVersion: "0.3.1", osVersion: "15.1.0")), as: UTF8.self)
          == #"{"app_version":"0.3.1","os_version":"15.1.0"}"#, "wire: heartbeat body")
    let audit = AuditBatch(events: [AuditEvent(type: "session.clipboard", ts: "2026-11-25T10:00:00Z", sessionId: "ses_1",
                                               detail: .object(["direction": .string("to_host"), "kind": .string("text"), "bytes": .int(12)]))])
    check(String(decoding: try JSONEncoder.cloud.encode(audit), as: UTF8.self)
          == #"{"events":[{"detail":{"bytes":12,"direction":"to_host","kind":"text"},"session_id":"ses_1","ts":"2026-11-25T10:00:00Z","type":"session.clipboard"}]}"#,
          "wire: POST /v1/audit body")
    let start = try dec.decode(DeviceAuthStart.self, from: Data(#"{"device_code":"dc","user_code":"WDJB-MJHT","verification_uri":"https://g.example.com/auth/device","verification_uri_complete":"https://g.example.com/auth/device?user_code=WDJB-MJHT","interval":5,"expires_in":600}"#.utf8))
    check(start.userCode == "WDJB-MJHT" && start.interval == 5 && start.verificationURIComplete.hasSuffix("WDJB-MJHT") && roundTrip(start), "wire: device authorization start")
    check(String(decoding: try JSONEncoder.cloud.encode(DeviceTokenRequest(deviceCode: "dc")), as: UTF8.self) == #"{"device_code":"dc"}"#, "wire: device token request")
    let tok = try dec.decode(DeviceTokenResponse.self, from: Data(#"{"user_token":"gu_x","expires_in":43200,"user":{"id":"usr_1","email":"ada@example.com","name":"Ada"}}"#.utf8))
    check(tok.userToken == "gu_x" && tok.user.label == "Ada (ada@example.com)" && roundTrip(tok), "wire: device token 200")
    let me = try dec.decode(MeResponse.self, from: Data(#"{"user":{"id":"usr_1","email":"a@x.com","name":"A","groups":["g"]},"org":{"id":"org_1","slug":"x","name":"X"}}"#.utf8))
    check(me.user.groups == ["g"] && me.org.slug == "x", "wire: GET /v1/me")
    let hosts = try dec.decode(HostsResponse.self, from: Data(#"{"hosts":[{"id":"dev_h1","name":"Front Desk","platform":"macos","tags":["lobby"],"online":true,"last_seen":"2026-11-25T09:59:00Z","permissions":\#(permJSON),"approval":"none"},{"id":"dev_h2","name":"Lab","platform":"windows","tags":[],"online":false,"last_seen":null,"permissions":{"control":false,"clipboard":"off","files":"off","audio":false},"approval":"required"}]}"#.utf8))
    check(hosts.hosts.count == 2 && hosts.hosts[0].online && hosts.hosts[0].approval == .none && hosts.hosts[1].permissions == .none && roundTrip(hosts),
          "wire: GET /v1/hosts")
    check(try String(decoding: try JSONEncoder.cloud.encode(SessionRequest(hostId: "dev_h1")), as: UTF8.self) == #"{"host_id":"dev_h1"}"#
          && String(decoding: try JSONEncoder.cloud.encode(SessionRequest(hostId: "dev_h1", viewOnly: true)), as: UTF8.self) == #"{"host_id":"dev_h1","view_only":true}"#,
          "wire: POST /v1/sessions body")
    let key = String(repeating: "cd", count: 32)
    let sess = try dec.decode(SessionResponse.self, from: Data(#"{"session_id":"ses_01","relay_url":"wss://g.example.com/v1/relay/ses_01","ticket":"eyJ.sig","host":{"id":"dev_h1","name":"Front Desk","public_key":"\#(key)"},"permissions":\#(permJSON),"approval_required":true,"expires_at":"2026-11-25T10:02:00Z"}"#.utf8))
    check(sess.sessionId == "ses_01" && sess.host.publicKey == key && sess.approvalRequired && roundTrip(sess), "wire: POST /v1/sessions 201")
    check(RelayPin(sess)?.target == "relay:ses_01" && RelayPin(sess)?.hostKey == Data(hex: key), "wire: viewer pins the cloud's host key for relay:<session_id>")

    // §6.4 hub frames.
    let offerJSON = #"{"type":"session_offer","session_id":"ses_01","viewer":{"device_id":"dev_v1","name":"Ada's MacBook","public_key":"\#(key)"},"user":{"id":"usr_1","email":"ada@example.com","name":"Ada"},"permissions":\#(permJSON),"approval":"required","relay_url":"wss://g.example.com/v1/relay/ses_01","ticket":"t.s","expires_at":"2026-11-25T10:02:00Z"}"#
    guard case let .sessionOffer(o) = try HubServerFrame.decode(offerJSON) else { check(false, "hub: session_offer"); return }
    check(o.sessionId == "ses_01" && o.viewer.publicKey == key && o.user.email == "ada@example.com" && o.approval == .required && o.permissions == .full,
          "hub: session_offer decodes")
    check(try HubServerFrame.decode(#"{"type":"hello","device_id":"dev_1","settings":\#(setJSON),"server_time":"2026-11-25T10:00:00Z"}"#)
          == .hello(deviceId: "dev_1", settings: OrgSettings(), serverTime: "2026-11-25T10:00:00Z"), "hub: hello")
    check(try HubServerFrame.decode(#"{"type":"session_cancel","session_id":"ses_01","reason":"timeout"}"#) == .sessionCancel(sessionId: "ses_01", reason: "timeout"), "hub: session_cancel")
    check(try HubServerFrame.decode(#"{"type":"settings","settings":{"lan_mode":false}}"#) == .settings(OrgSettings(lanMode: false)), "hub: settings")
    check(try HubServerFrame.decode(#"{"type":"revoked","reason":"device revoked"}"#) == .revoked(reason: "device revoked"), "hub: revoked")
    check(try HubServerFrame.decode(#"{"type":"ping","t":1732550400123}"#) == .ping(t: .number(1732550400123)), "hub: ping")
    check(try HubServerFrame.decode(#"{"type":"future_thing","x":1}"#) == .unknown("future_thing"), "hub: unknown frame type tolerated")
    check(HubClientFrame.sessionAnswer(sessionId: "ses_01", accept: true, reason: nil).json == #"{"accept":true,"session_id":"ses_01","type":"session_answer"}"#
          && HubClientFrame.sessionAnswer(sessionId: "ses_01", accept: false, reason: "declined").json == #"{"accept":false,"reason":"declined","session_id":"ses_01","type":"session_answer"}"#,
          "hub: session_answer JSON")
    check(HubClientFrame.sessionState(sessionId: "ses_01", state: "connected", detail: nil).json == #"{"session_id":"ses_01","state":"connected","type":"session_state"}"#,
          "hub: session_state JSON")
    check(HubClientFrame.pong(t: .number(1732550400123)).json == #"{"t":1732550400123,"type":"pong"}"#
          && HubClientFrame.pong(t: .string("abc")).json == #"{"t":"abc","type":"pong"}"#, "hub: pong echoes t unchanged")

    // §6.5 relay control frames, verbatim.
    check(RelayControl.decode(#"{"type":"waiting"}"#) == .waiting && RelayControl.decode(#"{"type":"peer_joined"}"#) == .peerJoined
          && RelayControl.decode(#"{"type":"peer_left"}"#) == .peerLeft && RelayControl.decode("nope") == nil, "relay: control frames")
    check(RelayCloseCode.text(4003).contains("administrator") && RelayCloseCode.text(4005).contains("time limit"), "relay: close code texts")
    check(CloudID.isValid("ses_01HZX3", prefix: "ses_") && !CloudID.isValid("ses_../../x") && !CloudID.isValid("dev_1", prefix: "ses_")
          && !CloudID.isValid("ses_é"), "wire: IDs checked before use in a path")
}

// MARK: Policy (§7) and offers (§6.4)

func cloudPolicyTests() {
    let on = ManagedPolicy(settings: OrgSettings(), disableLANMode: false, appVersion: "0.3.1")
    check(on.lanAllowed && on.localPairingAllowed && !on.updateRequired, "policy: defaults allow LAN and pairing")
    let noLAN = ManagedPolicy(settings: OrgSettings(lanMode: false), disableLANMode: false, appVersion: "0.3.1")
    check(!noLAN.lanAllowed && !noLAN.localPairingAllowed, "policy: lan_mode false stops LAN (and so pairing)")
    let noPair = ManagedPolicy(settings: OrgSettings(allowLocalPairing: false), disableLANMode: false, appVersion: "0.3.1")
    check(noPair.lanAllowed && !noPair.localPairingAllowed, "policy: allow_local_pairing false blocks only the pairing window")
    check(!ManagedPolicy(settings: OrgSettings(), disableLANMode: true, appVersion: "0.3.1").lanAllowed
          && !ManagedPolicy(settings: nil, disableLANMode: true, appVersion: "0.3.1").lanAllowed,
          "policy: local DisableLANMode is stricter than the org, also unenrolled")
    check(ManagedPolicy(settings: nil, disableLANMode: false, appVersion: "0.3.1").lanAllowed, "policy: unmanaged = LAN as before")
    check(ManagedPolicy(settings: OrgSettings(minAppVersion: "0.4.0"), disableLANMode: false, appVersion: "0.3.1").updateRequired
          && !ManagedPolicy(settings: OrgSettings(minAppVersion: "0.3.1"), disableLANMode: false, appVersion: "0.3.1").updateRequired
          && !ManagedPolicy(settings: OrgSettings(minAppVersion: "0.3"), disableLANMode: false, appVersion: "0.3.1").updateRequired,
          "policy: min_app_version")
    check(AppVersion.compare("0.10.0", "0.9.9") == 1 && AppVersion.compare("1.0", "1.0.0") == 0 && AppVersion.compare("v0.3.1-beta", "0.3.2") == -1,
          "policy: version comparison is numeric")
    check(ManagedPolicy.lanOffReason(settings: OrgSettings(lanMode: false), disableLANMode: false, orgName: "Example") == "turned off by Example",
          "policy: LAN-off reason names the org")

    // LAN mode enforced at admission (listener accept and dial completion), not only at teardown.
    check(!LANGate.admits(relaySessionId: nil, lanAllowed: false) && LANGate.admits(relaySessionId: nil, lanAllowed: true)
          && LANGate.admits(relaySessionId: "ses_1", lanAllowed: false), "LAN gate: LAN connections refused while LAN mode is off; relayed ones admitted")
    check(!LANGate.adoptsDialed(generation: 3, current: 3, lanAllowed: false) && !LANGate.adoptsDialed(generation: 2, current: 3, lanAllowed: true)
          && LANGate.adoptsDialed(generation: 3, current: 3, lanAllowed: true), "LAN gate: an in-flight dial is dropped after LAN-off or a target change")

    let cloud = URL(string: "https://g.example.com")!
    let key = String(repeating: "ab", count: 32)
    func offer(approval: ApprovalMode = .none, relay: String = "wss://g.example.com/v1/relay/ses_1", key k: String = key, expires: String? = nil) -> SessionOffer {
        let j = #"{"session_id":"ses_1","viewer":{"device_id":"dev_v","name":"V","public_key":"\#(k)"},"user":{"id":"u","email":"e@x.com","name":"E"},"permissions":{"control":true},"approval":"\#(approval.rawValue)","relay_url":"\#(relay)","ticket":"t"\#(expires.map { #","expires_at":"\#($0)""# } ?? "")}"#
        return try! JSONDecoder().decode(SessionOffer.self, from: Data(j.utf8))
    }
    check(OfferDecision.decide(offer(), cloudURL: cloud, busy: false, paused: false, updateRequired: false) == .accept, "offer: approval none, idle -> accept at once")
    check(OfferDecision.decide(offer(), cloudURL: cloud, busy: true, paused: false, updateRequired: false) == .decline("busy"), "offer: approval none, busy -> busy")
    check(OfferDecision.decide(offer(approval: .required), cloudURL: cloud, busy: true, paused: false, updateRequired: false) == .prompt, "offer: approval required -> prompt (even when busy)")
    check(OfferDecision.decide(offer(), cloudURL: cloud, busy: false, paused: true, updateRequired: false) == .decline("declined"), "offer: paused host declines")
    check(OfferDecision.decide(offer(), cloudURL: cloud, busy: false, paused: false, updateRequired: true) == .decline("policy"), "offer: update required -> policy")
    check(OfferDecision.decide(offer(relay: "wss://evil.example.net/v1/relay/ses_1"), cloudURL: cloud, busy: false, paused: false, updateRequired: false) == .decline("policy"),
          "offer: a relay on another host is refused (the ticket never leaves the cloud)")
    check(OfferDecision.decide(offer(key: "zz"), cloudURL: cloud, busy: false, paused: false, updateRequired: false) == .decline("policy"), "offer: bad viewer key refused")
    check(OfferDecision.decide(offer(expires: "2020-01-01T00:00:00Z"), cloudURL: cloud, busy: false, paused: false, updateRequired: false) == .decline("timeout"),
          "offer: expired offer -> timeout")
    check(OfferDecision.promptTimeout == 50 && OfferDecision.acceptDelay == 1, "offer: prompt auto-declines after 50 s, Accept enabled after 1 s")

    let u = RelayEndpoint.url("wss://g.example.com/v1/relay/ses_1", ticket: "a+b/c=.d", sessionId: "ses_1", cloudURL: cloud)
    check(u?.absoluteString == "wss://g.example.com/v1/relay/ses_1?ticket=a%2Bb/c%3D.d" || u?.absoluteString == "wss://g.example.com/v1/relay/ses_1?ticket=a%2Bb/c=.d",
          "relay URL: ?ticket= appended and encoded (\(u?.absoluteString ?? "nil"))")
    check(RelayEndpoint.url("ws://g.example.com/v1/relay/ses_1", ticket: "t", sessionId: "ses_1", cloudURL: cloud) == nil
          && RelayEndpoint.url("wss://g.example.com/v1/relay/ses_2", ticket: "t", sessionId: "ses_1", cloudURL: cloud) == nil
          && RelayEndpoint.url("wss://g.example.com:8443/v1/relay/ses_1", ticket: "t", sessionId: "ses_1", cloudURL: cloud) == nil,
          "relay URL: plain ws, another session's path or another port refused")
    check(RelayEndpoint.url("ws://127.0.0.1:8787/v1/relay/ses_1", ticket: "t", sessionId: "ses_1", cloudURL: URL(string: "http://127.0.0.1:8787")!) != nil,
          "relay URL: ws allowed for a loopback development cloud")
    check(RelayEndpoint.webSocketURL(cloud, path: "/v1/hub")?.absoluteString == "wss://g.example.com/v1/hub"
          && RelayEndpoint.webSocketURL(URL(string: "https://g.example.com/base")!, path: "/v1/hub")?.absoluteString == "wss://g.example.com/base/v1/hub",
          "hub URL: https -> wss")
}

// MARK: Permissions (§6.3)

func permissionTests() {
    let clip = ClipboardData(seq: 1, text: "x")
    let input: [ClientMessage] = [.mouseMove(x: 0.5, y: 0.5), .mouseButton(button: 1, down: true), .mouseWheel(dx: 0, dy: 1), .key(usage: 4, down: true),
                                  .scroll(precise: true, dx: 0, dy: 1), .mouseDelta(dx: 1, dy: 1), .setDisplayPreference(mode: 1)]
    let viewOnly = CloudPermissions(control: false, clipboard: .both, files: .both, audio: true)
    check(input.allSatisfy { !ManagedPermissions.hostAccepts($0, viewOnly) }, "permissions: control false -> host drops all input (and display-mode changes)")
    check(input.allSatisfy { ManagedPermissions.hostAccepts($0, .full) }, "permissions: control true -> input accepted")
    check(ManagedPermissions.hostAccepts(.releaseAll, viewOnly) && ManagedPermissions.hostAccepts(.ping(clientTimeUs: 1), viewOnly)
          && ManagedPermissions.hostAccepts(.viewSize(w: 1920, h: 1080), viewOnly) && ManagedPermissions.hostAccepts(.selectDisplay(id: 0), viewOnly),
          "permissions: view only still allows ReleaseAll, ping, view size, display choice")
    let offer = FileMessage.offer(id: 1, totalBytes: 1, files: [FileEntry(path: "a", size: 1, mtimeMs: 0)])
    check(!ManagedPermissions.hostAccepts(.clipboard(clip), viewOnly) && !ManagedPermissions.hostAccepts(.file(offer), viewOnly),
          "permissions: control false refuses the viewer's clipboard pushes and file offers")
    let toViewer = CloudPermissions(control: true, clipboard: .toViewer, files: .toViewer, audio: false)
    check(!ManagedPermissions.hostAccepts(.clipboard(clip), toViewer) && ManagedPermissions.hostSendsClipboard(toViewer),
          "permissions: clipboard to_viewer -> host sends, refuses the viewer's")
    check(!ManagedPermissions.hostAccepts(.file(offer), toViewer) && ManagedPermissions.hostAccepts(.file(.pull), toViewer)
          && ManagedPermissions.hostAccepts(.file(.ack(id: 0x8000_0001, bytes: 1)), toViewer), "permissions: files to_viewer -> pull and acks ok, offers refused")
    let toHost = CloudPermissions(control: true, clipboard: .toHost, files: .toHost, audio: false)
    check(ManagedPermissions.hostAccepts(.clipboard(clip), toHost) && !ManagedPermissions.hostSendsClipboard(toHost)
          && ManagedPermissions.hostAccepts(.file(offer), toHost) && !ManagedPermissions.hostAccepts(.file(.pull), toHost)
          && !ManagedPermissions.hostSendsFiles(toHost), "permissions: to_host -> host accepts the viewer's data, sends none")
    check(ManagedPermissions.hostAccepts(.file(.cancel(id: 1, reason: 1, detail: "")), .none), "permissions: cancelling a transfer is always allowed")
    check(!ManagedPermissions.hostSendsAudio(toHost) && ManagedPermissions.hostSendsAudio(.full), "permissions: audio")
    check(ManagedPermissions.hostFileCapsFlags(toViewer, receiveSetting: true) == FileMessage.capsSend
          && ManagedPermissions.hostFileCapsFlags(toHost, receiveSetting: true) == FileMessage.capsReceive
          && ManagedPermissions.hostFileCapsFlags(toHost, receiveSetting: false) == 0
          && ManagedPermissions.hostFileCapsFlags(nil, receiveSetting: true) == FileMessage.capsReceive | FileMessage.capsSend,
          "permissions: FileCaps flags follow the grant and the host setting")
    // Viewer side: enforce what it sends and what it accepts.
    check(input.allSatisfy { !ManagedPermissions.viewerMaySend($0, viewOnly) } && ManagedPermissions.viewerMaySend(.releaseAll, viewOnly),
          "permissions: viewer sends no input when view only")
    check(!ManagedPermissions.viewerMaySend(.clipboard(clip), toViewer) && ManagedPermissions.viewerMaySend(.clipboard(clip), toHost)
          && !ManagedPermissions.viewerMaySend(.file(offer), toViewer) && !ManagedPermissions.viewerMaySend(.audioEnable(true), toHost)
          && ManagedPermissions.viewerMaySend(.audioEnable(false), toHost), "permissions: viewer send directions")
    check(!ManagedPermissions.viewerAccepts(.clipboard(clip), toHost) && ManagedPermissions.viewerAccepts(.clipboard(clip), toViewer)
          && !ManagedPermissions.viewerAccepts(.audioFrame(seq: 1, captureTimeUs: 0, pcm: Data()), toHost)
          && !ManagedPermissions.viewerAccepts(.file(offer), toHost) && ManagedPermissions.viewerAccepts(.pong(clientTimeUs: 1, hostTimeUs: 2), .none),
          "permissions: viewer receive directions")
    let caps: CodecCaps = [.hevc420, .h264, .clipboard, .files, .audioPCM]
    check(ManagedPermissions.viewerCaps(caps, .none) == [.hevc420, .h264] && ManagedPermissions.viewerCaps(caps, .full) == caps
          && ManagedPermissions.viewerCaps(caps, CloudPermissions(control: false, clipboard: .toHost, files: .toViewer, audio: false)) == [.hevc420, .h264, .files],
          "permissions: viewer drops caps it may not use")
    check(CloudPermissions.full.summary == "Full control · clipboard both ways · files both ways · audio" && CloudPermissions.none.summary == "View only",
          "permissions: summary text")
}

// MARK: Backoff (§6.4)

func backoffTests() {
    var b = CloudBackoff()
    let mid = (0..<9).map { _ in b.next(random: 0.5) }
    check(mid == [1, 2, 4, 8, 16, 32, 60, 60, 60], "backoff: 1 s doubling to 60 s \(mid)")
    b.reset()
    check(abs(b.next(random: 0) - 0.8) < 1e-9 && abs(b.next(random: 0.999999) - 2.4) < 1e-4, "backoff: ±20 % jitter")
    var c = CloudBackoff()
    var ok = true
    for _ in 0..<30 { let d = c.next(); ok = ok && d >= 0.8 && d <= 72 }
    check(ok, "backoff: random jitter stays within bounds")
}

// MARK: Grants (§6.3)

func grantTests() {
    let key = Data(repeating: 7, count: 32), other = Data(repeating: 8, count: 32)
    let now = Date()
    let user = CloudUser(id: "usr_1", email: "ada@example.com", name: "Ada")
    func grant(_ sid: String = "ses_1", exp: TimeInterval = 60) -> SessionGrant {
        SessionGrant(sessionId: sid, viewerKey: key, viewerName: "V", user: user, permissions: .full, expiresAt: now.addingTimeInterval(exp))
    }
    let s = GrantStore()
    s.add(grant())
    check(s.claim(sessionId: "ses_1", viewerKey: key, now: now) != nil, "grants: the granted key claims its session")
    check(s.claim(sessionId: "ses_1", viewerKey: key, now: now) == nil, "grants: single use")
    s.add(grant())
    check(s.claim(sessionId: "ses_1", viewerKey: other, now: now) == nil && s.claim(sessionId: "ses_1", viewerKey: key, now: now) == nil,
          "grants: a wrong key is refused and burns the grant")
    s.add(grant(exp: 10))
    check(s.claim(sessionId: "ses_1", viewerKey: key, now: now.addingTimeInterval(11)) == nil && s.count == 0, "grants: expired grants can't be claimed")
    s.add(grant("ses_2"))
    check(s.claim(sessionId: "ses_1", viewerKey: key, now: now) == nil && s.isLive("ses_2", now: now), "grants: bound to their own session")
    s.revoke("ses_2")
    check(!s.isLive("ses_2", now: now), "grants: revoked (session cancelled)")

    let j = #"{"session_id":"ses_9","viewer":{"device_id":"dev_v","name":"V\u0007","public_key":"\#(String(repeating: "07", count: 32))"},"user":{"id":"u","email":"e@x.com","name":"E"},"permissions":{"control":false},"approval":"none","relay_url":"wss://x/v1/relay/ses_9","ticket":"t","expires_at":"2099-01-01T00:00:00Z"}"#
    let o = try! JSONDecoder().decode(SessionOffer.self, from: Data(j.utf8))
    let g = SessionGrant(offer: o, now: now)
    check(g?.viewerKey == key && g?.viewerName == "V" && g.map { abs($0.expiresAt.timeIntervalSince(now) - 120) < 1 } == true && g?.permissions.control == false,
          "grants: from an offer, lifetime capped at 120 s, name cleaned")

    // The host's auth decision: grants only for bridged connections, never pinned.
    let store = GrantStore()
    store.add(grant("ses_r"))
    var claimed = 0
    let lanGrant = HostAuth.decide(viewerKey: key, pairRequest: false, relaySessionId: nil, grants: store, isPaired: { _ in false }, claimPairing: { claimed += 1; return .granted }, now: now)
    check(lanGrant == .reject(.unknownViewer) && store.isLive("ses_r", now: now), "auth: a granted key over LAN is still an unknown viewer (grant untouched)")
    let relayPair = HostAuth.decide(viewerKey: key, pairRequest: true, relaySessionId: "ses_r", grants: store, isPaired: { _ in true }, claimPairing: { claimed += 1; return .granted }, now: now)
    check(relayPair == .reject(.pairingClosed) && claimed == 0 && !store.isLive("ses_r", now: now), "auth: no pairing over the relay (grant withdrawn, window untouched)")
    store.add(grant("ses_r"))
    let paired = HostAuth.decide(viewerKey: other, pairRequest: false, relaySessionId: "ses_r", grants: store, isPaired: { _ in true }, claimPairing: { .granted }, now: now)
    check(paired == .reject(.unknownViewer), "auth: a paired LAN viewer can't take over a relayed session")
    store.add(grant("ses_r"))
    if case let .granted(gg) = HostAuth.decide(viewerKey: key, pairRequest: false, relaySessionId: "ses_r", grants: store, isPaired: { _ in false }, claimPairing: { .closed }, now: now) {
        check(gg.sessionId == "ses_r" && gg.user.email == "ada@example.com", "auth: the granted key is accepted on its bridged connection without pairing")
    } else { check(false, "auth: granted") }
    check(HostAuth.decide(viewerKey: key, pairRequest: false, relaySessionId: "ses_r", grants: store, isPaired: { _ in false }, claimPairing: { .closed }, now: now)
          == .reject(.unknownViewer), "auth: exactly one Noise session per grant")
    check(HostAuth.decide(viewerKey: key, pairRequest: true, relaySessionId: nil, grants: store, isPaired: { _ in false }, claimPairing: { .closed }, now: now) == .reject(.pairingClosed)
          && HostAuth.decide(viewerKey: key, pairRequest: true, relaySessionId: nil, grants: store, isPaired: { _ in false }, claimPairing: { .granted }, now: now) == .pair
          && HostAuth.decide(viewerKey: key, pairRequest: false, relaySessionId: nil, grants: store, isPaired: { _ in true }, claimPairing: { .closed }, now: now) == .paired,
          "auth: LAN rules unchanged (paired key, pairing window)")
    // Nothing about a grant reaches host.json: the paired list is untouched by the whole flow.
    var cfg = HostConfig()
    cfg.pairedViewers = []
    let before = try? JSONEncoder().encode(cfg)
    _ = HostAuth.decide(viewerKey: key, pairRequest: false, relaySessionId: "ses_x", grants: GrantStore(), isPaired: { PairedViewers.contains(cfg.pairedViewers ?? [], key: $0) }, claimPairing: { .closed }, now: now)
    check((try? JSONEncoder().encode(cfg)) == before && !PairedViewers.contains(cfg.pairedViewers ?? [], key: key), "auth: grants are never written to pairedViewers")
}

// MARK: Enrollment file (§11.3)

func enrollmentStoreTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-cloud-\(getpid())-\(UInt32.random(in: 0...UInt32.max))/Glide")
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    let host = EnrollmentStore.file(for: .host, in: dir), viewer = EnrollmentStore.file(for: .viewer, in: dir)
    check(host.url.lastPathComponent == "cloud-host.json" && viewer.url.lastPathComponent == "cloud-viewer.json", "enrollment: file names")
    check(try host.load() == nil, "enrollment: none yet")
    var e = Enrollment(cloudURL: "https://g.example.com", orgId: "org_1", deviceId: "dev_1", deviceToken: "gd_secret", enrolledAt: "2026-11-25T10:00:00Z",
                       orgName: "Example", settings: OrgSettings(lanMode: false))
    try host.save(e)
    let fileMode = ((try FileManager.default.attributesOfItem(atPath: host.url.path))[.posixPermissions] as? NSNumber)?.intValue
    let dirMode = ((try FileManager.default.attributesOfItem(atPath: dir.path))[.posixPermissions] as? NSNumber)?.intValue
    check(fileMode == 0o600 && dirMode == 0o700, "enrollment: file 0600 in a 0700 folder (\(String(fileMode ?? 0, radix: 8)), \(String(dirMode ?? 0, radix: 8)))")
    check(try host.load() == e, "enrollment: round trip")
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: host.url)) as? [String: Any] ?? [:]
    check(["cloud_url", "org_id", "device_id", "device_token", "enrolled_at"].allSatisfy { raw[$0] != nil }, "enrollment: spec field names")
    check(e.isFor(URL(string: "https://G.example.com/")!) && !e.isFor(URL(string: "https://other.example.com")!), "enrollment: tied to its CloudURL")
    e.userToken = "gu_tok"
    e.userTokenExpires = CloudTime.format(Date().addingTimeInterval(3600))
    try viewer.save(e)
    check(try viewer.load()?.validUserToken() == "gu_tok", "enrollment: viewer keeps its user token")
    e.userTokenExpires = CloudTime.format(Date().addingTimeInterval(-5))
    check(e.validUserToken() == nil, "enrollment: an expired user token is not used")
    chmod(host.url.path, 0o644)
    _ = try host.load()
    let tightened = ((try FileManager.default.attributesOfItem(atPath: host.url.path))[.posixPermissions] as? NSNumber)?.intValue
    check(tightened == 0o600, "enrollment: a loosened file is tightened to 0600")
    try host.update { $0.deviceName = "Front Desk" }
    check(try host.load()?.deviceName == "Front Desk", "enrollment: update")
    host.wipe()
    check(try host.load() == nil && !FileManager.default.fileExists(atPath: host.url.path), "enrollment: wipe (revoked)")
    try Data("{".utf8).write(to: host.url)
    check((try? host.load()) == nil, "enrollment: a corrupt file throws instead of being replaced")
}

// MARK: API client (§6.1–6.2)

func cloudClientTests() throws {
    let t = FakeTransport { r in
        switch (r.httpMethod ?? "", r.url?.path ?? "") {
        case ("GET", "/v1/hosts"): return (200, #"{"hosts":[]}"#)
        case ("POST", "/v1/sessions"): return (409, #"{"error":{"code":"host_offline","message":"The host is not connected."}}"#)
        case ("POST", "/v1/auth/device/token"): return (400, #"{"error":{"code":"authorization_pending","message":""}}"#)
        default: return (404, "")
        }
    }
    let c = CloudClient(baseURL: URL(string: "https://g.example.com")!, deviceToken: "gd_dev", userToken: "gu_usr", transport: t)
    check((try? blocking { try await c.hosts() }.get()) == [], "client: GET /v1/hosts")
    let r = t.all.last
    check(r?.value(forHTTPHeaderField: "Authorization") == "Bearer gd_dev" && r?.value(forHTTPHeaderField: "X-Glide-User") == "gu_usr",
          "client: user calls send Authorization: Bearer gd_… and X-Glide-User: gu_…")
    if case let .failure(e as CloudError) = blocking({ try await c.createSession(hostId: "dev_h1") }) {
        check(e.code == "host_offline" && e.status == 409, "client: session errors carry the code (\(e))")
    } else { check(false, "client: 409 host_offline") }
    let sreq = t.all.last
    check(sreq?.timeoutInterval == 75 && sreq?.value(forHTTPHeaderField: "Content-Type") == "application/json; charset=utf-8"
          && String(decoding: sreq?.httpBody ?? Data(), as: UTF8.self) == #"{"host_id":"dev_h1"}"#, "client: POST /v1/sessions waits up to 75 s, JSON body")
    _ = blocking { try await c.deviceAuthToken(deviceCode: "dc") }
    check(t.all.last?.value(forHTTPHeaderField: "X-Glide-User") == nil && t.all.last?.value(forHTTPHeaderField: "Authorization") == "Bearer gd_dev",
          "client: device calls send only the device bearer")
    let enrollClient = CloudClient(baseURL: URL(string: "https://g.example.com")!, transport: t)
    let er = try enrollClient.request("POST", "/v1/enroll", auth: .none, body: Data())
    check(er.value(forHTTPHeaderField: "Authorization") == nil, "client: /v1/enroll has no bearer")
    check((try? c.hubRequest())?.url?.absoluteString == "wss://g.example.com/v1/hub" && (try? c.hubRequest())?.value(forHTTPHeaderField: "Authorization") == "Bearer gd_dev",
          "client: hub upgrade request")
    if case .failure = blocking({ try await c.endSession("ses_../x", as: .user) }) { check(true, "client: a malformed session id never reaches a URL") }
    else { check(false, "client: malformed session id") }
    // Device authorization polling (RFC 8628).
    check(DeviceAuthPoll.next(after: .http(status: 400, code: "authorization_pending", message: ""), interval: 5) == .keepPolling(interval: 5)
          && DeviceAuthPoll.next(after: .http(status: 400, code: "slow_down", message: ""), interval: 5) == .keepPolling(interval: 10)
          && DeviceAuthPoll.next(after: .transport("offline"), interval: 5) == .keepPolling(interval: 5),
          "device auth: pending keeps the interval, slow_down adds 5 s")
    if case .failed = DeviceAuthPoll.next(after: .http(status: 400, code: "expired_token", message: ""), interval: 5),
       case .failed = DeviceAuthPoll.next(after: .http(status: 400, code: "access_denied", message: ""), interval: 5) {
        check(true, "device auth: expired_token and access_denied stop polling")
    } else { check(false, "device auth: terminal errors") }
    check(URLSessionTransport.configuration().tlsMinimumSupportedProtocolVersion == .TLSv12 && URLSessionTransport.configuration().httpCookieAcceptPolicy == .never,
          "client: TLS 1.2+, no cookies")
}

// MARK: Hub client (§6.4)

func hubClientTests() {
    let lock = NSLock()
    var sockets: [FakeSocket] = []
    var events: [HubEvent] = []
    var delays: [TimeInterval] = []
    var pendingWork: [() -> Void] = []
    let q = DispatchQueue(label: "test.hub")
    let hub = HubClient(request: { URLRequest(url: URL(string: "wss://g.example.com/v1/hub")!) },
                        factory: { r in let s = FakeSocket(request: r); lock.withLock { sockets.append(s) }; return s },
                        queue: q, schedule: { d, w in lock.withLock { delays.append(d); pendingWork.append(w) } }, random: { 0.5 })
    hub.onEvent = { e in lock.withLock { events.append(e) } }
    hub.start()
    check(waitUntil { lock.withLock { sockets.count == 1 && sockets[0].started } }, "hub: connects on start")
    let s0 = lock.withLock { sockets[0] }
    s0.pushText(#"{"type":"hello","device_id":"dev_1","settings":{"lan_mode":false},"server_time":"2026-11-25T10:00:00Z"}"#)
    check(waitUntil { lock.withLock { events.contains(.connected(deviceId: "dev_1", settings: OrgSettings(lanMode: false))) } }, "hub: hello -> connected with settings")
    s0.pushText(#"{"type":"ping","t":12345}"#)
    check(waitUntil { s0.sentTexts.contains(#"{"t":12345,"type":"pong"}"#) }, "hub: ping answered with pong (same t)")
    s0.pushText(#"{"type":"session_cancel","session_id":"ses_1","reason":"timeout"}"#)
    check(waitUntil { lock.withLock { events.contains(.cancel(sessionId: "ses_1", reason: "timeout")) } }, "hub: session_cancel event")
    s0.pushText("not json")
    hub.send(.sessionAnswer(sessionId: "ses_1", accept: false, reason: "busy"))
    check(waitUntil { s0.sentTexts.contains(#"{"accept":false,"reason":"busy","session_id":"ses_1","type":"session_answer"}"#) }, "hub: malformed frame ignored; answers sent")
    // Disconnect -> backoff 1 s, then 2 s while the reconnects fail.
    s0.fail(code: 1006)
    check(waitUntil { lock.withLock { delays == [1.0] } }, "hub: reconnect after 1 s")
    lock.withLock { let w = pendingWork.removeFirst(); w() }
    check(waitUntil { lock.withLock { sockets.count == 2 } }, "hub: reconnected")
    lock.withLock { sockets[1] }.fail(status: 502)
    check(waitUntil { lock.withLock { delays == [1.0, 2.0] } }, "hub: backoff doubles (\(lock.withLock { delays }))")
    lock.withLock { let w = pendingWork.removeFirst(); w() }
    check(waitUntil { lock.withLock { sockets.count == 3 } }, "hub: reconnects again")
    let s2 = lock.withLock { sockets[2] }
    s2.pushText(#"{"type":"hello","device_id":"dev_1","settings":{}}"#)
    _ = waitUntil { lock.withLock { events.filter { if case .connected = $0 { return true }; return false }.count == 2 } }
    s2.fail(code: 1001)
    check(waitUntil { lock.withLock { delays.count == 3 && delays[2] == 1.0 } }, "hub: a hello resets the backoff")
    lock.withLock { let w = pendingWork.removeFirst(); w() }
    check(waitUntil { lock.withLock { sockets.count == 4 } }, "hub: reconnect 3")
    lock.withLock { sockets[3] }.fail(status: 401)
    check(waitUntil { lock.withLock { events.last == .revoked(reason: "unauthorized") } }, "hub: 401 on the upgrade = revoked")
    usleep(50_000)
    check(lock.withLock { delays.count == 3 && sockets.count == 4 }, "hub: no reconnect after 401")

    // A revoked frame stops the client too.
    var ev2: [HubEvent] = []
    var socks2: [FakeSocket] = []
    let hub2 = HubClient(request: { URLRequest(url: URL(string: "wss://g.example.com/v1/hub")!) },
                         factory: { r in let s = FakeSocket(request: r); lock.withLock { socks2.append(s) }; return s },
                         queue: DispatchQueue(label: "test.hub2"), schedule: { _, _ in }, random: { 0.5 })
    hub2.onEvent = { e in lock.withLock { ev2.append(e) } }
    hub2.start()
    _ = waitUntil { lock.withLock { socks2.count == 1 } }
    lock.withLock { socks2[0] }.pushText(#"{"type":"revoked","reason":"device revoked"}"#)
    check(waitUntil { lock.withLock { ev2 == [.revoked(reason: "device revoked")] } } && waitUntil { lock.withLock { socks2[0].closed != nil } },
          "hub: revoked frame -> event, socket closed")
    check(!hub2.isConnected, "hub: stopped after revoked")
}

// MARK: Audit (§9)

func auditTests() {
    let many = (0..<250).map { AuditEvent(type: "session.clipboard", ts: "2026-11-25T10:00:00Z", sessionId: "ses_1", detail: .object(["bytes": .int($0)])) }
    let b = AuditReporter.batches(many)
    check(b.map(\.events.count) == [100, 100, 50], "audit: batches of at most 100 events")
    let big = (0..<60).map { _ in AuditEvent(type: "session.file_sent", ts: "t", sessionId: "s", detail: .object(["names": .array([.string(String(repeating: "n", count: 8000))])])) }
    let bb = AuditReporter.batches(big)
    check(bb.allSatisfy { ((try? JSONEncoder.cloud.encode($0))?.count ?? .max) <= AuditReporter.maxBatchBytes } && bb.reduce(0) { $0 + $1.events.count } == 60,
          "audit: batches stay within 256 KiB")
    let lock = NSLock()
    var sent: [AuditBatch] = []
    let r = AuditReporter(delay: 0.05) { batch in lock.withLock { sent.append(batch) } }
    r.report("session.started", sessionId: "ses_1", detail: [:])  // a cloud-only type: never sent by a client
    r.clipboard(sessionId: "ses_1", toHost: true, image: false, bytes: 42)
    r.includeFileNames = false
    r.files(sent: false, sessionId: "ses_1", count: 2, bytes: 10, names: ["secret.pdf"])
    r.localEnd(sessionId: "ses_1", byHostUser: true)
    check(waitUntil { lock.withLock { sent.reduce(0) { $0 + $1.events.count } == 3 } }, "audit: client events batched and sent")
    let evs = lock.withLock { sent.flatMap(\.events) }
    check(evs.map(\.type) == ["session.clipboard", "session.file_received", "session.local_end"], "audit: only §9 client types (\(evs.map(\.type)))")
    check(evs[0].detail == .object(["direction": .string("to_host"), "kind": .string("text"), "bytes": .int(42)]), "audit: clipboard detail (never contents)")
    check(evs[1].detail["names"] == nil && evs[1].detail["count"] == .int(2), "audit: audit_file_names false -> counts and sizes only")
    check(evs[2].detail == .object(["by": .string("host_user")]), "audit: session.local_end by host_user")
}

// MARK: Relay bridge (§6.5–6.6)

func bridgeTests() {
    check(LoopbackPair.peerMatches(acceptedRemotePort: 50123, dialedLocalPort: 50123) && !LoopbackPair.peerMatches(acceptedRemotePort: 50124, dialedLocalPort: 50123)
          && !LoopbackPair.peerMatches(acceptedRemotePort: nil, dialedLocalPort: 50123), "bridge: peer-port check")
    // A lost race (simulated) closes both sockets and retries.
    let lock = NSLock()
    var calls = 0
    let sq = DispatchQueue(label: "test.session")
    var pair: (NWConnection, NWConnection)?
    var pairError: Error?
    LoopbackPair.make(sessionQueue: sq, bridgeQueue: DispatchQueue(label: "test.bridge"), peerCheck: { a, d in
        lock.withLock { calls += 1; return calls > 1 && LoopbackPair.peerMatches(acceptedRemotePort: a, dialedLocalPort: d) }
    }) { r in
        lock.withLock { switch r { case let .success(p): pair = (p.dialed, p.accepted); case let .failure(e): pairError = e } }
    }
    check(waitUntil(5) { lock.withLock { pair != nil || pairError != nil } } && lock.withLock { calls == 2 && pair != nil },
          "bridge: a failed peer-port check closes both and retries (\(lock.withLock { calls }) checks)")
    var allLost: Error?
    LoopbackPair.make(sessionQueue: sq, bridgeQueue: DispatchQueue(label: "test.bridge2"), peerCheck: { _, _ in false }) { r in
        if case let .failure(e) = r { lock.withLock { allLost = e } }
    }
    check(waitUntil(5) { lock.withLock { allLost != nil } } && "\(lock.withLock { allLost! })".contains("another local process"),
          "bridge: gives up after 3 lost races")
    if let p = lock.withLock({ pair }) { p.0.cancel(); p.1.cancel() }

    // Bytes both ways through a fake relay socket.
    let sock = FakeSocket()
    let bridge = RelayBridge(socket: sock)
    var statuses: [RelayBridge.Status] = []
    var closedWhy: String?
    var session: NWConnection?
    bridge.onStatus = { s in lock.withLock { statuses.append(s) } }
    bridge.onClosed = { w in lock.withLock { closedWhy = w } }
    bridge.start(sessionQueue: sq) { c in lock.withLock { session = c } }
    sock.pushText(#"{"type":"waiting"}"#)
    check(waitUntil { lock.withLock { statuses == [.connecting, .waiting] } } && sock.started, "bridge: relay socket opened, waiting")
    usleep(50_000)
    check(sock.sentBinary.isEmpty && lock.withLock { session == nil }, "bridge: nothing sent and no session before peer_joined")
    sock.pushText(#"{"type":"peer_joined"}"#)
    // The viewer may write the moment the relay says joined: frames before the loopback is ready are kept.
    sock.push(.success(.binary(Data("early".utf8))))
    check(waitUntil(5) { lock.withLock { session != nil } }, "bridge: peer_joined -> loopback connection handed to the session code")
    guard let conn = lock.withLock({ session }) else { return }
    check(conn.state == .ready, "bridge: the handed connection is connected")
    let payload = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    conn.send(content: payload, completion: .contentProcessed { _ in })
    check(waitUntil(5) { sock.sentBinary.count == payload.count } && sock.sentBinary == payload, "bridge: socket -> relay binary frames, in order")
    let maxFrame = sock.sent.map { if case let .binary(d) = $0 { return d.count } else { return 0 } }.max() ?? 0
    check(maxFrame <= RelayBridge.readMax, "bridge: frames ≤ 256 KiB reads (largest \(maxFrame))")
    var got = Data()
    func readMore() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, _, _ in
            if let d { lock.withLock { got.append(d) } }
            if d != nil { readMore() }
        }
    }
    readMore()
    sock.push(.success(.binary(Data(" and later".utf8))))
    check(waitUntil(5) { lock.withLock { got == Data("early and later".utf8) } }, "bridge: relay binary -> socket, in order (early frame kept)")
    check(bridge.bytesToRelay == UInt64(payload.count) && bridge.bytesFromRelay == 15, "bridge: byte counts")
    sock.pushText(#"{"type":"peer_left"}"#)
    check(waitUntil(5) { lock.withLock { closedWhy != nil } } && sock.closed == 1000, "bridge: peer_left closes the relay socket (1000)")
    check(waitUntil(5) { conn.state == .cancelled || { if case .failed = conn.state { return true }; return false }() }, "bridge: …and the session's socket")

    // Binary before peer_joined is a protocol violation; oversized frames too.
    let s2 = FakeSocket()
    let b2 = RelayBridge(socket: s2)
    var why2: String?
    b2.onClosed = { w in lock.withLock { why2 = w } }
    b2.start(sessionQueue: sq) { _ in }
    s2.push(.success(.binary(Data([1, 2, 3]))))
    check(waitUntil { lock.withLock { why2?.contains("before peer_joined") == true } }, "bridge: relay data before peer_joined closes the bridge")
    let s3 = FakeSocket()
    let b3 = RelayBridge(socket: s3)
    var why3: String?
    b3.onClosed = { w in lock.withLock { why3 = w } }
    b3.start(sessionQueue: sq) { _ in }
    s3.pushText(#"{"type":"peer_joined"}"#)
    s3.push(.success(.binary(Data(count: RelayBridge.frameMax + 1))))
    check(waitUntil(5) { lock.withLock { why3 == "relay frame too large" } }, "bridge: frames over 1 MiB refused")

    // The session closing its end closes the relay socket.
    let s4 = FakeSocket()
    let b4 = RelayBridge(socket: s4)
    var c4: NWConnection?
    var why4: String?
    b4.onClosed = { w in lock.withLock { why4 = w } }
    b4.start(sessionQueue: sq) { c in lock.withLock { c4 = c } }
    s4.pushText(#"{"type":"peer_joined"}"#)
    _ = waitUntil(5) { lock.withLock { c4 != nil } }
    lock.withLock { c4 }?.cancel()
    check(waitUntil(5) { lock.withLock { why4 != nil } } && s4.closed == 1000, "bridge: the session closing closes the relay socket")
    // The relay closing with a code is reported in words.
    let s5 = FakeSocket()
    let b5 = RelayBridge(socket: s5)
    var why5: String?
    b5.onClosed = { w in lock.withLock { why5 = w } }
    b5.start(sessionQueue: sq) { _ in }
    s5.fail(code: 4003)
    check(waitUntil { lock.withLock { why5 == "ended by an administrator" } }, "bridge: close code 4003 reported")
}

// MARK: Enroll -> hub -> revoke (§5.1, §6.4)

func cloudDeviceTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-clouddev-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = EnrollmentStore.file(for: .host, in: dir)
    let lock = NSLock()
    var enrollBodies: [String] = []
    let t = FakeTransport { r in
        switch (r.httpMethod ?? "", r.url?.path ?? "") {
        case ("POST", "/v1/enroll"):
            lock.withLock { enrollBodies.append(String(decoding: r.httpBody ?? Data(), as: UTF8.self)) }
            return (201, #"{"device_id":"dev_h1","device_token":"gd_tok","org":{"id":"org_1","slug":"ex","name":"Example"},"settings":{"lan_mode":true}}"#)
        case ("GET", "/v1/device"):
            return (200, #"{"device_id":"dev_h1","kind":"host","name":"Front Desk","tags":[],"org":{"id":"org_1","slug":"ex","name":"Example Corp"},"settings":{"lan_mode":false,"allow_local_pairing":false}}"#)
        case ("POST", "/v1/device/heartbeat"): return (204, "")
        default: return (404, "")
        }
    }
    var socks: [FakeSocket] = []
    let cfg = ManagedConfig.read(DictionarySource(["CloudURL": "https://g.example.com", "EnrollmentToken": "enr_x", "DeviceName": "Front Desk", "Tags": ["lobby"]]))
    let key = Data(repeating: 0xab, count: 32)
    let dev = CloudDevice(kind: .host, publicKey: key, store: store, config: cfg, appVersion: "0.3.1", transport: t,
                          wsFactory: { r in let s = FakeSocket(request: r); lock.withLock { socks.append(s) }; return s })
    var revokedReason: String?
    var offers: [SessionOffer] = []
    dev.onRevoked = { r in lock.withLock { revokedReason = r } }
    dev.onHubEvent = { e in if case let .offer(o) = e { lock.withLock { offers.append(o) } } }
    check(dev.status.policy.lanAllowed && dev.status.state == .unmanaged, "device: nothing known before start")
    dev.start()
    check(waitUntil { lock.withLock { socks.count == 1 } }, "device: enrolls, then connects to the hub")
    let body = lock.withLock { enrollBodies.first } ?? ""
    check(body.contains(#""kind":"host""#) && body.contains(#""public_key":"\#(key.hex)""#) && body.contains(#""name":"Front Desk""#)
          && body.contains(#""tags":["lobby"]"#) && body.contains(#""enrollment_token":"enr_x""#) && body.contains(#""platform":"macos""#),
          "device: enrollment body (kind, public key, name, tags)")
    check((try? store.load())?.deviceToken == "gd_tok", "device: enrollment stored")
    let hubReq = lock.withLock { socks[0].request }
    check(hubReq?.value(forHTTPHeaderField: "Authorization") == "Bearer gd_tok", "device: hub upgrade with the new device token")
    lock.withLock { socks[0] }.pushText(#"{"type":"hello","device_id":"dev_h1","settings":{"lan_mode":true}}"#)
    check(waitUntil { dev.queue.sync { dev.status.state == .enrolled(connected: true) } }, "device: hub hello -> enrolled, connected")
    check(waitUntil { dev.queue.sync { dev.status.orgName == "Example Corp" && !dev.status.policy.lanAllowed && !dev.status.policy.localPairingAllowed } },
          "device: GET /v1/device refreshes names and settings (lan_mode false applies)")
    check(waitUntil { (try? store.load())?.settings?.lanMode == false }, "device: org settings cached in the enrollment")
    // The cached settings apply at the next launch before any network.
    let relaunch = CloudDevice(kind: .host, publicKey: key, store: store, config: cfg, transport: t, wsFactory: { _ in FakeSocket() })
    check(!relaunch.status.policy.lanAllowed && relaunch.status.orgName == "Example Corp", "device: cached policy applies from launch")
    let k2 = String(repeating: "07", count: 32)
    lock.withLock { socks[0] }.pushText(#"{"type":"session_offer","session_id":"ses_1","viewer":{"device_id":"dev_v","name":"V","public_key":"\#(k2)"},"user":{"id":"u","email":"e@x.com","name":"E"},"permissions":{"control":true},"approval":"none","relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t"}"#)
    check(waitUntil { lock.withLock { offers.count == 1 } }, "device: offers reach the app")
    lock.withLock { socks[0] }.pushText(#"{"type":"revoked","reason":"device revoked"}"#)
    check(waitUntil { lock.withLock { revokedReason == "device revoked" } }, "device: revoked -> app told")
    check(!FileManager.default.fileExists(atPath: store.url.path) && dev.queue.sync { dev.status.policy.lanAllowed && dev.client == nil },
          "device: revoked wipes the enrollment and the org policy")

    // Enrolling a revoked key is refused for good.
    let t409 = FakeTransport { _ in (409, #"{"error":{"code":"device_revoked","message":"This device was revoked."}}"#) }
    let dev2 = CloudDevice(kind: .viewer, publicKey: key, store: EnrollmentStore.file(for: .viewer, in: dir), config: cfg, transport: t409, wsFactory: { _ in FakeSocket() })
    dev2.start()
    check(waitUntil { dev2.queue.sync { if case .revoked = dev2.status.state { return true }; return false } } && t409.all.count == 1,
          "device: 409 device_revoked is final (no retry loop)")
    let unmanaged = CloudDevice(kind: .host, publicKey: key, store: store, config: ManagedConfig(), transport: t, wsFactory: { _ in FakeSocket() })
    unmanaged.start()
    check(waitUntil { unmanaged.queue.sync { unmanaged.status.state == .unmanaged } } && unmanaged.status.policy.lanAllowed, "device: no CloudURL = unmanaged")
}
