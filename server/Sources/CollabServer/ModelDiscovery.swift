import CollabModels
import CollabRuntime
import Crypto
import Foundation

/// Settings discovery reuses the model credential HTTP boundary: privileged
/// members may contact the endpoint they configure. No redirects, retries,
/// ambient cookies, arbitrary headers or provider response text are returned.
enum ModelDiscovery {
    static let provider = "langgenius/openai_api_compatible/openai_api_compatible"
    static let metadataKey = "_dify_sf_autofill"
    static let maxBytes = 1 << 20
    typealias Send = @Sendable (RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse

    struct Connection: Sendable {
        let base: String
        let key: String
        var binding: String {
            SHA256.hash(data: Data((base + "\u{0}" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        }
        init(_ credentials: [String: JSON]) throws {
            guard !(credentials["endpoint_url"]?.string ?? "").contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ServerError.badRequest("Enter a valid Base URL.")
            }
            let raw = (credentials["endpoint_url"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.utf8.count <= 4096, let url = URLComponents(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, !raw.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ServerError.badRequest("Enter an HTTP(S) Base URL without credentials, query or fragment.")
            }
            let key = credentials["api_key"]?.string ?? ""
            guard key.utf8.count <= 8192, key != Credentials.hidden,
                  !key.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ServerError.badRequest("Enter the API Key again.")
            }
            base = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
            self.key = key
        }
        func request(_ path: String, body: JSON? = nil) throws -> RuntimeHTTPRequest {
            var headers = [("Accept", "application/json"), ("User-Agent", "dify-sf")]
            if !key.isEmpty { headers.append(("Authorization", "Bearer \(key)")) }
            if body != nil { headers.append(("Content-Type", "application/json")) }
            return RuntimeHTTPRequest(method: body == nil ? "GET" : "POST", url: base + path,
                headers: headers, body: try body.map { Array(try JSONCoding.encode($0)) },
                connectTimeout: 5, readTimeout: 12, writeTimeout: 3, followRedirects: false)
        }
    }

    static func transport(_ request: RuntimeHTTPRequest) async throws -> RuntimeHTTPResponse {
        // Same direct provider access as HTTPCredentialChecker and the installed
        // model plugin, without introducing a second proxy allow-list.
        try await CurlRuntimeHTTP.send(request, proxy: "", limit: maxBytes + 1)
    }

    static func checked(_ response: RuntimeHTTPResponse) throws -> Data {
        guard response.body.count <= maxBytes else {
            throw ServerError.http(status: 502, code: "model_discovery_too_large", message: "The service response exceeds 1 MB.")
        }
        guard response.status == 200 else {
            let code = [401, 403].contains(response.status) ? "model_discovery_auth_failed" : "model_discovery_failed"
            throw ServerError.http(status: 502, code: code,
                message: "The model service returned HTTP \(response.status). Check the address and API Key, then retry.")
        }
        return Data(response.body)
    }

    static func discover(_ connection: Connection, catalog: ModelCatalog? = nil, send: Send = transport) async throws -> JSON {
        let response: RuntimeHTTPResponse
        do { response = try await send(connection.request("/models")) }
        catch { throw ServerError.http(status: 502, code: "model_discovery_unreachable", message: "Cannot reach the model service. Check the address and retry.") }
        let data = try checked(response)
        guard let root = try? JSONCoding.decode(data), let rows = root["data"]?.array else {
            throw ServerError.http(status: 502, code: "model_discovery_invalid", message: "The service did not return a model list. You can enter a complete model name instead.")
        }
        guard rows.count <= 2000 else {
            throw ServerError.http(status: 502, code: "model_discovery_too_large", message: "The model list exceeds 2,000 entries. Enter a complete model name instead.")
        }
        var seen = Set<String>()
        let models = rows.compactMap { row -> JSON? in
            guard let id = row["id"]?.string, validModel(id), seen.insert(id).inserted else { return nil }
            return ModelDiscoveryReference.enrich(normalize(row, id: id), connection: connection, catalog: catalog)
        }
        return ["models": .array(models), "incomplete": .bool(root["has_more"]?.bool == true || root["next"]?.isTruthy == true),
                "fetched_at": .string(ISO8601DateFormatter().string(from: Date()))]
    }

    static func validModel(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 512 && !id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }
    static func field(_ value: JSON?, _ source: String = "provider") -> JSON {
        guard let value, !value.isNull else { return ["value": .null, "source": "unknown"] }
        return ["value": value, "source": .string(source)]
    }
    static func positive(_ row: JSON, _ names: [String]) -> JSON? {
        let values = names.compactMap { row[$0]?.int }.filter { $0 > 0 && $0 <= 1_000_000_000 }
        // Conflicting aliases are unknown, rather than an arbitrary winner.
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return .int(first)
    }
    static func strings(_ value: JSON?) -> [String]? {
        guard let array = value?.array, array.count <= 100, array.allSatisfy({ $0.string != nil && ($0.string?.utf8.count ?? 0) <= 128 }) else { return nil }
        return array.compactMap(\.string)
    }
    static func normalize(_ row: JSON, id: String) -> JSON {
        let modalities = strings(row["modalities"]?["input"])
        let endpoints = strings(row["native_endpoints"])
        let protocolName: JSON? = endpoints?.contains(where: { $0 == "/v1/responses" || $0 == "/responses" }) == true ? "responses"
            : endpoints?.contains(where: { $0.hasSuffix("/chat/completions") }) == true ? "chat_completions" : nil
        let name = row["name"]?.string.flatMap { $0.utf8.count <= 160 && !$0.contains(where: \.isNewline) ? $0 : nil } ?? id
        var fields: [String: JSON] = [
            "display_name": field(.string(name)), "api_type": field(protocolName),
            "context_capacity": field(positive(row, ["context_length", "context_window", "max_input_tokens"])),
            "output_capacity": field(positive(row, ["max_output_tokens", "max_completion_tokens"])),
            "vision": field(modalities.map { .bool($0.contains("image")) }),
            "reasoning": field(row["reasoning"]?.bool.map(JSON.bool)),
            "tools": field(row["supports_tools"]?.bool.map(JSON.bool)),
            "json_schema": field(row["supports_json_schema"]?.bool.map(JSON.bool)),
            "streaming": field(row["supports_streaming"]?.bool.map(JSON.bool)),
            "output_limit": field(nil),
        ]
        for (target, source) in [("reasoning_levels", "reasoning_levels"), ("service_tiers", "service_tiers")] {
            fields[target] = field(strings(row[source]).map { .array($0.map(JSON.string)) })
        }
        // Prices without an explicit unit/currency are not usable prices.
        return ["id": .string(id), "fields": .object(fields)]
    }

    static func defaults(_ model: JSON) -> [String: JSON] {
        let f = model["fields"]
        return ["display_name": f?["display_name"]?["value"] ?? model["id"] ?? "",
                "api_type": f?["api_type"]?["value"]?.string.map(JSON.string) ?? "chat_completions",
                "context_size": .string(String(f?["context_capacity"]?["value"]?.int ?? 4096)),
                "max_tokens_to_sample": .string(String(f?["output_capacity"]?["value"]?.int ?? 1024)),
                "vision_support": f?["vision"]?["value"]?.bool == true ? "support" : "no_support",
                "function_calling_type": f?["tools"]?["value"]?.bool == true ? "tool_call" : "no_call",
                "structured_output_support": f?["json_schema"]?["value"]?.bool == true ? "supported" : "not_supported",
                "agent_thought_support": f?["reasoning"]?["value"]?.bool == true || f?["reasoning_levels"]?["value"]?.array?.isEmpty == false
                    ? "only_thinking_supported" : "not_supported",
                "mode": "chat"]
    }
}

/// Short-lived receipts bind provenance to the caller and exact connection.
/// No API Key, raw provider response, or conversation is retained here.
actor ModelDiscoveryReceipts {
    struct Entry: Sendable { let owner: String; let binding: String; let value: JSON; let expires: Date }
    private var entries: [String: Entry] = [:]
    private var active = Set<String>()
    private var lastProbe: [String: Date] = [:]
    func begin(_ owner: String, probe: Bool = false, now: Date = Date()) throws {
        guard active.count < 4, !active.contains(owner), !probe || now.timeIntervalSince(lastProbe[owner] ?? .distantPast) >= 60 else {
            throw ServerError.http(status: 429, code: "model_discovery_busy", message: "A request is already running or was just completed. Try again shortly.")
        }
        active.insert(owner)
        if probe { lastProbe[owner] = now }
        lastProbe = lastProbe.filter { now.timeIntervalSince($0.value) < 3600 }
    }
    func end(_ owner: String) { active.remove(owner) }
    func put(owner: String, binding: String, value: JSON, now: Date = Date()) -> String {
        entries = entries.filter { $0.value.expires > now }
        if entries.count >= 128, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key { entries[oldest] = nil }
        let id = UUID().uuidString.lowercased()
        entries[id] = Entry(owner: owner, binding: binding, value: value, expires: now.addingTimeInterval(1800))
        return id
    }
    func get(_ id: String?, owner: String, binding: String, now: Date = Date()) throws -> JSON? {
        guard let id else { return nil }
        guard let e = entries[id], e.owner == owner, e.binding == binding, e.expires > now else {
            throw ServerError.http(status: 409, code: "model_discovery_expired", message: "The connection changed or its results expired. Refresh the model list or enter settings manually.")
        }
        return e.value
    }
}
