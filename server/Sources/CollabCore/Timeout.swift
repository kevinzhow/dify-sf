import Foundation

/// Deadline helper shared by the HTTP client and the Postgres store.
public struct TimeoutError: Error, Equatable, Sendable { public init() {} }

/// Runs `body`; throws `TimeoutError` if it does not finish within `duration`. Unlike a task group this
/// does NOT wait for `body` after the timeout: a request stuck in a dead connection must not hold up its caller.
public func withTimeout<T: Sendable>(_ duration: Duration, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
    let gate = Gate<T>()
    let work = Task {
        do { gate.finish(.success(try await body())) } catch { gate.finish(.failure(error)) }
    }
    let timer = Task {
        try? await Task.sleep(for: duration)
        gate.finish(.failure(TimeoutError()))
    }
    defer { work.cancel(); timer.cancel() }
    return try await withTaskCancellationHandler {
        try await gate.wait()
    } onCancel: {
        gate.finish(.failure(CancellationError()))
    }
}

/// One-shot result slot: the first `finish` wins, `wait` returns it.
final class Gate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var waiter: CheckedContinuation<T, Error>?

    func finish(_ r: Result<T, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = r
        let w = waiter
        waiter = nil
        lock.unlock()
        w?.resume(with: r)
    }

    func wait() async throws -> T {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
            lock.lock()
            if let r = result { lock.unlock(); c.resume(with: r) } else { waiter = c; lock.unlock() }
        }
    }
}
