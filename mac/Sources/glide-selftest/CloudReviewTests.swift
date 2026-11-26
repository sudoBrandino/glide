import CoreFoundation
import Foundation
import GlideCore
import Network

// ENTERPRISE.md §6.7 client behaviour (the review fixes): managed configuration source, CloudURL
// as an origin, loopback by IP, the exact relay URL, revocation keeping the last settings, view
// only, busy hosts, tolerant decoding, grant lifetime, enrollment and device-code retries, audit
// drops, the viewer's LAN gate, client.error, GET /v1/device per hub connection, the approval
// text, idempotent /end, and the display-string sanitizer.

/// HTTP transport answering from a script; `nil` = a network error.
final class ScriptTransport: CloudHTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    var handler: (URLRequest) -> (Int, String)?

    init(_ handler: @escaping (URLRequest) -> (Int, String)?) { self.handler = handler }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let r = lock.withLock { () -> (Int, String)? in
            requests.append(request)
            return handler(request)
        }
        guard let (status, body) = r else { throw CloudError.transport("offline") }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    var all: [URLRequest] { lock.withLock { requests } }
    func count(_ method: String, _ path: String) -> Int { all.filter { $0.httpMethod == method && $0.url?.path == path }.count }
}

func cloudReviewTests() throws {
    cloudTextTests()
    managedSourceTests()
    originTests()
    try tolerantDecodingTests()
    offerReviewTests()
    viewOnlyTests()
    grantLifetimeTests()
    enrollRetryTests()
    devicePollTests()
    auditDropTests()
    viewerLANGateTests()
    relayFailureTests()
    approvalTextTests()
    endSessionTests()
    try revocationTests()
    try deviceRefreshTests()
}

// MARK: Display strings (Windows parity)

func cloudTextTests() {
    let nasty = "A\u{7}d\u{200E}a\u{200F} \u{061C}L\u{202A}o\u{202E}v\u{2066}e\u{2069}\u{2028}l\u{2029}a\u{FEFF}c\u{200B}e\u{E0041}\u{E007F}\u{FE0F}\u{E0100}\u{180B}"
    check(CloudText.strip(nasty) == "Ada Lovelace", "text: controls, bidi marks and overrides, separators, Cf, tags, variation selectors removed (\(CloudText.strip(nasty).unicodeScalars.map { String($0.value, radix: 16) }))")
    check(CloudText.strip("  Ada \t\n  Lovelace  ") == "Ada Lovelace", "text: whitespace runs collapse, trimmed")
    check(CloudText.strip("x\u{00AD}y\u{2060}z") == "xyz", "text: every Cf format character removed (soft hyphen, word joiner)")
    let long = CloudText.clean(String(repeating: "n", count: 80))
    check(long.count == 64 && long.hasSuffix("…"), "text: names capped at 64 with an ellipsis")
    check(CloudText.clean(String(repeating: "n", count: 64)) == String(repeating: "n", count: 64), "text: 64 characters is not truncated")
    check(CloudText.name("\u{202E}\u{200B}", fallback: "the computer") == "the computer", "text: nothing left -> fallback")
    // Emails keep their real domain.
    check(CloudText.email("it@yourcompany.com.evil.example") == "it@yourcompany.com.evil.example", "email: a short address is shown whole (.evil.example visible)")
    let spoof = CloudText.email(String(repeating: "i", count: 50) + "@yourcompany.com.evil.example")
    check(spoof.count == 64 && spoof.hasSuffix("…@yourcompany.com.evil.example") && spoof.hasPrefix("iii"),
          "email: over 64 -> the local part is shortened, never the domain (\(spoof))")
    check(!CloudText.email(String(repeating: "i", count: 50) + "@yourcompany.com.evil.example").hasSuffix("yourcompany.com.e…"), "email: never cut at the end")
    let hugeDomain = CloudText.email("it@" + String(repeating: "sub.", count: 20) + "yourcompany.com.evil.example")
    check(hugeDomain.count == 64 && hugeDomain.hasPrefix("…") && hugeDomain.hasSuffix(".evil.example") && !hugeDomain.contains("@"),
          "email: a domain over 64 alone keeps its end behind a leading ellipsis (\(hugeDomain))")
    check(CloudText.email("it@yourcompany.com\u{202E}elpmaxe.live") == "it@yourcompany.comelpmaxe.live", "email: bidi override removed")
    let u = CloudUser(id: "u", email: String(repeating: "a", count: 70) + "@evil.example", name: String(repeating: "N", count: 70) + "\u{202E}")
    check(u.label.hasPrefix(String(repeating: "N", count: 63) + "… (") && u.label.hasSuffix("…@evil.example)") && !u.label.unicodeScalars.contains("\u{202E}"),
          "text: user label = name (≤ 64) and email (≤ 64, domain kept), cleaned")
    check(PairedViewer.displayName("PC\u{202E}gpj.exe\u{200B}") == "PCgpj.exe", "text: paired viewer names use the same rules")
}

// MARK: 1. Managed configuration source (§6.7)

func managedSourceTests() {
    let k = ManagedConfig.keys
    let all: [String: Any] = [k.cloudURL: "https://g.example.com", k.enrollmentToken: "enr_x", k.deviceName: "Desk", k.tags: ["owner:mallory@example.com"], k.disableLANMode: true]
    let user = ManagedConfig.read(DictionarySource(all, forced: []))
    check(user.cloudURL == nil && user.enrollmentToken == nil && !user.isCloudConfigured, "config: CloudURL and EnrollmentToken in ordinary preferences are ignored")
    check(user.deviceName == nil && user.tags.isEmpty, "config: DeviceName and Tags (enrollment input) need a profile too")
    check(user.disableLANMode, "config: DisableLANMode is read from anywhere (it can only be stricter)")
    check(user.problems.contains { $0.contains("CloudURL") && $0.contains("configuration profile") }, "config: the ignored value is reported")
    let partial = ManagedConfig.read(DictionarySource(all, forced: [k.cloudURL]))
    check(partial.cloudURL != nil && partial.enrollmentToken == nil && !partial.isCloudConfigured, "config: each key needs its own profile value")
    let forced = ManagedConfig.read(DictionarySource(all, forced: [k.cloudURL, k.enrollmentToken, k.deviceName, k.tags]))
    check(forced.isCloudConfigured && forced.deviceName == "Desk", "config: forced values are honoured")
    // The real CFPreferences path: a value written to the user's preferences is not forced.
    let domain = "dev.brandino.glide.selftest.\(getpid())" as CFString
    CFPreferencesSetAppValue(k.cloudURL as CFString, "https://g.example.com" as CFString, domain)
    CFPreferencesSetAppValue(k.enrollmentToken as CFString, "enr_x" as CFString, domain)
    CFPreferencesSetAppValue(k.disableLANMode as CFString, kCFBooleanTrue, domain)
    CFPreferencesAppSynchronize(domain)
    let src = PreferencesSource(domain: domain as String)
    let real = ManagedConfig.read(src)
    check(src.value(forKey: k.cloudURL) != nil && !src.isForced(k.cloudURL) && real.cloudURL == nil && real.disableLANMode,
          "config: CFPreferences user value -> not forced (CFPreferencesAppValueIsForced), ignored; DisableLANMode still applies")
    for key in [k.cloudURL, k.enrollmentToken, k.disableLANMode] { CFPreferencesSetAppValue(key as CFString, nil, domain) }
    CFPreferencesAppSynchronize(domain)
}

// MARK: 2. CloudURL origin, loopback by IP, exact relay URL

func originTests() {
    func parse(_ s: String) -> String? { try? ManagedConfig.parseCloudURL(s).get().absoluteString }
    check(parse("https://g.example.com/") == "https://g.example.com" && parse("https://g.example.com") == "https://g.example.com"
          && parse("https://g.example.com:8443") == "https://g.example.com:8443", "origin: https://host[:port], a lone / allowed")
    for bad in ["https://g.example.com/base", "https://g.example.com/v1/", "https://g.example.com//", "https://g.example.com/#f",
                "https://g.example.com?", "https://g.example.com/?a=1", "https://u@g.example.com"] {
        check(parse(bad) == nil, "origin: \(bad) refused")
    }
    for lo in ["127.0.0.1", "127.5.6.7", "127.255.255.255", "::1", "[::1]", "0:0:0:0:0:0:0:1"] { check(ManagedConfig.isLoopback(lo), "loopback: \(lo)") }
    for not in ["127.example.com", "localhost", "128.0.0.1", "127.1", "::2", "::ffff:127.0.0.1", "127.0.0.1.nip.io", ""] {
        check(!ManagedConfig.isLoopback(not), "loopback: \(not) is not a loopback IP")
    }
    check(parse("http://127.example.com") == nil && parse("http://localhost:8787") == nil && parse("http://127.0.0.1:8787") == "http://127.0.0.1:8787"
          && parse("http://[::1]:8787") != nil, "origin: plain http only for a loopback IP")
    let cloud = URL(string: "https://g.example.com")!
    func relay(_ u: String, _ c: URL = cloud) -> Bool { RelayEndpoint.url(u, ticket: "t", sessionId: "ses_1", cloudURL: c) != nil }
    check(relay("wss://g.example.com/v1/relay/ses_1") && relay("wss://G.example.com:443/v1/relay/ses_1"), "relay: wss://<CloudURL host:port>/v1/relay/<sid>")
    for bad in ["wss://g.example.com/v1/relay/ses_1/x", "wss://g.example.com/x/v1/relay/ses_1", "wss://g.example.com/v1/relay/ses_12",
                "wss://g.example.com/v1/relay/ses_1?a=b", "wss://g.example.com/v1/relay/ses_1#f", "wss://g.example.com:8443/v1/relay/ses_1",
                "wss://g.example.com/v1/relay/%73es_1", "wss://g.example.com.evil.example/v1/relay/ses_1", "ws://g.example.com/v1/relay/ses_1"] {
        check(!relay(bad), "relay: \(bad) refused")
    }
    check(relay("ws://127.0.0.1:8787/v1/relay/ses_1", URL(string: "http://127.0.0.1:8787")!), "relay: ws for a loopback development cloud")
}

// MARK: 6. Tolerant decoding

func tolerantDecodingTests() throws {
    let key = String(repeating: "07", count: 32)
    check(try HubServerFrame.decode(#"{"type":"hello"}"#) == .hello(deviceId: "", settings: OrgSettings(), serverTime: nil),
          "decode: hello without device_id or settings -> defaults")
    let bare = #"{"type":"session_offer","session_id":"ses_1","viewer":{"public_key":"\#(key)"},"relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t"}"#
    if case let .sessionOffer(o) = try HubServerFrame.decode(bare) {
        check(o.user.label == "an organization user" && o.approval == .required && o.permissions == .none && o.viewer.name.isEmpty,
              "decode: offer without user/approval/permissions -> an organization user, required, most restrictive")
    } else { check(false, "decode: minimal offer accepted") }
    for (missing, json) in [
        ("ticket", #"{"type":"session_offer","session_id":"ses_1","viewer":{"public_key":"\#(key)"},"relay_url":"wss://g.example.com/v1/relay/ses_1"}"#),
        ("relay_url", #"{"type":"session_offer","session_id":"ses_1","viewer":{"public_key":"\#(key)"},"ticket":"t"}"#),
        ("viewer key", #"{"type":"session_offer","session_id":"ses_1","viewer":{"name":"V"},"relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t"}"#),
    ] {
        if case .invalidOffer(sessionId: "ses_1", _) = try HubServerFrame.decode(json) { check(true, "decode: offer missing \(missing) -> rejected, session id known") }
        else { check(false, "decode: offer missing \(missing)") }
    }
    if case .invalidOffer(sessionId: nil, _) = try HubServerFrame.decode(#"{"type":"session_offer","ticket":"t"}"#) { check(true, "decode: offer without session_id -> rejected, nothing to answer") }
    else { check(false, "decode: offer without session_id") }
    let dec = JSONDecoder()
    let er = try dec.decode(EnrollResponse.self, from: Data(#"{"device_id":"dev_1","device_token":"gd_x"}"#.utf8))
    check(er.settings == OrgSettings() && er.org.id.isEmpty, "decode: enrollment without settings or org -> defaults")
    check((try? dec.decode(EnrollResponse.self, from: Data(#"{"device_id":"dev_1","org":{"id":"o"}}"#.utf8))) == nil, "decode: enrollment without device_token rejected")
    let di = try dec.decode(DeviceInfo.self, from: Data(#"{"settings":{"lan_mode":false}}"#.utf8))
    check(!di.settings.lanMode && di.name.isEmpty && di.tags.isEmpty, "decode: GET /v1/device with only settings")
    let sr = try dec.decode(SessionResponse.self, from: Data(#"{"session_id":"ses_1","relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t","host":{"public_key":"\#(key)"}}"#.utf8))
    check(RelayPin(sr)?.hostName == "the computer" && sr.permissions == .none, "decode: session without host.name/permissions -> defaults")
    check((try? dec.decode(SessionResponse.self, from: Data(#"{"session_id":"ses_1","relay_url":"wss://g.example.com/v1/relay/ses_1","host":{"public_key":"\#(key)"}}"#.utf8))) == nil,
          "decode: session without ticket rejected")
    let hosts = try dec.decode(HostsResponse.self, from: Data(#"{"hosts":[{"id":"dev_h","name":"Evil‮ Mac","tags":["a​b"]}]}"#.utf8))
    check(hosts.hosts[0].name == "Evil Mac" && hosts.hosts[0].tags == ["ab"], "decode: host names and tags cleaned for display")

    // The hub client turns a rejected offer into an event; the host answers policy.
    let lock = NSLock()
    var events: [HubEvent] = []
    var sockets: [FakeSocket] = []
    let hub = HubClient(request: { URLRequest(url: URL(string: "wss://g.example.com/v1/hub")!) },
                        factory: { r in let s = FakeSocket(request: r); lock.withLock { sockets.append(s) }; return s },
                        queue: DispatchQueue(label: "test.hub2"), schedule: { _, _ in }, random: { 0.5 })
    hub.onEvent = { e in lock.withLock { events.append(e) } }
    hub.start()
    _ = waitUntil { lock.withLock { sockets.count == 1 } }
    lock.withLock { sockets[0] }.pushText(#"{"type":"session_offer","session_id":"ses_9","viewer":{"name":"V"},"ticket":"t"}"#)
    check(waitUntil { lock.withLock { events.contains { if case .invalidOffer("ses_9", _) = $0 { return true }; return false } } },
          "hub: an offer missing a security field -> invalidOffer(session id) for a policy decline")
    hub.stop()

    // A session answer missing a security field: rejected, and the viewer ends the session.
    let t = ScriptTransport { r in
        switch (r.httpMethod ?? "", r.url?.path ?? "") {
        case ("POST", "/v1/sessions"): return (201, #"{"session_id":"ses_5","relay_url":"wss://g.example.com/v1/relay/ses_5","host":{"public_key":"\#(key)"}}"#)
        case ("POST", "/v1/sessions/ses_5/end"): return (204, "")
        default: return (404, "")
        }
    }
    let c = CloudClient(baseURL: URL(string: "https://g.example.com")!, deviceToken: "gd", userToken: "gu", transport: t)
    if case .failure = blocking({ try await c.createSession(hostId: "dev_h") }) {
        check(t.count("POST", "/v1/sessions/ses_5/end") == 1, "client: an invalid session answer is rejected and ended (/end)")
    } else { check(false, "client: invalid session answer rejected") }
}

// MARK: 5, 7. Offers: busy, prompt outcome, grant lifetime

func offerReviewTests() {
    let now = Date()
    check(OfferDecision.afterPrompt(accepted: true, reason: "", expiresAt: CloudTime.format(now.addingTimeInterval(30)), busy: false, now: now) == .accept,
          "prompt: accepted in time -> accept")
    check(OfferDecision.afterPrompt(accepted: true, reason: "", expiresAt: CloudTime.format(now.addingTimeInterval(-1)), busy: false, now: now) == .decline("timeout"),
          "prompt: accepted after expires_at -> timeout")
    check(OfferDecision.afterPrompt(accepted: true, reason: "", expiresAt: nil, busy: true, now: now) == .decline("busy"),
          "prompt: a session started meanwhile -> busy")
    check(OfferDecision.afterPrompt(accepted: false, reason: "declined", expiresAt: nil, busy: false) == .decline("declined")
          && OfferDecision.afterPrompt(accepted: false, reason: "timeout", expiresAt: nil, busy: false) == .decline("timeout"),
          "prompt: Decline -> declined, no answer in 50 s -> timeout")
}

func grantLifetimeTests() {
    let key = String(repeating: "07", count: 32)
    func offer(expires: Date) -> SessionOffer {
        try! JSONDecoder().decode(SessionOffer.self, from: Data(#"{"session_id":"ses_1","viewer":{"public_key":"\#(key)"},"relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t","expires_at":"\#(CloudTime.format(expires))"}"#.utf8))
    }
    let received = Date(timeIntervalSince1970: 1_800_000_000)
    let accepted = received.addingTimeInterval(40)  // after a 40 s prompt
    let g1 = SessionGrant(offer: offer(expires: received.addingTimeInterval(3600)), now: accepted)
    check(g1.map { abs($0.expiresAt.timeIntervalSince(accepted) - 120) < 1 } == true, "grant: lifetime starts at acceptance (accept + 120 s)")
    let g2 = SessionGrant(offer: offer(expires: received.addingTimeInterval(60)), now: accepted)
    check(g2.map { abs($0.expiresAt.timeIntervalSince(received.addingTimeInterval(60))) < 1 } == true, "grant: …capped at expires_at when that is earlier")
    let o = offer(expires: received.addingTimeInterval(60))
    check(OfferDecision.decide(o, cloudURL: URL(string: "https://g.example.com")!, busy: false, paused: false, updateRequired: false, now: received.addingTimeInterval(61)) == .decline("timeout"),
          "offer: expired -> timeout")
}

// MARK: 4. View only

func viewOnlyTests() {
    let viewOnly = CloudPermissions(control: false, clipboard: .both, files: .both, audio: true)
    check(!ManagedPermissions.hostAdaptsDisplay(viewOnly) && ManagedPermissions.hostAdaptsDisplay(.full) && ManagedPermissions.hostAdaptsDisplay(nil),
          "view only: the viewer's size never changes this Mac's display mode (LAN and control sessions do)")
    check(ManagedPermissions.hostAccepts(.viewSize(w: 1920, h: 1080), viewOnly), "view only: ViewSize still accepted (scaling)")
    check(!ManagedPermissions.hostAccepts(.setDisplayPreference(mode: 1), viewOnly) && !ManagedPermissions.viewerMaySend(.setDisplayPreference(mode: 1), viewOnly),
          "view only: no SetDisplayPreference either way")
}

// MARK: 8. Enrollment retries

func enrollRetryTests() {
    check(EnrollRetry.isFinal(.http(status: 401, code: "invalid_enrollment_token", message: "")) && EnrollRetry.isFinal(.http(status: 409, code: "device_revoked", message: "")),
          "enroll: final on 401 invalid_enrollment_token and 409 device_revoked")
    for e: CloudError in [.http(status: 401, code: "unauthorized", message: ""), .http(status: 403, code: "token_expired", message: ""),
                          .http(status: 400, code: "invalid_request", message: ""), .http(status: 429, code: "rate_limited", message: ""),
                          .http(status: 500, code: "http_500", message: ""), .http(status: 409, code: "conflict", message: ""), .transport("offline")] {
        check(!EnrollRetry.isFinal(e), "enroll: \(e) is retried")
    }
    var b = EnrollRetry.backoff()
    let seq = (0..<10).map { _ in b.next(random: 0.5) }
    check(seq == [5, 10, 20, 40, 80, 160, 320, 600, 600, 600], "enroll: backoff 5 s doubling to 10 min (\(seq))")
    var j = EnrollRetry.backoff()
    check(abs(j.next(random: 0) - 4) < 1e-9 && abs(j.next(random: 0.999999) - 12) < 1e-3, "enroll: ±20 % jitter")
    // Through CloudDevice: a 500 keeps retrying; an old guessed code is no longer final.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-enrollretry-\(getpid())")
    defer { try? FileManager.default.removeItem(at: dir) }
    let cfg = ManagedConfig.read(DictionarySource(["CloudURL": "https://g.example.com", "EnrollmentToken": "enr_x"]))
    func run(_ status: Int, _ code: String) -> CloudDevice.State {
        let t = ScriptTransport { _ in (status, #"{"error":{"code":"\#(code)","message":""}}"#) }
        let d = CloudDevice(kind: .host, publicKey: Data(repeating: 1, count: 32), store: EnrollmentStore.file(for: .host, in: dir), config: cfg,
                            transport: t, wsFactory: { _ in FakeSocket() })
        d.start()
        _ = waitUntil { d.queue.sync { if case .failed = d.status.state { return true }; return false } }
        let st = d.queue.sync { d.status.state }
        d.stop()
        return st
    }
    if case .failed(_, final: true) = run(401, "invalid_enrollment_token") { check(true, "enroll: invalid_enrollment_token stops for good") } else { check(false, "enroll: 401 final") }
    if case .failed(_, final: false) = run(401, "token_expired") { check(true, "enroll: a guessed code (token_expired) is retried") } else { check(false, "enroll: token_expired retried") }
    if case .failed(_, final: false) = run(503, "unavailable") { check(true, "enroll: 503 is retried") } else { check(false, "enroll: 503 retried") }
}

// MARK: 9. Device-code polling

func devicePollTests() {
    check(DeviceAuthPoll.next(after: .http(status: 503, code: "http_503", message: ""), interval: 5) == .retry(after: 10)
          && DeviceAuthPoll.next(after: .http(status: 429, code: "rate_limited", message: ""), interval: 5, failures: 1) == .retry(after: 20)
          && DeviceAuthPoll.next(after: .http(status: 500, code: "x", message: ""), interval: 5, failures: 9) == .retry(after: 60)
          && DeviceAuthPoll.next(after: .transport("x"), interval: 90, failures: 3) == .retry(after: 90),
          "poll: network, 429 and 5xx retry at least interval apart, backing off")
    for e: CloudError in [.http(status: 401, code: "unauthorized", message: ""), .http(status: 404, code: "not_found", message: ""),
                          .http(status: 400, code: "invalid_request", message: ""), .decoding("x")] {
        if case .failed = DeviceAuthPoll.next(after: e, interval: 5) { check(true, "poll: \(e) stops polling") } else { check(false, "poll: \(e) stops") }
    }
    let start = try! JSONDecoder().decode(DeviceAuthStart.self, from: Data(#"{"device_code":"dc","user_code":"U","verification_uri":"https://g.example.com/auth/device","interval":5,"expires_in":600}"#.utf8))
    func poll(_ script: [(Int, String)?]) -> (Result<DeviceTokenResponse, CloudError>, [TimeInterval], Int) {
        var i = 0
        let t = ScriptTransport { _ in defer { i += 1 }; return i < script.count ? script[i] : (503, "") }
        let c = CloudClient(baseURL: URL(string: "https://g.example.com")!, deviceToken: "gd", transport: t)
        let lock = NSLock()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var sleeps: [TimeInterval] = []
        let r = blocking { await DeviceAuthPoll.run(client: c, start: start, isCancelled: { false }, now: { lock.withLock { clock } },
                                                     sleep: { d in lock.withLock { sleeps.append(d); clock = clock.addingTimeInterval(d) } }) }
        return ((try? r.get()) ?? .failure(.invalid("threw")), lock.withLock { sleeps }, t.all.count)
    }
    let ok = #"{"user_token":"gu_x","expires_in":3600,"user":{"id":"u","email":"e@x.com","name":"E"}}"#
    let (r1, s1, n1) = poll([(503, ""), (429, ""), nil, (400, #"{"error":{"code":"authorization_pending","message":""}}"#), (200, ok)])
    check((try? r1.get())?.userToken == "gu_x" && n1 == 5 && s1 == [5, 10, 20, 40, 5], "poll: 503, 429, offline retried with backoff, then approved (\(s1))")
    let (r2, _, n2) = poll([(404, "")])
    if case .failure = r2, n2 == 1 { check(true, "poll: a 404 stops at once") } else { check(false, "poll: 404 stops") }
    let (r3, _, _) = poll([(401, "")])
    if case let .failure(e) = r3, e.isUnauthorized { check(true, "poll: a 401 comes back as is (the device was revoked)") } else { check(false, "poll: 401 as is") }
    let (r4, s4, n4) = poll([])
    if case .failure = r4, s4.allSatisfy({ $0 >= 5 }), s4.reduce(0, +) >= 600, n4 < 30 { check(true, "poll: retries stop at expires_in (\(n4) attempts)") }
    else { check(false, "poll: expires_in (\(s4))") }
}

// MARK: 10. Audit drops

func auditDropTests() {
    check(AuditReporter.isRejected(.http(status: 400, code: "invalid_request", message: "")) && AuditReporter.isRejected(.http(status: 403, code: "x", message: ""))
          && !AuditReporter.isRejected(.http(status: 401, code: "unauthorized", message: "")) && !AuditReporter.isRejected(.http(status: 429, code: "x", message: ""))
          && !AuditReporter.isRejected(.http(status: 503, code: "x", message: "")) && !AuditReporter.isRejected(.transport("x")),
          "audit: 4xx other than 401/429 = rejected for good")
    func run(_ e: CloudError) -> (queued: Int, sends: Int, logged: Bool) {
        let lock = NSLock()
        var sends = 0, logged = false
        let r = AuditReporter(delay: 0.01) { _ in lock.withLock { sends += 1 }; throw e }
        r.log = { _ in lock.withLock { logged = true } }
        r.error(code: "relay_failed", message: "x", sessionId: "ses_1")
        _ = waitUntil { lock.withLock { sends >= 1 } }
        usleep(100_000)
        return (r.queuedCount, lock.withLock { sends }, lock.withLock { logged })
    }
    let bad = run(.http(status: 400, code: "invalid_request", message: ""))
    check(bad.queued == 0 && bad.sends == 1 && bad.logged, "audit: a batch rejected with 400 is dropped, logged, not retried")
    for e: CloudError in [.http(status: 401, code: "unauthorized", message: ""), .http(status: 429, code: "x", message: ""), .http(status: 502, code: "x", message: ""), .transport("x")] {
        let r = run(e)
        check(r.queued == 1 && !r.logged, "audit: \(e) keeps the batch for a retry")
    }
}

// MARK: 11. Viewer LAN gate

func viewerLANGateTests() {
    let on = ManagedPolicy(settings: OrgSettings(), disableLANMode: false, appVersion: "1")
    let noPair = ManagedPolicy(settings: OrgSettings(allowLocalPairing: false), disableLANMode: false, appVersion: "1")
    let noLAN = ManagedPolicy(settings: OrgSettings(lanMode: false), disableLANMode: false, appVersion: "1")
    check(ViewerLANGate.mayPair(managedSession: false, policy: on) && !ViewerLANGate.mayPair(managedSession: false, policy: noPair)
          && !ViewerLANGate.mayPair(managedSession: false, policy: noLAN) && !ViewerLANGate.mayPair(managedSession: true, policy: on),
          "viewer: pairing only while allow_local_pairing and lan_mode allow it (never managed)")
    check(ViewerLANGate.mustEnd(managedSession: false, pairing: false, policy: noLAN) && !ViewerLANGate.mustEnd(managedSession: true, pairing: false, policy: noLAN),
          "viewer: lan_mode false ends a running LAN session at once, not a managed one")
    check(ViewerLANGate.mustEnd(managedSession: false, pairing: true, policy: noPair) && !ViewerLANGate.mustEnd(managedSession: false, pairing: false, policy: noPair)
          && !ViewerLANGate.mustEnd(managedSession: false, pairing: true, policy: on),
          "viewer: allow_local_pairing false ends a pairing in progress; paired sessions continue")
    check(ViewerLANGate.mustEnd(managedSession: false, pairing: false, policy: ManagedPolicy(settings: nil, disableLANMode: true, appVersion: "1")),
          "viewer: DisableLANMode ends LAN sessions too")
}

// MARK: 12. client.error for relay failures

func relayFailureTests() {
    let sq = DispatchQueue(label: "test.relayfail")
    func closeWith(_ act: (FakeSocket, RelayBridge) -> Void) -> (failed: Bool, why: String?) {
        let lock = NSLock()
        let s = FakeSocket()
        let b = RelayBridge(socket: s)
        var result: (Bool, String)?
        b.onClosed = { [weak b] w in let f = b?.failed ?? false; lock.withLock { result = (f, w) } }
        b.start(sessionQueue: sq) { _ in }
        _ = waitUntil { s.started }
        act(s, b)
        _ = waitUntil { lock.withLock { result != nil } }
        return lock.withLock { (result?.0 ?? false, result?.1) }
    }
    check(closeWith { s, _ in s.fail(code: 4004) }.failed && closeWith { s, _ in s.fail(code: 4001) }.failed
          && closeWith { s, _ in s.fail(status: 401) }.failed && closeWith { s, _ in s.fail() }.failed,
          "relay: peer never joined, bad ticket, refused upgrade, lost connection = failures (client.error)")
    check(!closeWith { s, _ in s.fail(code: 1000) }.failed && !closeWith { s, _ in s.fail(code: 4003) }.failed
          && !closeWith { s, _ in s.fail(code: 4005) }.failed && !closeWith { _, b in b.close("ended by the viewer") }.failed,
          "relay: normal end, admin end, time limit and a local close are not failures")
    check(closeWith { s, _ in s.push(.success(.binary(Data([1])))) }.failed, "relay: a protocol violation is a failure")
    let lock = NSLock()
    var sent: [AuditEvent] = []
    let r = AuditReporter(delay: 0.01) { b in lock.withLock { sent += b.events } }
    r.error(code: "handshake_failed", message: "bad key", sessionId: "ses_1")
    check(waitUntil { lock.withLock { sent.first?.type == "client.error" && sent.first?.detail["code"] == .string("handshake_failed") && sent.first?.sessionId == "ses_1" } },
          "audit: client.error {code, message} with the session id")
}

// MARK: 14. Approval prompt text

func approvalTextTests() {
    let key = String(repeating: "07", count: 32)
    func offer(control: Bool) -> SessionOffer {
        try! JSONDecoder().decode(SessionOffer.self, from: Data(#"{"session_id":"ses_1","viewer":{"name":"Help‮desk\u0007","public_key":"\#(key)"},"user":{"name":"Ada⁦ L","email":"ada@example.com"},"permissions":{"control":\#(control)},"relay_url":"wss://g.example.com/v1/relay/ses_1","ticket":"t"}"#.utf8))
    }
    let full = ApprovalText.body(offer(control: true), orgName: "Example\u{202E} Corp")
    let view = ApprovalText.body(offer(control: false), orgName: nil)
    check(full.contains("asked to see and control this Mac") && view.contains("asked to see this Mac (view only)") && !view.contains("control this Mac"),
          "prompt: \"see and control\" or \"see (view only)\" by permissions.control")
    let all = full + view + ApprovalText.title(offer(control: true))
    check(!all.unicodeScalars.contains { $0 != "\n" && CloudText.isRemoved($0) } && full.contains("“Helpdesk”") && full.contains("Example Corp's")
          && ApprovalText.title(offer(control: true)) == "Allow Ada L (ada@example.com) to connect to this Mac?",
          "prompt: user, viewer and org names are cleaned")
    check(view.contains("your organization's Glide Cloud"), "prompt: no org name -> your organization")
}

// MARK: 15. /end is idempotent

func endSessionTests() {
    let t = ScriptTransport { r in r.url?.path == "/v1/sessions/ses_gone/end" ? (404, #"{"error":{"code":"not_found","message":""}}"#) : (r.url?.path == "/v1/sessions/ses_err/end" ? (500, "") : (204, "")) }
    let c = CloudClient(baseURL: URL(string: "https://g.example.com")!, deviceToken: "gd", userToken: "gu", transport: t)
    if case .success = blocking({ try await c.endSession("ses_gone", as: .user) }), case .success = blocking({ try await c.endSession("ses_ok", as: .user) }) {
        check(true, "end: 204 and 404 both count as ended")
    } else { check(false, "end: 404 is fine") }
    if case .failure = blocking({ try await c.endSession("ses_err", as: .user) }) { check(true, "end: a 500 is still an error") } else { check(false, "end: 500") }
}

// MARK: 3. Revocation keeps the last settings

func revocationTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-revoke-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = Data(repeating: 0xcd, count: 32)
    let t = ScriptTransport { r in
        switch (r.httpMethod ?? "", r.url?.path ?? "") {
        case ("POST", "/v1/enroll"): return (201, #"{"device_id":"dev_v1","device_token":"gd_tok","org":{"id":"org_1","slug":"ex","name":"Example"},"settings":{"lan_mode":false,"allow_local_pairing":false}}"#)
        case ("GET", "/v1/device"): return (200, #"{"device_id":"dev_v1","name":"V","settings":{"lan_mode":false,"allow_local_pairing":false}}"#)
        case ("POST", "/v1/device/heartbeat"): return (204, "")
        default: return (404, "")
        }
    }
    let lock = NSLock()
    var socks: [FakeSocket] = []
    let cfg = ManagedConfig.read(DictionarySource(["CloudURL": "https://g.example.com", "EnrollmentToken": "enr_x"]))
    let store = EnrollmentStore.file(for: .viewer, in: dir)
    let dev = CloudDevice(kind: .viewer, publicKey: key, store: store, config: cfg, appVersion: "0.4.0", transport: t,
                          wsFactory: { r in let s = FakeSocket(request: r); lock.withLock { socks.append(s) }; return s })
    var revoked = false
    dev.onRevoked = { _ in lock.withLock { revoked = true } }
    dev.start()
    _ = waitUntil { lock.withLock { socks.count == 1 } }
    lock.withLock { socks[0] }.pushText(#"{"type":"revoked","reason":"device revoked"}"#)
    check(waitUntil { lock.withLock { revoked } }, "revoke: viewer told")
    let rec = store.loadRevoked()
    let raw = (try? JSONSerialization.jsonObject(with: Data(contentsOf: store.url))) as? [String: Any] ?? [:]
    check(rec?.revoked == true && rec?.cloudURL == "https://g.example.com" && rec?.settings?.lanMode == false && raw["device_token"] == nil
          && raw["revoked"] as? Bool == true, "revoke: {cloud_url, revoked: true, settings} kept, no credentials")
    check(dev.queue.sync { !dev.status.policy.lanAllowed && !dev.status.policy.localPairingAllowed }, "revoke: the last settings still apply (no setLANAllowed(true))")
    // A restart with the same CloudURL: still revoked, still LAN off, no enrollment attempt.
    let before = t.count("POST", "/v1/enroll")
    let again = CloudDevice(kind: .viewer, publicKey: key, store: store, config: cfg, transport: t, wsFactory: { _ in FakeSocket() })
    check(!again.status.policy.lanAllowed && { if case .revoked = again.status.state { return true }; return false }(), "revoke: applies across restarts from launch")
    again.start()
    usleep(200_000)
    check(t.count("POST", "/v1/enroll") == before && again.queue.sync { !again.status.policy.lanAllowed }, "revoke: no new enrollment while CloudURL is unchanged")
    // CloudURL changes: the record no longer applies; the device enrolls with the new cloud.
    let other = ManagedConfig.read(DictionarySource(["CloudURL": "https://other.example.com", "EnrollmentToken": "enr_y"]))
    let moved = CloudDevice(kind: .viewer, publicKey: key, store: store, config: other, transport: t, wsFactory: { _ in FakeSocket() })
    check(moved.status.policy.lanAllowed, "revoke: another CloudURL -> the old record no longer applies")
    moved.start()
    check(waitUntil { t.count("POST", "/v1/enroll") == before + 1 }, "revoke: another CloudURL enrolls again")
    moved.stop()
    // Removed CloudURL: unmanaged, LAN allowed.
    let gone = CloudDevice(kind: .viewer, publicKey: key, store: EnrollmentStore.file(for: .viewer, in: dir), config: ManagedConfig(), transport: t, wsFactory: { _ in FakeSocket() })
    check(gone.status.policy.lanAllowed, "revoke: CloudURL removed -> unmanaged, LAN allowed")
    dev.stop(); again.stop()
}

// MARK: 13. GET /v1/device on each hub connection

func deviceRefreshTests() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("glide-refresh-\(getpid())-\(UInt32.random(in: 0...UInt32.max))")
    defer { try? FileManager.default.removeItem(at: dir) }
    let lock = NSLock()
    var gets = 0
    var unauthorized = false
    let t = ScriptTransport { r in
        switch (r.httpMethod ?? "", r.url?.path ?? "") {
        case ("POST", "/v1/enroll"): return (201, #"{"device_id":"dev_h1","device_token":"gd_tok","org":{"id":"org_1","name":"Example"},"settings":{}}"#)
        case ("GET", "/v1/device"):
            return lock.withLock {
                if unauthorized { return (401, #"{"error":{"code":"unauthorized","message":""}}"#) }
                gets += 1
                return (200, #"{"device_id":"dev_h1","name":"Desk \#(gets)","tags":["t\#(gets)","‮owner"],"org":{"id":"org_1","name":"Example Corp \#(gets)"},"settings":{"lan_mode":false}}"#)
            }
        case ("POST", "/v1/device/heartbeat"): return (204, "")
        default: return (404, "")
        }
    }
    var socks: [FakeSocket] = []
    let cfg = ManagedConfig.read(DictionarySource(["CloudURL": "https://g.example.com", "EnrollmentToken": "enr_x"]))
    let store = EnrollmentStore.file(for: .host, in: dir)
    let dev = CloudDevice(kind: .host, publicKey: Data(repeating: 2, count: 32), store: store, config: cfg, transport: t,
                          wsFactory: { r in let s = FakeSocket(request: r); lock.withLock { socks.append(s) }; return s })
    dev.start()
    _ = waitUntil { lock.withLock { socks.count == 1 } }
    lock.withLock { socks[0] }.pushText(#"{"type":"hello","device_id":"dev_h1","settings":{"lan_mode":false}}"#)
    check(waitUntil { dev.queue.sync { dev.status.tags == ["t1", "owner"] && dev.status.deviceName == "Desk 1" && dev.status.orgName == "Example Corp 1" } },
          "refresh: GET /v1/device on connecting -> name, tags (cleaned) and org name")
    check((try? store.load())?.tags == ["t1", "owner"], "refresh: tags kept in the enrollment")
    lock.withLock { socks[0] }.fail(code: 1006)
    check(waitUntil(4) { lock.withLock { socks.count == 2 } }, "refresh: hub reconnects")
    lock.withLock { socks[1] }.pushText(#"{"type":"hello","device_id":"dev_h1","settings":{"lan_mode":false}}"#)
    check(waitUntil { dev.queue.sync { dev.status.tags.first == "t2" && dev.status.orgName == "Example Corp 2" } } && lock.withLock { gets } == 2,
          "refresh: …and again on each hub connection")
    // A 401 on GET /v1/device: revoked, last settings kept.
    lock.withLock { unauthorized = true }
    lock.withLock { socks[1] }.fail(code: 1006)
    _ = waitUntil(4) { lock.withLock { socks.count == 3 } }
    lock.withLock { socks.last }?.pushText(#"{"type":"hello","device_id":"dev_h1","settings":{"lan_mode":false}}"#)
    check(waitUntil(4) { dev.queue.sync { if case .revoked = dev.status.state { return true }; return false } }
          && dev.queue.sync { !dev.status.policy.lanAllowed } && store.loadRevoked()?.settings?.lanMode == false,
          "refresh: 401 on GET /v1/device = revoked, last settings kept")
    dev.stop()
}
