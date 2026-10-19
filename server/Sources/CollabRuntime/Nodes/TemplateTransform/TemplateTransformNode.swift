// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/nodes/template_transform/template_transform_node.py, entities.py; Dify 1.17.1 (Apache-2.0 with Dify's
// conditions): api/core/workflow/node_factory.py (renderer and TEMPLATE_TRANSFORM_MAX_LENGTH). See ../../NOTICE.md.

/// The template transform node: a Jinja2 template over named variables (rendered by the code sandbox), output `output`.
public struct TemplateTransformNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let variables: [VariableSelector]
    public let template: String
    let renderer: any Jinja2TemplateRenderer
    let maxOutputLength: Int

    public var nodeType: String { NodeType.templateTransform }

    public init(id: String, data: JSONObject, renderer: any Jinja2TemplateRenderer, maxOutputLength: Int = 400_000) throws {
        self.id = id
        base = try BaseNodeData(data)
        guard let vars = data["variables"]?.array else { throw NodeDataError("variables: Field required") }
        variables = try vars.map { v in
            guard let s = VariableSelector(json: v) else { throw NodeDataError("variables: variable and value_selector are required") }
            return s
        }
        guard let t = data["template"]?.string else { throw NodeDataError("template: Field required") }
        template = t
        self.renderer = renderer
        guard maxOutputLength > 0 else { throw NodeDataError("max_output_length must be a positive integer") }
        self.maxOutputLength = maxOutputLength
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var inputs = JSONObject()
        for v in variables { inputs[v.variable] = context.pool.get(v.valueSelector)?.object ?? .null }
        let rendered: String
        do {
            rendered = try await renderer.renderTemplate(template, inputs: inputs)
        } catch let e as TemplateRenderError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, error: e.message)))
            return
        }
        if rendered.unicodeScalars.count > maxOutputLength {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, error: "Output length exceeds \(maxOutputLength) characters")))
            return
        }
        await emit(.completed(NodeRunResult(status: .succeeded, inputs: inputs, outputs: ["output": .string(rendered)])))
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var out: [(String, [String])] = []
        for v in variables {
            let key = id + "." + v.variable
            if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = v.valueSelector } else { out.append((key, v.valueSelector)) }
        }
        return out
    }
}

extension BuiltinNodeFactory {
    /// Dify's factory: the sandbox-backed Jinja2 renderer and `TEMPLATE_TRANSFORM_MAX_LENGTH`.
    func makeTemplateTransform(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        let renderer: any Jinja2TemplateRenderer
        if let r = services.jinja2 {
            renderer = r
        } else if let executor = services.codeExecutor {
            renderer = SandboxJinja2Renderer(executor: executor)
        } else {
            throw ServiceNotConfigured(service: .codeSandbox)
        }
        let max = services.codeExecutor?.limits.templateTransformMaxLength ?? CodeNodeLimits.difyDefaults.templateTransformMaxLength
        return try TemplateTransformNode(id: config.id, data: config.data, renderer: renderer, maxOutputLength: max)
    }
}
