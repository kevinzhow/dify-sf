// Ported from Dify 1.17.1 (https://github.com/langgenius/dify):
// api/core/workflow/nodes/human_input/{entities,callback,constants}.py and
// api/services/human_input_service.py (text/select submission normalization). See ../../NOTICE.md.

import Foundation

/// Dify's form configuration, kept separately from the engine's HITL decision. File values are materialized by the
/// scoped service before submission is persisted, and revalidated by that service when the run resumes.
public struct HumanInputFormConfig: Sendable {
    public let base: BaseNodeData
    public let content: String
    public let inputs: [JSONObject]
    public let actions: [JSONObject]
    public let timeout: Int
    public let timeoutUnit: String
    /// Dify's `FormDefinition.display_in_ui`: whether the form is shown in a UI surface at all (the node sets it; the
    /// delivery policy turns it into tokens), kept as the config wrote it — never inferred from rendered defaults.
    public let displayInUi: Bool?
    /// `delivery_methods` as the node wrote them (`[{type: webapp|email, enabled, config}]`): the published-run display rule
    /// reads whether a **webapp** delivery is enabled (`human_input_adapter.is_human_input_webapp_enabled`).
    public let deliveryMethods: [JSONObject]

    /// `is_human_input_webapp_enabled`: any delivery method that is enabled and is the web app.
    public var webappDeliveryEnabled: Bool {
        deliveryMethods.contains { method in
            method["type"]?.string == "webapp" && (method["enabled"]?.bool ?? false)
        }
    }

    public static let timeoutHandle = "__timeout"
    public static let actionIdField = "__action_id"
    public static let actionValueField = "__action_value"
    public static let renderedContentField = "__rendered_content"

    public init(_ data: JSONObject) throws {
        base = try BaseNodeData(data)
        content = try Self.string(data, "form_content", fallback: "")
        displayInUi = data["display_in_ui"]?.bool
        deliveryMethods = (data["delivery_methods"]?.array ?? []).compactMap(\.object)
        timeout = data["timeout"]?.int ?? 36
        timeoutUnit = try Self.string(data, "timeout_unit", fallback: "hour")
        guard ["hour", "day"].contains(timeoutUnit) else { throw NodeDataError("timeout_unit: expected hour or day") }
        inputs = try Self.objects(data, "inputs")
        actions = try Self.objects(data, "user_actions")
        var names = Set<String>(), ids = Set<String>()
        for input in inputs {
            let name = try Self.string(input, "output_variable_name")
            guard names.insert(name).inserted else { throw NodeDataError("duplicated output_variable_name '\(name)' in inputs") }
            switch try Self.string(input, "type", fallback: "paragraph") {
            case "paragraph":
                if let value = input["default"], value != .null {
                    guard let source = value.object else { throw NodeDataError("default: expected an object") }
                    try Self.validateSource(source, list: false)
                }
            case "select":
                guard let source = input["option_source"]?.object else { throw NodeDataError("option_source: Field required") }
                try Self.validateSource(source, list: true)
            case "file", "file-list": break
            default: throw NodeDataError("inputs.type: expected paragraph, select, file or file-list")
            }
        }
        for action in actions {
            let id = try Self.string(action, "id"), title = try Self.string(action, "title")
            guard id.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,19}$"#, options: .regularExpression) != nil else {
                throw NodeDataError("user_actions.id: expected an identifier of at most 20 characters")
            }
            guard ids.insert(id).inserted else { throw NodeDataError("duplicated user action id '\(id)'") }
            guard title.unicodeScalars.count <= 100 else { throw NodeDataError("user_actions.title: at most 100 characters") }
            let style = try Self.string(action, "button_style", fallback: "default")
            guard ["primary", "default", "accent", "ghost"].contains(style) else { throw NodeDataError("button_style: invalid value") }
        }
    }

    public var requiresFileStorage: Bool { inputs.contains { ["file", "file-list"].contains($0["type"]?.string ?? "paragraph") } }

    public func expirationTime(from start: Date) -> Date {
        start.addingTimeInterval(Double(timeout) * (timeoutUnit == "day" ? 86400 : 3600))
    }

    /// `resolve_variable_select_input_options` (Dify's `human_input_policy`): a select whose options come from a variable
    /// gets the pool's list as its `option_source.value` (the source stays `variable`, its selector included), because a
    /// client can only draw options it was given. A source the pool cannot answer is left as written.
    public func inputsResolved(pool: VariablePool) -> [JSONObject] {
        inputs.map { input in
            guard (input["type"]?.string ?? "paragraph") == "select",
                  var source = input["option_source"]?.object,
                  source["type"]?.string == "variable",
                  let selector = source["selector"]?.array?.compactMap(\.string),
                  let value = pool.get(selector), case .array(let items) = value.value,
                  items.allSatisfy({ $0.string != nil }) else { return input }
            source["value"] = .array(items)
            var resolved = input
            resolved["option_source"] = .object(source)
            return resolved
        }
    }

    /// Before submission only runtime references are replaced; `$output` references stay in the form.
    public func renderedContent(pool: VariablePool) -> String { VariableTemplate.convert(pool, content).markdown }

    /// Constant paragraph defaults stay in the input definition; only variable defaults are resolved here.
    public func resolvedDefaults(pool: VariablePool) -> JSONObject {
        var result = JSONObject()
        for input in inputs where (input["type"]?.string ?? "paragraph") == "paragraph" {
            guard let name = input["output_variable_name"]?.string, let source = input["default"]?.object,
                  source["type"] == "variable", let selector = source["selector"]?.array?.compactMap(\.string),
                  let value = pool.get(selector) else { continue }
            result[name] = value.value
        }
        return result
    }

    public func variableMapping(nodeId: String) -> [(key: String, selector: [String])] {
        var result: [(key: String, selector: [String])] = []
        func add(_ selector: [String]) {
            let key = nodeId + ".#" + selector.joined(separator: ".") + "#"
            if let i = result.firstIndex(where: { $0.key == key }) { result[i].selector = selector }
            else { result.append((key, selector)) }
        }
        // Dify truncates form-content references to two elements, but retains full default/option selectors.
        for ref in VariableTemplate.extractSelectors(content) { add(Array(ref.valueSelector.prefix(2))) }
        for input in inputs {
            let type = input["type"]?.string ?? "paragraph"
            guard ["paragraph", "select"].contains(type) else { continue }
            let source = input[type == "select" ? "option_source" : "default"]
            if source?["type"] == "variable", let selector = source?["selector"]?.array?.compactMap(\.string) {
                add(selector)
            }
        }
        return result
    }

    public struct InvalidSubmission: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    /// Dify checks select values before action/missing fields. Paragraphs accept JSON (including empty/null values),
    /// and unknown fields survive validation but are discarded when restoring configured outputs.
    public func validateSubmission(action: String, values: JSONObject) throws {
        for input in inputs {
            let name = input["output_variable_name"]!.string!
            guard let value = values[name] else { continue }
            switch input["type"]?.string ?? "paragraph" {
            case "select":
                guard let text = value.string else {
                    throw InvalidSubmission(description: "Invalid value for select input '\(name)': expected string")
                }
                let source = input["option_source"]!
                if source["type"] == "constant", !(source["value"]?.array ?? []).contains(.string(text)) {
                    throw InvalidSubmission(description: "Invalid value for select input '\(name)': \(text)")
                }
            case "file":
                guard RuntimeFile.isFile(value) else { throw InvalidSubmission(description: "Invalid file input '\(name)'") }
            case "file-list":
                guard let items = value.array, items.allSatisfy(RuntimeFile.isFile) else {
                    throw InvalidSubmission(description: "Invalid file list input '\(name)'")
                }
            default: break
            }
        }
        guard actions.contains(where: { $0["id"] == .string(action) }) else {
            throw InvalidSubmission(description: "Invalid action: \(action)")
        }
        let missing = inputs.compactMap { $0["output_variable_name"]?.string }.filter { values[$0] == nil }
        guard missing.isEmpty else { throw InvalidSubmission(description: "Missing required inputs: " + missing.joined(separator: ", ")) }
    }

    /// The callback runs on stored, already validated data. Its edge uses the id; `__action_value` uses the title.
    public func completion(action: String, values: JSONObject, renderedContent: String) throws -> NodeRunResult {
        try validateSubmission(action: action, values: values)
        var restored = JSONObject()
        for input in inputs {
            let name = input["output_variable_name"]!.string!
            if let value = values[name] { restored[name] = value }
        }
        var rendered = renderedContent
        let pattern = #"\{\{#\$output\.([a-zA-Z_][a-zA-Z0-9_]{0,29})#\}\}"#
        let regex = try NSRegularExpression(pattern: pattern)
        let fields = regex.matches(in: content, range: NSRange(content.startIndex..., in: content)).compactMap { match in
            Range(match.range(at: 1), in: content).map { String(content[$0]) }
        }
        for name in fields {
            let value = restored[name] ?? .null
            // All text input classes use Python's str; missing values become empty text.
            rendered = rendered.replacingOccurrences(of: "{{#$output." + name + "#}}", with: value == .null ? "" : (RuntimeFile.isFile(value) || Segment.build(value).valueType == .arrayFile ? Segment.build(value).markdown : PythonText.str(value)))
        }
        let title = actions.first { $0["id"] == .string(action) }!["title"]!.string!
        var outputs = restored
        outputs[Self.actionIdField] = .string(action)
        outputs[Self.actionValueField] = .string(title)
        outputs[Self.renderedContentField] = .string(rendered)
        var result = NodeRunResult(status: .succeeded, inputs: restored, outputs: outputs)
        for input in inputs where input["type"] == "file-list" {
            if let name = input["output_variable_name"]?.string { result.outputTypes[name] = .arrayFile }
        }
        result.edgeSourceHandle = action
        return result
    }

    /// Dify service-level normalization: field restrictions are checked before an answer is persisted.
    public func normalizedFiles(_ values: JSONObject, using files: (any RuntimeFiles)?) async throws -> JSONObject {
        var result = values
        for input in inputs {
            guard let name = input["output_variable_name"]?.string, let value = values[name] else { continue }
            let type = input["type"]?.string ?? "paragraph"
            guard type == "file" || type == "file-list" else { continue }
            guard let files else { throw InvalidSubmission(description: "File input '\(name)' requires file storage") }
            if type == "file" { result[name] = try await files.resolve(value, config: input).json }
            else {
                guard let list = value.array else { throw InvalidSubmission(description: "File list input '\(name)' must be a list") }
                result[name] = .array(try await files.resolveList(list, config: input))
            }
        }
        return result
    }

    public func timeoutResult(renderedContent: String) -> NodeRunResult {
        var result = NodeRunResult(status: .succeeded, outputs: [Self.actionIdField: "", Self.actionValueField: "",
                                                              Self.renderedContentField: .string(renderedContent)])
        result.edgeSourceHandle = Self.timeoutHandle
        return result
    }

    private static func string(_ data: JSONObject, _ key: String, fallback: String? = nil) throws -> String {
        if let value = data[key]?.string { return value }
        if data[key] == nil, let fallback { return fallback }
        throw NodeDataError("\(key): expected a string")
    }

    private static func objects(_ data: JSONObject, _ key: String) throws -> [JSONObject] {
        guard let value = data[key] else { return [] }
        guard let items = value.array, items.allSatisfy({ $0.object != nil }) else { throw NodeDataError("\(key): expected a list of objects") }
        return items.compactMap(\.object)
    }

    private static func validateSource(_ source: JSONObject, list: Bool) throws {
        let type = try string(source, "type")
        guard ["variable", "constant"].contains(type) else { throw NodeDataError("source.type: expected variable or constant") }
        if type == "variable" {
            let selector = source["selector"]?.array ?? []
            guard (list || selector.count >= 2), selector.allSatisfy({ $0.string != nil }) else {
                throw NodeDataError("source.selector: expected at least two strings")
            }
        }
        if let value = source["value"] {
            if list {
                guard let items = value.array, items.allSatisfy({ $0.string != nil }) else { throw NodeDataError("source.value: expected strings") }
            } else if value.string == nil { throw NodeDataError("source.value: expected a string") }
        }
    }
}
