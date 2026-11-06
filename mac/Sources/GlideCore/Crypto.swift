import CryptoKit
import Foundation

/// Glide v2 handshake (docs/PROTOCOL.md §1–2): version preambles, Noise XX with Glide's payloads,
/// the pairing commitment and the Short Authentication String. Sans-IO engines for both roles:
/// `GlideHandshake.Host` (responder, glide-host) and `GlideHandshake.Viewer` (initiator,
/// glide-probe and tests). `SecureChannel` does the I/O.
public enum GlideHandshake {
    public static let magic = Data("GLD2".utf8)
    /// v1 (password) magic: only recognized to answer v1 peers with a clear error.
    public static let magicV1 = Data("GLD1".utf8)
    public static let version: UInt16 = 2
    public static let clientPreambleSize = 24
    public static let hostPreambleSize = 8
    /// Upper bound for one framed handshake message (real ones are < 400 bytes).
    public static let maxMessage = 1024
    /// v1 sizes (ClientHandshake / HostHandshake).
    public static let v1ClientSize = 54
    public static let v1HostSize = 70
    public static let maxName = 255

    // HostPreamble.status
    public static let statusOK: UInt16 = 0
    public static let statusUnsupportedVersion: UInt16 = 1
    public static let statusPaused: UInt16 = 2
    public static let statusRateLimited: UInt16 = 3

    /// msg2 flags: the host's pairing window is open.
    public static let hostFlagPairingOpen: UInt8 = 1
    /// msg3 flags: the viewer asks to pair.
    public static let viewerFlagPairRequest: UInt8 = 1

    static let commitLabel = Data("glide-v2 pair commit".utf8)
    static let sasLabel = Data("glide-v2 sas".utf8)

    public enum HandshakeError: Error, CustomStringConvertible, Equatable {
        case noise(Noise.NoiseError)
        /// Not Glide v2. `v1` = the peer sent the v1 magic.
        case badMagic(v1: Bool)
        case status(version: UInt16, status: UInt16)
        case malformed(String)
        case versionMismatch
        public var description: String {
            switch self {
            case .noise(let e): return "\(e)"
            case .badMagic(true): return "peer speaks Glide protocol v1"
            case .badMagic(false): return "peer is not speaking the Glide protocol"
            case let .status(v, s): return "handshake refused (status \(s), version \(v))"
            case .malformed(let s): return "malformed handshake: \(s)"
            case .versionMismatch: return "handshake version mismatch"
            }
        }
    }

    public static func clientPreamble() -> Data {
        var w = ByteWriter(capacity: clientPreambleSize)
        w.bytes(magic); w.u16(version); w.u16(version); w.bytes(Data(count: 16))
        return w.data
    }

    public static func hostPreamble(version: UInt16 = version, status: UInt16) -> Data {
        var w = ByteWriter(capacity: hostPreambleSize)
        w.bytes(magic); w.u16(version); w.u16(status)
        return w.data
    }

    /// Host side: (max, min) versions of a ClientPreamble.
    public static func parseClientPreamble(_ p: Data) throws -> (max: UInt16, min: UInt16) {
        guard p.count >= clientPreambleSize else { throw HandshakeError.malformed("short preamble") }
        var r = ByteReader(p)
        let m = try r.bytes(4)
        guard m == magic else { throw HandshakeError.badMagic(v1: m == magicV1) }
        return (try r.u16(), try r.u16())
    }

    /// Viewer side: the negotiated version (status must be 0).
    public static func parseHostPreamble(_ p: Data) throws -> UInt16 {
        var r = ByteReader(p)
        let m = try r.bytes(4)
        guard m == magic else { throw HandshakeError.badMagic(v1: m == magicV1) }
        let v = try r.u16(), st = try r.u16()
        guard st == statusOK else { throw HandshakeError.status(version: v, status: st) }
        guard v == version else { throw HandshakeError.status(version: v, status: statusUnsupportedVersion) }
        return v
    }

    /// `u16 length || message`.
    public static func frame(_ m: Data) -> Data {
        var w = ByteWriter(capacity: m.count + 2)
        w.u16(UInt16(m.count)); w.bytes(m)
        return w.data
    }

    /// The 70-byte reply a v2 host sends a v1 viewer: v1 magic with version 2, so the v1 viewer
    /// reports "unsupported protocol version 2" instead of a crypto failure.
    public static func v1Rejection() -> Data {
        var w = ByteWriter(capacity: v1HostSize)
        w.bytes(magicV1); w.u16(version); w.bytes(Data(count: v1HostSize - 6))
        return w.data
    }

    public static func commitment(_ nH: Data) -> Data { Data(SHA256.hash(data: commitLabel + nH)) }

    /// The 6-digit Short Authentication String (0…999999).
    public static func sasCode(handshakeHash h: Data, viewerNonce nV: Data, hostNonce nH: Data) -> UInt32 {
        let d = Data(SHA256.hash(data: sasLabel + h + nV + nH))
        let x = UInt32(d[0]) << 24 | UInt32(d[1]) << 16 | UInt32(d[2]) << 8 | UInt32(d[3])
        return x % 1_000_000
    }

    /// "123 456".
    public static func sasText(_ code: UInt32) -> String { String(format: "%03u %03u", code / 1000, code % 1000) }

    /// Display fingerprint: first 8 bytes of SHA-256(public key), "aaaa bbbb cccc dddd".
    public static func fingerprint(_ pub: Data) -> String {
        let h = Data(SHA256.hash(data: pub)).prefix(8).hex
        return stride(from: 0, to: 16, by: 4).map { i in
            String(h[h.index(h.startIndex, offsetBy: i) ..< h.index(h.startIndex, offsetBy: i + 4)])
        }.joined(separator: " ")
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(rc == errSecSuccess)
        return d
    }

    /// msg2 payload.
    public struct HostInfo: Equatable {
        public var version: UInt16
        public var flags: UInt8
        public var commitment: Data
        public init(version: UInt16, flags: UInt8, commitment: Data) { self.version = version; self.flags = flags; self.commitment = commitment }
        public var encoded: Data { var w = ByteWriter(); w.u16(version); w.u8(flags); w.bytes(commitment); return w.data }
        public static func decode(_ d: Data) throws -> HostInfo {
            guard d.count >= 35 else { throw HandshakeError.malformed("short msg2 payload") }
            var r = ByteReader(d)
            return HostInfo(version: try r.u16(), flags: try r.u8(), commitment: try r.bytes(32))
        }
        public var pairingOpen: Bool { flags & hostFlagPairingOpen != 0 }
    }

    /// msg3 payload.
    public struct ViewerInfo: Equatable {
        public var flags: UInt8
        public var nonce: Data
        public var name: String
        public init(flags: UInt8, nonce: Data, name: String) { self.flags = flags; self.nonce = nonce; self.name = name }
        public var encoded: Data {
            var n = Data(name.utf8)
            if n.count > maxName {
                var s = name
                while s.utf8.count > maxName { s.removeLast() }
                n = Data(s.utf8)
            }
            var w = ByteWriter(); w.u8(flags); w.bytes(nonce); w.u16(UInt16(n.count)); w.bytes(n)
            return w.data
        }
        public static func decode(_ d: Data) throws -> ViewerInfo {
            guard d.count >= 35 else { throw HandshakeError.malformed("short msg3 payload") }
            var r = ByteReader(d)
            let f = try r.u8(), n = try r.bytes(32)
            let len = Int(try r.u16())
            guard r.remaining >= len else { throw HandshakeError.malformed("truncated viewer name") }
            return ViewerInfo(flags: f, nonce: n, name: String(decoding: try r.bytes(len), as: UTF8.self))
        }
        public var pairRequest: Bool { flags & viewerFlagPairRequest != 0 }
    }

    /// Keys and hash after a completed handshake.
    public struct Established {
        public let sendKey: SymmetricKey
        public let recvKey: SymmetricKey
        public let sendKeyData: Data
        public let recvKeyData: Data
        public let handshakeHash: Data
        public let remoteStatic: Data
    }

    static func establish(_ hs: Noise.HandshakeXX) -> Established {
        let (s, r) = hs.split()
        return Established(sendKey: SymmetricKey(data: s.key!), recvKey: SymmetricKey(data: r.key!), sendKeyData: s.key!, recvKeyData: r.key!,
                           handshakeHash: hs.handshakeHash, remoteStatic: hs.rs!)
    }

    /// Host (responder) engine.
    public final class Host {
        let hs: Noise.HandshakeXX
        /// The host's pairing nonce n_h (committed in msg2, revealed in PairReveal).
        public let nonce: Data
        public private(set) var viewer: ViewerInfo?
        public private(set) var viewerKey: Data?

        /// Validates ClientPreamble + msg1 (unframed). Throws `.status(…unsupportedVersion)` if no
        /// common version.
        public init(identity: Curve25519.KeyAgreement.PrivateKey, preamble: Data, msg1: Data,
                    ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil, nonce: Data? = nil) throws {
            let (mx, mn) = try parseClientPreamble(preamble)
            guard mn <= version && version <= mx else { throw HandshakeError.status(version: version, status: statusUnsupportedVersion) }
            hs = Noise.HandshakeXX(initiator: false, s: identity, prologue: preamble.prefix(clientPreambleSize), ephemeral: ephemeral)
            self.nonce = nonce ?? randomBytes(32)
            do {
                guard try hs.readMessage(msg1).isEmpty else { throw HandshakeError.malformed("msg1 payload must be empty") }
            } catch let e as Noise.NoiseError { throw HandshakeError.noise(e) }
        }

        /// HostPreamble || frame(msg2).
        public func writeMsg2(flags: UInt8) throws -> Data {
            let p = HostInfo(version: version, flags: flags, commitment: commitment(nonce)).encoded
            do { return hostPreamble(status: statusOK) + frame(try hs.writeMessage(p)) }
            catch let e as Noise.NoiseError { throw HandshakeError.noise(e) }
        }

        /// Processes msg3 (unframed): the viewer's static key and info.
        @discardableResult
        public func readMsg3(_ m: Data) throws -> (key: Data, info: ViewerInfo) {
            let p: Data
            do { p = try hs.readMessage(m) } catch let e as Noise.NoiseError { throw HandshakeError.noise(e) }
            let info = try ViewerInfo.decode(p)
            viewer = info
            viewerKey = hs.rs
            return (hs.rs!, info)
        }

        public func finish() -> Established { precondition(hs.isFinished); return establish(hs) }
    }

    /// Viewer (initiator) engine (glide-probe, tests).
    public final class Viewer {
        let hs: Noise.HandshakeXX
        let preamble = clientPreamble()
        public let nonce: Data
        let name: String
        public private(set) var host: HostInfo?

        public init(identity: Curve25519.KeyAgreement.PrivateKey, name: String,
                    ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil, nonce: Data? = nil) {
            hs = Noise.HandshakeXX(initiator: true, s: identity, prologue: preamble, ephemeral: ephemeral)
            self.nonce = nonce ?? randomBytes(32)
            self.name = name
        }

        /// ClientPreamble || frame(msg1).
        public func firstFlight() -> Data { preamble + frame(try! hs.writeMessage(Data())) }

        public func readMsg2(_ m: Data, preambleVersion: UInt16) throws -> (key: Data, info: HostInfo) {
            let p: Data
            do { p = try hs.readMessage(m) } catch let e as Noise.NoiseError { throw HandshakeError.noise(e) }
            let info = try HostInfo.decode(p)
            guard info.version == preambleVersion else { throw HandshakeError.versionMismatch }
            host = info
            return (hs.rs!, info)
        }

        /// frame(msg3).
        public func writeMsg3(flags: UInt8) -> Data {
            frame(try! hs.writeMessage(ViewerInfo(flags: flags, nonce: nonce, name: name).encoded))
        }

        public func finish() -> Established { precondition(hs.isFinished); return establish(hs) }
    }
}

/// One direction of the encrypted record stream (docs/PROTOCOL.md §2): Noise transport keys,
/// nonce = 4 zero bytes || u64 LE counter, empty AAD, u32 length prefix. Not thread-safe.
public final class RecordCipher {
    public static let maxRecord = 32 * 1024 * 1024
    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    /// Returns a full record: u32 length prefix + ciphertext + tag.
    public func seal(_ plaintext: Data) -> Data {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: Noise.nonce(counter))
        counter += 1
        var w = ByteWriter(capacity: plaintext.count + 20)
        w.u32(UInt32(box.ciphertext.count + 16))
        w.bytes(box.ciphertext)
        w.bytes(box.tag)
        return w.data
    }

    /// `body` is the record body after the length prefix (ciphertext + tag).
    public func open(_ body: Data) throws -> Data {
        guard body.count >= 17 else { throw WireError.truncated }
        let ct = body.prefix(body.count - 16)
        let tag = body.suffix(16)
        do {
            let box = try ChaChaPoly.SealedBox(nonce: Noise.nonce(counter), ciphertext: ct, tag: tag)
            let pt = try ChaChaPoly.open(box, using: key)
            counter += 1
            return pt
        } catch {
            throw WireError.decryptFailed
        }
    }
}
