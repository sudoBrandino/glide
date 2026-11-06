import CryptoKit
import Foundation
import Network

/// Encrypted, framed message channel over a TCP NWConnection.
/// All callbacks are delivered on `queue`. `send` may be called from any thread.
public final class SecureChannel: @unchecked Sendable {
    public enum Role { case host, client }

    public let connection: NWConnection
    public let queue: DispatchQueue
    private var sendCipher: RecordCipher?
    private var recvCipher: RecordCipher?
    private let sendLock = NSLock()
    private var inFlight = 0
    private let inFlightLock = NSLock()
    private var closed = false

    public var onMessage: ((Data) -> Void)?
    public var onClose: ((Error?) -> Void)?

    /// Bytes handed to the network stack but not yet confirmed processed.
    public var bytesInFlight: Int { inFlightLock.lock(); defer { inFlightLock.unlock() }; return inFlight }

    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    public static func tcpParameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 10
        let p = NWParameters(tls: nil, tcp: tcp)
        p.serviceClass = .interactiveVideo
        return p
    }

    // MARK: Raw I/O

    private func readExactly(_ n: Int, _ done: @escaping (Result<Data, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: n, maximumLength: n) { data, _, isComplete, error in
            if let error { done(.failure(error)); return }
            guard let data, data.count == n else { done(.failure(isComplete ? WireError.closed : WireError.truncated)); return }
            done(.success(data))
        }
    }

    private func writeRaw(_ d: Data, _ done: ((Error?) -> Void)? = nil) {
        inFlightLock.lock(); inFlight += d.count; inFlightLock.unlock()
        connection.send(content: d, completion: .contentProcessed { [weak self] err in
            if let self { self.inFlightLock.lock(); self.inFlight -= d.count; self.inFlightLock.unlock() }
            done?(err)
        })
    }

    // MARK: Handshake

    /// Host side. `salt` is the host's persistent password salt.
    public func acceptHandshake(password: String, salt: Data, passwordKey: Data? = nil, completion: @escaping (Error?) -> Void) {
        readExactly(Handshake.clientSize) { [self] res in
            switch res {
            case .failure(let e): completion(e)
            case .success(let raw):
                do {
                    let ch = try Handshake.ClientHello.decode(raw)
                    let priv = Curve25519.KeyAgreement.PrivateKey()
                    let hh = Handshake.HostHello(publicKey: priv.publicKey.rawRepresentation, nonce: Handshake.randomBytes(16), salt: salt)
                    let hhRaw = hh.encoded
                    let shared = try Handshake.sharedSecret(privateKey: priv, peerPublic: ch.publicKey)
                    let pwk = passwordKey ?? Handshake.passwordKey(password, salt: salt)
                    let keys = Handshake.deriveKeys(shared: shared, passwordKey: pwk, clientHandshake: raw, hostHandshake: hhRaw)
                    sendCipher = RecordCipher(key: keys.s2c)
                    recvCipher = RecordCipher(key: keys.c2s)
                    writeRaw(hhRaw) { err in completion(err) }
                } catch { completion(error) }
            }
        }
    }

    /// Client side.
    public func performHandshake(password: String, completion: @escaping (Error?) -> Void) {
        let priv = Curve25519.KeyAgreement.PrivateKey()
        let ch = Handshake.ClientHello(publicKey: priv.publicKey.rawRepresentation, nonce: Handshake.randomBytes(16))
        let chRaw = ch.encoded
        writeRaw(chRaw)
        readExactly(Handshake.hostSize) { [self] res in
            switch res {
            case .failure(let e): completion(e)
            case .success(let raw):
                do {
                    let hh = try Handshake.HostHello.decode(raw)
                    let shared = try Handshake.sharedSecret(privateKey: priv, peerPublic: hh.publicKey)
                    let pwk = Handshake.passwordKey(password, salt: hh.salt)
                    let keys = Handshake.deriveKeys(shared: shared, passwordKey: pwk, clientHandshake: chRaw, hostHandshake: raw)
                    sendCipher = RecordCipher(key: keys.c2s)
                    recvCipher = RecordCipher(key: keys.s2c)
                    completion(nil)
                } catch { completion(error) }
            }
        }
    }

    // MARK: Records

    /// Encrypts and sends one message. Thread-safe; ordering is preserved.
    public func send(_ plaintext: Data, completion: ((Error?) -> Void)? = nil) {
        sendLock.lock()
        guard let c = sendCipher, !closed else { sendLock.unlock(); completion?(WireError.closed); return }
        let rec = c.seal(plaintext)
        // connection.send preserves call order; keep it under the lock so counter order == wire order.
        writeRaw(rec, completion)
        sendLock.unlock()
    }

    /// Starts the receive loop. Each decrypted plaintext is delivered to `onMessage`.
    public func startReceiving() { readRecord() }

    private func readRecord() {
        readExactly(4) { [self] res in
            guard case .success(let hdr) = res else { if case .failure(let e) = res { close(e) }; return }
            var r = ByteReader(hdr)
            let len = Int((try? r.u32()) ?? 0)
            guard len >= 17, len <= RecordCipher.maxRecord else { close(WireError.recordTooLarge(len)); return }
            readExactly(len) { [self] res in
                switch res {
                case .failure(let e): close(e)
                case .success(let body):
                    do {
                        guard let rc = recvCipher else { throw WireError.closed }
                        let pt = try rc.open(body)
                        onMessage?(pt)
                        if !closed { readRecord() }
                    } catch { close(error) }
                }
            }
        }
    }

    public func close(_ error: Error? = nil) {
        sendLock.lock()
        let was = closed
        closed = true
        sendLock.unlock()
        guard !was else { return }
        connection.cancel()
        onClose?(error)
    }
}
