import CryptoKit
import Foundation

/// Noise_XX_25519_ChaChaPoly_SHA256 (Noise Protocol Framework, revision 34), both roles, built on
/// CryptoKit primitives (Curve25519.KeyAgreement, ChaChaPoly, SHA256, HMAC-based HKDF).
/// Checked against the official vectors in docs/noise-vectors.json (cacophony, noise-c, snow) and
/// against the Python and Rust implementations through docs/test-vectors*.json (glide-selftest).
public enum Noise {
    public static let protocolName = Data("Noise_XX_25519_ChaChaPoly_SHA256".utf8)
    public static let dhLen = 32
    public static let tagLen = 16

    public enum NoiseError: Error, CustomStringConvertible, Equatable {
        case decrypt, short, state, badKey
        public var description: String {
            switch self {
            case .decrypt: return "handshake message failed authentication"
            case .short: return "handshake message too short"
            case .state: return "handshake message out of order"
            case .badKey: return "peer sent an invalid public key"
            }
        }
    }

    static func nonce(_ n: UInt64) -> ChaChaPoly.Nonce {
        var d = Data(count: 4)
        withUnsafeBytes(of: n.littleEndian) { d.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: d)
    }

    static func hmac(_ key: Data, _ data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    /// Noise HKDF with two outputs (RFC 5869 HKDF-SHA256, salt = chaining key, empty info).
    public static func hkdf2(_ ck: Data, _ ikm: Data) -> (Data, Data) {
        let tmp = hmac(ck, ikm)
        let o1 = hmac(tmp, Data([1]))
        let o2 = hmac(tmp, o1 + Data([2]))
        return (o1, o2)
    }

    public static func dh(_ sk: Curve25519.KeyAgreement.PrivateKey, _ pk: Data) throws -> Data {
        guard pk.count == 32, let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk) else { throw NoiseError.badKey }
        guard let ss = try? sk.sharedSecretFromKeyAgreement(with: pub) else { throw NoiseError.badKey }
        let out = ss.withUnsafeBytes { Data($0) }
        // A low-order peer key yields all zeros: reject (Noise §9.1 permits either behavior).
        guard out.contains(where: { $0 != 0 }) else { throw NoiseError.badKey }
        return out
    }

    /// A Noise CipherState. Glide's record layer (RecordCipher) uses the same nonce layout and an
    /// empty AAD with the transport keys from `split()`.
    public struct CipherState {
        public private(set) var key: Data?
        public private(set) var n: UInt64 = 0
        public init(key: Data?) { self.key = key }

        public mutating func encrypt(ad: Data, _ pt: Data) -> Data {
            guard let key else { return pt }
            let box = try! ChaChaPoly.seal(pt, using: SymmetricKey(data: key), nonce: Noise.nonce(n), authenticating: ad)
            n += 1
            return box.ciphertext + box.tag
        }

        public mutating func decrypt(ad: Data, _ ct: Data) throws -> Data {
            guard let key else { return ct }
            guard ct.count >= tagLen else { throw NoiseError.decrypt }
            do {
                let box = try ChaChaPoly.SealedBox(nonce: Noise.nonce(n), ciphertext: ct.prefix(ct.count - tagLen), tag: ct.suffix(tagLen))
                let pt = try ChaChaPoly.open(box, using: SymmetricKey(data: key), authenticating: ad)
                n += 1
                return pt
            } catch { throw NoiseError.decrypt }
        }
    }

    struct SymmetricState {
        var h: Data
        var ck: Data
        var cs = CipherState(key: nil)

        init() {
            if protocolName.count <= 32 {
                h = protocolName + Data(count: 32 - protocolName.count)
            } else {
                h = Data(SHA256.hash(data: protocolName))
            }
            ck = h
        }
        mutating func mixKey(_ ikm: Data) {
            let (a, b) = hkdf2(ck, ikm)
            ck = a
            cs = CipherState(key: b)
        }
        mutating func mixHash(_ d: Data) { h = Data(SHA256.hash(data: h + d)) }
        mutating func encryptAndHash(_ pt: Data) -> Data {
            let ct = cs.encrypt(ad: h, pt)
            mixHash(ct)
            return ct
        }
        mutating func decryptAndHash(_ ct: Data) throws -> Data {
            let pt = try cs.decrypt(ad: h, ct)
            mixHash(ct)
            return pt
        }
        func split() -> (CipherState, CipherState) {
            let (k1, k2) = hkdf2(ck, Data())
            return (CipherState(key: k1), CipherState(key: k2))
        }
    }

    /// XX: `-> e`, `<- e, ee, s, es`, `-> s, se`.
    public final class HandshakeXX {
        public let initiator: Bool
        let s: Curve25519.KeyAgreement.PrivateKey
        var e: Curve25519.KeyAgreement.PrivateKey?
        public private(set) var re: Data?
        public private(set) var rs: Data?
        var ss = SymmetricState()
        public private(set) var step = 0

        /// `ephemeral`: fixed ephemeral key (tests/vectors); nil = fresh random.
        public init(initiator: Bool, s: Curve25519.KeyAgreement.PrivateKey, prologue: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey? = nil) {
            self.initiator = initiator
            self.s = s
            self.e = ephemeral
            ss.mixHash(prologue)
        }

        private func ephemeral() -> Data {
            if e == nil { e = Curve25519.KeyAgreement.PrivateKey() }
            return e!.publicKey.rawRepresentation
        }

        public func writeMessage(_ payload: Data = Data()) throws -> Data {
            var out = Data()
            switch (initiator, step) {
            case (true, 0):
                let ep = ephemeral(); ss.mixHash(ep); out += ep
            case (false, 1):
                guard let re else { throw NoiseError.state }
                let ep = ephemeral(); ss.mixHash(ep); out += ep
                ss.mixKey(try dh(e!, re))
                out += ss.encryptAndHash(s.publicKey.rawRepresentation)
                ss.mixKey(try dh(s, re))
            case (true, 2):
                guard let re else { throw NoiseError.state }
                out += ss.encryptAndHash(s.publicKey.rawRepresentation)
                ss.mixKey(try dh(s, re))
            default:
                throw NoiseError.state
            }
            out += ss.encryptAndHash(payload)
            step += 1
            return out
        }

        public func readMessage(_ msg: Data) throws -> Data {
            let m = Data(msg)  // zero-based indices
            var rest: Data
            switch (initiator, step) {
            case (false, 0):
                guard m.count >= dhLen else { throw NoiseError.short }
                re = m.prefix(dhLen); ss.mixHash(re!)
                rest = m.dropFirst(dhLen)
            case (true, 1):
                guard m.count >= dhLen + dhLen + 2 * tagLen, let e else { throw m.count < 96 ? NoiseError.short : NoiseError.state }
                re = m.prefix(dhLen); ss.mixHash(re!)
                ss.mixKey(try dh(e, re!))
                rs = try ss.decryptAndHash(m.subdata(in: dhLen ..< dhLen + dhLen + tagLen))
                ss.mixKey(try dh(e, rs!))
                rest = m.dropFirst(dhLen + dhLen + tagLen)
            case (false, 2):
                guard m.count >= dhLen + 2 * tagLen, let e else { throw m.count < 64 ? NoiseError.short : NoiseError.state }
                rs = try ss.decryptAndHash(m.prefix(dhLen + tagLen))
                ss.mixKey(try dh(e, rs!))
                rest = m.dropFirst(dhLen + tagLen)
            default:
                throw NoiseError.state
            }
            let payload = try ss.decryptAndHash(Data(rest))
            step += 1
            return payload
        }

        public var isFinished: Bool { step == 3 }
        public var handshakeHash: Data { ss.h }

        /// Transport ciphers for this side: (send, receive).
        public func split() -> (send: CipherState, recv: CipherState) {
            let (c1, c2) = ss.split()
            return initiator ? (c1, c2) : (c2, c1)
        }
    }
}
