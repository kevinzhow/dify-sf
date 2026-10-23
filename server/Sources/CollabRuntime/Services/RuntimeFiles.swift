// Ported from Dify 1.17.1 factories/file_factory/{builders,validation}.py and graphon 0.7.0
// file/{models,file_manager}.py. Storage and authorization stay in the server adapter, never in graph JSON.
import Foundation

public struct RuntimeFile: Sendable, Hashable {
    public static let identity = "__dify__file__"
    public let recordId: String
    public let type: String
    public let transferMethod: String
    public let filename: String
    public let extensionName: String
    public let mimeType: String
    public let size: Int
    public let url: String
    public let remoteURL: String?

    public init(recordId: String, type: String, transferMethod: String = "local_file", filename: String,
                extensionName: String, mimeType: String, size: Int, url: String, remoteURL: String? = nil) {
        self.recordId = recordId; self.type = type; self.transferMethod = transferMethod
        self.filename = filename; self.extensionName = extensionName; self.mimeType = mimeType
        self.size = size; self.url = url; self.remoteURL = remoteURL
    }

    /// A record id, not a client-supplied storage path. Legacy opaque references may contain a path; it is ignored.
    public static func recordId(in value: JSONValue) -> String? {
        let raw = value["upload_file_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? value["tool_file_id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? value["reference"]?.string.flatMap { $0.isEmpty ? nil : $0 }
            ?? value["related_id"]?.string
        guard var id = raw else { return nil }
        if id.hasPrefix("dify-file-ref:") {
            var base64 = String(id.dropFirst("dify-file-ref:".count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64), let parsed = try? JSONValue.parse(Array(bytes)),
                  let record = parsed["record_id"]?.string else { return nil }
            id = record
        }
        return UUID(uuidString: id)?.uuidString.lowercased()
    }

    public var json: JSONValue {
        let reference = "dify-file-ref:" + Data("{\"record_id\":\"\(recordId)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return ["dify_model_identity": .string(Self.identity), "id": .null, "type": .string(type),
                "transfer_method": .string(transferMethod), "remote_url": remoteURL.map(JSONValue.string) ?? .null,
                "reference": .string(reference), "related_id": .string(recordId), "filename": .string(filename),
                "extension": .string(extensionName.hasPrefix(".") ? extensionName : "." + extensionName),
                "mime_type": .string(mimeType), "size": .int(size), "url": .string(url)]
    }

    public static func isFile(_ value: JSONValue) -> Bool { value["dify_model_identity"] == .string(identity) }
    public static func markdown(_ value: JSONValue) -> String {
        let name = value["filename"]?.string ?? "", url = value["url"]?.string ?? ""
        return (value["type"] == "image" ? "!" : "") + "[\(name)](\(url))"
    }

    public static func validate(_ file: RuntimeFile, config: JSONObject?) throws {
        guard let config else { return }
        let allowed = config["allowed_file_types"]?.array?.compactMap(\.string) ?? []
        let methods = config["allowed_file_upload_methods"]?.array?.compactMap(\.string) ?? []
        let normal = allowed.isEmpty || allowed.contains(file.type)
        let custom = allowed.contains("custom")
        if !normal && !custom { throw RuntimeFileError("File validation failed for file: \(file.filename)") }
        if file.type == "custom" || !normal {
            let extensions = config["allowed_file_extensions"]?.array?.compactMap(\.string) ?? []
            func normalized(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            guard extensions.map(normalized).contains(normalized(file.extensionName)) else {
                throw RuntimeFileError("File validation failed for file: \(file.filename)")
            }
        }
        let imageMethods = config["image"]?["transfer_methods"]?.array?.compactMap(\.string) ?? []
        let acceptedMethods = file.type == "image" && !imageMethods.isEmpty ? imageMethods : methods
        if !acceptedMethods.isEmpty && !acceptedMethods.contains(file.transferMethod) {
            throw RuntimeFileError("File validation failed for file: \(file.filename)")
        }
    }
}

public struct RuntimeFileError: Error, CustomStringConvertible, Sendable {
    public var description: String
    public init(_ description: String) { self.description = description }
}

/// A scoped adapter. Every read rechecks the backing record and ignores serialized URL/path/name/size claims.
public protocol RuntimeFiles: Sendable {
    func resolve(_ mapping: JSONValue, config: JSONObject?) async throws -> RuntimeFile
    func bytes(_ file: JSONValue) async throws -> [UInt8]
    func save(bytes: [UInt8], filename: String, mimeType: String, sourceURL: String?) async throws -> RuntimeFile
}

extension RuntimeFiles {
    public func resolveList(_ values: [JSONValue], config: JSONObject? = nil) async throws -> [JSONValue] {
        let limit = config?["number_limits"]?.int ?? config?["max_length"]?.int ?? 0
        if values.count > 100 || (limit > 0 && values.count > limit) { throw RuntimeFileError("Number of files exceeds the maximum limit \(limit > 0 ? limit : 100)") }
        var result: [JSONValue] = []
        var total = 0
        var images = 0
        for value in values {
            let file = try await resolve(value, config: config)
            total += file.size
            if file.type == "image" { images += 1 }
            if total > 100 * 1024 * 1024 { throw RuntimeFileError("Total file size exceeded") }
            result.append(file.json)
        }
        if let imageLimit = config?["image"]?["number_limits"]?.int, images > imageLimit {
            throw RuntimeFileError("Number of image files exceeds the maximum limit \(imageLimit)")
        }
        return result
    }

    /// Only recognized file values are materialized; ordinary user JSON is not turned into a file by a URL field.
    public func canonicalize(_ value: JSONValue, allowInputMappings: Bool = false) async throws -> JSONValue {
        if RuntimeFile.isFile(value) ||
            (allowInputMappings && value["transfer_method"]?.string != nil &&
             (value["upload_file_id"] != nil || value["reference"] != nil || value["related_id"] != nil ||
              (value["type"] != nil && (value["url"] != nil || value["remote_url"] != nil)))) {
            return try await resolve(value, config: nil).json
        }
        switch value {
        case .array(let values):
            var result: [JSONValue] = []
            let fileList = allowInputMappings && values.allSatisfy { $0.object != nil && $0["transfer_method"]?.string != nil }
            for item in values { result.append(try await canonicalize(item, allowInputMappings: fileList)) }
            return .array(result)
        case .object(let values):
            var result = JSONObject()
            for (key, item) in values { result[key] = try await canonicalize(item) }
            return .object(result)
        default: return value
        }
    }
}
