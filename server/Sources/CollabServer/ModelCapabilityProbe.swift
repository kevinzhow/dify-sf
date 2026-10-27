import CollabModels
import Foundation

/// Explicit, bounded observations; a successful HTTP status alone establishes
/// no capability. Failed/ambiguous checks stay unknown, never "unsupported".
enum ModelCapabilityProbe {
    static func run(_ connection: ModelDiscovery.Connection, model: String, protocolName: String,
                    send: ModelDiscovery.Send = ModelDiscovery.transport) async throws -> JSON {
        guard ModelDiscovery.validModel(model), ["responses", "chat_completions"].contains(protocolName) else {
            throw ServerError.badRequest("A complete model name and a supported API type are required.")
        }
        let responses = protocolName == "responses"
        let path = responses ? "/responses" : "/chat/completions"
        let nonce = "probe-" + UUID().uuidString.lowercased().prefix(12)
        var fields: [String: JSON] = [:]
        var calls = 0
        var observations: [String: JSON] = [:]
        func payload(_ text: String, maxTokens: Int = 64) -> [String: JSON] {
            var body: [String: JSON] = ["model": .string(model), "stream": false]
            body[responses ? "input" : "messages"] = [["role": "user", "content": .string(text)]]
            body[responses ? "max_output_tokens" : "max_completion_tokens"] = .int(maxTokens)
            if responses { body["store"] = false }
            return body
        }
        func call(_ body: [String: JSON]) async -> JSON? {
            calls += 1
            do {
                let response = try await send(connection.request(path, body: .object(body)))
                return try JSONCoding.decode(ModelDiscovery.checked(response))
            } catch { return nil }
        }
        func text(_ value: JSON?) -> String {
            guard let value else { return "" }
            if !responses { return value["choices"]?.array?.first?["message"]?["content"]?.string ?? "" }
            return (value["output"]?.array ?? []).flatMap { $0["content"]?.array ?? [] }
                .compactMap { $0["text"]?.string }.joined()
        }
        func observe(_ name: String, _ passed: Bool) {
            fields[name] = ModelDiscovery.field(passed ? true : nil, "observed")
            observations[name] = .string(passed ? "passed" : "inconclusive")
        }

        let basic = await call(payload("Reply with exactly \(nonce)."))
        let reachable = text(basic).contains(nonce)
        fields["api_type"] = ModelDiscovery.field(reachable ? .string(protocolName) : nil, "observed")
        observations["api_type"] = .string(reachable ? "passed" : "inconclusive")

        let schema: JSON = ["type": "object", "properties": ["proof": ["type": "string", "enum": [.string(nonce)]]],
                            "required": ["proof"], "additionalProperties": false]
        var structured = payload("Reply with the plain word unstructured, not JSON.")
        let format: JSON = ["type": "json_schema", "name": "probe", "strict": true, "schema": schema]
        if responses { structured["text"] = ["format": format] }
        else { structured["response_format"] = ["type": "json_schema", "json_schema": ["name": "probe", "strict": true, "schema": schema]] }
        let jsonResult = await call(structured)
        let parsed = try? JSONCoding.decode(Data(text(jsonResult).utf8))
        observe("json_schema", parsed?.object?.count == 1 && parsed?["proof"]?.string == nonce)

        var vision = payload("Read the six digits in the image. Return only the digits.", maxTokens: 32)
        let image: JSON = responses ? ["type": "input_image", "image_url": .string(ModelProbeImage.dataURL)]
            : ["type": "image_url", "image_url": ["url": .string(ModelProbeImage.dataURL)]]
        vision[responses ? "input" : "messages"] = [["role": "user", "content": [
            ["type": .string(responses ? "input_text" : "text"), "text": "Read the six digits in this image; return only digits."], image]]]
        observe("vision", text(await call(vision)).trimmingCharacters(in: .whitespacesAndNewlines) == ModelProbeImage.answer)

        // The tool result has a second nonce not present in the original prompt.
        let toolProof = "result-" + UUID().uuidString.lowercased().prefix(12)
        let parameters: JSON = ["type": "object", "properties": ["proof": ["type": "string", "enum": [.string(nonce)]]],
                                "required": ["proof"], "additionalProperties": false]
        let function: JSON = ["name": "connection_probe", "description": "Return a connection proof", "parameters": parameters, "strict": true]
        var toolRequest = payload("Call connection_probe with proof \(nonce). After its result, return only the returned proof.")
        toolRequest["tools"] = responses ? [["type": "function", "name": "connection_probe", "description": "Return a connection proof", "parameters": parameters, "strict": true]]
            : [["type": "function", "function": function]]
        toolRequest["tool_choice"] = responses ? ["type": "function", "name": "connection_probe"]
            : ["type": "function", "function": ["name": "connection_probe"]]
        let toolResponse = await call(toolRequest)
        let tool = responses ? toolResponse?["output"]?.array?.first(where: { $0["type"]?.string == "function_call" })
            : toolResponse?["choices"]?.array?.first?["message"]?["tool_calls"]?.array?.first
        let arguments = responses ? tool?["arguments"]?.string : tool?["function"]?["arguments"]?.string
        let args = arguments.flatMap { try? JSONCoding.decode(Data($0.utf8)) }
        let name = responses ? tool?["name"]?.string : tool?["function"]?["name"]?.string
        let callID = responses ? tool?["call_id"]?.string : tool?["id"]?.string
        var toolPassed = false
        if let callID, !callID.isEmpty, callID.utf8.count < 1024, name == "connection_probe", args?["proof"]?.string == nonce {
            var follow = payload("Return the tool result.")
            follow["tools"] = toolRequest["tools"]
            if responses {
                // Preserve reasoning and other required items only in memory;
                // none of them enter the discovery receipt or its response.
                let original = toolRequest["input"]?.array ?? []
                follow["input"] = .array(original + (toolResponse?["output"]?.array ?? []) + [
                    ["type": "function_call_output", "call_id": .string(callID), "output": .string(toolProof)]])
            } else {
                let original = toolRequest["messages"]?.array ?? []
                let message = toolResponse?["choices"]?.array?.first?["message"] ?? .null
                follow["messages"] = .array(original + [message, ["role": "tool", "tool_call_id": .string(callID), "content": .string(toolProof)]])
            }
            toolPassed = text(await call(follow)).contains(toolProof)
        }
        observe("tools", toolPassed)

        var stream = payload("Reply with exactly \(nonce).")
        stream["stream"] = true
        calls += 1
        var streamPassed = false
        do {
            let response = try await send(connection.request(path, body: .object(stream)))
            let data = try ModelDiscovery.checked(response)
            let raw = String(decoding: data, as: UTF8.self)
            var deltas = ""
            var finished = false
            for line in raw.components(separatedBy: "\n") where line.hasPrefix("data:") {
                let item = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
                if item == "[DONE]" { finished = true; continue }
                guard let event = try? JSONCoding.decode(Data(item.utf8)) else { continue }
                if responses {
                    if event["type"]?.string == "response.output_text.delta" { deltas += event["delta"]?.string ?? "" }
                    if event["type"]?.string == "response.completed" { finished = true }
                } else {
                    deltas += event["choices"]?.array?.first?["delta"]?["content"]?.string ?? ""
                }
            }
            streamPassed = finished && deltas.contains(nonce)
        } catch { }
        observe("streaming", streamPassed)

        let limitResult = await call(payload("Write the numbers one through twenty in English, all twenty words.", maxTokens: 1))
        let tokens = limitResult?["usage"]?[responses ? "output_tokens" : "completion_tokens"]?.int
        let limitIgnored = (tokens ?? 0) > 1
        fields["output_limit"] = ModelDiscovery.field(limitIgnored ? false : nil, "observed")
        observations["output_limit"] = .string(limitIgnored ? "not_enforced_in_probe" : "inconclusive")
        return ["id": .string(model), "protocol": .string(protocolName), "fields": .object(fields),
                "observations": .object(observations), "request_count": .int(calls),
                "probed_at": .string(ISO8601DateFormatter().string(from: Date()))]
    }
}
