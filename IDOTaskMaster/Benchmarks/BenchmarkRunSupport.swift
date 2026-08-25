import Foundation

/// Thread-safe cancel flag shared between whatever calls a
/// `BenchmarkRunner`'s `cancelActiveRun()` and the `DispatchQueue.global`
/// thread actually doing that run's work — the same shape (and same
/// reasoning: checking an actor-isolated property from inside a tight
/// per-item loop would cost an `await` for every check) as
/// `DiskSpaceScanner`'s own private `CancellationToken`. Shared here across
/// every `Benchmarks/*.swift` runner that needs it (CPU, GPU, Disk) rather
/// than each file duplicating its own private copy — `InternetBenchmarkRunner`
/// doesn't: its work is plain `async`/`await` network calls, so Swift
/// Concurrency's own `Task` cancellation (see `BenchmarkTaskBox` below)
/// already covers it.
final class BenchmarkCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// Holds the `BenchmarkCancellationToken` for whichever run a
/// `BenchmarkRunner` currently has active, behind its own lock rather than
/// actor isolation — mirrors `DiskSpaceScanner`'s own private `TokenBox`.
/// Storing this in a runner's `let` property (rather than a `var` token
/// directly) is what lets that runner's `cancelActiveRun()` stay
/// synchronous and take effect immediately, and lets the runner itself stay
/// built entirely out of immutable, `Sendable` stored properties — no
/// runner needs its own `@unchecked Sendable` opt-out.
final class BenchmarkTokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: BenchmarkCancellationToken?

    var current: BenchmarkCancellationToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func set(_ newToken: BenchmarkCancellationToken) {
        lock.lock()
        token = newToken
        lock.unlock()
    }
}

/// Holds the in-flight `Task` for a runner (`InternetBenchmarkRunner`) that
/// cancels via Swift Concurrency's own `Task.cancel()` rather than a
/// `BenchmarkCancellationToken` — same lock-protected-box shape as
/// `BenchmarkTokenBox`, just for a `Task` instead of a token, and for the
/// same reason: it keeps that runner's `cancelActiveRun()` synchronous and
/// its own stored properties immutable.
final class BenchmarkTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var current: Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }

    func set(_ newTask: Task<Void, Never>?) {
        lock.lock()
        task = newTask
        lock.unlock()
    }
}
