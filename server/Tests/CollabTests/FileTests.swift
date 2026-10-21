import CollabCore
import CollabStore
import Crypto
import Foundation
import HTTPTypes
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
