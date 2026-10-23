import CollabCore
import CollabModels
import CollabStore
import Crypto
import Foundation
import HTTPTypes
import MultipartKit
import Synchronization
import Vapor

/// The workspace is singleton throughout dify-sf, including accounts and app metadata.
let uploadWorkspaceId = ServerConfig.defaultPluginDaemonTenant

final class UploadBudget: Sendable {
    private let active = Mutex(0)
    func acquire() -> Bool { active.withLock { if $0 >= 2 { return false }; $0 += 1; return true } }
    func release() { active.withLock { $0 -= 1 } }
}

private final class PreviewBytes: Sendable {
    let value = Mutex(Data())
}

extension Routes {
    func registerFiles(on r: any RoutesBuilder) {
        r.get("v1", "files", "upload") { req in await handle(req) { try await uploadConfig(req) } }
        r.post("v1", "files", "upload") { req in await handle(req) { try await uploadFile(req) } }
        r.get("v1", "files", "support-type") { req in await handle(req) { try await fileSupportTypes(req) } }
        r.get("v1", "files", ":file", "preview") { req in await handle(req) { try await textFilePreview(req) } }
        r.get("files", ":file", "file-preview") { req in await handle(req) { try await deliverFile(req, kind: "file") } }
        r.get("files", ":file", "image-preview") { req in await handle(req) { try await deliverFile(req, kind: "image") } }
    }

    func fileSigner() throws -> FileSigner {
        guard let signer = FileSigner(config: config.files) else {
            throw ServerError.http(status: 503, code: "file_storage_not_configured",
                                   message: "File storage needs a signing key and a configured files URL.")
        }
        return signer
    }

    private func uploadConfig(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        _ = try fileSigner()
        let c = config.files
        return try json(["file_size_limit": c.fileMiB, "knowledge_file_size_limit": c.fileMiB,
            "batch_count_limit": 5, "file_upload_limit": 5, "image_file_size_limit": c.imageMiB,
            "video_file_size_limit": c.videoMiB, "audio_file_size_limit": c.audioMiB,
            "skill_file_size_limit": 30, "workflow_file_upload_limit": 10, "image_file_batch_limit": 10,
            "single_chunk_attachment_limit": 10, "attachment_image_file_size_limit": c.imageMiB])
    }

    private func fileSupportTypes(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        _ = try fileSigner()
        return try json(["allowed_extensions": FileStorageConfig.text.sorted()])
    }

    private func uploadFile(_ req: Request) async throws -> Response {
        let p = try await authenticate(req)
        _ = try fileSigner()
        guard uploadBudget.acquire() else {
            throw ServerError.http(status: 429, code: "upload_busy", message: "Two uploads are already being processed; retry shortly.")
        }
        defer { uploadBudget.release() }
        guard let boundary = req.headers.contentType?.parameters["boundary"], !boundary.isEmpty,
              boundary.utf8.count <= 200, req.headers[.contentType]?.lowercased().hasPrefix("multipart/form-data") == true else {
            throw Self.bad("no_file_uploaded", "Please upload your file.")
        }
        let data: Data
        do { data = try await req.body.collect(max: .specified(ByteCount(value: config.files.maximumBody))) ?? Data() }
        catch let e as Abort where e.status == .contentTooLarge {
            throw ServerError.http(status: 413, code: "file_too_large", message: "File size exceeded.")
        }
        let parts: [MultipartPart<Data>]
        do { parts = try MultipartParser<Data>(boundary: boundary).parse(data) }
        catch { throw Self.bad("bad_request", "Invalid multipart form data.") }
        var uploads: [(name: String, file: MultipartPart<Data>, filename: String)] = []
        var source = query(req)["source"]
        do {
            for part in parts {
                guard let field = part.headerFields[.contentDisposition] else { continue }
                let disposition = try MultipartKit.ContentDisposition(from: field)
                if let filename = disposition.filename {
                    uploads.append((disposition.name ?? "", part, filename))
                } else if disposition.name == "source" { source = String(data: part.body, encoding: .utf8) }
            }
        } catch { throw Self.bad("bad_request", "Invalid multipart headers.") }
        guard uploads.contains(where: { $0.name == "file" }) else { throw Self.bad("no_file_uploaded", "Please upload your file.") }
        guard uploads.count == 1 else { throw Self.bad("too_many_files", "Only one file is allowed.") }
        guard source != "datasets" else {
            throw ServerError.http(status: 400, code: "unsupported_upload_source", message: "Knowledge ingestion is not supported.")
        }
        let item = uploads[0]
        guard !item.filename.isEmpty else { throw Self.bad("filename_not_exists_error", "The specified filename does not exist.") }
        guard !item.filename.contains("/"), !item.filename.contains("\\"),
              !item.filename.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw Self.bad("bad_request", "Filename contains invalid characters.")
        }
        let ext = (item.filename as NSString).pathExtension.lowercased()
        guard !config.files.blockedExtensions.contains(ext) else {
            throw Self.bad("file_extension_blocked", "The file extension is blocked for security reasons.")
        }
        let rawMIME = item.file.headerFields[.contentType]?.split(separator: ";").first.map(String.init) ?? "application/octet-stream"
        let mime = Self.fileMIME(rawMIME, ext: ext)
        guard item.file.body.count <= config.files.limit(for: ext, mime: mime) else {
            throw ServerError.http(status: 413, code: "file_too_large", message: "File size exceeded.")
        }
        var name = item.filename
        if name.count > 200 { name = String(name.split(separator: ".").first?.prefix(200) ?? "") + "." + ext }
        let id = UUID().uuidString.lowercased()
        let file = StoredUploadFile(id: id, workspaceId: uploadWorkspaceId, key: "\(uploadWorkspaceId)/\(id)", name: name,
            size: Int64(item.file.body.count), extensionName: ext, mimeType: mime, createdBy: p.id,
            sha256: SHA256.hash(data: item.file.body).map { String(format: "%02x", $0) }.joined())
        try await persistUpload(file, bytes: item.file.body)
        return try json(fileJSON(file), status: .created)
    }

    /// Shared publication/compensation path for browser uploads and runtime-produced/downloaded bytes.
    func persistUpload(_ file: StoredUploadFile, bytes: Data) async throws {
        try await storeCall { try await store.insertUploadFile(file) }
        do {
            try await blobs.putAtomic(key: file.key, bytes: bytes)
        } catch {
            // The row cannot be ready yet, so compensating it cannot remove a published file.
            // Retain metadata if deletion fails, so maintenance can retry after restart.
            if let key = try? await store.claimPendingUploadCleanup(id: file.id, workspace: file.workspaceId) {
                do {
                    try await blobs.delete(key: key)
                    _ = try await store.removePendingUpload(id: file.id, workspace: file.workspaceId)
                } catch { logger.warning("unfinished file cleanup will be retried") }
            }
            logger.warning("file upload could not be written")
            throw ServerError.http(status: 503, code: "file_write_failed", message: "The file could not be saved. Retry the upload.")
        }
        // An uncertain UPDATE may have committed: preserve the bytes rather than deleting a now-ready file.
        guard try await storeCall({ try await store.markUploadReady(file.id, workspace: file.workspaceId) }) else {
            try? await blobs.delete(key: file.key)
            throw ServerError.http(status: 503, code: "file_write_failed", message: "The file could not be published.")
        }
    }

    static func fileMIME(_ supplied: String, ext: String) -> String {
        let safe = supplied.trimmingCharacters(in: .whitespaces).lowercased()
        let pieces = safe.split(separator: "/", omittingEmptySubsequences: false)
        if pieces.count == 2, pieces.allSatisfy({ !$0.isEmpty }),
           safe.utf8.allSatisfy({ (33...126).contains($0) && $0 != 34 && $0 != 92 }) {
            if safe != "application/octet-stream" { return safe }
        }
        return ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
                "webp": "image/webp", "bmp": "image/bmp", "txt": "text/plain", "md": "text/markdown",
                "json": "application/json", "csv": "text/csv", "svg": "image/svg+xml",
                "html": "text/html", "htm": "text/html"][ext] ?? "application/octet-stream"
    }

    func fileJSON(_ f: StoredUploadFile) throws -> JSON {
        let signer = try fileSigner()
        let reference = "dify-file-ref:" + Data("{\"record_id\":\"\(f.id)\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return .object(["id": .string(f.id), "reference": .string(reference), "name": .string(f.name),
            "size": .int(Int(f.size)), "extension": .string(f.extensionName), "mime_type": .string(f.mimeType),
            "created_by": .string(f.createdBy), "created_at": .int(Self.seconds(f.createdAt)),
            "preview_url": .string(signer.url(id: f.id)), "source_url": f.sourceURL.map(JSON.string) ?? .null,
            "original_url": .null, "user_id": .null, "tenant_id": .string(f.workspaceId), "conversation_id": .null, "file_key": .null])
    }

    private func uploadedFile(_ req: Request) async throws -> StoredUploadFile {
        guard let raw = req.parameters.get("file"), let uuid = UUID(uuidString: raw),
              let file = try await storeCall({ try await store.uploadFile(id: uuid.uuidString.lowercased(), workspace: uploadWorkspaceId) }),
              let info = try await blobs.info(key: file.key), info.size == file.size else {
            throw ServerError.missing("File not found or signature is invalid")
        }
        return file
    }

    private func textFilePreview(_ req: Request) async throws -> Response {
        _ = try await authenticate(req)
        _ = try fileSigner()
        let file = try await uploadedFile(req)
        guard FileStorageConfig.text.contains(file.extensionName) else {
            throw ServerError.http(status: 415, code: "unsupported_file_type", message: "Text extraction is not supported for this type. Download the original file.")
        }
        let output = PreviewBytes()
        try await blobs.readStream(key: file.key, range: 0..<file.size) { part in output.value.withLock { $0.append(part) } }
        guard let text = output.value.withLock({ String(data: $0, encoding: .utf8) }) else {
            throw ServerError.http(status: 415, code: "unsupported_file_type", message: "Text preview requires UTF-8.")
        }
        return try json(["content": String(String.UnicodeScalarView(text.unicodeScalars.prefix(3000)))])
    }

    private func deliverFile(_ req: Request, kind: String) async throws -> Response {
        let signer = try fileSigner(), q = query(req)
        guard let timestamp = q["timestamp"], let nonce = q["nonce"], let sign = q["sign"] else {
            throw Self.bad("bad_request", "timestamp, nonce and sign are required.")
        }
        guard let raw = req.parameters.get("file"), let uuid = UUID(uuidString: raw),
              signer.verify(id: uuid.uuidString.lowercased(), kind: kind, timestamp: timestamp, nonce: nonce, signature: sign) else {
            throw ServerError.missing("File not found or signature is invalid")
        }
        let file = try await uploadedFile(req)
        if kind == "image", !FileStorageConfig.images.contains(file.extensionName) {
            throw ServerError.http(status: 415, code: "unsupported_file_type", message: "File type not allowed.")
        }
        var headers = HTTPFields()
        headers[.contentType] = file.mimeType
        headers[.acceptRanges] = "bytes"
        headers[.xContentTypeOptions] = "nosniff"
        headers[.cacheControl] = "private, no-cache"
        let tag = "\"\(file.sha256)\""
        headers[.eTag] = tag
        let passiveTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/bmp", "image/heic",
            "image/heif", "application/pdf", "text/plain", "audio/mpeg", "audio/mp4", "audio/wav", "audio/ogg",
            "audio/flac", "audio/webm", "video/mp4", "video/webm", "video/quicktime"]
        let unsafe = !passiveTypes.contains(file.mimeType) ||
            ["svg", "html", "htm", "xhtml", "js", "mjs"].contains(file.extensionName)
        if unsafe || q["as_attachment"] == "true" || q["as_attachment"] == "1" {
            let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789!#$&+-.^_|~")
            headers[.contentType] = "application/octet-stream"
            headers[.contentDisposition] = "attachment; filename*=UTF-8''" + file.name.addingPercentEncoding(withAllowedCharacters: safe)!
        }
        if req.headers[.ifNoneMatch] == tag {
            var response = Response(status: .notModified, headers: headers, body: .empty)
            response.headers[.contentLength] = nil
            return response
        }
        var offset: Int64 = 0, count = file.size
        var status: HTTPResponse.Status = .ok
        // Vapor's range parser is reused; its bounds resolver is module-internal, so bounds are normalized here.
        if req.headers[.range] != nil {
            guard let range = req.headers.range else { throw Self.bad("bad_request", "Malformed Range header.") }
            if range.unit == .bytes, range.ranges.count == 1, let value = range.ranges.first,
               req.headers[.ifRange] == nil || req.headers[.ifRange] == tag {
                switch value {
                case .start(let start):
                    offset = Int64(start); count = file.size - offset
                case .tail(let suffix):
                    count = min(file.size, Int64(suffix)); offset = file.size - count
                case .within(let start, let end):
                    offset = Int64(start); count = min(file.size - 1, Int64(end)) - offset + 1
                }
                guard offset >= 0, count > 0, offset < file.size else {
                    headers[.contentRange] = "bytes */\(file.size)"
                    return Response(status: .rangeNotSatisfiable, headers: headers, body: .empty)
                }
                status = .partialContent
                headers[.contentRange] = "bytes \(offset)-\(offset + count - 1)/\(file.size)"
            }
        }
        let window = offset..<(offset + count)
        let storage = blobs, key = file.key
        let body = try Response.Body(stream: { writer in
            try await storage.readStream(key: key, range: window) { bytes in try await writer.write(bytes) }
        }, count: Int(count))
        return Response(status: status, headers: headers, body: body)
    }

    /// Canonical file id is persisted; the short-lived URL is materialized afresh on every response.
    func signedAvatar(_ raw: String?) -> String? {
        guard let raw else { return nil }
        if let uuid = UUID(uuidString: raw) {
            return FileSigner(config: config.files)?.url(id: uuid.uuidString.lowercased())
        }
        return (raw.hasPrefix("http://") || raw.hasPrefix("https://")) ? raw : nil
    }

    func validateImageFile(_ id: String, owner: String? = nil) async throws {
        guard let uuid = UUID(uuidString: id) else { throw Self.bad("invalid_image_file", "Choose an uploaded image.") }
        _ = try fileSigner()
        guard
              let file = try await storeCall({ try await store.uploadFile(id: uuid.uuidString.lowercased(), workspace: uploadWorkspaceId) }),
              FileStorageConfig.images.contains(file.extensionName), owner == nil || file.createdBy == owner,
              let info = try await blobs.info(key: file.key), info.size == file.size else {
            throw Self.bad("invalid_image_file", "Choose an uploaded image you are allowed to use.")
        }
    }
}

/// Called after migrations: the other live process has an hour to finish its bounded upload before reconciliation.
enum UploadReconciler {
    static func run(store: PostgresStore, blobs: any BlobStore, now: Date = Date()) async throws -> Int {
        let old = try await store.pendingUploads(workspace: uploadWorkspaceId, before: now.addingTimeInterval(-3600))
        var removed = 0
        for file in old {
            if let key = try await store.claimPendingUploadCleanup(id: file.id, workspace: uploadWorkspaceId) {
                try await blobs.delete(key: key)
                _ = try await store.removePendingUpload(id: file.id, workspace: uploadWorkspaceId)
                removed += 1
            }
        }
        return removed
    }
}
