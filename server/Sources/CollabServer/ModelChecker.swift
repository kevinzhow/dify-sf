import AsyncHTTPClient
import CollabModels
import Foundation
import Logging
import NIOCore
import NIOHTTP1

/// Sends a credential check (`Validation.Plan`) to the provider. Nil = accepted, else the short reason.
protocol CredentialChecker: Sendable {
    func check(_ plan: Validation.Plan) async -> String?
}

/// The real thing: one request (and possibly its fallback) with AsyncHTTPClient, a timeout, a capped response body and
/// error messages without secrets. Requests and answers are never logged (they carry API keys).
struct HTTPCredentialChecker: CredentialChecker {
    let client: HTTPClient
    let timeout: TimeAmount
    static let maxBody = 64 * 1024

    func check(_ plan: Validation.Plan) async -> String? {
        do {
            var (status, body) = try await send(plan.request)
            if plan.fallbackOn.contains(status), let fallback = plan.fallback {
                (status, body) = try await send(fallback)
            }
            if (200..<300).contains(status) { return nil }
            return Validation.failureMessage(status: status, body: body, secrets: plan.secrets)
        } catch let e as BadURL {
            return e.message
        } catch {
            let host = URL(string: plan.request.url)?.host ?? "the provider"
            return Validation.redact("Cannot reach \(host): \(Self.describe(error))", plan.secrets)
        }
    }

    struct BadURL: Error { var message: String }

    func send(_ r: Validation.Request) async throws -> (Int, Data) {
        guard let url = URL(string: r.url), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else {
            throw BadURL(message: "Invalid base URL")
        }
        var req = HTTPClientRequest(url: r.url)
        req.method = HTTPMethod(rawValue: r.method)
        for (k, v) in r.headers { req.headers.add(name: k, value: v) }
        req.headers.add(name: "User-Agent", value: "dify-sf")
        if let body = r.body { req.body = .bytes(ByteBuffer(bytes: body)) }
        let res = try await client.execute(req, timeout: timeout)
        let buffer = (try? await res.body.collect(upTo: Self.maxBody)) ?? ByteBuffer()
        return (Int(res.status.code), Data(buffer.readableBytesView))
    }

    static func describe(_ error: any Error) -> String {
        if let e = error as? HTTPClientError {
            switch e {
            case .connectTimeout: return "connection timed out"
            case .deadlineExceeded: return "timed out"
            case .remoteConnectionClosed: return "the connection was closed"
            default: return "\(e)"
            }
        }
        let text = "\(error)"
        return text.count > 200 ? String(text.prefix(200)) : text
    }
}

/// The catalog and the credential checker, shared by the model provider routes.
struct ModelService: Sendable {
    let catalog: ModelCatalog
    let checker: any CredentialChecker
    /// `COLLAB_MODELS_VALIDATE`.
    let validate: Bool

    /// The vendored definitions, loaded once per process.
    static let bundledCatalog: Result<ModelCatalog, any Error> = Result { try ModelCatalog.bundled() }

    static func live(config: ServerConfig) throws -> ModelService {
        ModelService(catalog: try bundledCatalog.get(),
                     checker: HTTPCredentialChecker(client: .shared, timeout: .seconds(Int64(config.modelsValidateTimeoutSeconds))),
                     validate: config.modelsValidate)
    }
}
