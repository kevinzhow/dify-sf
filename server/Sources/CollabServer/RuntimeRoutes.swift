import CollabCore
import CollabDSL
import CollabModels
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// The workflow runtime's console API (docs/protocol.md section 2, "Runtime (1.13)"): Dify 1.17.1's single node run
/// (`POST /apps/{app}/workflows/draft/nodes/{node}/run`) and the node's last run, over the Swift runtime (`CollabRuntime`)
/// with models through Dify's plugin daemon. A run reads the document at one seq (the sequencer's committed state) and
/// writes only run records (`workflow_node_executions`), never ops.
extension Routes {
    /// The node types a single run supports (`system-features`' `workflow_runtime.single_node_run`).
    /// The node types a draft run supports (`system-features`' `workflow_runtime.draft_run`).
    static var draftRunNodeTypes: [String] { BuiltinNodeFactory.supportedTypes + [NodeType.humanInput] }

    /// Iteration and loop nodes run alone through their own endpoints (`.../draft/iteration|loop/nodes/{node}/run`, protocol
    /// 1.15); their start nodes and the loop end have no single run (as in Dify's editor).
    static var singleRunNodeTypes: [String] {
        // Human input's "run" is its generated form (`.../human-input/nodes/{node}/form/{preview,run}`, 1.16).
        let helpers: Set<String> = [NodeType.iterationStart, NodeType.loopStart, NodeType.loopEnd, NodeType.humanInput]
        return BuiltinNodeFactory.supportedTypes.filter { !NodeType.startTypes.contains($0) && !helpers.contains($0) }
    }

    /// A model runtime is configured (`COLLAB_PLUGIN_DAEMON_URL`).
    var runtimeConfigured: Bool { !config.pluginDaemonURL.isEmpty }

    func registerRuntime(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.post(":app", "workflows", "draft", "nodes", ":node", "run") { req in await handle(req) { try await runDraftNode(req) } }
        apps.get(":app", "workflows", "draft", "nodes", ":node", "last-run") { req in await handle(req) { try await nodeLastRun(req) } }
    }

    func nodeId(_ req: Request) throws -> String {
        guard let id = req.parameters.get("node"), !id.isEmpty, id.utf8.count <= 255 else { throw ServerError.badRequest("invalid node id") }
        return id
    }

    func rawJSON(_ v: JSONValue, status: HTTPResponse.Status = .ok) -> Response {
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(string: v.compactJSON()))
    }

    static func invalidParam(_ message: String) -> ServerError { .http(status: 400, code: "invalid_param", message: message) }

    /// `POST /v1/apps/{app}/workflows/draft/nodes/{node}/run` `{"inputs": {...}}` (owner, admin, editor; workflow and
    /// chatflow apps): runs the node of the document at its current seq and answers Dify's
    /// `WorkflowRunNodeExecutionResponse` (`200` also when the node failed: `status` `failed` and `error`).
    private func runDraftNode(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let nodeId = try nodeId(req)
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        // Dify's DraftWorkflowNodeRunPayload: `inputs` is required (a dict); `query` and `files` matter for start nodes only.
        guard let inputsValue = b["inputs"], inputsValue != .null else { throw Self.invalidParam("missing inputs") }
        guard case .object(let inputs) = inputsValue else { throw ServerError.badRequest("inputs must be an object") }

        // One consistent read: the committed document at seq N (the sequencer's state), its metadata and secret values.
        let snapshot = try await registry.sequencer(a.id).currentSnapshot()
        let metadata = try await currentMetadata(a.id, viewer: p.id)
        let secrets: [String: String]
        do { secrets = try await store.secrets(a.id) } catch { throw ServerError.unavailable("\(error)") }
        let exported = try JSONValue.parse(try WireJSON.encode(try DifyDSL.exportValue(snapshot.doc, metadata: metadata, secrets: secrets)))
        let graph = try GraphConfig(json: exported["workflow"]?["graph"] ?? .null)
        guard let node = graph.node(nodeId) else { throw ServerError.missing("Node \(nodeId) not found") }
        guard Self.singleRunNodeTypes.contains(node.type) else {
            throw ServerError.http(status: 400, code: "unsupported_node_type",
                                   message: "Running a \(node.type) node is not supported by this server yet")
        }
        // Dify fills the conversation draft variables first, then loads what the node reads and the request lacks from them.
        do { try await prefillConversationDraftVariables(appId: a.id, userId: p.id, viewer: p.id) } catch {
            throw ServerError.unavailable("\(error)")
        }
        let routes = self
        let appId = a.id, userId = p.id
        let run = SingleStepRun(graph: graph, environmentVariables: exported["workflow"]?["environment_variables"]?.array ?? [],
                                factory: BuiltinNodeFactory(services: runtimeServices(appId: a.id, userId: p.id)),
                                variableLoader: { selectors in try await routes.loadDraftVariables(appId: appId, userId: userId, selectors: selectors) },
                                files: runtimeServices(appId: a.id, userId: p.id).files)
        let execution: NodeExecution
        do {
            execution = try await run.run(nodeId: nodeId, userInputs: inputs, userId: p.id, appId: a.id)
        } catch let e as SingleStepRun.NodeNotFound {
            throw ServerError.missing(e.description)
        } catch let e as UnsupportedNodeType {
            throw ServerError.http(status: 400, code: "unsupported_node_type", message: e.description)
        } catch let e as SingleStepRun.InvalidInput {
            throw Self.invalidParam(e.description)
        } catch let e as NodeDataError {
            throw Self.invalidParam(e.description)
        } catch let e as any NodeRunError {
            // Preparing the node failed (Dify raises these out of the request too): the model's credentials or schema.
            throw Self.invalidParam(e.description)
        } catch let e as DraftVariableError {
            throw Self.invalidParam(e.description)
        } catch {
            throw preparationError(error)
        }

        let stored = StoredNodeExecution(
            id: execution.id, docId: a.id, workflowRunId: nil, triggeredFrom: "single-step", docSeq: snapshot.seq, index: execution.index,
            predecessorNodeId: execution.predecessorNodeId, nodeId: execution.nodeId, nodeType: execution.nodeType, title: execution.title,
            inputs: execution.inputs.map { JSONValue.object($0).compactJSON() },
            processData: execution.processData.map { JSONValue.object($0).compactJSON() },
            outputs: execution.outputs.map { JSONValue.object($0).compactJSON() }, status: execution.status.rawValue, error: execution.error,
            elapsedTime: execution.elapsedTime, executionMetadata: execution.metadata.map { JSONValue.object($0).compactJSON() },
            createdBy: p.id, createdAt: execution.createdAt, finishedAt: execution.finishedAt)
        do { try await store.insertNodeExecution(stored) } catch { throw ServerError.unavailable("\(error)") }
        // `_handle_single_step_result`: the node's outputs become draft variables (the variable inspect panel).
        if execution.status == .succeeded || execution.status == .exception {
            do {
                try await saveDraftVariables(appId: a.id, userId: p.id, docSeq: snapshot.seq, nodeId: execution.nodeId, nodeType: execution.nodeType,
                                             executionId: execution.id, processData: execution.processData, outputs: execution.outputs ?? [:], outputTypes: execution.outputTypes)
            } catch {
                logger.error("saving draft variables of \(execution.id) failed: \(error)")
            }
        }
        let account: JSONValue = ["id": .string(p.id), "name": .string(p.account.name), "email": .string(p.account.email)]
        return await fileJSONResponse(execution.responseJSON(createdByAccount: account), userId: p.id)
    }

    /// `GET /v1/apps/{app}/workflows/draft/nodes/{node}/last-run` (any member): the node's newest execution, `404` if none.
    private func nodeLastRun(_ req: Request) async throws -> Response {
        let p = try await authenticate(req, .member)
        let a = try await appOfMode(req, p, Self.workflowModes)
        let nodeId = try nodeId(req)
        let stored: StoredNodeExecution?
        do { stored = try await store.lastNodeExecution(doc: a.id, nodeId: nodeId, createdBy: a.mode == "advanced-chat" ? p.id : nil) } catch { throw ServerError.unavailable("\(error)") }
        guard let e = stored else { throw ServerError.missing("last run not found") }
        return await fileJSONResponse(Self.executionJSON(e), userId: p.id)
    }

    /// A stored execution as Dify's `WorkflowRunNodeExecutionResponse`.
    static func executionJSON(_ e: StoredNodeExecution) -> JSONValue {
        func obj(_ text: String?) -> JSONObject? { text.flatMap { try? JSONValue.parse($0) }?.object }
        var x = NodeExecution(id: e.id, nodeId: e.nodeId, nodeType: e.nodeType, title: e.title,
                              status: NodeExecutionStatus(rawValue: e.status) ?? .failed, elapsedTime: e.elapsedTime,
                              createdAt: e.createdAt, finishedAt: e.finishedAt)
        x.index = e.index
        x.predecessorNodeId = e.predecessorNodeId
        x.inputs = obj(e.inputs)
        x.processData = obj(e.processData)
        x.outputs = obj(e.outputs)
        x.error = e.error
        x.metadata = obj(e.executionMetadata)
        let account: JSONValue = e.createdBy.map { id in
            ["id": .string(id), "name": .string(e.createdByName ?? ""), "email": .string(e.createdByEmail ?? "")]
        } ?? .null
        return x.responseJSON(createdByAccount: account)
    }

    /// Dify's `DifyCredentialsProvider.fetch`: the current credentials of a model of the workspace (a custom model's own,
    /// else the provider's), with Dify's errors when the provider, the model or its credentials are missing.
    func currentCredentials(provider: String, model: String, modelType: String) async throws -> JSONObject {
        guard let def = models.catalog.provider(provider) else { throw NodeError("ValueError", "Provider \(provider) does not exist.") }
        let state: ModelProviderState
        do { state = try await store.modelProviderState() } catch { throw NodeError("ValueError", "\(error)") }
        let v = view(def, state)
        func parsed(_ text: String?) -> JSONObject? {
            guard let text, let o = (try? JSONValue.parse(text))?.object, !o.isEmpty else { return nil }
            return JSONObject(o.filter { $0.key != ModelDiscovery.metadataKey })
        }
        if let c = v.customModels.first(where: { !$0.unadded && $0.key.model == model && $0.key.modelType == modelType }) {
            if v.settings[c.key] == false { throw NodeError("ValueError", "Model is disabled") }
            guard let creds = parsed(c.current?.config) else {
                throw NodeError("ProviderTokenNotInitError", "Model \(model) credentials is not initialized.")
            }
            return creds
        }
        guard def.models.contains(where: { $0.model == model && $0.modelType == modelType }) else {
            throw NodeError("ModelNotExistError", "Model \(model) not exist.")
        }
        if v.settings[ModelKey(provider: def.id.description, model: model, modelType: modelType)] == false {
            throw NodeError("ValueError", "Model is disabled")
        }
        guard let creds = parsed(v.current?.config) else {
            if v.currentUnreadable { throw NodeError("ProviderTokenNotInitError", "Model \(model) credentials is not initialized.") }
            throw NodeError("ValueError", "Model is not configured")
        }
        return creds
    }
}
