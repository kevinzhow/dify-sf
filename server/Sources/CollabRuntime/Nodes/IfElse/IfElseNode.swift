// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/if_else/if_else_node.py,
// entities.py. See ../../NOTICE.md.

/// The if-else node: the first case whose conditions hold selects its handle (`case_id`), else `false`.
public struct IfElseNode: RuntimeNode {
    public struct Case: Sendable {
        public var caseId: String
        public var logicalOperator: String
        public var conditions: [Condition]

        var json: JSONValue {
            ["case_id": .string(caseId), "logical_operator": .string(logicalOperator), "conditions": .array(conditions.map(\.json))]
        }
    }

    public let id: String
    public let base: BaseNodeData
    public let cases: [Case]
    /// The pre-`cases` shape (`conditions` + `logical_operator`): one case `true`, logged as group "default".
    public let legacy: Bool

    public var nodeType: String { NodeType.ifElse }
    public var executionType: NodeExecutionType { .branch }

    public init(id: String, data: JSONObject) throws {
        self.id = id
        base = try BaseNodeData(data)
        func logical(_ v: JSONValue?) throws -> String {
            switch v {
            case nil, .null?: return "and"
            case .string(let s)? where s == "and" || s == "or": return s
            default: throw NodeDataError("logical_operator: Input should be 'and' or 'or'")
            }
        }
        if let list = data["cases"]?.array {
            legacy = false
            cases = try list.map { c in
                guard let id = c["case_id"]?.string else { throw NodeDataError("cases.case_id: Field required") }
                guard let op = c["logical_operator"]?.string, op == "and" || op == "or" else {
                    throw NodeDataError("cases.logical_operator: Input should be 'and' or 'or'")
                }
                return Case(caseId: id, logicalOperator: op, conditions: try (c["conditions"]?.array ?? []).map(Condition.init(json:)))
            }
        } else {
            legacy = true
            cases = [Case(caseId: "true", logicalOperator: try logical(data["logical_operator"]),
                          conditions: try (data["conditions"]?.array ?? []).map(Condition.init(json:)))]
        }
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var inputs: JSONObject = ["conditions": .array([])]
        var results: [JSONValue] = []
        var finalResult = false
        var selected = "false"
        var lastInputs: [JSONValue] = []
        do {
            for c in cases {
                let r = try ConditionProcessor.process(pool: context.pool, conditions: c.conditions, logicalOperator: c.logicalOperator)
                lastInputs = r.inputs
                results.append(["group": legacy ? "default" : c.json, "results": .array(r.groupResults.map(JSONValue.bool)),
                                "final_result": .bool(r.finalResult)])
                if r.finalResult {
                    finalResult = true
                    selected = legacy ? "true" : c.caseId
                    break
                }
            }
            inputs["conditions"] = .array(lastInputs)
        } catch let e as ConditionProcessor.EvaluationError {
            await emit(.completed(NodeRunResult(status: .failed, inputs: inputs, processData: ["condition_results": .array(results)],
                                                error: e.description)))
            return
        }
        var r = NodeRunResult(status: .succeeded, inputs: inputs, processData: ["condition_results": .array(results)],
                              outputs: ["result": .bool(finalResult), "selected_case_id": .string(selected)])
        r.edgeSourceHandle = selected.isEmpty ? "false" : selected
        await emit(.completed(r))
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var out: [(String, [String])] = []
        for c in cases {
            for cond in c.conditions {
                let key = "\(id).#\(cond.variableSelector.joined(separator: "."))#"
                if let i = out.firstIndex(where: { $0.0 == key }) { out[i].1 = cond.variableSelector } else { out.append((key, cond.variableSelector)) }
            }
        }
        return out
    }
}

extension BuiltinNodeFactory {
    func makeIfElse(_ config: NodeConfig, graph: GraphConfig) async throws -> any RuntimeNode {
        try IfElseNode(id: config.id, data: config.data)
    }
}
