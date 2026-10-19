import Foundation

/// The credential check on save: one cheap request per API dialect, built here (pure) and sent by the server.
///
/// Dify asks the provider's plugin (`validate_provider_credentials`, often a real completion). dify-sf has no model runtime,
/// so it makes one inexpensive authenticated request instead:
///
/// | dialect | providers | request |
/// |---|---|---|
/// | OpenAI style | openai, deepseek, moonshot, tongyi (compatible mode), zhipuai | `GET {base}/models`, `Authorization: Bearer` |
/// | OpenAI-API-compatible | openai_api_compatible | `GET {endpoint}/models`; on 404/405 a 1-token chat (or completion) request |
/// | Anthropic | anthropic | `GET {base}/v1/models?limit=1`, `x-api-key`, `anthropic-version` |
/// | Gemini | google | `GET {base}/v1beta/models?pageSize=1`, `x-goog-api-key` |
/// | Ollama | ollama | `POST {base_url}/api/show {"model"}` |
/// | Azure OpenAI | azure_openai (API key auth) | `GET {endpoint}/openai/models?api-version=`, `api-key` |
///
/// Secrets go only into headers (never into URLs), so nothing secret can end up in a URL in a log.
public enum Validation {
    public struct Request: Sendable, Equatable {
        public var method: String
        public var url: String
        public var headers: [String: String]
        public var body: Data?
    }

    /// The first request, and the one to send instead when the first answers one of `fallbackOn`.
    public struct Plan: Sendable, Equatable {
        public var request: Request
        public var fallback: Request?
        public var fallbackOn: Set<Int>
        /// Values that must never appear in an error message (the secrets of the credentials).
        public var secrets: [String]
    }

    /// The check for `credentials` (provider credentials when `model` is nil, else a custom model's), or nil when there
    /// is none for this provider/configuration (the credentials are saved unchecked).
    public static func plan(provider: ProviderDefinition, model: String?, modelType: String?, credentials c: [String: JSON]) -> Plan? {
        func s(_ k: String) -> String? {
            guard let v = c[k]?.scalarText?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
            return v
        }
        func trimmed(_ base: String) -> String { var b = base; while b.hasSuffix("/") { b.removeLast() }; return b }
        func v1(_ base: String) -> String { let b = trimmed(base); return b.hasSuffix("/v1") ? b : b + "/v1" }
        let secretKeys = provider.secretVariables(forModel: model != nil)
        let secrets = secretKeys.compactMap { s($0) }
        func bearer(_ url: String, _ key: String?, extra: [String: String] = [:]) -> Plan {
            var h = extra
            if let key { h["Authorization"] = "Bearer \(key)" }
            return Plan(request: Request(method: "GET", url: url, headers: h, body: nil), fallback: nil, fallbackOn: [], secrets: secrets)
        }
        switch provider.id.description {
        case "langgenius/openai/openai":
            var extra: [String: String] = [:]
            if let org = s("openai_organization") { extra["OpenAI-Organization"] = org }
            return bearer(v1(s("openai_api_base") ?? "https://api.openai.com") + "/models", s("openai_api_key"), extra: extra)
        case "langgenius/deepseek/deepseek":
            return bearer(trimmed(s("endpoint_url") ?? "https://api.deepseek.com") + "/models", s("api_key"))
        case "langgenius/moonshot/moonshot":
            return bearer(v1(s("endpoint_url") ?? "https://api.moonshot.cn") + "/models", s("api_key"))
        case "langgenius/tongyi/tongyi":
            let host = s("api_host") ?? (s("use_international_endpoint") == "true" ? "https://dashscope-intl.aliyuncs.com" : "https://dashscope.aliyuncs.com")
            return bearer(trimmed(host) + "/compatible-mode/v1/models", s("dashscope_api_key"))
        case "langgenius/zhipuai/zhipuai":
            return bearer(trimmed(s("base_url") ?? "https://open.bigmodel.cn/api/paas/v4") + "/models", s("api_key"))
        case "langgenius/anthropic/anthropic":
            var base = trimmed(s("anthropic_api_url") ?? "https://api.anthropic.com")
            if base.hasSuffix("/v1") { base.removeLast(3) }
            var h = ["anthropic-version": "2023-06-01"]
            if let key = s("anthropic_api_key") { h["x-api-key"] = key }
            return Plan(request: Request(method: "GET", url: base + "/v1/models?limit=1", headers: h, body: nil), fallback: nil, fallbackOn: [],
                        secrets: secrets)
        case "langgenius/gemini/google":
            var h: [String: String] = [:]
            if let key = s("google_api_key") { h["x-goog-api-key"] = key }
            return Plan(request: Request(method: "GET", url: trimmed(s("google_base_url") ?? "https://generativelanguage.googleapis.com") + "/v1beta/models?pageSize=1",
                                         headers: h, body: nil), fallback: nil, fallbackOn: [], secrets: secrets)
        case "langgenius/ollama/ollama":
            guard let base = s("base_url"), let model else { return nil }
            var h = ["Content-Type": "application/json"]
            if let key = s("api_key") { h["Authorization"] = "Bearer \(key)" }
            let body = try? JSONCoding.encode(JSON.object(["model": .string(model)]))
            return Plan(request: Request(method: "POST", url: trimmed(base) + "/api/show", headers: h, body: body), fallback: nil, fallbackOn: [],
                        secrets: secrets)
        case "langgenius/openai_api_compatible/openai_api_compatible":
            guard let endpoint = s("endpoint_url") else { return nil }
            let base = trimmed(endpoint)
            var plan = bearer(base + "/models", s("api_key"))
            if modelType == nil || modelType == "llm" {
                let name = s("endpoint_model_name") ?? model ?? ""
                let completion = s("mode") == "completion"
                let payload: JSON = completion
                    ? ["model": .string(name), "prompt": "ping", "max_tokens": 5]
                    : ["model": .string(name), "messages": [["role": "user", "content": "ping"]], "max_tokens": 5]
                var h = plan.request.headers
                h["Content-Type"] = "application/json"
                plan.fallback = Request(method: "POST", url: base + (completion ? "/completions" : "/chat/completions"), headers: h,
                                        body: try? JSONCoding.encode(payload))
                plan.fallbackOn = [404, 405]
            }
            return plan
        case "langgenius/azure_openai/azure_openai":
            guard (s("auth_method") ?? "api_key") == "api_key", let base = s("openai_api_base") else { return nil }
            var h: [String: String] = [:]
            if let key = s("openai_api_key") { h["api-key"] = key }
            let version = s("openai_api_version") ?? "2024-10-21"
            let query = version.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? version
            return Plan(request: Request(method: "GET", url: trimmed(base) + "/openai/models?api-version=\(query)", headers: h, body: nil),
                        fallback: nil, fallbackOn: [], secrets: secrets)
        default:
            return nil
        }
    }

    /// The short error message for a non-2xx answer: the provider's own message when its body has one (OpenAI, Anthropic,
    /// Gemini: `error.message`; Ollama: `error`), else the status. At most 300 characters; secrets replaced by `***`.
    public static func failureMessage(status: Int, body: Data, secrets: [String]) -> String {
        var message: String?
        if let json = try? JSONCoding.decode(body) {
            message = json["error"]?["message"]?.string ?? json["error"]?.string ?? json["message"]?.string ?? json["detail"]?.string
        }
        let text = (message?.isEmpty == false ? "\(message!) (HTTP \(status))" : "HTTP \(status)")
        return redact(String(text.prefix(300)), secrets)
    }

    /// `text` with every secret (and its masked form) replaced by `***`.
    public static func redact(_ text: String, _ secrets: [String]) -> String {
        var out = text
        for s in secrets where s.count >= 4 { out = out.replacingOccurrences(of: s, with: "***") }
        return out
    }
}
