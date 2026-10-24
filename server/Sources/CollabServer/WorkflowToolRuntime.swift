// Dify 1.17.1 core/tools/workflow_as_tool/tool.py: blocking internal execution of a published workflow.
import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation

struct ServerToolRuntime: ToolRuntime {
    let routes: Routes
    let userId: String
    let plugin: PluginDaemonToolRuntime?
    let callStack: [String]
    var endUserId: String? = nil

    func workflow(_ tool: ToolReference) async throws -> StoredWorkflowTool {
        guard let definition = try await routes.store.workflowTools().first(where: { $0.id == tool.providerID && $0.name == tool.name }) else {
            throw NodeError("ToolNotFoundError", "Workflow tool not found")
        }
        guard callStack.count < 5, !callStack.contains(definition.appId) else {
            throw NodeError("ToolInvokeError", "Workflow tool call depth or recursion limit exceeded")
        }
        return definition
    }
    func parameters(_ tool: ToolReference, context: NodeRunContext) async throws -> [JSONValue] {
        if tool.providerType == "workflow" {
            let definition = try await workflow(tool)
            return try JSONValue.parse(Array(definition.definition.utf8))["parameters"]?.array ?? []
        }
        guard tool.providerType == "builtin", let plugin else { throw NodeError("ToolProviderNotFoundError", "Tool provider type is not configured") }
        return try await plugin.parameters(tool, context: context)
    }
    func invoke(_ tool: ToolReference, parameters: JSONObject, context: NodeRunContext) -> AsyncThrowingStream<ToolRuntimeEvent, any Error> {
        if tool.providerType != "workflow" {
            guard let plugin, tool.providerType == "builtin" else { return AsyncThrowingStream { $0.finish(throwing: NodeError("ToolInvokeError", "Unsupported tool provider type")) } }
            return plugin.invoke(tool, parameters: parameters, context: context)
        }
        let (stream, continuation) = AsyncThrowingStream<ToolRuntimeEvent, any Error>.makeStream()
        func send(_ message: JSONValue) { continuation.yield(.message(message)) }
        let commands = GraphEngineCommands()
        let task = Task {
            let monitor = Task {
                while !Task.isCancelled {
                    if context.isAborted() { commands.abort(); return }
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            defer { monitor.cancel() }
            var trace: ToolWorkflowTrace?
            do {
                let definition = try await workflow(tool)
                guard let version = try await routes.store.version(definition.appId, id: definition.versionId) else { throw NodeError("ToolInvokeError", "Published workflow no longer exists") }
                let secrets = try await routes.store.secrets(definition.appId)
                let root = try DifyDSL.exportValue(WireJSON.decode(Document.self, from: version.state), metadata: WireJSON.decode(Value.self, from: version.dsl), secrets: secrets)
                let value = try JSONValue.parse(WireJSON.encode(root))
                var services = routes.runtimeServices(appId: definition.appId, userId: userId, endUserId: endUserId)
                services.tools = ServerToolRuntime(routes: routes, userId: userId, plugin: plugin, callStack: callStack + [definition.appId], endUserId: endUserId)
                // Upstream deliberately disables pausing inside a workflow tool.
                services.humanInput = nil
                let runId = UUID().uuidString.lowercased()
                var inputs = tool.configurations
                for (key, value) in parameters { inputs[key] = value }
                let prepared = try await PreparedRun.make(workflow: value["workflow"] ?? .null, rawInputs: inputs,
                    services: services, userId: endUserId ?? userId, appId: definition.appId, workflowId: version.id, runId: runId)
                try await routes.store.insertWorkflowRun(StoredWorkflowRun(id: runId, docId: definition.appId, docSeq: version.seq,
                    workflowId: version.id, type: "workflow", triggeredFrom: "workflow-tool", version: version.version,
                    graph: (value["workflow"]?["graph"] ?? .null).compactJSON(), inputs: JSONValue.object(prepared.workflowInputs).compactJSON(),
                    status: "running", createdBy: userId, createdAt: Date()))
                let recorder = ToolWorkflowTrace(store: routes.store, appId: definition.appId, runId: runId, seq: version.seq, userId: userId)
                trace = recorder
                continuation.yield(.metadata(["workflow_run_id": .string(runId), "workflow_id": .string(version.id)]))
                let engine = GraphEngine(graph: prepared.graph, config: GraphEngineConfig(maxWorkers: routes.config.runtimeMaxWorkers,
                    maxSteps: routes.config.runtimeMaxSteps, maxTimeSeconds: routes.config.runtimeMaxTimeSeconds), commands: commands, userId: endUserId ?? userId, appId: definition.appId)
                var completed = false
                for await event in engine.run(pool: prepared.pool) {
                    if context.isAborted() || Task.isCancelled { commands.abort(); throw CancellationError() }
                    switch event {
                    case .node(let event): try await recorder.record(event)
                    case .runSucceeded(let stats), .runPartialSucceeded(let stats):
                        try await recorder.finish(stats, status: stats.exceptionsCount == 0 ? "succeeded" : "partial-succeeded")
                        trace = nil
                        continuation.yield(.usage(stats.llmUsage))
                        var output = stats.outputs
                        func extract(_ value: JSONValue) -> JSONValue {
                            if RuntimeFile.isFile(value) { send(["type": "file", "message": [:], "meta": ["file": value]]); return value }
                            switch value {
                            case .object(let object): return .object(JSONObject(object.map { ($0.key, extract($0.value)) }))
                            case .array(let array): return .array(array.map(extract))
                            default: return value
                            }
                        }
                        output = JSONObject(output.map { ($0.key, extract($0.value)) })
                        for (key, value) in output where !["text", "json", "files"].contains(key) {
                            send(["type": "variable", "message": ["variable_name": .string(key), "variable_value": value, "stream": false]])
                        }
                        send(["type": "text", "message": ["text": .string(JSONValue.object(output).compactJSON())]])
                        send(["type": "json", "message": ["json_object": .object(output), "suppress_output": true]])
                        completed = true
                    case .runFailed(let error, let stats), .runAborted(let error, let stats):
                        try await recorder.finish(stats, status: "failed", error: error)
                        trace = nil
                        continuation.yield(.usage(stats.llmUsage))
                        throw NodeError("ToolInvokeError", error)
                    case .runPaused: commands.abort(); throw NodeError("ToolInvokeError", "Workflow tools cannot pause")
                    default: break
                    }
                }
                guard completed else { throw NodeError("ToolInvokeError", "Workflow tool ended without a result") }
                continuation.finish()
            } catch {
                commands.abort()
                if let trace { try? await trace.finish(GraphRunStats(), status: "failed", error: "\(error)") }
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in commands.abort(); task.cancel() }
        return stream
    }
}

/// Nested execution uses the same run and node tables, distinguished from debugger and public runs.
actor ToolWorkflowTrace {
    let store: PostgresStore
    let appId: String
    let runId: String
    let seq: Int
    let userId: String
    let startedAt = Date()
    var index = 0
    struct Started: Sendable { var node: String; var type: String; var title: String; var at: Date; var index: Int }
    var running: [String: Started] = [:]
    init(store: PostgresStore, appId: String, runId: String, seq: Int, userId: String) {
        self.store = store; self.appId = appId; self.runId = runId; self.seq = seq; self.userId = userId
    }
    func record(_ event: GraphNodeEvent) async throws {
        switch event {
        case .started(let execution, let node, let type, let title, let at, _):
            index += 1; running[execution] = Started(node: node, type: type, title: title, at: at, index: index)
        case .succeeded(let execution, _, _, let at, let result), .failed(let execution, _, _, let at, let result, _), .exception(let execution, _, _, let at, let result, _):
            if let start = running[execution] {
                try await save(execution, start, result, finishedAt: at)
                running.removeValue(forKey: execution)
            }
        default: break
        }
    }
    func save(_ execution: String, _ start: Started, _ result: NodeRunResult, finishedAt: Date) async throws {
        let value = StoredNodeExecution(id: execution, docId: appId, workflowRunId: runId, triggeredFrom: "workflow-tool", docSeq: seq,
            index: start.index, predecessorNodeId: nil, nodeId: start.node, nodeType: start.type, title: start.title,
            inputs: JSONValue.object(result.inputs).compactJSON(), processData: JSONValue.object(result.processData).compactJSON(),
            outputs: JSONValue.object(result.outputs).compactJSON(), status: result.status.rawValue, error: result.error.isEmpty ? nil : result.error,
            elapsedTime: max(0, finishedAt.timeIntervalSince(start.at)), executionMetadata: JSONValue.object(result.metadata).compactJSON(),
            createdBy: userId, createdAt: start.at, finishedAt: finishedAt)
        try await store.upsertNodeExecution(value)
    }
    func finish(_ stats: GraphRunStats, status: String, error: String? = nil) async throws {
        let at = Date()
        for (execution, start) in running {
            try await save(execution, start, NodeRunResult(status: .failed, error: error ?? "Workflow tool stopped"), finishedAt: at)
        }
        running.removeAll()
        try await store.finishWorkflowRun(id: runId, status: status, outputs: JSONValue.object(stats.outputs).compactJSON(), error: error,
            elapsedTime: max(0, at.timeIntervalSince(startedAt)), totalTokens: stats.totalTokens, totalSteps: stats.totalSteps,
            exceptionsCount: stats.exceptionsCount, finishedAt: at)
    }
}
