import Foundation

/// Ticks at a configurable rate, incrementing a generation counter each
/// cycle and publishing a `Snapshot` to every subscriber over an
/// `AsyncStream` (PLAN.md §3 data flow: "`Sampler` (an actor) ticks at the
/// configured rate ... published via `AsyncStream` / `@Observable` model
/// to the UI").
///
/// This is the M0 skeleton: the tick loop, generation counter, and
/// multi-subscriber publishing plumbing that later milestones hang real
/// work off of. It does not sample any `Provider` yet — M2 adds a
/// provider registry here so `tick()` awaits `CPUProvider`,
/// `MemoryProvider`, etc. and folds their results (and any thrown errors,
/// as `ProviderHealth.degraded`) into the published `Snapshot`. Until
/// then every snapshot carries an empty `providersHealth`.
///
/// An actor (rather than an `ObservableObject`) because sampling touches
/// OS APIs that must not run on the main thread; UI code subscribes via
/// `stream()` and republishes onto `@Observable` state for SwiftUI, per
/// PLAN.md §3.
actor Sampler {
    /// Update-speed presets mirrored by `SettingsStore` and the View
    /// menu's Update Frequency ⌘-1/2/3 commands (PLAN.md §3, §1.1
    /// "real-time update speed (e.g. Normal — 2/sec)").
    enum Interval: Sendable, Equatable {
        /// ⌘1 — 4 samples/sec.
        case fast
        /// ⌘2 — 2 samples/sec. Default, matching [name removed]'s "Normal".
        case normal
        /// ⌘3 — 1 sample/sec.
        case slow
        /// Any other rate, e.g. from a user-configurable Settings field.
        case custom(TimeInterval)

        /// Seconds between ticks.
        var seconds: TimeInterval {
            switch self {
            case .fast: 0.25
            case .normal: 0.5
            case .slow: 1.0
            case .custom(let seconds): seconds
            }
        }
    }

    /// Current tick rate. Changing it takes effect after the in-flight
    /// tick's sleep completes — the loop re-reads this each cycle rather
    /// than restarting the task, so a Settings/View-menu change never
    /// drops a subscriber or resets `generation`.
    private(set) var interval: Interval

    /// Ticks since `start()` was first called. Never resets for the
    /// lifetime of a `Sampler` instance, matching the bottom info bar's
    /// generation counter (PLAN.md §1.1).
    private(set) var generation: UInt64 = 0

    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var tickTask: Task<Void, Never>?

    init(interval: Interval = .normal) {
        self.interval = interval
    }

    deinit {
        tickTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
    }

    /// Returns a fresh `AsyncStream` of published snapshots. Each call
    /// registers an independent subscriber that receives every snapshot
    /// published from that point on (not replayed history); the
    /// subscriber is unregistered automatically when its stream's
    /// iteration ends or `stop()` is called. Safe to call from multiple
    /// views concurrently.
    nonisolated func stream() -> AsyncStream<Snapshot> {
        let id = UUID()
        return AsyncStream { continuation in
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            Task { await self.addContinuation(id: id, continuation: continuation) }
        }
    }

    private func addContinuation(id: UUID, continuation: AsyncStream<Snapshot>.Continuation) {
        continuations[id] = continuation
    }

    /// Starts the tick loop if it isn't already running. Safe to call
    /// repeatedly — a second call while running is a no-op.
    func start() {
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.tick()
                let seconds = await self.interval.seconds
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    /// Cancels the tick loop and finishes every subscriber's stream
    /// (each subscriber's `for await` loop ends normally). `generation`
    /// is left untouched, and a later `start()` resumes counting from
    /// where it left off — there's no "restart from zero" case in the
    /// data flow this feeds (info bar, `AlertsEngine`, `HistoryStore`).
    func stop() {
        tickTask?.cancel()
        tickTask = nil
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
    }

    /// Updates the tick rate. Takes effect starting the next cycle.
    func setInterval(_ newInterval: Interval) {
        interval = newInterval
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    /// Advances `generation` and publishes one `Snapshot` to every
    /// current subscriber. M0: no `Provider` exists yet, so
    /// `providersHealth` is always empty; M2 replaces the body with a
    /// concurrent await of each registered provider.
    private func tick() async {
        generation += 1
        let snapshot = Snapshot(
            generation: generation,
            timestamp: Date(),
            providersHealth: [:]
        )
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
