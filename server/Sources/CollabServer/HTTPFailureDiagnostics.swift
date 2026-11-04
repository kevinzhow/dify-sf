import Logging
import Vapor

/// Error categories, not error messages: messages may contain user input or
/// upstream credentials. The transport separately records framing/parse errors.
enum HTTPFailureDiagnostics {
    static func validatedRequestID(_ value: String?) -> String? {
        guard let value, value.utf8.count == 32,
            value.utf8.allSatisfy({ (97...102).contains($0) || (48...57).contains($0) }) else { return nil }
        return value
    }

    static func metadata(requestID: String?, status: Int, code: String, failureCase: String) -> Logger.Metadata {
        let safeCode = !code.isEmpty && code.utf8.count <= 64
            && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
        var result: Logger.Metadata = [
            "status": "\(status)", "failure_case": "\(failureCase)", "error_code": "\(safeCode ? code : "unclassified")",
        ]
        if let id = validatedRequestID(requestID) { result["request_id"] = "\(id)" }
        return result
    }
}
