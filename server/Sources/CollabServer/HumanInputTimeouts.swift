import CollabCore
import CollabStore
import Foundation
import Logging
import ServiceLifecycle

/// Dify's human-input timeout tasks, as a task of this server (protocol 1.16): a periodic **production** scan, not a
/// store method someone has to remember to call.
///
/// * A waiting form past its node's `expiration_time` is ended `timedOut`; that wakes its pause and the run resumes into
///   the node's `__timeout` branch — the same path an answer takes, so the state and the stream cannot disagree.
/// * A run paused past the global deadline (`COLLAB_HUMAN_INPUT_GLOBAL_TIMEOUT_SECONDS`) is stopped with Dify's error,
///   and `Routes.finishRunWithoutEngine` gives the connection that is attached its one terminal frame and closes it.
///
/// The scan runs once at startup (a stopped server leaves work behind) and then every `intervalSeconds`. Each row is
/// rechecked under the run's lock by the store, so a scan that races an answer loses, as in Dify.
struct HumanInputTimeouts: Service {
    let routes: Routes
    let intervalSeconds: Int
    let logger: Logger
    var readiness: DatabaseReadiness? = nil

    /// The same pass runs at every interval, so transient claim failures do not
    /// strand an answer after the bounded startup recovery has finished.
    func runOnce(now: Date) async {
        do {
            let resumed = try await routes.resumeRunsWaitingAfterRestartStrict()
            if resumed > 0 { logger.info("resumed \(resumed) answered run(s)") }
        } catch {
            logger.warning("answered-run recovery will retry on the next pass: \(error)")
        }
        let swept = await routes.sweepHumanInputTimeouts(now: now)
        if swept.timedOut > 0 || swept.expired > 0 {
            logger.info("human input timeout scan: \(swept.timedOut) form(s), \(swept.expired) run(s)")
        }
        let mailed = await routes.deliverPendingHumanInputMail()
        if mailed > 0 { logger.info("human input mail retry: \(mailed) message(s) delivered") }
    }

    func run() async throws {
        try await withGracefulShutdownHandler {
            if let readiness {
                do { try await cancelWhenGracefulShutdown { try await readiness.wait() } }
                catch { return }
            }
            while !Task.isCancelled {
                await runOnce(now: Date())
                do {
                    try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(intervalSeconds)) }
                } catch { break }
            }
        } onGracefulShutdown: {}
    }
}
