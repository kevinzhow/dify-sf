// Ported from Dify 1.17.1 (https://github.com/langgenius/dify): api/core/plugin/impl/base.py (stream responses and
// their errors), api/core/plugin/impl/model.py (dispatch payloads). See NOTICE.md.
//
// The wire format of Dify's plugin daemon (0.6.x), without I/O: request bodies and the line stream of
// `{"code", "message", "data"}` objects every dispatch endpoint answers. The HTTP client is the server's.

/// Request bodies and responses of the plugin daemon's dispatch API (`POST /plugin/{tenant}/dispatch/...`, headers
/// `X-Api-Key`, `X-Plugin-ID`, `Content-Type: application/json`).
public enum PluginDaemonWire {
    /// `_dispatch_payload`: `{"data": ..., "user_id": ..., "app_id": ...}` (absent members omitted).
    public static func dispatchBody(userId: String?, appId: String?, data: JSONObject) -> JSONValue {
        var o: JSONObject = ["data": .object(data)]
        if let userId { o["user_id"] = .string(userId) }
        if let appId { o["app_id"] = .string(appId) }
        return .object(o)
    }

    /// `dispatch/llm/invoke`'s data.
    public static func llmInvokeData(provider: String, model: String, credentials: JSONObject, promptMessages: [PromptMessage],
                                     parameters: JSONObject, tools: [PromptMessageTool] = [], stop: [String],
                                     stream: Bool = true) -> JSONObject {
        [
            "provider": .string(provider),
            "model_type": "llm",
            "model": .string(model),
            "credentials": .object(credentials),
            "prompt_messages": .array(promptMessages.map(\.json)),
            "model_parameters": .object(parameters),
            "tools": tools.isEmpty ? .null : .array(tools.map(\.json)),
            "stop": stop.isEmpty ? .null : .array(stop.map(JSONValue.string)),
            "stream": .bool(stream),
        ]
    }

    /// `dispatch/model/schema`'s data.
    public static func modelSchemaData(provider: String, modelType: String, model: String, credentials: JSONObject) -> JSONObject {
        ["provider": .string(provider), "model_type": .string(modelType), "model": .string(model), "credentials": .object(credentials)]
    }

    /// An error the daemon reported (or a line it could not have meant).
    public struct DaemonError: Error, CustomStringConvertible, Sendable {
        public var errorType: String
        public var message: String
        public var httpStatus: Int?
        public init(errorType: String, message: String, httpStatus: Int? = nil) {
            self.errorType = errorType
            self.message = message
            self.httpStatus = httpStatus
        }
        public var description: String { message }
    }

    /// One line of a stream response (`_request_with_plugin_daemon_response_stream`): nil for blank lines, else the
    /// `data` member. A non-zero `code` throws: daemon errors carry `{"error_type", "message"}` JSON in `message`, and a
    /// `PluginInvokeError` carries the model's error the same way (`InvokeAuthorizationError`, ...), which is thrown as a
    /// `ModelInvokeError`.
    public static func decodeLine(_ raw: String) throws -> JSONValue? {
        var line = raw.trimmingWhitespace()
        if line.hasPrefix("data:") { line = String(line.dropFirst(5)).trimmingWhitespace() }
        if line.isEmpty { return nil }
        guard let obj = try? JSONValue.parse(line), case .object(let o) = obj else {
            throw DaemonError(errorType: "ValueError", message: line)
        }
        guard let code = o["code"]?.int else {
            // Not a daemon envelope: Dify raises ValueError(line_data.get("error", line)).
            throw DaemonError(errorType: "ValueError", message: o["error"].map(PythonText.str) ?? line)
        }
        let message = o["message"]?.string ?? ""
        if code != 0 {
            if code == -500, let inner = try? JSONValue.parse(message), let errorType = inner["error_type"]?.string {
                let innerMessage = inner["message"]?.string ?? ""
                if errorType == "PluginInvokeError", let invoke = try? JSONValue.parse(innerMessage), let t = invoke["error_type"]?.string {
                    throw ModelInvokeError(errorType: t, message: invoke["message"].map(PythonText.str) ?? "")
                }
                if errorType == "PluginInvokeError" { throw ModelInvokeError(errorType: "PluginInvokeError", message: innerMessage) }
                throw DaemonError(errorType: errorType, message: innerMessage)
            }
            throw DaemonError(errorType: "ValueError", message: "plugin daemon: \(message), code: \(code)")
        }
        guard let data = o["data"], data != .null else {
            throw DaemonError(errorType: "ValueError", message: "got empty data from plugin daemon")
        }
        return data
    }
}

extension String {
    func trimmingWhitespace() -> String {
        var s = Substring(self)
        while let f = s.first, f.isWhitespace { s.removeFirst() }
        while let l = s.last, l.isWhitespace { s.removeLast() }
        return String(s)
    }
}

extension PluginDaemonWire.DaemonError: NodeRunError {
    public var errorTypeName: String { errorType }
}

extension ModelInvokeError: NodeRunError {
    public var errorTypeName: String { errorType }
}
