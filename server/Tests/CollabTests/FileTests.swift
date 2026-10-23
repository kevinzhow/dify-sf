import CollabCore
import CollabRuntime
@testable import CollabStore
import Crypto
import Foundation
import HTTPTypes
import PostgresNIO
import Synchronization
import Testing
import VaporTesting
@testable import CollabServer

private func fileConfig() -> ServerConfig {
    var c = ServerConfig.defaults
    c.files.directory = FileManager.default.temporaryDirectory.appendingPathComponent("uploads-" + UUID().uuidString).path
    c.files.signingKey = Data((0..<48).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
    c.files.externalURL = "http://files.example.test"
    c.files.internalURL = "http://internal.example.test"
    return c
}

private func localPath(_ url: String) -> String {
    let u = URLComponents(string: url)!
    return u.percentEncodedPath + (u.percentEncodedQuery.map { "?" + $0 } ?? "")
}

private func multipart(_ files: [(String, String, String)] = [("file", "notes.txt", "hello")]) -> String {
    files.map { field, filename, bytes in
        "--test-boundary\r\nContent-Disposition: form-data; name=\"\(field)\"; filename=\"\(filename)\"\r\nContent-Type: application/octet-stream\r\n\r\n\(bytes)\r\n"
    }.joined() + "--test-boundary--\r\n"
}

private func upload(_ api: API, _ token: String?, files: [(String, String, String)] = [("file", "notes.txt", "hello")]) async throws -> API.Answer {
    try await api.send(.post, "/v1/files/upload", multipart(files), token: token,
                       headers: [("Content-Type", "multipart/form-data; boundary=test-boundary")])
}

private func withFiles(config: ServerConfig, blobs: (any BlobStore)? = nil,
                       _ body: @Sendable @escaping (API, PostgresStore, Routes) async throws -> Void) async throws {
    try await withStore { store, logger in
        let registry = DocumentRegistry(store: store, config: config, logger: logger)
        let routes = try Routes(registry: registry, store: store, config: config, logger: logger, blobs: blobs)
        try await withApp(configure: { routes.register(on: $0) }) { app in
            try await app.testing { client in try await body(API(client: client), store, routes) }
        }
    }
}

@Suite("File storage signing and blobs")
struct FileStorageTests {
    @Test func signerHasNoDefaultAndMatchesDifyMessageAndEncoding() throws {
        #expect(FileSigner(config: ServerConfig.defaults.files) == nil)
        var c = fileConfig().files
        let signer = try #require(FileSigner(config: c))
        let id = UUID().uuidString.lowercased(), nonce = String(repeating: "a", count: 32), stamp = "1780000000"
        let message = Data(("file-preview|" + id + "|" + stamp + "|" + nonce).utf8)
        let oracle = Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data(c.signingKey.utf8))))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let signed = signer.sign(id: id, timestamp: stamp, nonce: nonce)
        #expect(signed == oracle)
        #expect(signed.hasSuffix("="))
        #expect(signer.verify(id: id, kind: "file", timestamp: stamp, nonce: nonce, signature: signed, now: Date(timeIntervalSince1970: 1780000300)))
        #expect(!signer.verify(id: id, kind: "file", timestamp: stamp, nonce: nonce, signature: signed, now: Date(timeIntervalSince1970: 1780000301)))
        #expect(!signer.verify(id: id, kind: "image", timestamp: stamp, nonce: nonce, signature: signed, now: Date(timeIntervalSince1970: 1780000001)))
        #expect(!signer.verify(id: UUID().uuidString, kind: "file", timestamp: stamp, nonce: nonce, signature: signed))
        #expect(signer.url(id: id).contains("%3D"))
        #expect(FileSigner(config: c, internalAudience: true)?.url(id: id).hasPrefix(c.internalURL) == true)
        c.signingKey = ""; #expect(FileSigner(config: c) == nil)
        c = fileConfig().files; c.externalURL = "http://user:password@files.test"; #expect(FileSigner(config: c) == nil)
    }

    @Test func localAtomicPublicationRejectsPathsAndOverwriteAndClosesOnCancellation() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        let blob = try LocalBlobStore(directory: c.files.directory), id = UUID().uuidString
        let key = uploadWorkspaceId + "/" + id
        await #expect(throws: BlobStoreError.self) { try await blob.putAtomic(key: "../outside", bytes: Data()) }
        let bytes = Data(repeating: 42, count: 300_000)
        try await blob.putAtomic(key: key, bytes: bytes)
        await #expect(throws: (any Error).self) { try await blob.putAtomic(key: key, bytes: Data([1])) }
        #expect(try await blob.info(key: key)?.size == Int64(bytes.count))
        let output = Mutex(Data())
        try await blob.readStream(key: key, range: 127_999..<262_150) { b in output.withLock { $0.append(b) } }
        #expect(output.withLock { $0 } == bytes[127_999..<262_150])
        await #expect(throws: CancellationError.self) {
            try await blob.readStream(key: key, range: 0..<Int64(bytes.count)) { _ in throw CancellationError() }
        }
        try await blob.delete(key: key)
        #expect(try await blob.info(key: key) == nil)
        let parent = c.files.directory + "/" + uploadWorkspaceId
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent).isEmpty)
    }
}

@Suite("File HTTP routes", .enabled(if: testDbHost != nil))
struct FileRouteTests {
    @Test func uploadPreviewAndSignedBytesRangesAndUnsafeDelivery() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, _ in
            let token = try await api.setupOwner()
            let content = String(repeating: "🌲é中", count: 1002)
            let result = try await upload(api, token, files: [("file", "notes.txt", content)])
            #expect(result.status == 201, "\(result.text)")
            #expect(result.str("reference").hasPrefix("dify-file-ref:"))
            #expect(result.json["file_key"] == .null)
            let row = try #require(try await store.uploadFile(id: result.str("id"), workspace: uploadWorkspaceId))
            #expect(row.ready); #expect(row.size == content.utf8.count)
            let preview = try await api.get("/v1/files/\(row.id)/preview", token: token)
            #expect(preview.str("content").unicodeScalars.count == 3000)
            let signed = localPath(result.str("preview_url"))
            let delivery = try await api.get(signed)
            #expect(delivery.status == 200); #expect(delivery.text == content)
            let partial = try await api.send(.get, signed, headers: [("Range", "bytes=0-3")])
            #expect(partial.status == 206); #expect(partial.text == "🌲")
            #expect(try await api.send(.get, signed, headers: [("Range", "bytes=999999-")]).status == 416)
            #expect(try await api.send(.get, signed, headers: [("Range", "bytes=garbage")]).status == 400)
            #expect(try await api.get(signed + "bad").status == 404)
            #expect(try await api.get("/files/\(row.id)/file-preview").status == 400)
            let html = try await upload(api, token, files: [("file", "bad.html", "<script>alert(1)</script>")])
            let raw = try await api.client.send(.get, to: .init(stringLiteral: localPath(html.str("preview_url"))))
            #expect(raw.headers[.contentType] == "application/octet-stream")
            #expect(raw.headers[.contentDisposition]?.hasPrefix("attachment;") == true)
            #expect(raw.headers[.xContentTypeOptions] == "nosniff")
            let pdf = try await upload(api, token, files: [("file", "raw.pdf", "%PDF-1.7")])
            #expect(try await api.get("/v1/files/\(pdf.str("id"))/preview", token: token).status == 415)
            #expect(try await api.get(localPath(pdf.str("preview_url"))).text == "%PDF-1.7")
        }
    }

    @Test func authMultipartLimitsAndTraversal() async throws {
        var c = fileConfig(); c.files.fileMiB = 1; c.files.blockedExtensions = ["exe"]
        let config = c
        defer { try? FileManager.default.removeItem(atPath: config.files.directory) }
        try await withFiles(config: config) { api, _, _ in
            #expect(try await upload(api, nil).status == 401)
            let token = try await api.setupOwner()
            #expect(try await api.get("/v1/files/upload", token: token).status == 200)
            #expect(try await api.get("/v1/system-features").json["enable_file_upload"] == .bool(true))
            for (files, code) in [
                ([], "no_file_uploaded"),
                ([("file", "a.txt", "a"), ("other", "b.txt", "b")], "too_many_files"),
                ([("file", "../bad.txt", "a")], "bad_request"),
                ([("file", "bad.exe", "a")], "file_extension_blocked"),
                ([("file", "", "a")], "filename_not_exists_error")
            ] {
                #expect(try await upload(api, token, files: files).errorCode == code)
            }
            let at = try await upload(api, token, files: [("file", "limit.txt", String(repeating: "x", count: 1024 * 1024))])
            #expect(at.status == 201)
            #expect(try await upload(api, token, files: [("file", "large.txt", String(repeating: "x", count: 1024 * 1024 + 1))]).status == 413)
            let empty = try await upload(api, token, files: [("file", "empty.txt", "")])
            #expect(try await api.get(localPath(empty.str("preview_url"))).status == 200)
        }
    }

    @Test func avatarMustBeOwnUploadWhileAppIconIsWorkspaceSharedAndURLsAreRegenerated() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, _ in
            let owner = try await api.setupOwner()
            let other = try await api.member("other@example.test", role: "editor", inviter: owner)
            let image = try await upload(api, owner, files: [("file", "avatar.png", "image-bytes")])
            let id = image.str("id")
            let profile = try await api.patch("/v1/account/profile", "{\"avatar\":\"\(id)\"}", token: owner)
            #expect(profile.status == 200)
            #expect(profile.str("avatar_url").contains("/files/\(id)/file-preview?"))
            #expect(try await store.account(id: profile.str("id"))?.avatarUrl == id)
            #expect(try await api.patch("/v1/account/profile", "{\"avatar\":\"\(id)\"}", token: other.token).status == 400)
            let app = try await api.post("/v1/apps", "{\"name\":\"Image app\",\"mode\":\"workflow\",\"icon_type\":\"image\",\"icon\":\"\(id)\"}", token: other.token)
            #expect(app.status == 201, "\(app.text)")
            #expect(app.str("icon_url").contains("/files/\(id)/file-preview?"))
            let next = try await api.get("/v1/apps/\(app.str("id"))", token: owner)
            #expect(next.str("icon_url") != app.str("icon_url"))
            let site = try await api.post("/v1/apps/\(app.str("id"))/site", #"{"icon_type":"image","icon":"\#(id)"}"#, token: other.token)
            #expect(site.status == 200)
            #expect(site.str("icon_url").contains("/files/\(id)/file-preview?"))
            let cleared = try await api.patch("/v1/account/profile", #"{"avatar":""}"#, token: owner)
            #expect(cleared.status == 200)
            #expect(try await store.account(id: profile.str("id"))?.avatarUrl == nil)
            #expect(try await api.post("/v1/apps", #"{"name":"Bad","mode":"workflow","icon_type":"image","icon":"unknown"}"#, token: owner).status == 400)
        }
    }

    @Test func sameFilenameConcurrentUploadsKeepIndependentBytes() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, _, _ in
            let token = try await api.setupOwner()
            async let left = upload(api, token, files: [("file", "same.txt", "left")])
            async let right = upload(api, token, files: [("file", "same.txt", "right")])
            let (a, b) = try await (left, right)
            #expect(a.status == 201); #expect(b.status == 201)
            #expect(a.str("id") != b.str("id"))
            #expect(a.str("name") == b.str("name"))
            #expect(try await api.get(localPath(a.str("preview_url"))).text == "left")
            #expect(try await api.get(localPath(b.str("preview_url"))).text == "right")
        }
    }

    @Test func databasePublishFailureNeverReturnsASuccessOrAReadyFile() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, routes in
            let token = try await api.setupOwner()
            _ = try await store.client.query("ALTER TABLE upload_files ADD CONSTRAINT refuse_ready CHECK (NOT ready)", logger: routes.logger)
            #expect(try await upload(api, token).status == 503)
            let pending = try await store.pendingUploads(workspace: uploadWorkspaceId, before: Date().addingTimeInterval(10))
            #expect(pending.count == 1)
            let row = try #require(pending.first)
            #expect(try await store.uploadFile(id: row.id, workspace: uploadWorkspaceId) == nil)
            #expect(try await routes.blobs.info(key: row.key)?.size == 5)
            #expect(try await api.get(localPath(try routes.fileSigner().url(id: row.id))).status == 404)
            _ = try await store.client.query("ALTER TABLE upload_files DROP CONSTRAINT refuse_ready", logger: routes.logger)
            #expect(try await UploadReconciler.run(store: store, blobs: routes.blobs, now: Date().addingTimeInterval(7200)) == 1)
            #expect(try await routes.blobs.info(key: row.key) == nil)
        }
    }

    @Test func foreignWorkspaceFilesStayHiddenEvenWithAValidSignature() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, routes in
            let token = try await api.setupOwner()
            let me = try await api.get("/v1/account", token: token)
            let id = UUID().uuidString.lowercased(), workspace = UUID().uuidString.lowercased()
            let row = StoredUploadFile(id: id, workspaceId: workspace, key: workspace + "/" + id, name: "foreign.png",
                size: 1, extensionName: "png", mimeType: "image/png", createdBy: me.str("id"), sha256: "")
            try await store.insertUploadFile(row)
            try await routes.blobs.putAtomic(key: row.key, bytes: Data([1]))
            _ = try await store.markUploadReady(id, workspace: workspace)
            #expect(try await api.get("/v1/files/\(id)/preview", token: token).status == 404)
            #expect(try await api.get(localPath(try routes.fileSigner().url(id: id))).status == 404)
            #expect(try await api.patch("/v1/account/profile", #"{"avatar":"\#(id)"}"#, token: token).status == 400)
        }
    }

    @Test func unconfiguredStorageIsNotAdvertisedAndHasNoImplicitSecret() async throws {
        try await withServer { api, _, _ in
            let token = try await api.setupOwner()
            #expect(try await api.get("/v1/system-features").json["enable_file_upload"] == .bool(false))
            #expect(try await upload(api, token).status == 503)
        }
    }

    @Test func writeFailureCompensatesPendingMetadataAndBytes() async throws {
        let c = fileConfig(), blob = try FailingFileStore(directory: fileConfig().files.directory)
        defer { try? FileManager.default.removeItem(atPath: blob.local.root) }
        try await withFiles(config: c, blobs: blob) { api, store, _ in
            let token = try await api.setupOwner()
            let result = try await upload(api, token)
            #expect(result.status == 503)
            #expect(try await store.pendingUploads(workspace: uploadWorkspaceId, before: Date().addingTimeInterval(10)).isEmpty)
            let key = try #require(blob.written.withLock { $0 })
            #expect(try await blob.local.info(key: key) == nil)
        }
    }

    @Test func failedCleanupRetainsMetadataAndReservationBlocksPublication() async throws {
        let c = fileConfig(), blob = try FailingFileStore(directory: fileConfig().files.directory)
        blob.failDeletion.withLock { $0 = true }
        defer { try? FileManager.default.removeItem(atPath: blob.local.root) }
        try await withFiles(config: c, blobs: blob) { api, store, _ in
            let token = try await api.setupOwner()
            #expect(try await upload(api, token).status == 503)
            let pending = try await store.pendingUploads(workspace: uploadWorkspaceId, before: Date().addingTimeInterval(10))
            #expect(pending.count == 1)
            let row = try #require(pending.first)
            #expect(try await blob.info(key: row.key)?.size == 5)
            #expect(try await store.markUploadReady(row.id, workspace: uploadWorkspaceId) == false)
            blob.failDeletion.withLock { $0 = false }
            #expect(try await UploadReconciler.run(store: store, blobs: blob, now: Date().addingTimeInterval(7200)) == 1)
            #expect(try await blob.info(key: row.key) == nil)
            #expect(try await store.pendingUploads(workspace: uploadWorkspaceId, before: Date().addingTimeInterval(10)).isEmpty)
        }
    }

    @Test func stalePendingRowsSweepWithoutRemovingReadyFiles() async throws {
        let c = fileConfig(), local = try LocalBlobStore(directory: fileConfig().files.directory)
        defer { try? FileManager.default.removeItem(atPath: local.root) }
        try await withFiles(config: c, blobs: local) { api, store, _ in
            let token = try await api.setupOwner()
            let me = try await api.get("/v1/account", token: token)
            var rows: [StoredUploadFile] = []
            for _ in 0..<2 {
                let id = UUID().uuidString.lowercased(), key = uploadWorkspaceId + "/" + id
                let row = StoredUploadFile(id: id, workspaceId: uploadWorkspaceId, key: key, name: "pending.txt",
                    size: 1, extensionName: "txt", mimeType: "text/plain", createdBy: me.str("id"),
                    createdAt: Date().addingTimeInterval(-7200), sha256: "")
                try await store.insertUploadFile(row); try await local.putAtomic(key: key, bytes: Data([1])); rows.append(row)
            }
            _ = try await store.markUploadReady(rows[1].id, workspace: uploadWorkspaceId)
            #expect(try await UploadReconciler.run(store: store, blobs: local) == 1)
            #expect(try await local.info(key: rows[0].key) == nil)
            #expect(try await local.info(key: rows[1].key)?.size == 1)
            #expect(try await store.uploadFile(id: rows[1].id, workspace: UUID().uuidString) == nil)
            #expect(try await store.uploadFile(id: rows[1].id, workspace: uploadWorkspaceId)?.ready == true)
        }
    }
}

private final class FailingFileStore: BlobStore {
    let local: LocalBlobStore
    let written = Mutex<String?>(nil)
    let failDeletion = Mutex(false)
    init(directory: String) throws { local = try LocalBlobStore(directory: directory) }
    func putAtomic(key: String, bytes: Data) async throws {
        written.withLock { $0 = key }
        try await local.putAtomic(key: key, bytes: bytes)
        throw BlobStoreError.missing
    }
    nonisolated(nonsending) func readStream(key: String, range: Range<Int64>, consume: (Data) async throws -> Void) async throws {
        try await local.readStream(key: key, range: range, consume: consume)
    }
    func info(key: String) async throws -> BlobInfo? { try await local.info(key: key) }
    func delete(key: String) async throws {
        if failDeletion.withLock({ $0 }) { throw BlobStoreError.missing }
        try await local.delete(key: key)
    }
}

@Suite("Runtime file route boundaries", .enabled(if: testDbHost != nil))
struct RuntimeFileRouteTests {
    static let yaml = """
    app: {mode: workflow, name: Runtime files}
    kind: app
    version: 0.3.1
    workflow:
      features:
        file_upload: {enabled: true, allowed_file_types: [image, document], allowed_file_upload_methods: [local_file], number_limits: 2}
      graph:
        edges:
        - {id: e1, source: start, sourceHandle: source, target: end, targetHandle: target}
        nodes:
        - id: start
          data:
            type: start
            title: Start
            variables:
            - {label: File, variable: file, type: file, required: true, allowed_file_types: [document], allowed_file_upload_methods: [local_file]}
            - {label: Files, variable: many, type: file-list, max_length: 2, allowed_file_types: [document], required: true}
        - id: end
          data:
            type: end
            title: End
            outputs:
            - {variable: one, value_selector: [start, file]}
            - {variable: many, value_selector: [start, many]}
            - {variable: system_files, value_selector: [sys, files]}
    """

    @Test func scopedIdentityNeverTrustsClientMetadataPathOrExpiredURL() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, routes in
            let token = try await api.setupOwner()
            let me = try await api.get("/v1/account", token: token)
            let uploaded = try await upload(api, token, files: [("file", "original.txt", "binary\u{0}é")])
            let id = uploaded.str("id")
            let files = ServerWorkflowFiles(routes: routes, userId: me.str("id"))
            let forged: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(id), "filename": "fake.png",
                                     "mime_type": "image/png", "size": 1, "url": "http://expired.test", "storage_key": "/etc/passwd"]
            let resolved = try await files.resolve(forged, config: ["allowed_file_types": ["document"]])
            #expect(resolved.filename == "original.txt" && resolved.type == "document" && resolved.size == "binary\u{0}é".utf8.count)
            #expect(resolved.url != "http://expired.test")
            let remoteReference: JSONValue = ["transfer_method": "remote_url", "upload_file_id": .string(id), "remote_url": "http://untrusted.test"]
            let remote = try await files.resolve(remoteReference, config: nil)
            #expect(remote.remoteURL == remote.url && remote.remoteURL != nil)
            #expect(try await files.bytes(remote.json) == Array("binary\u{0}é".utf8))
            #expect(try await files.bytes(resolved.json) == Array("binary\u{0}é".utf8))
            await #expect(throws: RuntimeFileError.self) { try await files.resolve(forged, config: ["allowed_file_types": ["image"]]) }
            let alien = ServerWorkflowFiles(routes: routes, userId: me.str("id"), workspace: UUID().uuidString.lowercased())
            await #expect(throws: RuntimeFileError.self) { try await alien.resolve(forged, config: nil) }
            let teammate = try await api.member("files-teammate@example.com", role: "editor", inviter: token)
            // Console files belong to the workspace, not only their uploader (public/end-user scope is a later task).
            let teammateFiles = ServerWorkflowFiles(routes: routes, userId: teammate.id)
            #expect(try await teammateFiles.resolve(forged, config: nil).recordId == id)
            let row = try #require(try await store.uploadFile(id: id, workspace: uploadWorkspaceId))
            try await routes.blobs.delete(key: row.key)
            await #expect(throws: RuntimeFileError.self) { try await files.resolve(forged, config: nil) }
            let projected = await routes.projectRuntimeFiles(resolved.json, userId: me.str("id"))
            #expect(projected["url"] == "")
        }
    }

    @Test func actualUploadWholeRunDraftCacheSingleStepAndHistory() async throws {
        let c = fileConfig()
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        try await withFiles(config: c) { api, store, routes in
            let token = try await api.setupOwner()
            let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(Self.yaml)]).compactJSON(), token: token)
            let app = try #require(imported.str("app_id").isEmpty ? nil : imported.str("app_id"))
            let uploaded = try await upload(api, token)
            let file: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(uploaded.str("id"))]
            let head = try await store.documentHead(app)
            let bad = try await api.post("/v1/apps/\(app)/workflows/draft/run", JSONValue.object(["inputs": ["file": file, "many": [file, file, file]]]).compactJSON(), token: token)
            #expect(bad.status == 400, "\(bad.text)")
            let run = try await api.post("/v1/apps/\(app)/workflows/draft/run", JSONValue.object(["inputs": ["file": file, "many": [file]], "files": [file]]).compactJSON(), token: token)
            #expect(run.status == 200, "\(run.text)")
            let events = RunRouteTests.events(run.text)
            let terminal = try #require(events.last)
            #expect(terminal["data"]?["status"] == "succeeded", "\(terminal)")
            #expect(terminal["data"]?["outputs"]?["one"]?["related_id"] == .string(uploaded.str("id")))
            #expect(terminal["data"]?["outputs"]?["many"]?.array?.count == 1)
            #expect(terminal["data"]?["outputs"]?["system_files"]?.array?.first?["filename"] == "notes.txt")
            #expect(try await store.documentHead(app) == head)
            let runId = try #require(terminal["workflow_run_id"]?.string)
            let variables = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflows/draft/nodes/start/variables", token: token).text)
            let cached = try #require(variables["items"]?.array?.first { $0["name"] == "file" })
            #expect(cached["value_type"] == "file")
            let oneId = try #require(cached["id"]?.string)
            // The edit accepts a backing reference and revalidates it; caches never turn a stale link into an input URL.
            let edited = try await api.patch("/v1/apps/\(app)/workflows/draft/variables/\(oneId)", JSONValue.object(["value": file]).compactJSON(), token: token)
            #expect(edited.status == 200, "\(edited.text)")
            let single = try await api.post("/v1/apps/\(app)/workflows/draft/nodes/end/run", #"{"inputs":{}}"#, token: token)
            #expect(single.status == 200 && single.text.contains("__dify__file__"), "\(single.text)")
            let history = try JSONValue.parse(try await api.get("/v1/apps/\(app)/workflow-runs/\(runId)", token: token).text)
            let link = try #require(history["outputs"]?["one"]?["url"]?.string)
            #expect(try await api.get(localPath(link)).status == 200)
            let replay = RunRouteTests.events(try await api.get("/v1/workflow/\(runId)/events?include_state_snapshot=true", token: token).text)
            let replayLink = try #require(replay.last?["data"]?["outputs"]?["one"]?["url"]?.string)
            #expect(try await api.get(localPath(replayLink)).status == 200)
            let me = try await api.get("/v1/account", token: token)
            let stored = try #require(try await store.uploadFile(id: uploaded.str("id"), workspace: uploadWorkspaceId))
            let scope = ServerWorkflowFiles(routes: routes, userId: me.str("id"))
            #expect(try await scope.bytes(["transfer_method": "local_file", "upload_file_id": .string(stored.id)]) == Array("hello".utf8))
        }
    }
}

@Suite("Human input runtime files", .enabled(if: testDbHost != nil))
struct HumanInputRuntimeFileRouteTests {
    @Test func fileAnswerIsValidatedBeforePersistingAndIsRestoredIntoTheActualRun() async throws {
        var c = fileConfig(); c.humanInputWebEnabled = true; c.humanInputEmailEnabled = false
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        let frozen = c
        try await withFiles(config: frozen) { api, store, routes in
            let token = try await api.setupOwner()
            let yaml = HumanInputRunTests.appYAML()
                .replacingOccurrences(of: "{type: paragraph, output_variable_name: reply}", with: "{type: file, output_variable_name: reply, allowed_file_types: [document], allowed_file_upload_methods: [local_file]}")
            let imported = try await api.post("/v1/apps/imports", JSONValue.object(["mode": "yaml-content", "yaml_content": .string(yaml)]).compactJSON(), token: token)
            let app = try #require(imported.str("app_id").isEmpty ? nil : imported.str("app_id"))
            let uploaded = try await upload(api, token)
            let file: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(uploaded.str("id"))]
            let preview = try await api.post(HumanInputNodeRouteTests.path(app, "run"), JSONValue.object([
                "inputs": [:], "form_inputs": ["reply": file], "action": "approve"]).compactJSON(), token: token)
            #expect(preview.status == 200 && preview.text.contains("__dify__file__"), "\(preview.text)")
            let started = try await api.post("/v1/apps/\(app)/workflows/draft/run", #"{"inputs":{}}"#, token: token)
            let frames = HumanInputRunTests.frames(started.text)
            let required = try #require(frames.first { $0["event"] == "human_input_required" })
            let runId = try #require(required["workflow_run_id"]?.string)
            let formToken = try #require(required["data"]?["form_token"]?.string)
            #expect(frames.last?["event"] == "workflow_paused")
            let bad: JSONValue = ["transfer_method": "local_file", "upload_file_id": .string(UUID().uuidString.lowercased())]
            let refused = try await api.post("/v1/form/human_input/\(formToken)", JSONValue.object(["inputs": ["reply": bad], "action": "approve"]).compactJSON(), token: token)
            #expect(refused.status == 400 && refused.errorCode == "invalid_form_data", "\(refused.text)")
            #expect(try await store.humanInputForms(workflowRunId: runId).first?.status == .waiting)
            let answered = try await api.post("/v1/form/human_input/\(formToken)", JSONValue.object(["inputs": ["reply": file], "action": "approve"]).compactJSON(), token: token)
            #expect(answered.status == 200, "\(answered.text)")
            for _ in 0..<100 {
                if try await store.workflowRun(id: runId)?.status == "succeeded" { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            let finished = try #require(try await store.workflowRun(id: runId))
            #expect(finished.status == "succeeded", "\(finished.error ?? "")")
            let output = try JSONValue.parse(finished.outputs ?? "{}")
            #expect(output["reply"]?["related_id"] == .string(uploaded.str("id")))
            let answer = try #require(try await store.humanInputForms(workflowRunId: runId).first)
            let stored = try JSONValue.parse(answer.submittedInputs ?? "{}")
            #expect(RuntimeFile.isFile(stored["reply"] ?? .null))
            let me = try await api.get("/v1/account", token: token)
            #expect(try await ServerWorkflowFiles(routes: routes, userId: me.str("id")).bytes(output["reply"] ?? .null) == Array("hello".utf8))
        }
    }
}


@Suite("Runtime file MIME size boundaries", .enabled(if: testDbHost != nil))
struct RuntimeFileMIMEBoundsTests {
    @Test func imageMimeCannotBorrowTheLargerDocumentLimit() async throws {
        var c = fileConfig(); c.files.imageMiB = 0
        defer { try? FileManager.default.removeItem(atPath: c.files.directory) }
        let config = c
        try await withFiles(config: config) { api, _, routes in
            let token = try await api.setupOwner()
            let data = multipart([( "file", "misnamed.txt", "x")]).replacingOccurrences(of: "application/octet-stream", with: "image/png")
            let uploaded = try await api.send(.post, "/v1/files/upload", data, token: token,
                                               headers: [("Content-Type", "multipart/form-data; boundary=test-boundary")])
            #expect(uploaded.status == 413 && uploaded.errorCode == "file_too_large")
            let user = try await api.get("/v1/account", token: token)
            let files = ServerWorkflowFiles(routes: routes, userId: user.str("id"))
            await #expect(throws: RuntimeFileError.self) {
                try await files.save(bytes: [1], filename: "misnamed.txt", mimeType: "image/png", sourceURL: nil)
            }
        }
    }
}
