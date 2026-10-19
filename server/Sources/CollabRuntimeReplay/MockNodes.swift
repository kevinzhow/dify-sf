// Dify 1.17.1's mock nodes for graph-engine tests (api/tests/unit_tests/core/workflow/graph_engine/test_mock_nodes.py,
// test_mock_factory.py, test_mock_config.py; Apache-2.0 with Dify's conditions), as the golden traces were recorded
// with them (e2e/traces/record_graphon.py). Service-backed nodes are replaced by these; start, end, answer, if-else,
// the aggregator, the assigners and the list operator are the runtime's own.

import CollabRuntime
import Foundation

/// A mock node: the real node's identity and engine-facing traits, a scripted run.
struct MockNode: RuntimeNode {
    let id: String
    let base: BaseNodeData
    let nodeType: String
    let executionType: NodeExecutionType
    let retryEnabled: Bool
    let body: @Sendable (NodeRunContext, @Sendable (NodeEvent) async -> Void) async throws -> Void

    func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        try await body(context, emit)
    }
}

/// `MockNodeFactory` with a `MockConfig` of per-node outputs (and errors).
public struct MockNodeFactory: NodeFactory {
    public var real: BuiltinNodeFactory
    /// node id -> outputs replacing the mock's defaults.
    public var outputs: [String: JSONObject]
    /// node id -> a simulated error.
    public var errors: [String: String]

    public init(real: BuiltinNodeFactory = BuiltinNodeFactory(services: RuntimeServices()), outputs: [String: JSONObject] = [:],
                errors: [String: String] = [:]) {
        self.real = real
        self.outputs = outputs
        self.errors = errors
    }

    public static let mockedTypes: Set<String> = [
        NodeType.llm, "agent", NodeType.tool, NodeType.knowledgeRetrieval, NodeType.httpRequest, NodeType.questionClassifier,
        NodeType.parameterExtractor, NodeType.documentExtractor, NodeType.templateTransform, NodeType.code,
    ]

    public func createNode(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        let type = config.type
        guard Self.mockedTypes.contains(type) else { return try await real.createNode(config, graph: graph) }
        let base = try BaseNodeData(config.data)
        let id = config.id
        let override = outputs[id]
        let error = errors[id]
        func mocked(_ defaults: JSONObject) -> JSONObject {
            if let override, !override.isEmpty { return override }
            return defaults
        }
        @Sendable func failed(_ e: String) -> NodeRunResult {
            NodeRunResult(status: .failed, inputs: [:], processData: [:], error: e, errorType: "MockError")
        }
        let retry = base.retryConfig.retryEnabled && [NodeType.llm, NodeType.code, NodeType.httpRequest, NodeType.tool].contains(type)
        func node(_ exec: NodeExecutionType = .executable,
                  _ body: @escaping @Sendable (NodeRunContext, @Sendable (NodeEvent) async -> Void) async throws -> Void) -> MockNode {
            MockNode(id: id, base: base, nodeType: type, executionType: exec, retryEnabled: retry, body: body)
        }
        switch type {
        case NodeType.llm:
            let outs = mocked(["text": "This is a mocked LLM response",
                               "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15], "finish_reason": "stop"])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                if let text = outs["text"] {
                    let words = PythonText.str(text).components(separatedBy: " ")
                    for (i, w) in words.enumerated() {
                        await emit(.streamChunk(selector: [id, "text"], chunk: i > 0 ? " " + w : w, isFinal: false))
                    }
                    await emit(.streamChunk(selector: [id, "text"], chunk: "", isFinal: true))
                }
                var usage = LLMUsage()
                usage.promptTokens = outs["usage"]?["prompt_tokens"]?.int ?? 10
                usage.completionTokens = outs["usage"]?["completion_tokens"]?.int ?? 5
                usage.totalTokens = outs["usage"]?["total_tokens"]?.int ?? 15
                await emit(.completed(NodeRunResult(
                    status: .succeeded, inputs: ["mock": "inputs"],
                    processData: ["model_mode": "chat", "prompts": [], "usage": outs["usage"] ?? .object([:]),
                                  "finish_reason": outs["finish_reason"] ?? "stop", "model_provider": "mock_provider", "model_name": "mock_model"],
                    outputs: outs,
                    metadata: [MetadataKey.totalTokens: .int(usage.totalTokens), MetadataKey.totalPrice: .double(0), MetadataKey.currency: "USD"],
                    llmUsage: usage)))
            }
        case NodeType.tool:
            let outs = mocked(["result": "mocked tool output"])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["mock": "inputs"],
                                                    processData: ["tool_name": "mock_tool", "tool_parameters": [:]], outputs: outs,
                                                    metadata: ["tool_info": ["tool_name": "mock_tool", "tool_label": "Mock Tool"]])))
            }
        case NodeType.httpRequest:
            let outs = mocked(["status_code": 200, "body": "mocked response", "headers": [:]])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["url": "http://mock.url", "method": "GET"],
                                                    processData: ["request_url": "http://mock.url", "request_method": "GET"], outputs: outs)))
            }
        case NodeType.questionClassifier:
            let outs = mocked(["class_name": "class_1"])
            return node(.branch) { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                let cls = outs["class_name"]?.string ?? "class_1"
                var r = NodeRunResult(status: .succeeded, inputs: ["query": "mock query"], processData: ["classification": .string(cls)],
                                      outputs: outs)
                r.edgeSourceHandle = cls
                await emit(.completed(r))
            }
        case NodeType.parameterExtractor:
            let outs = mocked(["parameters": ["param1": "value1", "param2": "value2"]])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: ["text": "mock text"],
                                                    processData: ["extracted_parameters": outs["parameters"] ?? .object([:])], outputs: outs)))
            }
        case NodeType.templateTransform:
            let template = config.data["template"]?.string
            let variables = (config.data["variables"]?.array ?? []).compactMap(VariableSelector.init(json:))
            return node { context, emit in
                if let error { await emit(.completed(failed(error))); return }
                var vars = JSONObject()
                for v in variables { vars[v.variable] = context.pool.get(v.valueSelector)?.object ?? .null }
                if let override, !override.isEmpty {
                    await emit(.completed(NodeRunResult(status: .succeeded, inputs: vars, outputs: override)))
                    return
                }
                let text = template.flatMap { MiniJinja.render($0, vars) } ?? "This is mocked template transform output"
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: vars, outputs: ["output": .string(text)])))
            }
        case NodeType.code:
            var defaults = JSONObject()
            if let declared = config.data["outputs"]?.object, !declared.isEmpty {
                for (name, spec) in declared {
                    switch spec["type"]?.string {
                    case "string": defaults[name] = .string("mocked_\(name)")
                    case "number": defaults[name] = 42
                    case "object": defaults[name] = ["key": "value"]
                    case "array[string]": defaults[name] = ["item1", "item2"]
                    case "array[number]": defaults[name] = [1, 2, 3]
                    case "array[object]": defaults[name] = [["key": "value1"], ["key": "value2"]]
                    default: break
                    }
                }
            } else {
                defaults = ["result": "mocked code execution result"]
            }
            let outs = mocked(defaults)
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: [:], outputs: outs)))
            }
        case NodeType.documentExtractor:
            let outs = mocked(["text": "This is mocked document content"])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: [:], outputs: outs)))
            }
        default:
            let outs = mocked(["result": "mocked output"])
            return node { _, emit in
                if let error { await emit(.completed(failed(error))); return }
                await emit(.completed(NodeRunResult(status: .succeeded, inputs: [:], outputs: outs)))
            }
        }
    }
}

/// Enough Jinja2 for the samples' templates: `{{ name }}` / `{{ name.attr }}` with Python's `str()` of the value.
enum MiniJinja {
    static func render(_ template: String, _ vars: JSONObject) -> String? {
        if template.contains("{%") || template.contains("{#") { return nil }
        var out = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            out += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else { return nil }
            let expr = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            let path = expr.split(separator: ".").map(String.init)
            guard let first = path.first, var v = vars[first] else { return nil }
            for p in path.dropFirst() { v = v[p] ?? .null }
            out += v == .null ? "None" : PythonText.str(v)
            rest = rest[close.upperBound...]
        }
        return out + rest
    }
}
