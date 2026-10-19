import CollabStore
import Crypto
import Foundation

/// AES-256-GCM with the server's secrets key (`COLLAB_SECRETS_KEY`, base64 of 32 random bytes): how secrets are stored at
/// rest (protocol 1.9: model provider credentials and secret environment variables). A sealed value is `v1:` followed by
/// base64(nonce | ciphertext | tag); `v1` names the key generation, which leaves room for key rotation. The row's
/// context (`provider_credentials:<id>`, `secrets:<doc>:<ref>`) is the associated data, so a value only opens where it was
/// written.
public struct SecretsKey: SecretCipher {
    let key: SymmetricKey

    public struct Invalid: Error, CustomStringConvertible {
        public var description: String
    }

    /// Nil for an empty setting (no key: secrets cannot be stored); throws for a setting that is not base64 of 32 bytes.
    public static func from(setting: String) throws -> SecretsKey? {
        let s = setting.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        guard let data = Data(base64Encoded: s), data.count == 32 else {
            throw Invalid(description: "COLLAB_SECRETS_KEY must be the base64 encoding of 32 random bytes (e.g. `openssl rand -base64 32`)")
        }
        return SecretsKey(key: SymmetricKey(data: data))
    }

    public static func random() -> SecretsKey { SecretsKey(key: SymmetricKey(size: .bits256)) }

    public func seal(_ plaintext: String, context: String) throws -> String {
        let box = try AES.GCM.seal(Data(plaintext.utf8), using: key, authenticating: Data(context.utf8))
        guard let combined = box.combined else { throw Invalid(description: "AES-GCM produced no combined box") }
        return "v1:" + combined.base64EncodedString()
    }

    public func open(_ sealed: String, context: String) throws -> String {
        guard sealed.hasPrefix("v1:"), let data = Data(base64Encoded: String(sealed.dropFirst(3))) else {
            throw Invalid(description: "not a sealed value of key generation v1")
        }
        let plain = try AES.GCM.open(try AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(context.utf8))
        return String(decoding: plain, as: UTF8.self)
    }
}
