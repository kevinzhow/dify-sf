import CollabCore

/// Protocol 1.10: what a blank app starts with (`POST /v1/apps`), as a Dify file imported like any other (so the document,
/// its metadata and its export are exactly an import's).
///
/// * `advanced-chat` (Chatflow): Dify's chatflow template (`useWorkflowTemplate`, web/app/components/workflow-app/hooks):
///   User Input -> LLM (`llm`, empty model, Dify's memory window and query template) -> Answer (`answer`, `{{#llm.text#}}`),
///   features `retriever_resource` on (what Dify's first draft sync sends).
/// * `workflow`: one User Input (start) node. Dify's blank workflow has no node and shows a local "start" placeholder that
///   the user turns into a start or trigger node; dify-sf seeds the start node instead.
extension DifyDSL {
    public static func blankApp(mode: String, name: String, description: String = "", iconType: String? = nil, icon: String? = nil,
                                iconBackground: String? = nil) -> Value {
        func node(_ id: String, _ type: String, _ title: String, x: Int, height: Int, _ data: [String: Value]) -> Value {
            var d = data
            d["type"] = .string(type)
            d["title"] = .string(title)
            d["desc"] = .string("")
            d["selected"] = .bool(false)
            return .map([
                "id": .string(id), "type": .string("custom"),
                "position": .map(["x": .int(x), "y": .int(282)]), "positionAbsolute": .map(["x": .int(x), "y": .int(282)]),
                "width": .int(240), "height": .int(height), "sourcePosition": .string("right"), "targetPosition": .string("left"),
                "selected": .bool(false), "data": .map(d),
            ])
        }
        func edge(_ s: String, _ st: String, _ t: String, _ tt: String) -> Value {
            .map([
                "id": .string("\(s)-source-\(t)-target"), "type": .string("custom"), "source": .string(s), "sourceHandle": .string("source"),
                "target": .string(t), "targetHandle": .string("target"), "zIndex": .int(0),
                "data": .map(["sourceType": .string(st), "targetType": .string(tt), "isInIteration": .bool(false), "isInLoop": .bool(false)]),
            ])
        }
        let chat = mode == "advanced-chat"
        var nodes: [Value] = [node("start", "start", "User Input", x: 80, height: 54, ["variables": .list([])])]
        var edges: [Value] = []
        if chat {
            nodes.append(node("llm", "llm", "LLM", x: 380, height: 98, [
                "model": .map(["provider": .string(""), "name": .string(""), "mode": .string("chat"),
                               "completion_params": .map(["temperature": .double(0.7)])]),
                "prompt_template": .list([.map(["role": .string("system"), "text": .string("")])]),
                "context": .map(["enabled": .bool(false), "variable_selector": .list([])]),
                "vision": .map(["enabled": .bool(false)]),
                "memory": .map(["window": .map(["enabled": .bool(false), "size": .int(10)]),
                                "query_prompt_template": .string("{{#sys.query#}}\n\n{{#sys.files#}}")]),
            ]))
            nodes.append(node("answer", "answer", "Answer", x: 680, height: 104, ["variables": .list([]), "answer": .string("{{#llm.text#}}")]))
            edges = [edge("start", "start", "llm", "llm"), edge("llm", "llm", "answer", "answer")]
        }
        var app: [String: Value] = ["mode": .string(mode), "name": .string(name), "description": .string(description),
                                    "use_icon_as_answer_icon": .bool(false)]
        if let iconType { app["icon_type"] = .string(iconType) }
        app["icon"] = .string(icon ?? "🤖")
        app["icon_background"] = .string(iconBackground ?? "#FFEAD5")
        return .map([
            "version": .string(currentDSLVersion), "kind": .string("app"), "app": .map(app), "dependencies": .list([]),
            "workflow": .map([
                "environment_variables": .list([]), "conversation_variables": .list([]),
                "features": chat ? .map(["retriever_resource": .map(["enabled": .bool(true)])]) : .map([:]),
                "graph": .map(["nodes": .list(nodes), "edges": .list(edges),
                               "viewport": .map(["x": .int(0), "y": .int(0), "zoom": .int(1)])]),
            ]),
        ])
    }

    /// `metadata` with its `app` section's members replaced by `fields` (the app row is the source of truth for name,
    /// description and icon, protocol 1.10); `.null` members are removed.
    public static func overlayingApp(_ metadata: Value, _ fields: [String: Value]) -> Value {
        guard case .map(var top) = metadata else { return metadata }
        var app: [String: Value] = { if case .map(let a)? = top["app"] { return a }; return [:] }()
        for (k, v) in fields { app[k] = v == .null ? nil : v }
        top["app"] = .map(app)
        return .map(top)
    }
}
