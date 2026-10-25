import CollabRuntime
import CollabStore
import Foundation
import Logging
import ServiceLifecycle

/// Network retries never sit in the database-heartbeat loop. Browser/SSE lifetimes have no ownership role.
struct AgentMaintenance: Service {
    let routes: Routes
    var readiness: DatabaseReadiness? = nil

    func run() async throws {
        guard routes.config.agentService.isConfigured else { return }
        try await withGracefulShutdownHandler {
            if let readiness {
                do { try await cancelWhenGracefulShutdown { try await readiness.wait() } } catch { return }
            }
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await loop(seconds: 3) { await routes.renewAgentOwnership() } }
                group.addTask { await loop(seconds: 20) { await routes.renewAgentRemoteLeases() } }
                group.addTask { await loop(seconds: 2) { await routes.deliverAgentOutbox() } }
                group.addTask { await loop(seconds: 5) { await routes.recoverAgentExecutions() } }
                await group.waitForAll()
            }
        } onGracefulShutdown: {}
    }

    private func loop(seconds: Int, work: @Sendable () async -> Void) async {
        while !Task.isCancelled {
            await work()
            do { try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(seconds)) } } catch { break }
        }
    }
}

extension Routes {
    func requireDurableAgentScope(_ scope: AgentModelScope) async throws {
        guard let owner = scope.durableOwner else { throw ServerError.forbidden(code: "agent_run_forbidden", message: "The agent execution is not durable") }
        guard let current = try await store.agentSession(execution: scope.executionID), current.ownerID == owner,
              current.generation == scope.generation, current.operationID == scope.operationID, current.status == "running",
              try await store.renewAgentSession(execution: current.executionID, owner: owner, generation: current.generation),
              let run = try await store.workflowRun(doc: scope.appID, id: scope.workflowRunID), run.status == "running", run.type == "workflow" else {
            throw ServerError.forbidden(code: "agent_run_inactive", message: "The agent execution is no longer active")
        }
        _ = try await liveApp(scope.appID, viewer: scope.userID)
    }

    func renewAgentOwnership() async {
        guard let sessions = try? await store.ownedAgentSessions(owner: agentOwner) else { return }
        for session in sessions {
            if (try? await store.renewAgentSession(execution: session.executionID, owner: agentOwner, generation: session.generation)) != true {
                await agentModelScopes.revokeExecution(session.executionID, generation: session.generation)
            }
        }
    }

    func renewAgentRemoteLeases() async {
        guard let sessions = try? await store.ownedAgentSessions(owner: agentOwner) else { return }
        let service = AgentServiceClient(config: config.agentService, logger: logger)
        await withTaskGroup(of: Void.self) { group in
            for session in sessions {
                group.addTask {
                    do { try await service.lease(execution: session.executionID, generation: session.generation) }
                    catch { logger.warning("agent remote lease will retry") }
                }
            }
        }
    }

    func deliverAgentOutbox() async {
        guard let jobs = try? await store.pendingAgentJobs() else { return }
        let service = AgentServiceClient(config: config.agentService, logger: logger)
        // Sequential ACKs preserve each execution's committed result order. Cleanup was excluded while any ACK is pending.
        for job in jobs {
            if Task.isCancelled { return }
            do {
                switch job.kind {
                case "ack":
                    guard let run = job.agentRunID, let event = job.resultEventID else { continue }
                    try await service.acknowledge(run: run, generation: job.generation, event: event)
                case "cancel":
                    if let run = job.agentRunID { try await service.cancel(run: run, generation: job.generation) }
                case "cleanup": try await service.cleanup(execution: job.executionID, generation: job.generation)
                default: continue
                }
                try await store.finishAgentJob(id: job.id, succeeded: true)
            } catch {
                try? await store.finishAgentJob(id: job.id, succeeded: false, delaySeconds: min(300, 2 << min(job.attempts, 7)))
                logger.warning("agent confirmation or cleanup will retry")
            }
        }
    }

    func recoverAgentExecutions() async {
        do {
            // Recover a remote accepted run that crashed before its ID reached the local operation ledger.
            // Unknown remote executions can belong to another database, so this only fills an exact expired local match.
            do {
                for remote in try await AgentServiceClient(config: config.agentService).activeRuns() {
                    guard let execution = remote["execution_id"]?.string, let operation = remote["operation_id"]?.string,
                          case .int(let generation)? = remote["generation"], let id = remote["run_id"]?.string else { continue }
                    try await store.reconcileExpiredAgentRun(execution: execution, operation: operation, generation: generation, run: id)
                }
            } catch { logger.warning("agent service reconciliation will retry; local recovery continues") }
            // Adoption is independent from answering the question. Otherwise a restarted server would let the
            // remote workspace expire while waiting for the user, despite having a durable resumable pause.
            for session in try await store.expiredPausedAgents() {
                _ = try? await store.adoptPausedAgent(execution: session.executionID, owner: agentOwner)
            }
            for session in try await store.expiredActiveAgents() {
                if try await store.failExpiredAgent(session) {
                    await agentModelScopes.revokeExecution(session.executionID, generation: session.generation)
                    await finishRunWithoutEngine(session.workflowRunID)
                }
            }
            for run in try await store.terminalRunsWithActiveAgents() {
                try await store.cancelAgentsInTerminalRun(run: run)
            }
        } catch { logger.warning("agent execution recovery will retry") }
    }
}
