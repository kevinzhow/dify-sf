import CollabCore
import CollabDSL
import CollabRuntime
import CollabStore
import Foundation
import HTTPTypes
import Vapor

/// Draft variables (docs/protocol.md section 2, "Draft variables (1.14)"): Dify 1.17.1's
/// `controllers/console/app/workflow_draft_variable.py` over `workflow_draft_variables`. Each account has its own draft
/// variables per app (Dify keys them by app and user): the latest node outputs, system variables and conversation
/// variables of its debug runs, which the editor's variable inspect panel shows and edits. They are run records, never
/// document ops.
extension Routes {
    func registerDraftVariables(on r: any RoutesBuilder) {
        let apps = r.grouped("v1", "apps")
        apps.get(":app", "workflows", "draft", "variables") { req in await handle(req) { try await listDraftVariables(req) } }
        apps.delete(":app", "workflows", "draft", "variables") { req in await handle(req) { try await deleteAllDraftVariables(req) } }
        apps.get(":app", "workflows", "draft", "nodes", ":node", "variables") { req in await handle(req) { try await nodeDraftVariables(req) } }
        apps.delete(":app", "workflows", "draft", "nodes", ":node", "variables") { req in
            await handle(req) { try await deleteNodeDraftVariables(req) }
        }
        apps.get(":app", "workflows", "draft", "variables", ":variable") { req in await handle(req) { try await getDraftVariable(req) } }
        apps.patch(":app", "workflows", "draft", "variables", ":variable") { req in await handle(req) { try await patchDraftVariable(req) } }
        apps.delete(":app", "workflows", "draft", "variables", ":variable") { req in await handle(req) { try await deleteDraftVariable(req) } }
        apps.put(":app", "workflows", "draft", "variables", ":variable", "reset") { req in await handle(req) { try await resetDraftVariable(req) } }
        apps.get(":app", "workflows", "draft", "conversation-variables") { req in await handle(req) { try await conversationDraftVariables(req) } }
        apps.get(":app", "workflows", "draft", "system-variables") { req in await handle(req) { try await systemDraftVariables(req) } }
        apps.get(":app", "workflows", "draft", "environment-variables") { req in await handle(req) { try await environmentVariables(req) } }
    }

    // MARK: - API for the runs

    /// `DraftVariableSaver.save` for one node execution of a debug run of `userId` (a draft run or a single-step run) at
    /// document seq `docSeq`. `outputs` as the run reports them (a start node in a draft run: its inputs; in a single-step
    /// run: its whole outputs). `enclosingNodeId`: the iteration or loop the node is in.
    func saveDraftVariables(appId: String, userId: String, docSeq: Int, nodeId: String, nodeType: String, executionId: String,
                            enclosingNodeId: String? = nil, processData: JSONObject?, outputs: JSONObject?, outputTypes: [String: SegmentType] = [:]) async throws {
        let vars = try DraftVariableRules.variables(nodeId: nodeId, nodeType: nodeType, executionId: executionId, enclosingNodeId: enclosingNodeId,
                                                    processData: processData, outputs: outputs)
        let now = Date()
        // Each variable a little newer than the previous one, as Dify's per-row timestamps (lists are newest first).
        let rows = vars.enumerated().map { i, v in
            StoredDraftVariable(id: UUID().uuidString.lowercased(), docId: appId, userId: userId, nodeId: v.nodeId, name: v.name,
                                description: v.description, valueType: (outputTypes[v.nodeId == nodeId ? v.name : v.nodeId + "." + v.name] ?? v.valueType).rawValue, value: v.value.compactJSON(), visible: v.visible,
                                editable: v.editable, nodeExecutionId: v.nodeExecutionId, docSeq: docSeq,
                                createdAt: now.addingTimeInterval(Double(i) * 0.00001), updatedAt: now)
        }
        try await store.upsertDraftVariables(rows)
    }

    /// The `DraftVarLoader`: `userId`'s draft variables at these selectors (`[node, name]`; longer selectors read their
    /// first two parts), as typed segments, for a single-step run's missing inputs (`DraftVariableRules.selectorsToLoad`).
    func loadDraftVariables(appId: String, userId: String, selectors: [[String]]) async throws -> [(selector: [String], segment: Segment)] {
        guard !selectors.isEmpty else { return [] }
        let rows = try await store.draftVariables(doc: appId, user: userId, selectors: selectors)
        var result: [(selector: [String], segment: Segment)] = []
        let files = runtimeServices(appId: appId, userId: userId).files
        for row in rows {
            let segment = Self.draftSegment(row)
            let value = try await files?.canonicalize(segment.value) ?? segment.value
            result.append(([row.nodeId, row.name], Segment(segment.valueType, value)))
        }
        return result
    }

    /// `prefill_conversation_variable_default_values`: the draft's conversation variables as `userId`'s draft variables,
    /// keeping values that already exist (Dify does this before a single-step run and when the list is read).
    func prefillConversationDraftVariables(appId: String, userId: String, viewer: String) async throws {
        let conversation = try await documentVariables(appId, viewer: viewer, key: DifyDSL.conversationVariables)
        let now = Date()
        var rows: [StoredDraftVariable] = []
        for (i, item) in conversation.enumerated() {
            guard let built = try? WorkflowBootstrap.variable(item) else { continue }
            let (name, segment) = built
            rows.append(StoredDraftVariable(id: UUID().uuidString.lowercased(), docId: appId, userId: userId, nodeId: VariablePool.conversationNodeId,
                                            name: name, description: item["description"]?.string ?? "", valueType: segment.valueType.rawValue,
                                            value: segment.value.compactJSON(), visible: true, editable: true, nodeExecutionId: nil, docSeq: nil,
                                            createdAt: now.addingTimeInterval(Double(i) * 0.00001), updatedAt: now))
        }
        try await store.upsertDraftVariables(rows, ignoreExisting: true)
    }

    // MARK: - Shapes

    static func draftSegment(_ r: StoredDraftVariable) -> Segment {
        Segment(SegmentType(rawValue: r.valueType) ?? .none, (try? JSONValue.parse(r.value)) ?? .null)
    }

    /// `WorkflowDraftVariableWithoutValueResponse` (`value` and `full_content` added for the full shape). Values are
    /// never offloaded here: `is_truncated` false, `full_content` null.
    static func draftVariableJSON(_ r: StoredDraftVariable, withValue: Bool) -> JSONValue {
        let type = SegmentType(rawValue: r.valueType) ?? .none
        var o: JSONObject = [
            "id": .string(r.id),
            "type": .string(DraftVariable.variableType(nodeId: r.nodeId)),
            "name": .string(r.name),
            "description": .string(r.description),
            "selector": [.string(r.nodeId), .string(r.name)],
            "value_type": .string(type.exposed.rawValue),
            "edited": .bool(r.lastEditedAt != nil),
            "visible": .bool(r.visible),
            "is_truncated": false,
        ]
        if withValue {
            o["value"] = (try? JSONValue.parse(r.value)) ?? .null
            o["full_content"] = .null
        }
        return .object(o)
    }

    static func draftList(_ rows: [StoredDraftVariable]) -> JSONValue {
        ["items": .array(rows.map { draftVariableJSON($0, withValue: true) })]
    }

    // MARK: - Plumbing

    /// Dify's `_api_prerequisite`: edit permission, workflow and chatflow apps.
    func draftPrerequisite(_ req: Request) async throws -> (Principal, StoredApp) {
        let p = try await authenticate(req, .edit)
        let a = try await appOfMode(req, p, Self.workflowModes)
        return (p, a)
    }

    /// `ensure_variable_access`: the caller's variable of this app, else `404` "variable not found, id=...".
    func ownedDraftVariable(_ req: Request, _ p: Principal, _ a: StoredApp) async throws -> StoredDraftVariable {
        let id = req.parameters.get("variable") ?? ""
        let found: StoredDraftVariable?
        if UUID(uuidString: id) == nil {
            found = nil
        } else {
            do { found = try await store.draftVariable(id: id.lowercased()) } catch { throw ServerError.unavailable("\(error)") }
        }
        guard let v = found, v.docId == a.id, v.userId == p.id else { throw ServerError.missing("variable not found, id=\(id)") }
        return v
    }

    func draftStore<T: Sendable>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch let e as ServerError { throw e } catch { throw ServerError.unavailable("\(error)") }
    }

    /// The document's `environment_variables` / `conversation_variables` (as `GET /v1/docs/{doc}/meta` gives them: secret
    /// values masked), at the current seq.
    func documentVariables(_ appId: String, viewer: String, key: String) async throws -> [JSONValue] {
        let snapshot = try await registry.sequencer(appId).currentSnapshot()
        let metadata = try await currentMetadata(appId, viewer: viewer)
        let meta = try JSONValue.parse(try WireJSON.encode(DifyDSL.appMeta(metadata, document: snapshot.doc)))
        return meta[key]?.array ?? []
    }

    static func noContent() -> Response { Response(status: .noContent) }

    // MARK: - Endpoints

    /// `GET .../workflows/draft/variables?page=&limit=`: the caller's variables without values, newest first; `total` on
    /// the first page only.
    private func listDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let q = queryAll(req)
        let page = try queryInt(q, "page", 1, 1...100_000)
        let limit = try queryInt(q, "limit", 20, 1...100)
        let (rows, total) = try await draftStore { try await store.draftVariablesPage(doc: a.id, user: p.id, page: page, limit: limit) }
        return await fileJSONResponse(["items": .array(rows.map { Self.draftVariableJSON($0, withValue: false) }), "total": total.map(JSONValue.int) ?? .null], userId: p.id)
    }

    private func deleteAllDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        try await draftStore { try await store.deleteDraftVariables(doc: a.id, user: p.id) }
        return Self.noContent()
    }

    /// `validate_node_id`: `sys` and `conversation` have their own endpoints.
    func draftNodeId(_ req: Request) throws -> String {
        let node = try nodeId(req)
        if node == VariablePool.conversationNodeId || node == VariablePool.systemNodeId {
            throw Self.invalidParam("invalid node_id, please use correspond api for conversation and system variables, node_id=\(node)")
        }
        return node
    }

    private func nodeDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let node = try draftNodeId(req)
        return await fileJSONResponse(Self.draftList(try await draftStore { try await store.draftVariables(doc: a.id, user: p.id, node: node) }), userId: p.id)
    }

    private func deleteNodeDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let node = try draftNodeId(req)
        try await draftStore { try await store.deleteDraftVariables(doc: a.id, user: p.id, node: node) }
        return Self.noContent()
    }

    private func getDraftVariable(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        return await fileJSONResponse(Self.draftVariableJSON(try await ownedDraftVariable(req, p, a), withValue: true), userId: p.id)
    }

    /// `PATCH .../variables/{id}` `{"name"?, "value"?}`: an editable variable's new name and/or value (the value must fit the
    /// variable's type); marks it edited.
    private func patchDraftVariable(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let data = try await body(req)
        guard let parsed = try? JSONValue.parse(data.isEmpty ? Data("{}".utf8) : data), case .object(let b) = parsed else {
            throw ServerError.badRequest("the body must be a JSON object")
        }
        let v = try await ownedDraftVariable(req, p, a)
        var newName: String?
        switch b["name"] {
        case nil, .null?: newName = nil
        case .string(let s)?: newName = s
        default: throw Self.invalidParam("name must be a string")
        }
        let rawValue = b["value"].flatMap { $0 == .null ? nil : $0 }
        if newName == nil && rawValue == nil { return await fileJSONResponse(Self.draftVariableJSON(v, withValue: true), userId: p.id) }
        guard v.editable else { throw Self.invalidParam("variable not support updating, id=\(v.id)") }
        var segment: Segment?
        if let rawValue {
            let type = SegmentType(rawValue: v.valueType) ?? .none
            do {
                let value = try await runtimeServices(appId: a.id, userId: p.id).files?.canonicalize(rawValue, allowInputMappings: type == .file || type == .arrayFile) ?? rawValue
                if (type == .file || type == .arrayFile) && !config.files.isConfigured { throw RuntimeFileError("File storage is not configured") }
                segment = try DraftVariableRules.buildSegment(type: type, value: value)
            } catch {
                throw Self.invalidParam("\(error)")
            }
        }
        if let newName, newName != v.name {
            let clash = try await draftStore { try await store.draftVariables(doc: a.id, user: p.id, selectors: [[v.nodeId, newName]]) }
            if !clash.isEmpty { throw Self.invalidParam("a variable named \(newName) already exists, node_id=\(v.nodeId)") }
        }
        let updated = try await draftStore {
            try await store.updateDraftVariable(id: v.id, name: newName, valueType: segment?.valueType.rawValue, value: segment?.value.compactJSON(),
                                                edited: true)
        }
        guard let updated else { throw ServerError.missing("variable not found, id=\(v.id)") }
        return await fileJSONResponse(Self.draftVariableJSON(updated, withValue: true), userId: p.id)
    }

    private func deleteDraftVariable(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let v = try await ownedDraftVariable(req, p, a)
        try await draftStore { try await store.deleteDraftVariable(id: v.id) }
        return Self.noContent()
    }

    /// `PUT .../variables/{id}/reset`: back to what the draft or the last execution says (`reset_variable`); `204` when
    /// that is nothing (the variable is deleted).
    private func resetDraftVariable(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let v = try await ownedDraftVariable(req, p, a)
        let kind = DraftVariable.variableType(nodeId: v.nodeId)
        if kind == "sys" && !DraftVariableRules.isSystemVariableEditable(v.name) {
            throw Self.invalidParam("cannot reset system variable, variable_id=\(v.id)")
        }
        func deleted() async throws -> Response {
            try await draftStore { try await store.deleteDraftVariable(id: v.id) }
            return Self.noContent()
        }
        func reset(to segment: Segment) async throws -> Response {
            let r = try await draftStore {
                try await store.updateDraftVariable(id: v.id, name: nil, valueType: segment.valueType.rawValue, value: segment.value.compactJSON(),
                                                    edited: false)
            }
            guard let r else { return Self.noContent() }
            return await fileJSONResponse(Self.draftVariableJSON(r, withValue: true), userId: p.id)
        }
        if kind == "conversation" {
            // _reset_conv_var: the draft's default, or gone.
            let items = try await documentVariables(a.id, viewer: p.id, key: DifyDSL.conversationVariables)
            guard let item = items.first(where: { $0["name"]?.string == v.name }), let built = try? WorkflowBootstrap.variable(item) else {
                return try await deleted()
            }
            return try await reset(to: built.segment)
        }
        // _reset_node_var_or_sys_var
        if !v.editable { return await fileJSONResponse(Self.draftVariableJSON(v, withValue: true), userId: p.id) }
        guard let executionId = v.nodeExecutionId else { return try await deleted() }
        guard let execution = try await draftStore({ try await store.nodeExecutionOutputs(id: executionId) }) else { return try await deleted() }
        let outputs = execution.outputs.flatMap { try? JSONValue.parse($0) }?.object ?? [:]
        let key: String
        if kind == "node" {
            if execution.nodeType == NodeType.variableAssigner { return await fileJSONResponse(Self.draftVariableJSON(v, withValue: true), userId: p.id) }
            key = v.name
        } else {
            key = "sys.\(v.name)"
        }
        guard let value = outputs[key] else { return try await deleted() }
        let type = SegmentType(rawValue: v.valueType) ?? .none
        let segment = (try? DraftVariableRules.buildSegment(type: type, value: value)) ?? Segment.build(value)
        return try await reset(to: segment)
    }

    /// `GET .../conversation-variables`: the draft's conversation variables (filled in with their defaults first).
    private func conversationDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        try await prefillConversationDraftVariables(appId: a.id, userId: p.id, viewer: p.id)
        return await fileJSONResponse(Self.draftList(try await draftStore {
            try await store.draftVariables(doc: a.id, user: p.id, node: VariablePool.conversationNodeId)
        }), userId: p.id)
    }

    private func systemDraftVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        return await fileJSONResponse(Self.draftList(try await draftStore {
            try await store.draftVariables(doc: a.id, user: p.id, node: VariablePool.systemNodeId)
        }), userId: p.id)
    }

    /// `GET .../environment-variables`: the draft's environment variables (secrets masked, as the editor shows them).
    private func environmentVariables(_ req: Request) async throws -> Response {
        let (p, a) = try await draftPrerequisite(req)
        let items = try await documentVariables(a.id, viewer: p.id, key: DifyDSL.environmentVariables)
        let out: [JSONValue] = items.compactMap { v in
            guard let name = v["name"]?.string else { return nil }
            let selector: JSONValue = (v["selector"]?.array).map { .array($0) } ?? [.string(VariablePool.environmentNodeId), .string(name)]
            return [
                "id": v["id"] ?? .null, "type": "env", "name": .string(name), "description": v["description"] ?? .null,
                "selector": selector, "value_type": v["value_type"] ?? .null, "value": v["value"] ?? .null,
                "edited": false, "visible": true, "editable": true,
            ]
        }
        return await fileJSONResponse(["items": .array(out)], userId: p.id)
    }
}
