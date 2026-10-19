/// Encrypts secrets at rest (protocol 1.9): secret environment variables (`secrets`) and model provider credentials. The
/// server implements it with AES-GCM and the key from its configuration (`COLLAB_SECRETS_KEY`); `context` is bound to the
/// ciphertext (associated data), so a sealed value only opens in the row it was written for.
public protocol SecretCipher: Sendable {
    func seal(_ plaintext: String, context: String) throws -> String
    func open(_ sealed: String, context: String) throws -> String
}

/// A secret was to be stored but the server has no secrets key: it refuses rather than store plaintext.
public struct SecretsKeyMissing: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "the server has no secrets key (COLLAB_SECRETS_KEY): secrets cannot be stored" }
}
