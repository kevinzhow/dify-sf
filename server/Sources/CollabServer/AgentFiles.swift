import CollabRuntime
import CollabStore
import Crypto
import Foundation
import HTTPTypes
import Vapor

extension Routes {
    /// Progress cannot mint file ownership from an arbitrary ID or URL. It uses
    /// the same completed operation upload receipt as a final declared file.
    func normalizeAgentProgress(_ data: JSONObject, session: StoredAgentSession, files: (any RuntimeFiles)?) async throws -> JSONObject {
        var safe: JSONObject = [:]
        if let caption = data["caption"]?.string {
            safe["caption"] = .string(String(String.UnicodeScalarView(caption.unicodeScalars.prefix(200))))
        }
        if case .int(let index)? = data["call_index"], (1...1000).contains(index) {
            safe["call_index"] = .int(index)
        }
        guard let file = data["file"], let id = file["upload_id"]?.string, UUID(uuidString: id) != nil,
              let mime = file["mime_type"]?.string, ["image/png", "image/jpeg", "image/webp"].contains(mime),
              case .int(let size)? = file["size"], size > 0, size <= 3 << 20 else {
            safe["file_unavailable"] = true
            return safe
        }
        let normalized = try await normalizeAgentFileLeaf(file, definition: ["type": "file"], session: session, files: files)
        if RuntimeFile.isFile(normalized) { safe["file"] = normalized }
        else { safe["file_unavailable"] = true }
        return safe
    }

    func registerAgentUploads(on r: any RoutesBuilder) {
        r.post("inner", "agent", "files", "upload-request") { req in await handle(req) { try await self.reserveAgentFile(req) } }
        r.put("inner", "agent", "files", "uploads", ":upload") { req in await handle(req) { try await self.receiveAgentFile(req) } }
    }

    private func reserveAgentFile(_ req: Request) async throws -> Response {
        let token = try authenticateAgentService(req)
        let scope = try await agentModelScopes.activeScope(token: token)
        try await requireDurableAgentScope(scope)
        let data = try await req.body.collect(max: .specified(ByteCount(value: 4096))) ?? Data()
        let payload = try JSONValue.parse(data)
        guard let name = payload["filename"]?.string, !name.isEmpty, name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"), name != ".", name != "..",
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }),
              let supplied = payload["mime_type"]?.string, case .int(let size)? = payload["size"], size >= 0 else {
            throw Self.invalidParam("Invalid agent upload description")
        }
        let ext = (name as NSString).pathExtension.lowercased(), mime = Self.fileMIME(supplied, ext: (name as NSString).pathExtension.lowercased())
        guard size <= 64 << 20, size <= config.files.limit(for: ext, mime: mime), !config.files.blockedExtensions.contains(ext) else {
            throw ServerError.http(status: 413, code: "file_too_large", message: "The agent output file is not allowed")
        }
        let id = UUID().uuidString.lowercased(), capability = Tokens.random()
        _ = try fileSigner()
        let origin = config.files.internalURL.isEmpty ? config.files.externalURL : config.files.internalURL
        guard var url = URLComponents(string: origin) else { throw ServerError.unavailable("File storage is not configured") }
        url.path = "/inner/agent/files/uploads/" + id
        url.queryItems = [URLQueryItem(name: "cap", value: capability)]
        guard let destination = url.url?.absoluteString else { throw ServerError.unavailable("File storage is not configured") }
        try await store.reserveAgentUpload(id: id, execution: scope.executionID, operation: scope.operationID, generation: scope.generation,
            tokenHash: Tokens.sha256(capability), filename: name, mime: mime, size: size)
        return rawJSON(["url": .string(destination), "upload_id": .string(id)])
    }

    private func receiveAgentFile(_ req: Request) async throws -> Response {
        guard let id = req.parameters.get("upload"), UUID(uuidString: id) != nil,
              let capability = query(req)["cap"], capability.utf8.count <= 512,
              let upload = try await store.claimAgentUpload(id: id, tokenHash: Tokens.sha256(capability)),
              let session = try await store.agentSession(execution: upload.executionID),
              let run = try await store.workflowRun(id: session.workflowRunID), run.status == "running",
              let account = run.executionAccountId ?? run.createdBy else { throw ServerError.missing("Agent upload not found") }
        guard uploadBudget.acquire() else { throw ServerError.http(status: 429, code: "upload_busy", message: "File storage is busy") }
        defer { uploadBudget.release() }
        let bytes = try await req.body.collect(max: .specified(ByteCount(value: upload.size))) ?? Data()
        guard bytes.count == upload.size else { throw Self.invalidParam("Agent upload size does not match its reservation") }
        let ext = (upload.filename as NSString).pathExtension.lowercased()
        guard !config.files.blockedExtensions.contains(ext), bytes.count <= config.files.limit(for: ext, mime: upload.mimeType) else {
            throw ServerError.http(status: 413, code: "file_too_large", message: "The agent output file is not allowed")
        }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let file = StoredUploadFile(id: id, workspaceId: uploadWorkspaceId, key: uploadWorkspaceId + "/" + id, name: upload.filename,
            size: Int64(upload.size), extensionName: ext, mimeType: upload.mimeType, createdBy: account, sha256: digest, endUserId: run.endUserId)
        try await persistUpload(file, bytes: bytes)
        guard try await store.completeAgentUpload(upload, sha256: digest) else { throw ServerError.forbidden(code: "agent_run_inactive", message: "The agent upload is no longer active") }
        // Only a received, published file becomes part of the operation's model/download capability.
        await agentModelScopes.grantFiles(execution: upload.executionID, generation: upload.generation, files: [id])
        return rawJSON(["upload_id": .string(id)], status: .created)
    }

    /// Normalize only declared file leaves. An ordinary object may legitimately contain an upload_id key.
    /// Bad receipts become field failures and take the same retry/default/fail-branch policy as type errors.
    func normalizeAgentCandidate(_ value: JSONValue, session: StoredAgentSession, files: (any RuntimeFiles)?, declarations: [AgentDeclaredOutput]) async throws -> JSONValue {
        guard var object = value.object else { return value }
        for field in declarations {
            if let present = object[field.name] {
                object[field.name] = try await normalizeAgentFileLeaf(present, definition: field.json, session: session, files: files)
            }
        }
        return .object(object)
    }

    private func normalizeAgentFileLeaf(_ value: JSONValue, definition: JSONObject, session: StoredAgentSession, files: (any RuntimeFiles)?, depth: Int = 0) async throws -> JSONValue {
        guard depth < 32 else { return .null }
        if definition["type"] == "file" {
            guard let id = value["upload_id"]?.string,
                  let receipt = try await store.agentUpload(id: id, execution: session.executionID, generation: session.generation),
                  let fileID = receipt.fileID, let files, value["filename"] == .string(receipt.filename),
                  value["mime_type"] == .string(receipt.mimeType), value["size"] == .int(receipt.size),
                  let resolved = try? await files.resolve(["transfer_method": "tool_file", "upload_file_id": .string(fileID)], config: nil) else { return .null }
            return resolved.json
        }
        if definition["type"] == "object", var object = value.object {
            for child in definition["children"]?.array ?? [] {
                if let spec = child.object, let name = spec["name"]?.string, let present = object[name] {
                    object[name] = try await normalizeAgentFileLeaf(present, definition: spec, session: session, files: files, depth: depth + 1)
                }
            }
            return .object(object)
        }
        if definition["type"] == "array", let array = value.array {
            let spec = definition["array_item"]?.object ?? ["type": "object"]
            var normalized: [JSONValue] = []
            for child in array { normalized.append(try await normalizeAgentFileLeaf(child, definition: spec, session: session, files: files, depth: depth + 1)) }
            return .array(normalized)
        }
        return value
    }

}


extension Routes {
    /// Fallbacks are user-configured mappings and use the ordinary scoped file resolver. Model candidates still
    /// require operation upload receipts and cannot use this path to turn arbitrary references into owned files.
    func resolveAgentDefault(definition: JSONObject, value: JSONValue, files: (any RuntimeFiles)?, depth: Int = 0) async throws -> JSONValue {
        guard depth < 32 else { throw RuntimeFileError("Agent default nesting is too deep") }
        if definition["type"] == "file" {
            guard let files else { throw RuntimeFileError("File storage is unavailable") }
            return try await files.resolve(value, config: nil).json
        }
        if definition["type"] == "object", var object = value.object {
            for child in definition["children"]?.array ?? [] {
                if let spec = child.object, let name = spec["name"]?.string, let present = object[name] {
                    object[name] = try await resolveAgentDefault(definition: spec, value: present, files: files, depth: depth + 1)
                }
            }
            return .object(object)
        }
        if definition["type"] == "array", let array = value.array {
            let spec = definition["array_item"]?.object ?? ["type": "object"]
            var resolved: [JSONValue] = []
            for item in array { resolved.append(try await resolveAgentDefault(definition: spec, value: item, files: files, depth: depth + 1)) }
            return .array(resolved)
        }
        return value
    }
}
