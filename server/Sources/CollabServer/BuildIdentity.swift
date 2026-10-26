import Foundation

/// Public release identity only. Do not serialize environment, hosts, paths,
/// configuration values or provider credentials into diagnostic metadata.
struct BuildIdentity: Encodable, Sendable {
    let revision: String
    let workflow_protocol = "1.21"
    let agent_protocol = "dify-sf-agent/1"
    let client_manifest = "/version.json"

    init(revision: String) { self.revision = Self.validRevision(revision) ?? "development" }
    static func validRevision(_ value: String) -> String? {
        guard (12...40).contains(value.count), value.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return value.lowercased()
    }
}
