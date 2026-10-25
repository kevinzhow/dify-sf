// Dify Agent task markers and run-specific context. File identities survive pauses; signed URLs never enter snapshots.
import Foundation

public struct AgentPrompt: Sendable {
    public var system: String
    public var task: [JSONValue]
    public var files: [JSONValue]
    public var inputFileIDs: Set<String>
}

public enum AgentPromptBuilder {
    public static func build(node: AgentNodeData, config: AgentInlineConfig, pool: VariablePool,
                             files: (any RuntimeFiles)?, nodeJob: JSONObject = [:]) async throws -> AgentPrompt {
        var task: [JSONValue] = []
        var mounts: [JSONValue] = []
        var ids = Set<String>()
        var context: [String] = []
        var modelFileBytes = 0
        if let query = pool.get(["sys", "query"])?.text, !query.isEmpty { context.append("- User query: " + query) }
        var references: [JSONValue] = []
        if let files = pool.get(["sys", "files"])?.value.array, !files.isEmpty {
            references.append(contentsOf: files)
            context.append("- Uploaded workflow files: " + summarize(.array(files)))
        }
        var selectors = AgentNodeData.selectors(node.task)
        for reference in nodeJob["previous_node_output_refs"]?.array ?? [] {
            let selector = (reference["selector"] ?? reference["variable_selector"] ?? reference["value_selector"])?.array?.compactMap(\.string)
                ?? [reference["node_id"]?.string ?? "", reference["output"]?.string ?? ""]
            guard selector.count >= 2, selector.allSatisfy({ !$0.isEmpty }), !["env", "conversation", "rag"].contains(selector[0]) else {
                throw NodeError("AgentInputInvalid", "Invalid previous-node output reference")
            }
            if !selectors.contains(selector) { selectors.append(selector) }
        }
        for reference in nodeJob["metadata"]?["file_refs"]?.array ?? [] {
            if RuntimeFile.isFile(reference) { references.append(reference); continue }
            guard let id = RuntimeFile.recordId(in: reference) ?? reference["file_id"]?.string ?? reference["id"]?.string,
                  UUID(uuidString: id) != nil else { throw NodeError("AgentFileUnavailable", "Invalid agent task file reference") }
            references.append(["transfer_method": "local_file", "upload_file_id": .string(id)])
        }
        guard references.count <= 128 && selectors.count <= 128 else { throw NodeError("AgentInputTooLarge", "Too many agent inputs") }
        for selector in selectors {
            guard let segment = pool.get(selector) else {
                throw NodeError("MissingPreviousNodeOutput", "Cannot resolve agent input " + selector.joined(separator: "."))
            }
            context.append("  - " + selector.joined(separator: ".") + ": " + summarize(segment.value))
            collectFiles(segment.value, into: &references)
        }
        guard references.count <= 128 else { throw NodeError("AgentInputTooLarge", "Too many agent files") }
        for reference in references {
            guard let files else { throw NodeError("AgentFileUnavailable", "File storage is required for this agent input") }
            let file = try await files.resolve(reference, config: nil)
            if ids.insert(file.recordId).inserted {
                mounts.append(["file_id": .string(file.recordId), "path": .string("inputs/" + file.recordId)])
                if file.mimeType.hasPrefix("image/") {
                    modelFileBytes += file.size
                    task.append(["type": "file", "file_id": .string(file.recordId), "mime_type": .string(file.mimeType)])
                }
            }
        }
        for definition in config.files {
            guard let id = definition["file_id"]?.string, let name = definition["name"]?.string, let files else {
                throw NodeError("AgentFileUnavailable", "An agent config file is unavailable")
            }
            let file = try await files.resolve(["transfer_method": "local_file", "upload_file_id": .string(id)], config: nil)
            if ids.insert(file.recordId).inserted, file.mimeType.hasPrefix("image/") {
                modelFileBytes += file.size
                task.append(["type": "file", "file_id": .string(file.recordId), "mime_type": .string(file.mimeType)])
            }
            mounts.append(["file_id": .string(file.recordId), "path": .string("files/" + name)])
        }
        var text = expand(node.task, outputs: node.declarations, config: config)
        if !context.isEmpty {
            text += "\n\nWorkflow context loaded for this run:\n" + context.joined(separator: "\n")
            text += "\nThe above workflow context is run-specific. Do not treat it as Agent Soul or persistent memory."
        }
        let system = expand(config.systemPrompt, outputs: [], config: config)
        // History re-sends these images. Reserve room for tools and later text before spending the first model call.
        guard modelFileBytes <= 6 << 20, 4 * ((modelFileBytes + 2) / 3) + text.utf8.count + system.utf8.count <= 7 << 20 else {
            throw NodeError("AgentFileBudgetExceeded", "Agent input files exceed the model conversation budget")
        }
        guard text.utf8.count <= 2 << 20 else { throw NodeError("AgentInputTooLarge", "The agent task context is too large") }
        task.insert(["type": "text", "text": .string(text)], at: 0)
        return AgentPrompt(system: system, task: task, files: mounts, inputFileIDs: ids)
    }

    private static func collectFiles(_ value: JSONValue, into files: inout [JSONValue]) {
        if RuntimeFile.isFile(value) { files.append(value); return }
        if let values = value.array { for item in values { collectFiles(item, into: &files) } }
        if let object = value.object { for (_, item) in object { collectFiles(item, into: &files) } }
    }

    private static func summarize(_ value: JSONValue) -> String {
        // Avoid putting stale signed URLs into the agent's persisted conversation.
        if RuntimeFile.isFile(value) {
            return "file_id=" + (RuntimeFile.recordId(in: value) ?? "unavailable")
        }
        if let values = value.array { return "[" + values.map(summarize).joined(separator: ", ") + "]" }
        if let object = value.object {
            return "{" + object.map { $0.key + ": " + summarize($0.value) }.joined(separator: ", ") + "}"
        }
        return value.string ?? value.pythonJSONDumps()
    }

    /// Dify's prompt_mentions: supported references expand, unresolved mentions degrade to their label/id.
    static func expand(_ prompt: String, outputs: [AgentDeclaredOutput], config: AgentInlineConfig) -> String {
        let regex = try! NSRegularExpression(pattern: #"\[§([^:§]+):([^:§]*)(?::([^§]*))?§\]|§(output):([^:§]+)(?::([^§]*))?§"#)
        var text = prompt
        for match in regex.matches(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)).reversed() {
            let offset = match.range(at: 1).location == NSNotFound ? 3 : 0
            guard let range = Range(match.range, in: text), let k = Range(match.range(at: 1 + offset), in: text),
                  let r = Range(match.range(at: 2 + offset), in: text) else { continue }
            var kind = String(text[k]), id = String(text[r])
            var label = Range(match.range(at: 3 + offset), in: text).map { String(text[$0]) } ?? ""
            // The frontend also writes [§name:label:output§].
            if label == "output" { kind = "output"; label = id; id = String(text[k]) }
            var replacement = label.isEmpty ? id : label
            if kind == "output" {
                if id == "text" { replacement = "text (string)" }
                else if let field = outputs.first(where: { $0.name == id }) { replacement = id + " (" + field.kind.rawValue + ")" }
            } else if kind == "file", let file = config.files.first(where: { $0["file_id"] == .string(id) || $0["name"] == .string(id) }), let name = file["name"]?.string {
                replacement = "files/" + name
            } else if kind == "human", let contact = config.contacts.first(where: {
                $0["id"] == .string(id) || $0["contact_id"] == .string(id) || $0["human_id"] == .string(id)
            }) {
                replacement = contact["name"]?.string ?? contact["email"]?.string ?? replacement
                if let channel = contact["channel"]?.string ?? contact["method"]?.string ?? contact["contact_method"]?.string, !channel.isEmpty {
                    replacement = channel.uppercased() + " · " + replacement
                }
            }
            text.replaceSubrange(range, with: String(replacement.prefix(255)))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
