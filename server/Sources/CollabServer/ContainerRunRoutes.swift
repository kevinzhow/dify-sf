import CollabRuntime
import Foundation
import Vapor

/// Iteration and loop single runs (protocol 1.15): Dify 1.17.1's `POST /apps/{app}/workflows/draft/iteration/nodes/{node}/run`
/// and `.../loop/nodes/{node}/run` (`{"inputs": {...}}`): the container with its inner nodes runs on the engine, rooted at
/// the container, and answers the same SSE stream as a draft run (`workflow_started`, the iteration / loop events, the
/// inner nodes' `node_started` / `node_finished`, `workflow_finished`). Like Dify it is recorded as a debugging run (run
/// history) whose node executions are `single-step`. Reads the document at one seq; writes no ops.
extension Routes {
    func registerContainerRuns(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.post(":app", "workflows", "draft", "iteration", "nodes", ":node", "run") { req in
            await handle(req) { try await runContainerNode(req, kind: .iteration) }
        }
        apps.post(":app", "workflows", "draft", "loop", "nodes", ":node", "run") { req in
            await handle(req) { try await runContainerNode(req, kind: .loop) }
        }
    }

    private func runContainerNode(_ req: Request, kind: ContainerKind) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, ["workflow"])
        let nodeId = try nodeId(req)
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        // `single_iteration_generate`: "inputs is required".
        guard let inputsValue = b["inputs"], inputsValue != .null else { throw Self.invalidParam("inputs is required") }
        guard case .object(let inputs) = inputsValue else { throw ServerError.badRequest("inputs must be an object") }

        let (seq, workflow) = try await draftWorkflow(a.id, viewer: p.id)
        let graph = try GraphConfig(json: workflow["graph"] ?? .null)
        guard graph.node(nodeId) != nil else { throw ServerError.missing("Node \(nodeId) not found") }
        do { try await prefillConversationDraftVariables(appId: a.id, userId: p.id, viewer: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        let routes = self
        let appId = a.id, userId = p.id
        let run = ContainerSingleRun(graph: graph, environmentVariables: workflow["environment_variables"]?.array ?? [],
                                     factory: BuiltinNodeFactory(services: runtimeServices(appId: a.id)),
                                     variableLoader: { selectors in try await routes.loadDraftVariables(appId: appId, userId: userId, selectors: selectors) })
        let runId = UUID().uuidString.lowercased()
        let prepared: ContainerSingleRun.Prepared
        do {
            prepared = try await run.prepare(nodeId: nodeId, kind: kind, userInputs: inputs, runId: runId)
        } catch let e as ContainerSingleRun.InvalidInput {
            throw Self.invalidParam(e.description)
        } catch let e as DraftVariableError {
            throw Self.invalidParam(e.description)
        } catch {
            throw preparationError(error)
        }
        // `_prepare_workflow_inputs`: the (empty) inputs and `sys.*`.
        var workflowInputs = JSONObject()
        for (k, v) in prepared.system where k != "conversation_id" { workflowInputs["sys.\(k)"] = v }
        return try await startRun(appId: a.id, principal: p, seq: seq, workflow: workflow, runId: runId, graph: prepared.graph, pool: prepared.pool,
                                  workflowInputs: workflowInputs, nodeTriggeredFrom: "single-step")
    }
}
