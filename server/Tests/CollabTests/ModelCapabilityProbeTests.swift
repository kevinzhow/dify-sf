import CollabModels
import CollabRuntime
import Foundation
import Synchronization
import Testing
@testable import CollabServer

@Suite("Model capability observations") struct ModelCapabilityProbeTests {
    @Test(arguments: ["responses", "chat_completions"])
    func requiresActualProtocolResultsIncludingToolsImagesAndStreaming(_ api: String) async throws {
        let count = Mutex(0)
        let connection = try ModelDiscovery.Connection(["endpoint_url": "https://gateway.example/v1", "api_key": "fixture-only"])
        let responses = api == "responses"
        let result = try await ModelCapabilityProbe.run(connection, model: "custom-model", protocolName: api) { request in
            count.withLock { $0 += 1 }
            let payload = try JSONCoding.decode(Data(request.body ?? []))
            #expect(payload["model"] == "custom-model")
            #expect(request.url.hasSuffix(responses ? "/responses" : "/chat/completions"))
            if responses { #expect(payload["store"] == false) }
            let messages = payload[responses ? "input" : "messages"]?.array ?? []
            let prompt = messages.first?["content"]?.string ?? ""
            func output(_ text: String, tokens: Int = 8) throws -> RuntimeHTTPResponse {
                let body: JSON = responses
                    ? ["output": [["type": "message", "content": [["type": "output_text", "text": .string(text)]]]], "usage": ["output_tokens": .int(tokens)]]
                    : ["choices": [["message": ["role": "assistant", "content": .string(text)]]], "usage": ["completion_tokens": .int(tokens)]]
                return .init(status: 200, headers: [], body: Array(try JSONCoding.encode(body)))
            }
            if let last = messages.last, last["type"] == "function_call_output" || last["role"] == "tool" {
                let proof = last[responses ? "output" : "content"]?.string ?? ""
                #expect(proof.hasPrefix("result-"))
                #expect(messages.count == 3)
                return try output(proof)
            }
            if payload["tool_choice"] != nil {
                let tool = payload["tools"]?.array?.first
                let function = responses ? tool : tool?["function"]
                let nonce = try #require(function?["parameters"]?["properties"]?["proof"]?["enum"]?.array?.first?.string)
                let args = String(decoding: try JSONCoding.encode(JSON.object(["proof": .string(nonce)])), as: UTF8.self)
                let body: JSON = responses
                    ? ["output": [["type": "function_call", "call_id": "fixture-call", "name": "connection_probe", "arguments": .string(args)]]]
                    : ["choices": [["message": ["role": "assistant", "content": .null, "tool_calls": [["id": "fixture-call", "type": "function", "function": ["name": "connection_probe", "arguments": .string(args)]]]]]]]
                return .init(status: 200, headers: [], body: Array(try JSONCoding.encode(body)))
            }
            if let content = messages.first?["content"]?.array {
                #expect(content.count == 2)
                let imagePrompt = content.first?["text"]?.string ?? ""
                let revealsAnswer = imagePrompt.contains(ModelProbeImage.answer)
                #expect(revealsAnswer == false)
                let image = content.last
                #expect((responses ? image?["image_url"]?.string : image?["image_url"]?["url"]?.string) == ModelProbeImage.dataURL)
                return try output(ModelProbeImage.answer)
            }
            let format = responses ? payload["text"]?["format"] : payload["response_format"]?["json_schema"]
            if let schema = format?["schema"] {
                let nonce = try #require(schema["properties"]?["proof"]?["enum"]?.array?.first?.string)
                #expect(prompt.contains("not JSON"))
                return try output(String(decoding: try JSONCoding.encode(JSON.object(["proof": .string(nonce)])), as: UTF8.self))
            }
            if payload[responses ? "max_output_tokens" : "max_completion_tokens"] == .int(responses ? 16 : 1) {
                // One token was observed, which still does not establish the true ceiling.
                return try output("one", tokens: responses ? 16 : 1)
            }
            let nonce = try #require(prompt.components(separatedBy: "exactly ").last?.dropLast().description)
            #expect(nonce.hasPrefix("probe-"))
            if payload["stream"] == true {
                let delta: JSON = responses ? ["type": "response.output_text.delta", "delta": .string(nonce)]
                    : ["choices": [["delta": ["content": .string(nonce)]]]]
                let line = String(decoding: try JSONCoding.encode(delta), as: UTF8.self)
                let done = responses ? #"{"type":"response.completed"}"# : "[DONE]"
                return .init(status: 200, headers: [("Content-Type", "text/event-stream")], body: Array("data: \(line)\n\ndata: \(done)\n\n".utf8))
            }
            return try output(nonce)
        }
        #expect(count.withLock { $0 } == 7)
        #expect(result["request_count"] == 7 && result["fields"]?["api_type"]?["value"] == .string(api))
        for name in ["json_schema", "vision", "tools", "streaming"] {
            #expect(result["fields"]?[name]?["value"] == true)
            #expect(result["fields"]?[name]?["source"] == "observed")
        }
        #expect(result["fields"]?["output_limit"]?["source"] == "unknown")
        #expect(result["fields"]?["context_capacity"] == nil)
        #expect(!String(decoding: try JSONCoding.encode(result), as: UTF8.self).contains("fixture-only"))
    }
}
