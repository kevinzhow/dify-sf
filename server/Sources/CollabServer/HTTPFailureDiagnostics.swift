import Logging
import Vapor

/// Error categories, not error messages: messages may contain user input or
/// upstream credentials. The transport separately records framing/parse errors.
enum HTTPFailureDiagnostics {
    static func metadata(requestID: String?, status: Int, code: String, failureCase: String) -> Logger.Metadata {
        let safeCode = !code.isEmpty && code.utf8.count <= 64
            && code.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
        var result: Logger.Metadata = [
            "status": "\(status)", "failure_case": "\(failureCase)", "error_code": "\(safeCode ? code : "unclassified")",
        ]
        if let requestID, requestID.utf8.count == 32,
            requestID.utf8.allSatisfy({ (97...102).contains($0) || (48...57).contains($0) }) {
            result["request_id"] = "\(requestID)"
        }
        return result
    }
}
