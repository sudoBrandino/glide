import CommonCrypto
import CryptoKit
import Foundation

public enum Handshake {
    public static let magic = Data("GLD1".utf8)
    public static let version: UInt16 = 1
    public static let clientSize = 54
    public static let hostSize = 70
    public static let pbkdf2Iterations: UInt32 = 100_000

    public struct ClientHello {
        public var publicKey: Data  // 32
        public var nonce: Data      // 16

        public init(publicKey: Data, nonce: Data) { self.publicKey = publicKey; self.nonce = nonce }

        public var encoded: Data {
            var w = ByteWriter(capacity: clientSize)
            w.bytes(magic); w.u16(version); w.bytes(publicKey); w.bytes(nonce)
            return w.data
        }

        public static func decode(_ d: Data) throws -> ClientHello {
            var r = ByteReader(d)
            guard try r.bytes(4) == magic else { throw WireError.badMagic }
            let v = try r.u16()
            guard v == version else { throw WireError.badVersion(v) }
            return ClientHello(publicKey: try r.bytes(32), nonce: try r.bytes(16))
        }
    }

    public struct HostHello {
        public var publicKey: Data  // 32
        public var nonce: Data      // 16
        public var salt: Data       // 16

        public init(publicKey: Data, nonce: Data, salt: Data) { self.publicKey = publicKey; self.nonce = nonce; self.salt = salt }

        public var encoded: Data {
            var w = ByteWriter(capacity: hostSize)
            w.bytes(magic); w.u16(version); w.bytes(publicKey); w.bytes(nonce); w.bytes(salt)
            return w.data
        }

        public static func decode(_ d: Data) throws -> HostHello {
            var r = ByteReader(d)
            guard try r.bytes(4) == magic else { throw WireError.badMagic }
            let v = try r.u16()
            guard v == version else { throw WireError.badVersion(v) }
            return HostHello(publicKey: try r.bytes(32), nonce: try r.bytes(16), salt: try r.bytes(16))
        }
    }

    public static func passwordKey(_ password: String, salt: Data) -> Data {
        var out = [UInt8](repeating: 0, count: 32)
        let pw = Array(password.utf8)
        let rc = pw.withUnsafeBufferPointer { pwp in
            salt.withUnsafeBytes { sp in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    pwp.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, pw.count,
                    sp.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), pbkdf2Iterations,
                    &out, out.count)
            }
        }
        precondition(rc == kCCSuccess, "PBKDF2 failed")
        return Data(out)
    }

    public struct Keys {
        public let c2s: SymmetricKey
        public let s2c: SymmetricKey
    }

    public static func deriveKeys(shared: Data, passwordKey: Data, clientHandshake: Data, hostHandshake: Data) -> Keys {
        let salt = Data(SHA256.hash(data: clientHandshake + hostHandshake))
        let okm = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: shared + passwordKey),
            salt: salt,
            info: Data("glide v1 session keys".utf8),
            outputByteCount: 64)
        let bytes = okm.withUnsafeBytes { Data($0) }
        return Keys(c2s: SymmetricKey(data: bytes.prefix(32)), s2c: SymmetricKey(data: bytes.suffix(32)))
    }

    public static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey, peerPublic: Data) throws -> Data {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublic)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Data($0) }
    }

    public static func randomBytes(_ n: Int) -> Data {
        var d = Data(count: n)
        let rc = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
        precondition(rc == errSecSuccess)
        return d
    }
}

/// One direction of the encrypted record stream. Not thread-safe; serialize access.
public final class RecordCipher {
    public static let maxRecord = 32 * 1024 * 1024
    private let key: SymmetricKey
    public private(set) var counter: UInt64 = 0

    public init(key: SymmetricKey) { self.key = key }

    private func nonce() -> ChaChaPoly.Nonce {
        var n = Data(count: 4)
        withUnsafeBytes(of: counter.littleEndian) { n.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: n)
    }

    /// Returns a full record: u32 length prefix + ciphertext + tag.
    public func seal(_ plaintext: Data) -> Data {
        let box = try! ChaChaPoly.seal(plaintext, using: key, nonce: nonce())
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
            let box = try ChaChaPoly.SealedBox(nonce: nonce(), ciphertext: ct, tag: tag)
            let pt = try ChaChaPoly.open(box, using: key)
            counter += 1
            return pt
        } catch {
            throw WireError.decryptFailed
        }
    }
}
