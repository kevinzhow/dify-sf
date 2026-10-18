import Crypto
import CryptoExtras
import Foundation

/// Dify's password rules and scheme (api/libs/password.py), so that accounts could move between Dify and dify-sf:
///
/// * rule: `^(?=.*[a-zA-Z])(?=.*\d).{8,}$` (at least 8 characters, at least one ASCII letter and one digit);
/// * hash: PBKDF2-HMAC-SHA256, 10000 iterations, 16-byte random salt; stored as base64 of the hex digest (Dify's
///   `base64.b64encode(binascii.hexlify(dk))`), salt as base64. Checked in constant time.
///
/// 10000 iterations is Dify's number; swift-crypto refuses fewer than 210000 through its checked API, so the unchecked
/// one is used on purpose (compatibility with Dify's stored hashes).
public enum Passwords {
    public static let iterations = 10_000

    /// Dify's `valid_password`.
    public static func isValid(_ password: String) -> Bool {
        // Python's `re` counts code points and `\d` is any Unicode digit; `.` does not match a newline.
        let scalars = password.unicodeScalars
        return scalars.count >= 8 && !scalars.contains("\n")
            && scalars.contains { ("a"..."z").contains($0) || ("A"..."Z").contains($0) }
            && scalars.contains { $0.properties.numericType == .decimal }
    }

    /// Dify's message for a password that breaks the rule.
    public static let ruleMessage = "Password must contain letters and numbers, and the length must be at least 8 characters."

    /// A fresh salt and the stored hash for `password`.
    public static func hash(_ password: String) throws -> (hash: String, salt: String) {
        var salt = [UInt8](repeating: 0, count: 16)
        var rng = SystemRandomNumberGenerator()
        for i in salt.indices { salt[i] = UInt8.random(in: 0...255, using: &rng) }
        return (try hash(password, salt: salt), Data(salt).base64EncodedString())
    }

    /// The stored form for `password` with `salt`: base64(hex(PBKDF2-HMAC-SHA256(password, salt, 10000, 32 bytes))).
    public static func hash(_ password: String, salt: [UInt8]) throws -> String {
        let key = try KDF.Insecure.PBKDF2.deriveKey(from: Array(password.utf8), salt: salt, using: .sha256, outputByteCount: 32,
                                                     unsafeUncheckedRounds: iterations)
        let hex = key.withUnsafeBytes { raw in raw.map { String(format: "%02x", $0) }.joined() }
        return Data(hex.utf8).base64EncodedString()
    }

    /// Dify's `compare_password`, in constant time over the stored bytes.
    public static func verify(_ password: String, hash stored: String, salt: String) -> Bool {
        guard let saltBytes = Data(base64Encoded: salt), let expected = Data(base64Encoded: stored),
              let computed = try? hash(password, salt: Array(saltBytes)), let actual = Data(base64Encoded: computed) else { return false }
        return constantTimeEqual(Array(expected), Array(actual))
    }

    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for i in a.indices { diff |= a[i] ^ b[i] }
        return diff == 0
    }
}

/// Opaque bearer tokens: 32 random bytes, base64url without padding. The server stores only their SHA-256 (hex).
public enum Tokens {
    public static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        var rng = SystemRandomNumberGenerator()
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255, using: &rng) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func sha256(_ token: String) -> String {
        SHA256.hash(data: Array(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
