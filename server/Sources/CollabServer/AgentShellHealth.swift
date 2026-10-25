import Foundation

/// A short probe is shared by concurrent feature requests; failures are cached too (fail closed).
actor AgentShellHealthCache {
    private var cached: (Bool, Date)?
    private var pending: Task<Bool, Never>?
    func available(_ config: AgentServiceConfig) async -> Bool {
        guard config.shellEnabled else { return false }
        if let (value, until) = cached, Date() < until { return value }
        if let pending { return await pending.value }
        let task = Task { await AgentServiceClient(config: config).shellAvailable() }
        pending = task
        let value = await task.value
        cached = (value, Date().addingTimeInterval(15)); pending = nil
        return value
    }
}
extension Routes {
    func agentShellAvailable() async -> Bool { await agentShellHealth.available(config.agentService) }
}
