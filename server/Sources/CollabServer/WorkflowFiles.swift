// Dify 1.17.1 file_factory builders/validation, workflow file runtime and graphon file models.
// Reuses UploadFiles, the bounded HTTP client and the same atomic publisher as authenticated uploads.
import CollabRuntime
import CollabStore
import Crypto
import Foundation
import Synchronization
import Vapor

struct ServerWorkflowFiles: RuntimeFiles {
    let routes: Routes
    let userId: String
    var endUserId: String? = nil
    var workspace: String = uploadWorkspaceId

    func resolve(_ mapping: JSONValue, config: JSONObject?) async throws -> RuntimeFile {
        guard mapping.object != nil else { throw RuntimeFileError("File mapping must be an object") }
        let method = mapping["transfer_method"]?.string ?? ""
        guard ["local_file", "remote_url", "tool_file"].contains(method) else { throw RuntimeFileError("Invalid file transfer_method") }
        _ = try routes.fileSigner()
        var record: StoredUploadFile
        if let id = RuntimeFile.recordId(in: mapping) {
            guard let stored = try await routes.store.uploadFile(id: id, workspace: workspace),
                  (endUserId == nil ? stored.endUserId == nil : stored.endUserId == endUserId),
                  let info = try await routes.blobs.info(key: stored.key), info.size == stored.size else {
                throw RuntimeFileError("File not found")
            }
            record = stored
        } else {
            guard method == "remote_url", let raw = mapping["url"]?.string.flatMap({ $0.isEmpty ? nil : $0 }) ?? mapping["remote_url"]?.string,
                  let url = URLComponents(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { throw RuntimeFileError("Missing or invalid file reference") }
            // Never bypass the strict proxy to fetch remote URLs, even for a URL that resembles our own preview.
            guard !routes.config.runtimeServices.ssrfProxyURL.isEmpty else { throw RuntimeFileError("Remote files require the SSRF proxy") }
            let response = try await routes.config.runtimeServices.httpClient.send(.init(method: "GET", url: raw, readTimeout: 30, writeTimeout: 10))
            guard (200..<300).contains(response.status) else { throw RuntimeFileError("Remote file could not be downloaded") }
            let mime = response.headers.first { $0.name.lowercased() == "content-type" }?.value.components(separatedBy: ";").first ?? "application/octet-stream"
            let name = Self.remoteFilename(response.headers, url: raw, mime: mime)
            let ext = (name as NSString).pathExtension.lowercased()
            let candidate = RuntimeFile(recordId: "", type: Self.fileType(ext: ext, mime: mime), transferMethod: method,
                                        filename: name, extensionName: ext, mimeType: mime, size: response.body.count, url: "", remoteURL: raw)
            try RuntimeFile.validate(candidate, config: config)
            let file = try await save(bytes: response.body, filename: name, mimeType: mime, sourceURL: raw)
            guard let stored = try await routes.store.uploadFile(id: file.recordId, workspace: workspace) else { throw RuntimeFileError("File not found") }
            record = stored
        }
        guard record.size >= 0, record.size <= routes.config.files.limit(for: record.extensionName, mime: record.mimeType),
              !routes.config.files.blockedExtensions.contains(record.extensionName) else { throw RuntimeFileError("File type or size is not allowed") }
        let file = try canonical(record, method: method)
        try RuntimeFile.validate(file, config: config)
        return file
    }

    func canonical(_ record: StoredUploadFile, method: String) throws -> RuntimeFile {
        let signer = try routes.fileSigner()
        let signedURL = signer.url(id: record.id)
        return RuntimeFile(recordId: record.id, type: Self.fileType(ext: record.extensionName, mime: record.mimeType),
                           transferMethod: method, filename: record.name, extensionName: record.extensionName,
                           mimeType: record.mimeType, size: Int(record.size), url: signedURL,
                           remoteURL: method == "remote_url" ? signedURL : nil)
    }

    func bytes(_ value: JSONValue) async throws -> [UInt8] {
        let file = try await resolve(value, config: nil)
        guard let record = try await routes.store.uploadFile(id: file.recordId, workspace: workspace),
              record.size <= routes.config.files.limit(for: record.extensionName, mime: record.mimeType) else { throw RuntimeFileError("File size exceeded") }
        let box = WorkflowFileBytes()
        try await routes.blobs.readStream(key: record.key, range: 0..<record.size) { part in
            try box.append(part, limit: Int(record.size))
        }
        let bytes = box.bytes()
        guard bytes.count == record.size,
              SHA256.hash(data: Data(bytes)).map({ String(format: "%02x", $0) }).joined() == record.sha256 else {
            throw RuntimeFileError("File content is missing or changed")
        }
        return bytes
    }

    func save(bytes: [UInt8], filename: String, mimeType: String, sourceURL: String?) async throws -> RuntimeFile {
        guard !filename.isEmpty, !filename.contains("/"), !filename.contains("\\"),
              !filename.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw RuntimeFileError("Filename contains invalid characters")
        }
        let ext = (filename as NSString).pathExtension.lowercased()
        guard !routes.config.files.blockedExtensions.contains(ext), bytes.count <= routes.config.files.limit(for: ext, mime: Routes.fileMIME(mimeType, ext: ext)) else {
            throw RuntimeFileError("File type or size is not allowed")
        }
        guard routes.uploadBudget.acquire() else { throw RuntimeFileError("File storage is busy; retry shortly") }
        defer { routes.uploadBudget.release() }
        _ = try routes.fileSigner()
        let id = UUID().uuidString.lowercased()
        let name = filename.count > 200 ? String(filename.prefix(180)) + "." + ext : filename
        let stored = StoredUploadFile(id: id, workspaceId: workspace, key: "\(workspace)/\(id)", name: name,
            size: Int64(bytes.count), extensionName: ext, mimeType: Routes.fileMIME(mimeType, ext: ext), createdBy: userId,
            sha256: SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(), sourceURL: sourceURL, endUserId: endUserId)
        try await routes.persistUpload(stored, bytes: Data(bytes))
        return try canonical(stored, method: sourceURL == nil ? "tool_file" : "remote_url")
    }

    static func fileType(ext: String, mime: String) -> String {
        if ["jpg", "jpeg", "png", "webp", "gif", "svg"].contains(ext) || mime.hasPrefix("image/") { return "image" }
        if ["mp4", "mov", "mpeg", "webm"].contains(ext) || mime.hasPrefix("video/") { return "video" }
        if ["mp3", "m4a", "wav", "amr", "mpga"].contains(ext) || mime.hasPrefix("audio/") { return "audio" }
        if ["txt", "markdown", "md", "mdx", "pdf", "html", "htm", "xlsx", "xls", "vtt", "properties", "doc", "docx",
            "csv", "eml", "msg", "ppt", "pptx", "xml", "epub", "odt"].contains(ext) || mime.hasPrefix("text/") ||
            ["application/pdf", "application/epub+zip", "application/msword"].contains(mime) ||
            mime.hasPrefix("application/vnd.openxmlformats-officedocument") { return "document" }
        return "custom"
    }

    static func remoteFilename(_ headers: [(name: String, value: String)], url: String, mime: String) -> String {
        let name = RuntimeFileHeaders.filename(in: headers) ?? URL(string: url)?.lastPathComponent.removingPercentEncoding
        if let name, !name.isEmpty { return name }
        return "file." + (["image/png": "png", "image/jpeg": "jpg", "application/pdf": "pdf", "text/plain": "txt"][mime] ?? "bin")
    }
}

private final class WorkflowFileBytes: Sendable {
    let data = Mutex([UInt8]())
    func append(_ bytes: Data, limit: Int) throws {
        try data.withLock { out in
            guard out.count <= limit - bytes.count else { throw RuntimeFileError("File size exceeded") }
            out.append(contentsOf: bytes)
        }
    }
    func bytes() -> [UInt8] { data.withLock { $0 } }
}


extension Routes {
    /// Re-sign only DB-backed files authorized in this workspace. Merely storing a file-shaped JSON object cannot
    /// mint a bearer link or make an outbound request. Missing/deleted files stay visible but have no usable link.
    func projectRuntimeFiles(_ value: JSONValue, userId: String, endUserId: String? = nil) async -> JSONValue {
        if RuntimeFile.isFile(value) {
            if RuntimeFile.recordId(in: value) != nil,
               let file = try? await ServerWorkflowFiles(routes: self, userId: userId, endUserId: endUserId).resolve(value, config: nil) { return file.json }
            var missing = value.object ?? [:]
            missing["url"] = ""; missing["remote_url"] = .null
            return .object(missing)
        }
        switch value {
        case .array(let items):
            var projected: [JSONValue] = []
            for item in items { projected.append(await projectRuntimeFiles(item, userId: userId, endUserId: endUserId)) }
            return .array(projected)
        case .object(let object):
            var projected = JSONObject()
            for (key, item) in object { projected[key] = await projectRuntimeFiles(item, userId: userId, endUserId: endUserId) }
            return .object(projected)
        default: return value
        }
    }
    func fileJSONResponse(_ value: JSONValue, userId: String, endUserId: String? = nil) async -> Response {
        rawJSON(await projectRuntimeFiles(value, userId: userId, endUserId: endUserId))
    }
}
