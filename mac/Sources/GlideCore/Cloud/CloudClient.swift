import Foundation

/// Sends one HTTP request. The app uses `URLSessionTransport`; tests use a fake.
public protocol CloudHTTPTransport: AnyObject, Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` with the system proxy settings and trust store (an org's TLS-inspection root
/// works, ENTERPRISE.md §3.3), TLS 1.2+, no cookies or cache, and no redirects: the API never
/// redirects, and a redirect must not carry the device bearer token to another host.
public final class URLSessionTransport: NSObject, CloudHTTPTransport, URLSessionTaskDelegate, @unchecked Sendable {
    public static let shared = URLSessionTransport()
    public private(set) var session: URLSession!

    public override init() {
        super.init()
        session = URLSession(configuration: Self.configuration(), delegate: self, delegateQueue: nil)
    }

    public static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.tlsMinimumSupportedProtocolVersion = .TLSv12
        c.httpCookieAcceptPolicy = .never
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.timeoutIntervalForRequest = 30
        c.waitsForConnectivity = false
        c.httpAdditionalHeaders = ["User-Agent": "Glide/\(GlideVersion.version) (macOS)"]
        return c
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (d, r) = try await session.data(for: request)
        guard let h = r as? HTTPURLResponse else { throw CloudError.transport("not an HTTP response") }
        return (d, h)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum CloudError: Error, Equatable, CustomStringConvertible {
    /// Any non-2xx answer with its error code (`host_offline`, `not_allowed`, …).
    case http(status: Int, code: String, message: String)
    case transport(String)
    case decoding(String)
    case invalid(String)

    public var status: Int? { if case let .http(s, _, _) = self { return s }; return nil }
    public var code: String? { if case let .http(_, c, _) = self { return c }; return nil }
    public var isUnauthorized: Bool { status == 401 }

    public var description: String {
        switch self {
        case let .http(s, c, m): return m.isEmpty ? "\(c) (HTTP \(s))" : "\(m) (\(c))"
        case let .transport(s): return "can't reach Glide Cloud: \(s)"
        case let .decoding(s): return "unexpected answer from Glide Cloud: \(s)"
        case let .invalid(s): return s
        }
    }

    /// Plain words for the session errors of `POST /v1/sessions` (§6.2).
    public var sessionText: String {
        switch code {
        case "not_allowed": return "You are not allowed to connect to this computer."
        case "host_offline": return "The computer is not connected to Glide Cloud right now."
        case "denied_by_host": return "The person at the computer declined the session."
        case "host_busy": return "The computer is busy with another session."
        case "host_no_answer": return "The computer didn't answer in time."
        case "update_required": return "Glide needs an update before it can connect."
        default: return description
        }
    }
}

/// The device API (ENTERPRISE.md §6.2). Device calls send `Authorization: Bearer gd_…`; user calls
/// also send `X-Glide-User: gu_…`.
public final class CloudClient: @unchecked Sendable {
    public let baseURL: URL
    public let transport: CloudHTTPTransport
    private let lock = NSLock()
    private var deviceTokenValue: String?
    private var userTokenValue: String?

    public var deviceToken: String? {
        get { lock.withLock { deviceTokenValue } }
        set { lock.withLock { deviceTokenValue = newValue } }
    }
    public var userToken: String? {
        get { lock.withLock { userTokenValue } }
        set { lock.withLock { userTokenValue = newValue } }
    }

    public init(baseURL: URL, deviceToken: String? = nil, userToken: String? = nil, transport: CloudHTTPTransport = URLSessionTransport.shared) {
        self.baseURL = baseURL
        self.transport = transport
        self.deviceTokenValue = deviceToken
        self.userTokenValue = userToken
    }

    public enum Auth { case none, device, user }

    /// Builds a request for `path` (starting with `/v1/`).
    public func request(_ method: String, _ path: String, auth: Auth, body: Data? = nil, timeout: TimeInterval? = nil) throws -> URLRequest {
        guard let url = URL(string: baseURL.absoluteString + path) else { throw CloudError.invalid("bad path \(path)") }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            r.httpBody = body
            r.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        }
        if let timeout { r.timeoutInterval = timeout }
        switch auth {
        case .none: break
        case .device, .user:
            guard let t = deviceToken else { throw CloudError.invalid("this device is not enrolled") }
            r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            if auth == .user {
                guard let u = userToken else { throw CloudError.invalid("not signed in") }
                r.setValue(u, forHTTPHeaderField: "X-Glide-User")
            }
        }
        return r
    }

    /// Sends and checks the status; returns the body of a 2xx answer.
    @discardableResult
    public func call(_ method: String, _ path: String, auth: Auth, body: Data? = nil, timeout: TimeInterval? = nil) async throws -> Data {
        let req = try request(method, path, auth: auth, body: body, timeout: timeout)
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await transport.send(req) } catch let e as CloudError { throw e } catch {
            throw CloudError.transport((error as NSError).localizedDescription)
        }
        guard (200..<300).contains(resp.statusCode) else { throw Self.error(status: resp.statusCode, body: data) }
        return data
    }

    public static func error(status: Int, body: Data) -> CloudError {
        if let env = try? JSONDecoder().decode(CloudErrorEnvelope.self, from: body) {
            return .http(status: status, code: env.error.code, message: env.error.message)
        }
        return .http(status: status, code: status == 401 ? "unauthorized" : "http_\(status)", message: "")
    }

    func decode<T: Decodable>(_ t: T.Type, _ d: Data) throws -> T {
        do { return try JSONDecoder().decode(t, from: d) } catch { throw CloudError.decoding("\(T.self): \(error)") }
    }

    func encode<T: Encodable>(_ v: T) throws -> Data {
        do { return try JSONEncoder.cloud.encode(v) } catch { throw CloudError.invalid("\(error)") }
    }

    // MARK: Endpoints

    public func enroll(_ r: EnrollRequest) async throws -> EnrollResponse {
        try decode(EnrollResponse.self, try await call("POST", "/v1/enroll", auth: .none, body: try encode(r)))
    }

    public func device() async throws -> DeviceInfo {
        try decode(DeviceInfo.self, try await call("GET", "/v1/device", auth: .device))
    }

    public func heartbeat(_ r: HeartbeatRequest) async throws {
        try await call("POST", "/v1/device/heartbeat", auth: .device, body: try encode(r))
    }

    public func audit(_ b: AuditBatch) async throws {
        try await call("POST", "/v1/audit", auth: .device, body: try encode(b))
    }

    public func deviceAuthStart() async throws -> DeviceAuthStart {
        try decode(DeviceAuthStart.self, try await call("POST", "/v1/auth/device/start", auth: .device, body: Data("{}".utf8)))
    }

    public func deviceAuthToken(deviceCode: String) async throws -> DeviceTokenResponse {
        try decode(DeviceTokenResponse.self, try await call("POST", "/v1/auth/device/token", auth: .device, body: try encode(DeviceTokenRequest(deviceCode: deviceCode))))
    }

    public func signOut() async throws {
        try await call("POST", "/v1/auth/signout", auth: .user, body: Data("{}".utf8))
    }

    public func me() async throws -> MeResponse {
        try decode(MeResponse.self, try await call("GET", "/v1/me", auth: .user))
    }

    public func hosts() async throws -> [CloudHost] {
        try decode(HostsResponse.self, try await call("GET", "/v1/hosts", auth: .user)).hosts
    }

    /// Waits for the host's answer: up to 60 s with approval (§5.3), so the request may take 75 s.
    public func createSession(hostId: String, viewOnly: Bool = false) async throws -> SessionResponse {
        guard CloudID.isValid(hostId) else { throw CloudError.invalid("bad host id") }
        let body = try encode(SessionRequest(hostId: hostId, viewOnly: viewOnly ? true : nil))
        return try decode(SessionResponse.self, try await call("POST", "/v1/sessions", auth: .user, body: body, timeout: 75))
    }

    /// `as`: `.user` for the session's viewer, `.device` for its host.
    public func endSession(_ id: String, as auth: Auth) async throws {
        guard CloudID.isValid(id) else { throw CloudError.invalid("bad session id") }
        try await call("POST", "/v1/sessions/\(id)/end", auth: auth, body: Data("{}".utf8))
    }

    /// The hub socket request (`GET /v1/hub`, device bearer).
    public func hubRequest() throws -> URLRequest {
        guard let url = RelayEndpoint.webSocketURL(baseURL, path: "/v1/hub") else { throw CloudError.invalid("bad cloud URL") }
        var r = URLRequest(url: url)
        guard let t = deviceToken else { throw CloudError.invalid("this device is not enrolled") }
        r.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        r.timeoutInterval = 30
        return r
    }
}

/// The viewer's polling of `POST /v1/auth/device/token` (RFC 8628 §3.5).
public enum DeviceAuthPoll: Equatable {
    case keepPolling(interval: TimeInterval)
    case failed(String)

    /// What to do after a poll failed with `error`; `interval` is the current interval.
    public static func next(after error: CloudError, interval: TimeInterval) -> DeviceAuthPoll {
        switch error.code {
        case "authorization_pending": return .keepPolling(interval: interval)
        case "slow_down": return .keepPolling(interval: interval + 5)
        case "expired_token": return .failed("The sign-in code expired. Start again.")
        case "access_denied": return .failed("Sign-in was denied.")
        default:
            if case .transport = error { return .keepPolling(interval: interval) }  // a network hiccup: try again
            return .failed(error.description)
        }
    }

    /// Polls until approved, failed, expired (`expiresIn`) or `isCancelled()`.
    public static func run(client: CloudClient, start: DeviceAuthStart, isCancelled: @escaping () -> Bool) async -> Result<DeviceTokenResponse, CloudError> {
        var interval = TimeInterval(max(start.interval, 1))
        let deadline = Date().addingTimeInterval(TimeInterval(max(start.expiresIn, 30)))
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1e9))
            if isCancelled() { return .failure(.invalid("cancelled")) }
            do {
                return .success(try await client.deviceAuthToken(deviceCode: start.deviceCode))
            } catch let e as CloudError {
                switch next(after: e, interval: interval) {
                case let .keepPolling(i): interval = i
                case let .failed(why): return .failure(.invalid(why))
                }
            } catch {
                return .failure(.transport("\(error)"))
            }
        }
        return .failure(.invalid("The sign-in code expired. Start again."))
    }
}

/// This Mac, for enrollment and heartbeats.
public enum DeviceFacts {
    public static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    public static var computerName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }
}
