// Ported from graphon 0.7.0 nodes/tool/tool_node.py and entities.py (Apache-2.0).
// File materialization uses the existing scoped file service. See ../../NOTICE.md.
import Foundation

public struct ToolNode: RuntimeNode {
    public let id: String
    public let base: BaseNodeData
    public let reference: ToolReference
    let bindings: JSONObject
    let runtime: any ToolRuntime
    let files: (any RuntimeFiles)?
    public var nodeType: String { NodeType.tool }
    public var retryEnabled: Bool { base.retryConfig.retryEnabled }

    public init(id: String, data: JSONObject, runtime: any ToolRuntime, files: (any RuntimeFiles)? = nil) throws {
        self.id = id; base = try BaseNodeData(data)
        guard let provider = data["provider_id"]?.string, !provider.isEmpty,
              let name = data["tool_name"]?.string, !name.isEmpty else { throw NodeDataError("provider_id and tool_name are required") }
        reference = ToolReference(providerID: provider, providerType: data["provider_type"]?.string ?? "builtin", name: name,
                                  credentialID: data["credential_id"]?.string, configurations: data["tool_configurations"]?.object ?? [:])
        bindings = data["tool_parameters"]?.object ?? [:]
        self.runtime = runtime; self.files = files
    }

    func parameters(_ declarations: [JSONValue], pool: VariablePool, forLog: Bool) throws -> JSONObject {
        var result = JSONObject()
        for (key, binding) in bindings where binding != .null {
            guard let declaration = declarations.first(where: { $0["name"]?.string == key }) else { result[key] = .null; continue }
            switch binding["type"]?.string {
            case "variable":
                guard let values = binding["value"]?.array, values.allSatisfy({ $0.string != nil }) else {
                    throw NodeError("ToolParameterError", "Variable tool input value must be a list of strings.")
                }
                let selector = values.compactMap(\.string)
                guard let segment = pool.get(selector) else {
                    if declaration["required"] == true { throw NodeError("ToolParameterError", "Variable \(selector) does not exist") }
                    continue
                }
                result[key] = forLog && segment.valueType == .secret ? .string("[hidden]") : segment.object
            case "constant", "mixed":
                let group = VariableTemplate.convert(pool, PythonText.str(binding["value"] ?? .null))
                result[key] = .string(forLog ? group.value.map { $0.valueType == .secret ? "[hidden]" : $0.log }.joined() : group.text)
            default: throw NodeError("ToolParameterError", "Unknown tool input type '\(binding["type"]?.string ?? "")'")
            }
        }
        return result
    }

    public func run(_ context: NodeRunContext, emit: @Sendable (NodeEvent) async -> Void) async throws {
        var logged = JSONObject()
        var usage = LLMUsage.empty
        var extraMetadata = JSONObject()
        do {
            var reference = self.reference
            var configurations = JSONObject()
            for (name, value) in reference.configurations {
                switch value["type"]?.string {
                case "variable":
                    guard let values = value["value"]?.array, values.allSatisfy({ $0.string != nil }),
                          let segment = context.pool.get(values.compactMap(\.string)) else { throw NodeError("ToolParameterError", "Tool configuration variable does not exist") }
                    configurations[name] = segment.object
                case "mixed": configurations[name] = .string(VariableTemplate.convert(context.pool, value["value"]?.string ?? "").text)
                case "constant": configurations[name] = value["value"] ?? .null
                default: configurations[name] = value
                }
            }
            reference.configurations = configurations
            let declarations = try await runtime.parameters(reference, context: context)
            let parameters = try parameters(declarations, pool: context.pool, forLog: false)
            logged = try self.parameters(declarations, pool: context.pool, forLog: true)
            var text = "", json: [JSONValue] = [], attachments: [JSONValue] = [], variables = JSONObject()
            var streamed = Set<String>()
            var jsonBytes = 0
            struct Blob { var bytes = Data(); var total: Int; var next = 0; var meta: JSONObject }
            var blobs: [String: Blob] = [:]
            var totalBytes = 0
            func save(_ bytes: Data, _ meta: JSONObject) async throws -> JSONValue {
                guard let files else { throw RuntimeFileError("Tool file storage is not configured") }
                return try await files.save(bytes: Array(bytes), filename: meta["filename"]?.string ?? "tool-output",
                                            mimeType: meta["mime_type"]?.string ?? meta["mimetype"]?.string ?? "application/octet-stream", sourceURL: nil).json
            }
            for try await event in runtime.invoke(reference, parameters: parameters, context: context) {
                switch event {
                case .usage(let value): usage = usage.plus(value); continue
                case .metadata(let value): for (key, item) in value { extraMetadata[key] = item }; continue
                case .message: break
                }
                guard case .message(let message) = event else { continue }
                if context.isAborted() || Task.isCancelled { throw CancellationError() }
                let payload = message["message"] ?? .null, meta = message["meta"]?.object ?? [:]
                switch message["type"]?.string {
                case "text", "link":
                    guard var chunk = payload["text"]?.string else { throw NodeError("ToolNodeError", "Tool text message is malformed") }
                    if message["type"] == "link" { chunk = "Link: " + chunk + "\n" }
                    text += chunk; await emit(.streamChunk(selector: [id, "text"], chunk: chunk, isFinal: false))
                case "json":
                    if payload["suppress_output"] != true, let value = payload["json_object"], value != .null,
                       value != .object([:]), value != .array([]) {
                        jsonBytes += value.compactJSON().utf8.count
                        guard jsonBytes <= 16 * 1024 * 1024 else { throw NodeError("ToolNodeError", "Tool JSON output exceeds limits") }
                        json.append(value)
                    }
                case "variable":
                    guard let name = payload["variable_name"]?.string, !["text", "files", "json"].contains(name),
                          let value = payload["variable_value"] else { throw NodeError("ToolNodeError", "Invalid or reserved tool output variable") }
                    if payload["stream"] == true {
                        guard let chunk = value.string else { throw NodeError("ToolNodeError", "Streamed tool variable must be a string") }
                        variables[name] = .string((variables[name]?.string ?? "") + chunk); streamed.insert(name)
                        await emit(.streamChunk(selector: [id, name], chunk: chunk, isFinal: false))
                    } else { variables[name] = value }
                case "blob", "blob_chunk":
                    guard let encoded = payload["blob"]?.string, encoded.utf8.count <= 24 * 1024 * 1024,
                          let bytes = Data(base64Encoded: encoded) else { throw NodeError("ToolFileError", "Invalid tool blob") }
                    totalBytes += bytes.count
                    guard totalBytes <= 100 * 1024 * 1024 else { throw NodeError("ToolFileError", "Tool files exceed 100 MiB") }
                    if message["type"] == "blob" { attachments.append(try await save(bytes, meta)); break }
                    guard let key = payload["id"]?.string, let total = payload["total_length"]?.int,
                          (0...100 * 1024 * 1024).contains(total), let sequence = payload["sequence"]?.int else {
                        throw NodeError("ToolFileError", "Invalid tool blob chunk")
                    }
                    var blob = blobs[key] ?? Blob(total: total, meta: meta)
                    guard blob.total == total, blob.next == sequence, blob.bytes.count + bytes.count <= total else {
                        throw NodeError("ToolFileError", "Inconsistent tool blob chunks")
                    }
                    blob.bytes.append(bytes); blob.next += 1
                    if payload["end"] == true {
                        guard blob.bytes.count == total else { throw NodeError("ToolFileError", "Incomplete tool blob") }
                        attachments.append(try await save(blob.bytes, blob.meta)); blobs.removeValue(forKey: key)
                    } else { blobs[key] = blob }
                case "image", "image_link", "binary_link":
                    guard let files, let url = payload["text"]?.string else { throw RuntimeFileError("Invalid linked tool file") }
                    attachments.append(try await files.resolve(["transfer_method": "remote_url", "type": message["type"] == "binary_link" ? "custom" : "image", "url": .string(url)], config: nil).json)
                case "file":
                    guard let files, let file = meta["file"] else { throw RuntimeFileError("Invalid tool file reference") }
                    attachments.append(try await files.resolve(file, config: nil).json)
                case "log": break
                default: break // Upstream ignores unknown future message types.
                }
                guard blobs.count <= 100, attachments.count <= 100, text.utf8.count <= 16 * 1024 * 1024,
                      JSONValue.object(variables).compactJSON().utf8.count <= 16 * 1024 * 1024 else { throw NodeError("ToolNodeError", "Tool output exceeds limits") }
            }
            guard blobs.isEmpty else { throw NodeError("ToolFileError", "Incomplete tool blob stream") }
            await emit(.streamChunk(selector: [id, "text"], chunk: "", isFinal: true))
            for name in streamed.sorted() { await emit(.streamChunk(selector: [id, name], chunk: "", isFinal: true)) }
            var output = variables
            output["text"] = .string(text); output["files"] = .array(attachments)
            output["json"] = .array(json.isEmpty ? [["data": []]] : json)
            var result = NodeRunResult(status: .succeeded, inputs: logged, outputs: output,
                metadata: extraMetadata, llmUsage: usage)
            result.metadata["tool_info"] = ["provider_type": .string(reference.providerType), "provider_id": .string(reference.providerID)]
            result.outputTypes = ["files": .arrayFile, "json": .arrayObject]
            await emit(.completed(result))
        } catch {
            let type = (error as? any NodeRunError)?.errorTypeName ?? "ToolNodeError"
            await emit(.completed(NodeRunResult(status: .failed, inputs: logged, metadata: extraMetadata, llmUsage: usage, error: "\(error)", errorType: type)))
        }
    }

    public func variableMapping(graph: GraphConfig) -> [(key: String, selector: [String])] {
        var result: [(String, [String])] = []
        for (key, binding) in bindings {
            if binding["type"] == "variable", let selector = binding["value"]?.array {
                result.append((id + "." + key, selector.compactMap(\.string)))
            } else if let template = binding["value"]?.string {
                result += VariableTemplate.extractSelectors(template).map { (id + "." + key + "." + $0.variable, $0.valueSelector) }
            }
        }
        return result
    }
}
