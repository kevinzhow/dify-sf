import Foundation

/// Signed runtime packages corresponding to the bundled provider definitions.
/// Generated from e2e/plugins.lock.json; tool/check_provider_plugins.py rejects drift.
public struct ProviderPlugin: Codable, Sendable {
    public var id: String
    public var version: String
    public var uniqueIdentifier: String
    public var file: String
    public var sha256: String

    enum CodingKeys: String, CodingKey {
        case id, version, file, sha256
        case uniqueIdentifier = "unique_identifier"
    }

    public static func bundled() throws -> [ProviderPlugin] {
        struct Lock: Decodable { var plugins: [ProviderPlugin] }
        guard let url = Bundle.module.url(forResource: "provider-plugins.lock", withExtension: "json") else {
            throw CatalogError("Provider runtime lock is missing")
        }
        let pins = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: url)).plugins
        guard Set(pins.map(\.id)).count == pins.count,
              pins.allSatisfy({ $0.id.hasPrefix("langgenius/") && $0.uniqueIdentifier.hasPrefix($0.id + ":" + $0.version + "@") && $0.sha256.count == 64 }) else {
            throw CatalogError("Provider runtime lock is invalid")
        }
        return pins
    }
}
