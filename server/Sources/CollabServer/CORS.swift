import HTTPTypes
import Vapor

/// CORS for browser clients (the Flutter web app). Preflight (`OPTIONS`) is answered here, before routing.
/// Allowed origins come from `collab.cors.allowedOrigins`; the default covers local development only.
struct CORSPolicy: Middleware {
    let allowedOrigins: [String]

    static let allowedMethods = "GET, POST, PUT, DELETE, OPTIONS"
    static let allowedHeaders = "Content-Type, Accept, Authorization, Last-Event-ID, Cache-Control"
    static let exposedHeaders = "Content-Type"

    func allows(_ origin: String) -> Bool {
        for pattern in allowedOrigins {
            if pattern == "*" || pattern == origin { return true }
            if pattern.hasSuffix(":*") {
                let prefix = String(pattern.dropLast(1))  // "http://localhost:"
                if origin.hasPrefix(prefix), origin.dropFirst(prefix.count).allSatisfy(\.isNumber), origin.count > prefix.count { return true }
                if origin == String(pattern.dropLast(2)) { return true }  // default port
            }
        }
        return false
    }

    func respond(to request: Request, chainingTo next: any Responder) async throws -> Response {
        let originName = HTTPField.Name("Origin")!
        guard let origin = request.headers[originName] else { return try await next.respond(to: request) }
        let allowed = allows(origin)
        var response: Response
        if request.method == .options {
            response = Response(status: .noContent)
            if allowed {
                response.headers[HTTPField.Name("Access-Control-Allow-Methods")!] = Self.allowedMethods
                response.headers[HTTPField.Name("Access-Control-Allow-Headers")!] = request.headers[HTTPField.Name("Access-Control-Request-Headers")!] ?? Self.allowedHeaders
                response.headers[HTTPField.Name("Access-Control-Max-Age")!] = "600"
            }
        } else {
            response = try await next.respond(to: request)
        }
        response.headers[.vary] = "Origin"
        if allowed {
            response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] = origin
            response.headers[HTTPField.Name("Access-Control-Expose-Headers")!] = Self.exposedHeaders
        }
        return response
    }
}
