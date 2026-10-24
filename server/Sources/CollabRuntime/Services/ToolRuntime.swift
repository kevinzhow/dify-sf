// Dify 1.17.1 api/core/tools/plugin_tool/tool.py and graphon 0.7.0 nodes/tool.
// The server owns credentials, authorization, plugin dispatch and workflow recursion.
import Foundation

public struct ToolReference: Sendable {
    public var providerID: String
    public var providerType: String
    public var name: String
    public var credentialID: String?
    public var configurations: JSONObject
    public init(providerID: String, providerType: String, name: String, credentialID: String? = nil, configurations: JSONObject = [:]) {
        self.providerID = providerID; self.providerType = providerType; self.name = name
        self.credentialID = credentialID; self.configurations = configurations
    }
}

public enum ToolRuntimeEvent: Sendable {
    case message(JSONValue)
    case usage(LLMUsage)
    case metadata(JSONObject)
}

public protocol ToolRuntime: Sendable {
    /// Includes dynamically supplied parameters; never includes credential values.
    func parameters(_ tool: ToolReference, context: NodeRunContext) async throws -> [JSONValue]
    /// Dify ToolInvokeMessage values. Cancellation must terminate the underlying invocation.
    func invoke(_ tool: ToolReference, parameters: JSONObject, context: NodeRunContext) -> AsyncThrowingStream<ToolRuntimeEvent, any Error>
}
