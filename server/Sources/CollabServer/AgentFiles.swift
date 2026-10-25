import CollabRuntime
import CollabStore
import Crypto
import Foundation
import HTTPTypes
import Vapor

extension Routes {
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

    func normalizeAgentCandidate(_ value: JSONValue, session: StoredAgentSession, files: (any RuntimeFiles)?, depth: Int = 0) async throws -> JSONValue {
        guard depth < 40 else { throw NodeError("file_error", "Agent output nesting is too deep") }
        if let id = value["upload_id"]?.string {
            guard let receipt = try await store.agentUpload(id: id, execution: session.executionID, generation: session.generation),
                  let fileID = receipt.fileID, let files, value["filename"] == .string(receipt.filename),
                  value["mime_type"] == .string(receipt.mimeType), value["size"] == .int(receipt.size) else {
                throw NodeError("file_error", "An agent output file has no matching received upload")
            }
            let file = try await files.resolve(["transfer_method": "tool_file", "upload_file_id": .string(fileID)], config: nil)
            return file.json
        }
        // A model cannot turn an arbitrary object/ID/URL into an owned runtime file. Only upload receipts cross this boundary.
        if RuntimeFile.isFile(value) { throw NodeError("file_error", "An agent output file must reference its upload receipt") }
        if let object = value.object {
            var normalized = JSONObject()
            for (key, child) in object { normalized[key] = try await normalizeAgentCandidate(child, session: session, files: files, depth: depth + 1) }
            return .object(normalized)
        }
        if let array = value.array {
            var normalized: [JSONValue] = []
            for child in array { normalized.append(try await normalizeAgentCandidate(child, session: session, files: files, depth: depth + 1)) }
            return .array(normalized)
        }
        return value
    }
}
