// Dify 1.17.1 ask_human_hitl.py: reuse the native form vocabulary, storage and delivery path.
import CollabRuntime
import CollabStore
import Foundation

struct AgentQuestion: Sendable {
    let config: HumanInputFormConfig
    let defaults: JSONObject
    let actionIDs: [String: String]
    let question: JSONObject

    init(_ question: JSONObject, title: String, contacts: [JSONObject]) throws {
        guard let text = question["question"]?.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= 256 << 10 else { throw NodeError("ask_human_invalid", "The agent question is invalid") }
        self.question = question
        var content: [String] = []
        if let heading = question["title"]?.string, !heading.isEmpty { content.append("## " + heading) }
        content.append(text)
        if let markdown = question["markdown"]?.string, !markdown.isEmpty { content.append(markdown) }
        let fields = question["fields"]?.array ?? []
        guard fields.count <= 8 else { throw NodeError("ask_human_invalid", "Too many question fields") }
        var inputs: [JSONValue] = []
        var defaults: JSONObject = [:]
        for field in fields {
            guard let name = field["name"]?.string, let label = field["label"]?.string,
                  name.range(of: #"^[A-Za-z_][A-Za-z0-9_]{0,29}$"#, options: .regularExpression) != nil else {
                throw NodeError("ask_human_invalid", "Invalid question field")
            }
            content.append("**" + label + (field["required"] == true ? " *" : "") + "**\n\n{{#$output." + name + "#}}")
            var input: JSONObject = ["output_variable_name": .string(name)]
            switch field["type"]?.string ?? "paragraph" {
            case "paragraph":
                input["type"] = "paragraph"
                if let value = field["default"], value != .null {
                    input["default"] = ["type": "constant", "value": value]; defaults[name] = value
                }
            case "select":
                let options = field["options"]?.array ?? []
                guard !options.isEmpty, options.allSatisfy({ $0["value"]?.string != nil }) else { throw NodeError("ask_human_invalid", "Invalid question options") }
                input["type"] = "select"
                input["option_source"] = ["type": "constant", "value": .array(options.map { $0["value"]! })]
                input["option_labels"] = .object(JSONObject(options.map { ($0["value"]!.string!, $0["label"] ?? $0["value"]!) }))
                if let value = field["default"], value != .null { defaults[name] = value }
            default: throw NodeError("ask_human_invalid", "Agent file question fields are not supported")
            }
            inputs.append(.object(input))
        }
        var actions: [JSONValue] = []
        var mapping: [String: String] = [:]
        for action in question["actions"]?.array ?? [] {
            guard let id = action["id"]?.string, let label = action["label"]?.string,
                  id.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw NodeError("ask_human_invalid", "Invalid question action") }
            // This extension uses the server's existing SHA-256 utility rather than adding a new crypto implementation.
            // The original long ID is restored on resume; ordinary (<=20 character) IDs are unchanged.
            let short = id.count <= 20 ? id : String(id.prefix(13)) + "_" + String(Tokens.sha256(id).prefix(6))
            guard mapping[short] == nil else { throw NodeError("ask_human_invalid", "Duplicate question action") }
            mapping[short] = id
            let style = action["style"]?.string ?? "default"
            actions.append(["id": .string(short), "title": .string(label), "button_style": .string(style == "destructive" ? "accent" : style)])
        }
        if actions.isEmpty { actions = [["id": "submit", "title": "Submit", "button_style": "primary"]]; mapping["submit"] = "submit" }
        guard actions.count <= 4 else { throw NodeError("ask_human_invalid", "Too many question actions") }
        var delivery: [JSONValue] = [["type": "webapp", "enabled": true]]
        let emails = Set(contacts.compactMap { $0["email"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }).sorted()
        if !emails.isEmpty {
            var subject = String((question["title"]?.string ?? text).trimmingCharacters(in: .whitespacesAndNewlines).prefix(120))
            if question["urgency"] == "high" { subject = "[Action needed] " + subject }
            delivery.append(["type": "email", "enabled": true, "config": ["subject": .string(subject), "body": .string(text + "\n\nOpen the request: {{#url#}}"),
                "recipients": ["items": .array(emails.map { ["type": "external", "email": .string($0)] })]]])
        }
        config = try HumanInputFormConfig(["title": .string(title), "form_content": .string(content.joined(separator: "\n\n")),
            "inputs": .array(inputs), "user_actions": .array(actions), "delivery_methods": .array(delivery), "timeout": 36, "timeout_unit": "hour"])
        self.defaults = defaults; actionIDs = mapping
    }

    func answer(_ form: StoredHumanInputForm, files: (any RuntimeFiles)?) async throws -> JSONValue {
        switch form.status {
        case .timedOut: return ["status": "timeout"]
        case .expired: throw NodeError("HumanInputExpired", "The agent question expired with its workflow")
        case .waiting: throw NodeError("AgentQuestionPending", "The agent question has not been answered")
        case .submitted:
            let values = try await config.normalizedFiles(try JSONValue.parse(form.submittedInputs ?? "{}").object ?? [:], using: files)
            let completion = try config.completion(action: form.submittedAction ?? "", values: values, renderedContent: form.renderedContent)
            let submitted = form.submittedAction ?? ""
            return ["status": "submitted", "action": ["id": .string(actionIDs[submitted] ?? submitted),
                "label": completion.outputs[HumanInputFormConfig.actionValueField] ?? ""], "values": .object(values),
                "rendered_content": completion.outputs[HumanInputFormConfig.renderedContentField] ?? .string(form.renderedContent)]
        }
    }
}
