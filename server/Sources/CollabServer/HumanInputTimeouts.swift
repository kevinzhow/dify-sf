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

    func run() async throws {
        try await withGracefulShutdownHandler {
            while !Task.isCancelled {
                let now = Date()
                let swept = await routes.sweepHumanInputTimeouts(now: now)
                if swept.timedOut > 0 || swept.expired > 0 {
                    logger.info("human input timeout scan: \(swept.timedOut) form(s) timed out, \(swept.expired) run(s) past the global deadline")
                }
                do {
                    try await cancelWhenGracefulShutdown { try await Task.sleep(for: .seconds(intervalSeconds)) }
                } catch { break }
            }
        } onGracefulShutdown: {}
    }
}
