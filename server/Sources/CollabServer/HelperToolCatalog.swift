import CollabRuntime
import Foundation

extension Routes {
    /// Public tool schemas only, never credentials. The same installed/frozen definitions as the Tool panel.
    func generatorToolCatalog(appId: String?) async throws -> [JSONValue] {
        var values:[JSONValue] = []
        for page in 1...4 {
            let rows=try await toolDaemon().management("tools",query:[.init(name:"page",value:String(page)),.init(name:"page_size",value:"128")]).array ?? []
            for row in rows {
                guard let plugin=row["plugin_id"]?.string, let declaration=row["declaration"],let name=declaration["identity"]?["name"]?.string else { continue }
                for tool in declaration["tools"]?.array ?? [] {
                    let action=Self.toolProjection(tool)
                    guard let name=action["name"]?.string else { continue }
                    values.append(["provider_type":"builtin","provider_id":.string(plugin+"/"+(declaration["identity"]?["name"]?.string ?? "")),
                        "tool_name":.string(name),"description":action["description"] ?? .null,"parameters":action["parameters"] ?? []])
                }
                _ = name
            }
            if rows.count < 128 { break }
            if page == 4 { throw NodeError("GeneratorInputError","The installed tool catalog is too large for generation") }
        }
        for tool in try await store.workflowTools() where tool.appId != appId {
            let projection=try workflowToolProjection(tool)
            for action in projection["tools"]?.array ?? [] {
                values.append(["provider_type":"workflow","provider_id":.string(tool.id),"tool_name":.string(tool.name),
                    "description":action["description"] ?? .null,"parameters":action["parameters"] ?? []])
            }
        }
        guard JSONValue.array(values).compactJSON().utf8.count <= 128 << 10 else { throw NodeError("GeneratorInputError","The tool schemas exceed the generator context limit") }
        return values
    }
}
