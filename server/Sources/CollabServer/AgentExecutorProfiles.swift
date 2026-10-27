import CollabRuntime
import Foundation
import Vapor

/// Deliberately projects only the public catalog fields. Host configuration never reaches a workflow client.
struct AgentExecutorProfile: Sendable {
    var name: String
    var description: String
    var status: String
    var timeoutSecondsMax: Int
    var maxTurnsMax: Int = 50
    var json: JSONValue {
        ["name": .string(name), "description": .string(description), "status": .string(status),
         "timeout_seconds_max": .int(timeoutSecondsMax), "max_turns_max": .int(maxTurnsMax)]
    }

    static func parse(_ value: JSONValue) throws -> [Self] {
        guard let entries = value["profiles"]?.array, !entries.isEmpty, entries.count <= 256 else { throw invalid() }
        var names = Set<String>()
        let profiles = try entries.map { item in
            guard let name = item["name"]?.string, AgentInlineConfig.validExecutorProfile(name), names.insert(name).inserted,
                  let description = item["description"]?.string, description.count <= 200,
                  let status = item["status"]?.string, ["ok", "image_missing", "device_missing", "unavailable"].contains(status),
                  case .int(let timeout)? = item["timeout_seconds_max"], (1...86400).contains(timeout) else { throw invalid() }
            let maxTurns: Int
            if let value = item["max_turns_max"] {
                guard case .int(let count) = value, (1...1000).contains(count) else { throw invalid() }
                maxTurns = count
            } else { maxTurns = 50 }
            return Self(name: name, description: description, status: status, timeoutSecondsMax: timeout, maxTurnsMax: maxTurns)
        }
        guard names.contains("default") else { throw invalid() }
        return profiles
    }

    private static func invalid() -> NodeError { NodeError("AgentServiceProtocolError", "Invalid executor profile catalog") }
}

enum AgentExecutionPolicy {
    static func turns(node: Int, profile: Int?) throws -> Int {
        guard (1...1000).contains(node), node <= (profile ?? 50) else {
            throw NodeError("AgentTurnLimitExceeded", "The requested model-call limit exceeds the executor environment limit")
        }
        return node
    }
    /// The existing node timeout is supplied by the server configuration; profiles can only reduce it.
    static func timeout(node: Int, profile: Int?, server: Int) -> Int {
        max(1, min(node, profile ?? node, server))
    }
}

/// Coalesces probes and caches both success and failure for the same short period as shell health.
actor AgentExecutorProfilesCache {
    private var cached: (profiles: [AgentExecutorProfile]?, until: Date)?
    private var pending: Task<[AgentExecutorProfile]?, Never>?
    func profiles(_ config: AgentServiceConfig) async -> [AgentExecutorProfile]? {
        guard config.isConfigured, config.shellEnabled else { return nil }
        if let cached, Date() < cached.until { return cached.profiles }
        if let pending { return await pending.value }
        let task = Task { () -> [AgentExecutorProfile]? in
            guard let (status, value) = try? await AgentServiceClient(config: config).request(.GET, path: "/v1/profiles", timeoutSeconds: 6),
                  status == 200 else { return nil }
            return try? AgentExecutorProfile.parse(value)
        }
        pending = task
        let profiles = await task.value
        cached = (profiles, Date().addingTimeInterval(15)); pending = nil
        return profiles
    }
}

extension Routes {
    func agentExecutorContext() async -> JSONValue {
        let profiles = await agentExecutorProfiles.profiles(config.agentService)
        return ["shell_enabled": .bool(config.agentService.shellEnabled),
                "profiles": profiles.map { .array($0.map(\.json)) } ?? .null]
    }

    func registerAgentExecutorProfiles(on routes: any RoutesBuilder) {
        routes.get("v1", "apps", ":app", "agent-executor-profiles") { req in
            await handle(req) {
                let principal = try await self.authenticate(req)
                _ = try await self.appOfMode(req, principal, ["workflow"])
                return self.rawJSON(await self.agentExecutorContext())
            }
        }
    }
}
