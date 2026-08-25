import Foundation

/// Real engine behind `.cpuSingleCore`/`.cpuMultiCore` — PLAN.md §4 M7's
/// second task's "CPU benchmark (single/multi core)". One instance backs
/// exactly one of those two `BenchmarkKind`s (`BenchmarkCatalog` constructs
/// two, `CPUBenchmarkRunner(kind: .cpuSingleCore)` and
/// `CPUBenchmarkRunner(kind: .cpuMultiCore)`), since `BenchmarkRunner.kind`
/// is a fixed per-instance property, not a run-time parameter.
///
/// The workload is trial-division primality testing over consecutive odd
/// numbers — cheap to implement correctly, branchy and data-dependent
/// enough that the compiler can't fold or hoist it, and its result
/// (`primesFound`, this thread's return value) is what actually gets
/// reported, so nothing about the loop can be dead-code-eliminated as
/// "computed but never used." **This is not calibrated against any
/// published benchmark suite** (Geekbench, ...) — the "Score" is
/// self-consistent only: primes-per-second of wall-clock trial-division
/// work, meaningful for comparing this same Mac's own runs over time (the
/// point of `BenchmarksPage`'s history table), not for comparing against a
/// different app's numbers.
///
/// Single-core mode runs the workload on exactly one background thread for
/// `testDuration`; multi-core splits the same wall-clock budget across
/// `ProcessInfo.processInfo.activeProcessorCount` threads, each testing its
/// own disjoint slice of numbers (`3 + threadIndex*2`, stepping by
/// `threadCount*2`) so they never race over the same candidates, and sums
/// every thread's primes-found. The two modes' scores are consequently
/// **not** comparable to each other — only single-core-to-single-core and
/// multi-core-to-multi-core across runs.
///
/// Mirrors `DiskSpaceScanner`'s own shape: the actual work runs on
/// `DispatchQueue.global`, never inside this `async`-shaped protocol's own
/// cooperative-pool `Task` — a tight CPU-bound loop must never tie up a
/// thread from the same pool `Sampler`'s ticks and every other provider
/// share, the identical reasoning `DiskSpaceScanner` gives for its own
/// blocking filesystem walk. Cancellation is `BenchmarkCancellationToken`,
/// checked once per `batchSize` iterations (not every single one — a lock
/// check per number would dwarf the arithmetic being measured).
final class CPUBenchmarkRunner: BenchmarkRunner {
    let kind: BenchmarkKind
    private let tokenBox = BenchmarkTokenBox()

    /// - Parameter kind: Must be `.cpuSingleCore` or `.cpuMultiCore` — every
    ///   other case is a programmer error (`BenchmarkCatalog` is this
    ///   type's only caller and never passes one).
    init(kind: BenchmarkKind) {
        precondition(kind == .cpuSingleCore || kind == .cpuMultiCore, "CPUBenchmarkRunner only backs the CPU benchmark kinds")
        self.kind = kind
    }

    private static let testDuration: TimeInterval = 2.5
    private static let batchSize = 20_000
    /// How often (in seconds of wall clock) the coordinating loop polls for
    /// completion/cancellation and emits a `.progress` tick while the
    /// worker thread(s) run — this is independent of `batchSize`, which
    /// only governs how often a *worker* thread checks the clock/token.
    private static let progressPollInterval: TimeInterval = 0.15

    func run(context: BenchmarkRunContext) -> AsyncStream<BenchmarkRunEvent> {
        let token = BenchmarkCancellationToken()
        tokenBox.set(token)
        let kind = self.kind
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .userInitiated).async {
                Self.performRun(kind: kind, token: token, continuation: continuation)
            }
        }
    }

    /// Mirrors `DiskSpaceScanner.cancelActiveScan()`: a no-op if nothing is
    /// running, otherwise takes effect the next time a worker thread checks
    /// `token.isCancelled` (at most one `batchSize` chunk of latency later).
    func cancelActiveRun() {
        tokenBox.current?.cancel()
    }

    private static func performRun(kind: BenchmarkKind, token: BenchmarkCancellationToken, continuation: AsyncStream<BenchmarkRunEvent>.Continuation) {
        let threadCount = kind == .cpuMultiCore ? max(1, ProcessInfo.processInfo.activeProcessorCount) : 1
        continuation.yield(.progress(BenchmarkProgress(fraction: 0, phase: "Warming up\u{2026}")))

        let group = DispatchGroup()
        let resultsLock = NSLock()
        var perThreadPrimesFound = [Int](repeating: 0, count: threadCount)
        let startedAt = Date()

        for threadIndex in 0..<threadCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                let primesFound = runWorkload(startingAt: threadIndex, stride: threadCount, duration: testDuration, token: token)
                resultsLock.lock()
                perThreadPrimesFound[threadIndex] = primesFound
                resultsLock.unlock()
                group.leave()
            }
        }

        let phaseText = kind == .cpuMultiCore ? "Measuring \(threadCount)-core throughput\u{2026}" : "Measuring single-core throughput\u{2026}"

        // Coordinator: poll for completion while the worker(s) above run,
        // reporting elapsed-time-based progress (an honest fraction — the
        // target duration is fixed and known up front, unlike
        // `DiskSpaceScanProgress`'s permanently-indeterminate item count).
        while true {
            if token.isCancelled {
                continuation.yield(.cancelled)
                continuation.finish()
                return
            }
            if group.wait(timeout: .now() + progressPollInterval) == .success {
                break
            }
            let elapsed = Date().timeIntervalSince(startedAt)
            continuation.yield(.progress(BenchmarkProgress(fraction: min(elapsed / testDuration, 0.99), phase: phaseText)))
        }

        // The group can finish because every worker naturally hit its
        // deadline, or because `cancelActiveRun()` landed in the same
        // ~`progressPollInterval` window a worker was already about to
        // finish in — both look identical to `group.wait` returning
        // `.success` above, so cancellation has to be checked again here
        // rather than assumed away just because the loop broke normally.
        guard !token.isCancelled else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        let elapsed = Date().timeIntervalSince(startedAt)
        let totalPrimesFound = perThreadPrimesFound.reduce(0, +)
        guard elapsed > 0, totalPrimesFound > 0 else {
            continuation.yield(.failed("The CPU benchmark didn\u{2019}t complete a measurable amount of work."))
            continuation.finish()
            return
        }

        let score = Double(totalPrimesFound) / elapsed
        let result = BenchmarkResult(
            id: UUID(),
            kind: kind,
            generatedAt: Date(),
            metrics: [BenchmarkMetric(label: "Score", value: score, unit: "pts")],
            detail: kind == .cpuMultiCore ? "\(threadCount) threads" : "1 thread"
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    /// One thread's share of the workload: tests odd numbers for primality
    /// by trial division, starting at `3 + threadIndex*2` and stepping by
    /// `stride*2` so concurrent threads examine disjoint numbers rather
    /// than racing over the same range (`stride == 1` for single-core mode
    /// is just the plain sequential 3, 5, 7, ... progression). Runs until
    /// `duration` has elapsed or `token` is cancelled, checking both only
    /// every `batchSize` numbers.
    /// - Returns: How many of the candidates this thread tested were prime.
    private static func runWorkload(startingAt threadIndex: Int, stride: Int, duration: TimeInterval, token: BenchmarkCancellationToken) -> Int {
        let deadline = Date().addingTimeInterval(duration)
        let step = max(stride, 1) * 2
        var candidate = 3 + threadIndex * 2
        var primesFound = 0

        while true {
            for _ in 0..<batchSize {
                if isPrime(candidate) { primesFound += 1 }
                candidate += step
            }
            if token.isCancelled || Date() >= deadline { break }
        }
        return primesFound
    }

    private static func isPrime(_ n: Int) -> Bool {
        if n < 2 { return false }
        if n % 2 == 0 { return n == 2 }
        var divisor = 3
        while divisor * divisor <= n {
            if n % divisor == 0 { return false }
            divisor += 2
        }
        return true
    }
}
