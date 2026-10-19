// Ported from Dify 1.17.1 (https://github.com/langgenius/dify, Apache-2.0 with Dify's conditions):
// api/services/workflow_draft_variable_service.py (DraftVariableSaver, DraftVarLoader's selection),
// api/models/workflow.py (WorkflowDraftVariable factories, is_system_variable_editable), graphon 0.7.0
// (https://github.com/langgenius/graphon, Apache-2.0): graphon/variable_loader.py (load_into_variable_pool),
// graphon/variables/factory.py (build_segment_with_type), graphon/nodes/variable_assigner/common/helpers.py
// (the `__updated_variables` process data). See NOTICE.md.
//
// Not ported: offloading large values to file storage (`WorkflowDraftVariableFile`; values are never truncated here, so
// `is_truncated` is false and `full_content` null), file values (no files before P5).

import Foundation

/// A draft variable as Dify keeps it (`workflow_draft_variables`): the latest value of a node output, a system variable
/// or a conversation variable for one account in one app, shown by the editor's variable inspect panel.
public struct DraftVariable: Sendable, Equatable {
    public var nodeId: String
    public var name: String
    /// The stored `SegmentType` (`integer`, `float`, `string`, ...; `exposed` maps numbers to `number`).
    public var valueType: SegmentType
    public var value: JSONValue
    public var visible: Bool
    public var editable: Bool
    /// The node execution that produced it; nil for conversation variables.
    public var nodeExecutionId: String?
    public var description: String

    public init(nodeId: String, name: String, valueType: SegmentType, value: JSONValue, visible: Bool, editable: Bool,
                nodeExecutionId: String?, description: String = "") {
        self.nodeId = nodeId
        self.name = name
        self.valueType = valueType
        self.value = value
        self.visible = visible
        self.editable = editable
        self.nodeExecutionId = nodeExecutionId
        self.description = description
    }

    public var selector: [String] { [nodeId, name] }

    /// `DraftVariableType`: `sys`, `conversation` or `node`.
    public static func variableType(nodeId: String) -> String {
        switch nodeId {
        case VariablePool.conversationNodeId: return "conversation"
        case VariablePool.systemNodeId: return "sys"
        default: return "node"
        }
    }

    public var variableType: String { Self.variableType(nodeId: nodeId) }
    public var segment: Segment { Segment(valueType, value) }
}

/// Dify's `DraftVariableSaver` rules and the draft-variable side of a single-step run.
public enum DraftVariableRules {
    /// `_DUMMY_OUTPUT_IDENTITY`: marks that a node ran when it saved no other variable.
    public static let dummyName = "__dummy__"
    /// `_EXCLUDE_VARIABLE_NAMES_MAPPING`.
    public static let excludedNames: [String: Set<String>] = [NodeType.llm: ["finish_reason"], NodeType.loop: ["loop_round"]]
    /// `_EDITABLE_SYSTEM_VARIABLE`.
    public static let editableSystemVariables: Set<String> = ["query", "files"]
    /// `_UPDATED_VARIABLES_KEY` of the variable assigner's process data.
    public static let updatedVariablesKey = "__updated_variables"
    /// Node types whose outputs map like a start node's (`is_start_node_type` without the datasource).
    static let startLikeTypes: Set<String> = [NodeType.start, "trigger-webhook", "trigger-schedule", "trigger-plugin"]

    public static func isSystemVariableEditable(_ name: String) -> Bool { editableSystemVariables.contains(name) }

    /// `_should_variable_be_editable`.
    public static func isEditable(nodeId: String, name: String) -> Bool {
        if nodeId == VariablePool.conversationNodeId || nodeId == VariablePool.environmentNodeId { return false }
        if nodeId == VariablePool.systemNodeId && !isSystemVariableEditable(name) { return false }
        return true
    }

    /// `_should_variable_be_visible`.
    public static func isVisible(nodeId: String, nodeType: String, name: String) -> Bool {
        if nodeType == NodeType.ifElse { return false }
        if nodeId == VariablePool.systemNodeId && !isSystemVariableEditable(name) { return false }
        return true
    }

    /// `DraftVariableSaver.save`: the variables one node execution saves (upserted by `(node_id, name)`), in Dify's
    /// creation order. `enclosingNodeId` = the iteration or loop the node is in (those save nothing but assigners).
    /// `outputs` as Dify passes them: the node's outputs as the run reports them (for a start node in a draft run: its
    /// inputs; in a single-step run: its whole outputs, `sys.*` included).
    public static func variables(nodeId: String, nodeType: String, executionId: String, enclosingNodeId: String? = nil,
                                 processData: JSONObject?, outputs: JSONObject?) throws -> [DraftVariable] {
        let outputs = outputs ?? [:]
        let processData = processData ?? [:]
        if enclosingNodeId != nil && nodeType != NodeType.variableAssigner { return [] }
        func dummy() -> DraftVariable {
            DraftVariable(nodeId: nodeId, name: dummyName, valueType: .none, value: .null, visible: false, editable: false,
                          nodeExecutionId: executionId)
        }
        if nodeType == NodeType.variableAssigner {
            // _build_from_variable_assigner_mapping: only conversation variables are saved.
            var out: [DraftVariable] = []
            for item in processData[updatedVariablesKey]?.array ?? [] {
                guard let selector = item["selector"]?.array?.compactMap(\.string), let name = item["name"]?.string else {
                    throw DraftVariableError.invalid("Invalid updated variable: \(PythonText.str(item))")
                }
                if selector.count < VariablePool.selectorsLength { throw DraftVariableError.invalid("selector too short") }
                guard selector[0] == VariablePool.conversationNodeId else { continue }
                var type = SegmentType(rawValue: item["value_type"]?.string ?? "") ?? .none
                if type == .integer { type = .number }
                let segment = try buildSegment(type: type, value: item["new_value"] ?? .null)
                out.append(DraftVariable(nodeId: VariablePool.conversationNodeId, name: name, valueType: segment.valueType, value: segment.value,
                                         visible: true, editable: true, nodeExecutionId: nil))
            }
            out.append(dummy())
            return out
        }
        if startLikeTypes.contains(nodeType) {
            // _build_variables_from_start_mapping.
            var out: [DraftVariable] = []
            var hasNonSys = false
            for (key, value) in outputs {
                var segment = Segment.build(value)
                let (owner, name) = normalizeStartName(key, nodeId: nodeId)
                if owner == VariablePool.systemNodeId {
                    if name == "files" { segment = Segment(.arrayFile, value.array.map { .array($0) } ?? .array([])) }
                    out.append(DraftVariable(nodeId: owner, name: name, valueType: segment.valueType, value: segment.value, visible: true,
                                             editable: isEditable(nodeId: owner, name: name), nodeExecutionId: executionId))
                } else if owner == VariablePool.conversationNodeId {
                    out.append(DraftVariable(nodeId: owner, name: name, valueType: segment.valueType, value: segment.value, visible: true,
                                             editable: true, nodeExecutionId: nil))
                    hasNonSys = true
                } else {
                    out.append(DraftVariable(nodeId: owner, name: name, valueType: segment.valueType, value: segment.value,
                                             visible: isVisible(nodeId: owner, nodeType: nodeType, name: name),
                                             editable: isEditable(nodeId: owner, name: name), nodeExecutionId: executionId))
                    hasNonSys = true
                }
            }
            if !hasNonSys { out.append(dummy()) }
            return out
        }
        // _build_variables_from_mapping.
        let excluded = excludedNames[nodeType] ?? []
        return outputs.filter { !excluded.contains($0.key) }.map { name, value in
            let segment = Segment.build(value)
            return DraftVariable(nodeId: nodeId, name: name, valueType: segment.valueType, value: segment.value, visible: true, editable: true,
                                 nodeExecutionId: executionId)
        }
    }

    /// `_normalize_variable_for_start_node`: `sys.x`, `env.x`, `conversation.x`, `rag.x` belong to those prefixes.
    static func normalizeStartName(_ key: String, nodeId: String) -> (String, String) {
        for reserved in [VariablePool.systemNodeId, VariablePool.environmentNodeId, VariablePool.conversationNodeId,
                         VariablePool.ragPipelineNodeId] where key.hasPrefix(reserved + ".") {
            return (reserved, String(key.dropFirst(reserved.count + 1)))
        }
        return (nodeId, key)
    }

    /// `build_segment_with_type`: `value` must have `type` (`number` takes an integer or a float; an empty list fits every
    /// array type), else `TypeMismatchError`.
    public static func buildSegment(type: SegmentType, value: JSONValue) throws -> Segment {
        if value == .null {
            if type == .none { return .none }
            throw DraftVariableError.typeMismatch("Type mismatch: expected \(type.rawValue), but got None")
        }
        if case .array(let a) = value, a.isEmpty {
            switch type {
            case .arrayAny, .arrayString, .arrayBoolean, .arrayNumber, .arrayObject, .arrayFile: return Segment(type, value)
            default: throw DraftVariableError.typeMismatch("Type mismatch: expected \(type.rawValue), but got empty list")
            }
        }
        let inferred = Segment.build(value).valueType
        if inferred == type { return Segment(type, value) }
        if type == .number, inferred == .integer || inferred == .float { return Segment(inferred, value) }
        throw DraftVariableError.typeMismatch(
            "Type mismatch: expected \(type.rawValue), but got \(inferred.rawValue), value=\(PythonText.str(value))")
    }

    /// `load_into_variable_pool`'s selection: the selectors of a node's variable mapping that neither `userInputs` (keyed
    /// `node.#x.y#` or `#x.y#`) nor the pool provide; the caller loads them from the draft variables.
    public static func selectorsToLoad(mapping: [(key: String, selector: [String])], userInputs: JSONObject,
                                       pool: VariablePool) throws -> [[String]] {
        var out: [[String]] = []
        for (key, selector) in mapping {
            let parts = key.split(separator: ".", omittingEmptySubsequences: false)
            if parts.count < VariablePool.selectorsLength {
                throw DraftVariableError.invalid("Invalid variable key: \(key). It should have at least two elements.")
            }
            if userInputs[key] != nil { continue }
            if userInputs[parts.dropFirst().joined(separator: ".")] != nil { continue }
            if pool.get(selector) == nil { out.append(selector) }
        }
        return out
    }
}

public enum DraftVariableError: Error, CustomStringConvertible, Sendable {
    case invalid(String)
    case typeMismatch(String)

    public var description: String {
        switch self {
        case .invalid(let m), .typeMismatch(let m): return m
        }
    }
}
