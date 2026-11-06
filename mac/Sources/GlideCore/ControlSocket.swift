import Foundation

/// A tiny line-based Unix-domain control socket: the running host serves it (0600, in its 0700
/// config folder) so `glide-host --pair` / `--paired` / `--unpair` work headless (over SSH).
/// One thread per client; `handler` gets each line and a `reply` that writes one line back.
/// Same-user only: the socket file's permissions are the access control.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = (_ line: String, _ client: ControlClientRef) -> Void
    public let path: String
    private var fd: Int32 = -1
    private let handler: Handler

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Binds and starts accepting. Fails if another live server owns the path.
    public func start() throws {
        if let c = try? ControlClient(path: path) { c.close(); throw ControlError.inUse(path) }
        unlink(path)
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ControlError.sys("socket", errno) }
        var addr = try Self.address(path)
        let old = umask(0o077)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard rc == 0 else { let e = errno; Darwin.close(s); throw ControlError.sys("bind", e) }
        chmod(path, 0o600)
        guard listen(s, 4) == 0 else { let e = errno; Darwin.close(s); throw ControlError.sys("listen", e) }
        fd = s
        Thread.detachNewThread { [weak self] in self?.acceptLoop(s) }
    }

    public func stop() {
        if fd >= 0 { Darwin.close(fd); fd = -1 }
        unlink(path)
    }

    private func acceptLoop(_ s: Int32) {
        while true {
            let c = accept(s, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            let ref = ControlClientRef(fd: c)
            Thread.detachNewThread { [handler] in
                let reader = LineReader(fd: c)
                while let line = reader.next() { handler(line, ref) }
                ref.close()
            }
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var a = sockaddr_un()
        a.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: a.sun_path) else { throw ControlError.pathTooLong(path) }
        withUnsafeMutableBytes(of: &a.sun_path) { p in
            for (i, b) in bytes.enumerated() { p[i] = b }
            p[bytes.count] = 0
        }
        return a
    }
}

public enum ControlError: Error, CustomStringConvertible {
    case sys(String, Int32)
    case inUse(String)
    case pathTooLong(String)
    public var description: String {
        switch self {
        case let .sys(f, e): return "\(f): \(String(cString: strerror(e)))"
        case .inUse(let p): return "another Glide Host is already serving \(p)"
        case .pathTooLong(let p): return "socket path too long: \(p)"
        }
    }
}

/// Server-side handle of one connected client (thread-safe writes; may outlive the read loop).
public final class ControlClientRef: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    init(fd: Int32) { self.fd = fd }

    /// Writes one line; returns false if the client is gone.
    @discardableResult
    public func send(_ line: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return false }
        let d = Array((line.replacingOccurrences(of: "\n", with: " ") + "\n").utf8)
        var off = 0
        while off < d.count {
            let n = d[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { closed = true; return false }
            off += n
        }
        return true
    }

    public var isClosed: Bool { lock.lock(); defer { lock.unlock() }; return closed }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; Darwin.close(fd) }
    }
}

final class LineReader {
    private let fd: Int32
    private var buf = [UInt8]()
    init(fd: Int32) { self.fd = fd }
    func next() -> String? {
        while true {
            if let i = buf.firstIndex(of: 0x0A) {
                let line = String(decoding: buf[..<i], as: UTF8.self)
                buf.removeSubrange(...i)
                return line.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n <= 0 { return nil }
            buf += chunk[..<n]
            if buf.count > 65536 { return nil }  // no line that long in this protocol
        }
    }
}

/// Client side (the `glide-host --pair` CLI, tests).
public final class ControlClient {
    private let fd: Int32
    private let reader: LineReader

    public init(path: String) throws {
        let s = socket(AF_UNIX, SOCK_STREAM, 0)
        guard s >= 0 else { throw ControlError.sys("socket", errno) }
        var addr = try ControlServer.address(path)
        let rc = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard rc == 0 else { let e = errno; Darwin.close(s); throw ControlError.sys("connect", e) }
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        fd = s
        reader = LineReader(fd: s)
    }

    public func send(_ line: String) {
        let d = Array((line + "\n").utf8)
        _ = d.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// Next line from the server; nil when it closed the connection.
    public func readLine() -> String? { reader.next() }

    public func close() { Darwin.close(fd) }
}
