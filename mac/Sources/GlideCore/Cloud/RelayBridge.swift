import Foundation
import Network

// The client side of a relayed session (docs/ENTERPRISE.md §6.5–6.6): the relay WebSocket, and a
// loopback TCP pair that lets the unchanged session code (Noise XX, records) run over it.

/// Two connected loopback TCP sockets (§6.6 step 1): bind 127.0.0.1:0, connect to it, accept,
/// and check that the accepted socket's peer port is the connecting socket's local port (else
/// another local process won the race: close both and retry). The listener is closed afterwards.
public enum LoopbackPair {
    public enum Failure: Error, CustomStringConvertible {
        case listener(String), timeout, raceLost
        public var description: String {
            switch self {
            case let .listener(s): return "loopback listener failed: \(s)"
            case .timeout: return "loopback connection timed out"
            case .raceLost: return "another local process connected to the loopback bridge"
            }
        }
    }

    /// The §6.6 check: both ports known and equal.
    public static func peerMatches(acceptedRemotePort: UInt16?, dialedLocalPort: UInt16?) -> Bool {
        guard let a = acceptedRemotePort, let d = dialedLocalPort, a != 0 else { return false }
        return a == d
    }

    static func port(_ e: NWEndpoint?) -> UInt16? {
        if case let .hostPort(_, p)? = e { return p.rawValue }
        return nil
    }

    static func isLoopback(_ e: NWEndpoint?) -> Bool {
        guard case let .hostPort(h, _)? = e else { return false }
        switch h {
        case let .ipv4(a): return a == .loopback
        case let .ipv6(a): return a == .loopback || a.asIPv4 == .loopback
        default: return "\(h)" == "127.0.0.1" || "\(h)" == "localhost"
        }
    }

    /// `dialed` is started on `sessionQueue` (the session code reads it there); `accepted` on
    /// `bridgeQueue`. `peerCheck` replaces the port comparison (tests).
    public static func make(sessionQueue: DispatchQueue, bridgeQueue: DispatchQueue, attempts: Int = 3, timeout: TimeInterval = 5,
                            peerCheck: ((UInt16?, UInt16?) -> Bool)? = nil,
                            completion: @escaping (Result<(dialed: NWConnection, accepted: NWConnection), Error>) -> Void) {
        let attempt = Attempt(sessionQueue: sessionQueue, bridgeQueue: bridgeQueue, timeout: timeout, peerCheck: peerCheck ?? peerMatches)
        attempt.run { r in
            if case .failure(Failure.raceLost) = r, attempts > 1 {
                make(sessionQueue: sessionQueue, bridgeQueue: bridgeQueue, attempts: attempts - 1, timeout: timeout, peerCheck: peerCheck, completion: completion)
            } else {
                completion(r)
            }
        }
    }

    /// One try; all state on `bridgeQueue`.
    private final class Attempt: @unchecked Sendable {
        let sessionQueue: DispatchQueue, q: DispatchQueue, timeout: TimeInterval
        let peerCheck: (UInt16?, UInt16?) -> Bool
        var listener: NWListener?
        var dialed: NWConnection?
        var accepted: NWConnection?
        var dialedReady = false, acceptedReady = false
        var done = false
        var completion: ((Result<(dialed: NWConnection, accepted: NWConnection), Error>) -> Void)?
        /// Keeps the attempt alive until it finishes (its callbacks hold it weakly).
        var keepAlive: Attempt?

        init(sessionQueue: DispatchQueue, bridgeQueue: DispatchQueue, timeout: TimeInterval, peerCheck: @escaping (UInt16?, UInt16?) -> Bool) {
            self.sessionQueue = sessionQueue; self.q = bridgeQueue; self.timeout = timeout; self.peerCheck = peerCheck
        }

        static func params() -> NWParameters {
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let p = NWParameters(tls: nil, tcp: tcp)
            p.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            p.allowLocalEndpointReuse = false
            return p
        }

        func run(_ completion: @escaping (Result<(dialed: NWConnection, accepted: NWConnection), Error>) -> Void) {
            self.completion = completion
            keepAlive = self
            q.async { [self] in
                let l: NWListener
                do { l = try NWListener(using: Self.params()) } catch { finish(.failure(Failure.listener("\(error)"))); return }
                listener = l
                l.newConnectionHandler = { [weak self] c in self?.incoming(c) }
                l.stateUpdateHandler = { [weak self] st in
                    guard let self else { return }
                    switch st {
                    case .ready: self.dial()
                    case let .failed(e): self.finish(.failure(Failure.listener("\(e)")))
                    default: break
                    }
                }
                l.start(queue: q)
                q.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish(.failure(Failure.timeout)) }
            }
        }

        func dial() {
            guard !done, dialed == nil, let port = listener?.port else { return }
            let tcp = NWProtocolTCP.Options()
            tcp.noDelay = true
            let c = NWConnection(host: .ipv4(.loopback), port: port, using: NWParameters(tls: nil, tcp: tcp))
            dialed = c
            c.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                self.q.async {
                    switch st {
                    case .ready: self.dialedReady = true; self.check()
                    case let .failed(e), let .waiting(e): self.finish(.failure(Failure.listener("connect: \(e)")))
                    default: break
                    }
                }
            }
            c.start(queue: sessionQueue)
        }

        func incoming(_ c: NWConnection) {
            // Only the first connection is ours to check; anything else is refused at once.
            guard !done, accepted == nil else { c.cancel(); return }
            accepted = c
            c.stateUpdateHandler = { [weak self] st in
                guard let self else { return }
                self.q.async {
                    switch st {
                    case .ready: self.acceptedReady = true; self.check()
                    case let .failed(e): self.finish(.failure(Failure.listener("accept: \(e)")))
                    default: break
                    }
                }
            }
            c.start(queue: q)
        }

        func check() {
            guard !done, dialedReady, acceptedReady, let d = dialed, let a = accepted else { return }
            let remote = a.currentPath?.remoteEndpoint ?? a.endpoint
            let local = d.currentPath?.localEndpoint
            guard LoopbackPair.isLoopback(remote), peerCheck(LoopbackPair.port(remote), LoopbackPair.port(local)) else {
                finish(.failure(Failure.raceLost))
                return
            }
            finish(.success((d, a)))
        }

        func finish(_ r: Result<(dialed: NWConnection, accepted: NWConnection), Error>) {
            guard !done else { return }
            done = true
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            if case .failure = r { dialed?.cancel(); accepted?.cancel() }
            dialed?.stateUpdateHandler = nil
            accepted?.stateUpdateHandler = nil
            let c = completion
            completion = nil
            keepAlive = nil
            c?(r)
        }
    }
}

/// One relayed session's byte pump (§6.5, §6.6). Opens the relay socket, waits for
/// `peer_joined` (sending nothing before it), then builds the loopback pair, hands the dialed end
/// to `ready`, and pumps: socket → binary frames (reads of ≤ 256 KiB, one frame each), binary
/// frames → socket, in order and with backpressure. Either side closing closes both.
public final class RelayBridge: @unchecked Sendable {
    public static let readMax = 256 * 1024
    public static let frameMax = 1 << 20
    /// Relay bytes that may wait for the loopback pair right after `peer_joined`.
    public static let bufferMax = 8 << 20

    public enum Status: Equatable { case connecting, waiting, joined }

    public let queue: DispatchQueue
    private let socket: CloudWebSocket
    private var accepted: NWConnection?
    private weak var dialed: NWConnection?
    private var joined = false
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var closed = false
    /// Who closed first, for the log and audit.
    public private(set) var closeReason: String?
    /// The bridge closed because something went wrong (relay refused or lost, protocol violation,
    /// the other side never joined…), not because a side ended the session: the apps report it as
    /// `client.error` (§6.7). Set before `onClosed` runs.
    public private(set) var failed = false
    public private(set) var bytesToRelay: UInt64 = 0
    public private(set) var bytesFromRelay: UInt64 = 0

    public var onStatus: (Status) -> Void = { _ in }
    /// Called once, on `queue`, when the bridge is closed for good.
    public var onClosed: (String) -> Void = { _ in }
    /// Test hook for the loopback race check.
    public var peerCheck: ((UInt16?, UInt16?) -> Bool)?

    public init(socket: CloudWebSocket, queue: DispatchQueue = DispatchQueue(label: "glide.cloud.relay", qos: .userInteractive)) {
        self.socket = socket
        self.queue = queue
    }

    /// `ready` (on `queue`) receives the loopback connection for the session code, already
    /// connected and started on `sessionQueue`.
    public func start(sessionQueue: DispatchQueue, ready: @escaping (NWConnection) -> Void) {
        queue.async { [self] in
            onStatus(.connecting)
            socket.start()
            receive(sessionQueue: sessionQueue, ready: ready)
        }
    }

    /// Ends the bridge (the relay socket with 1000, the loopback pair).
    public func close(_ reason: String = "closed locally") {
        queue.async { [self] in shutdown(reason, code: RelayCloseCode.normal, failure: false) }
    }

    public var isClosed: Bool { queue.sync { closed } }

    private func receive(sessionQueue: DispatchQueue, ready: @escaping (NWConnection) -> Void) {
        socket.receive { [weak self] r in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                switch r {
                case let .failure(e):
                    let why: String
                    var failure = true
                    if let st = self.socket.upgradeStatus { why = "the relay refused the connection (HTTP \(st))" }
                    else if let c = self.socket.closeCode { why = RelayCloseCode.text(c); failure = !RelayBridge.isOrderlyClose(c) }
                    else { why = "relay connection lost (\((e as NSError).localizedDescription))" }
                    self.shutdown(why, code: nil, failure: failure)
                case let .success(.text(t)):
                    switch RelayControl.decode(t) {
                    case .waiting?: self.onStatus(.waiting)
                    case .peerJoined? where !self.joined:
                        self.joined = true
                        self.onStatus(.joined)
                        self.makePair(sessionQueue: sessionQueue, ready: ready)
                    case .peerLeft?:
                        self.shutdown("the other side left", code: RelayCloseCode.normal, failure: false)
                        return
                    default: break  // unknown control frames are ignored
                    }
                    self.receive(sessionQueue: sessionQueue, ready: ready)
                case let .success(.binary(d)):
                    guard self.joined, d.count <= RelayBridge.frameMax else {
                        self.shutdown(self.joined ? "relay frame too large" : "relay protocol violation (data before peer_joined)", code: RelayCloseCode.normal)
                        return
                    }
                    self.bytesFromRelay += UInt64(d.count)
                    if let a = self.accepted {
                        // Backpressure: the next frame is read once this one is in the socket.
                        a.send(content: d, completion: .contentProcessed { [weak self] err in
                            guard let self else { return }
                            self.queue.async {
                                if err != nil { self.shutdown("loopback write failed", code: RelayCloseCode.normal); return }
                                self.receive(sessionQueue: sessionQueue, ready: ready)
                            }
                        })
                    } else {
                        self.pending.append(d)
                        self.pendingBytes += d.count
                        if self.pendingBytes > RelayBridge.bufferMax { self.shutdown("relay buffer overflow", code: RelayCloseCode.normal); return }
                        self.receive(sessionQueue: sessionQueue, ready: ready)
                    }
                }
            }
        }
    }

    private func makePair(sessionQueue: DispatchQueue, ready: @escaping (NWConnection) -> Void) {
        LoopbackPair.make(sessionQueue: sessionQueue, bridgeQueue: queue, peerCheck: peerCheck) { [weak self] r in
            guard let self else { return }
            self.queue.async {
                switch r {
                case let .failure(e): self.shutdown("\(e)", code: RelayCloseCode.normal)
                case let .success((d, a)):
                    guard !self.closed else { d.cancel(); a.cancel(); return }
                    self.accepted = a
                    self.dialed = d
                    a.stateUpdateHandler = { [weak self] st in
                        switch st {
                        case .failed, .cancelled: self?.queue.async { self?.shutdown("the session closed", code: RelayCloseCode.normal, failure: false) }
                        default: break
                        }
                    }
                    for p in self.pending { a.send(content: p, completion: .contentProcessed { _ in }) }
                    self.pending = []
                    self.pendingBytes = 0
                    self.pumpToRelay(a)
                    ready(d)
                }
            }
        }
    }

    private func pumpToRelay(_ a: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: RelayBridge.readMax) { [weak self] data, _, complete, err in
            guard let self else { return }
            self.queue.async {
                guard !self.closed else { return }
                if let data, !data.isEmpty {
                    self.bytesToRelay += UInt64(data.count)
                    self.socket.send(.binary(data)) { [weak self] e in
                        guard let self else { return }
                        self.queue.async {
                            if e != nil { self.shutdown("relay send failed", code: nil); return }
                            if complete || err != nil { self.shutdown("the session closed", code: RelayCloseCode.normal, failure: false); return }
                            self.pumpToRelay(a)
                        }
                    }
                    return
                }
                if complete || err != nil { self.shutdown("the session closed", code: RelayCloseCode.normal, failure: false); return }
                self.pumpToRelay(a)
            }
        }
    }

    /// Relay close codes that end a session in an orderly way: normal, ended by an administrator
    /// (or revoked), time limit.
    public static func isOrderlyClose(_ code: Int) -> Bool {
        code == RelayCloseCode.normal || code == RelayCloseCode.endedByAdmin || code == RelayCloseCode.timeLimit
    }

    /// `code` nil: the relay socket is already gone.
    private func shutdown(_ reason: String, code: Int?, failure: Bool = true) {
        guard !closed else { return }
        closed = true
        closeReason = reason
        failed = failure
        socket.close(code: code ?? RelayCloseCode.normal)
        accepted?.stateUpdateHandler = nil
        accepted?.cancel()
        dialed?.cancel()
        pending = []
        onClosed(reason)
    }
}
