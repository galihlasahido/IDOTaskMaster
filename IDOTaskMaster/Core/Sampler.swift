import Foundation

/// Ticks at a configurable rate, incrementing a generation counter each
/// cycle and publishing a `Snapshot` to every subscriber over an
/// `AsyncStream` (PLAN.md §3 data flow: "`Sampler` (an actor) ticks at the
/// configured rate ... published via `AsyncStream` / `@Observable` model
/// to the UI").
///
/// M0 shipped the tick loop, generation counter, and multi-subscriber
/// publishing plumbing with no `Provider` wired in. M2 starts filling that
/// in: `tick()` now samples `CPUProvider`, `MemoryProvider`, `GPUProvider`,
/// `DiskProvider`, `NetworkProvider`, `EnergyProvider`, `ThermalProvider`,
/// and `NPUProvider`, folding each result (or, on a thrown error, a
/// `ProviderHealth.degraded` entry) into the published `Snapshot`.
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

    /// M2's provider registry, growing one property per domain as its
    /// `Provider` lands (PLAN.md §3 `Providers/`). Owned here rather than
    /// as locals in `tick()` because providers like `CPUProvider` carry
    /// state across ticks (previous sample's raw counts) that must survive
    /// between calls.
    private let cpuProvider = CPUProvider()
    private let memoryProvider = MemoryProvider()
    private let gpuProvider = GPUProvider()
    private let diskProvider = DiskProvider()
    private let networkProvider = NetworkProvider()
    private let energyProvider = EnergyProvider()
    private let thermalProvider = ThermalProvider()
    private let npuProvider = NPUProvider()

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

    /// Advances `generation`, awaits every registered `Provider`, and
    /// publishes one merged `Snapshot` to every current subscriber. Each
    /// provider's failure is isolated — a thrown error becomes that
    /// provider's `ProviderHealth.degraded` entry and a `nil` payload for
    /// its domain, rather than failing the whole tick (PLAN.md's "honest
    /// degradation": one bad provider must not take the others down).
    private func tick() async {
        generation += 1

        var health: [String: ProviderHealth] = [:]

        var cpuSnapshot: CPUSnapshot?
        do {
            // `CPUProvider.sample()` is a plain synchronous `throws`
            // function (see `Provider`'s doc comment on why an async
            // protocol requirement doesn't force every conformer to
            // suspend) — called directly with no `await` since `cpuProvider`
            // is held here as the concrete type, not `any Provider`.
            cpuSnapshot = try cpuProvider.sample()
            health[CPUProvider.providerID] = .ok
        } catch {
            health[CPUProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var memorySnapshot: MemorySnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `memoryProvider` is held here as its concrete type.
            memorySnapshot = try memoryProvider.sample()
            health[MemoryProvider.providerID] = .ok
        } catch {
            health[MemoryProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var gpuSnapshot: GPUSnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `gpuProvider` is held here as its concrete type.
            gpuSnapshot = try gpuProvider.sample()
            health[GPUProvider.providerID] = .ok
        } catch {
            health[GPUProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var diskSnapshot: DiskSnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `diskProvider` is held here as its concrete type.
            diskSnapshot = try diskProvider.sample()
            health[DiskProvider.providerID] = .ok
        } catch {
            health[DiskProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var networkSnapshot: NetworkSnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `networkProvider` is held here as its concrete type.
            networkSnapshot = try networkProvider.sample()
            health[NetworkProvider.providerID] = .ok
        } catch {
            health[NetworkProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var energySnapshot: EnergySnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `energyProvider` is held here as its concrete type.
            energySnapshot = try energyProvider.sample()
            health[EnergyProvider.providerID] = .ok
        } catch {
            health[EnergyProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var thermalSnapshot: ThermalSnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `thermalProvider` is held here as its concrete type.
            // (`ThermalProvider.sample()` never actually throws — see its
            // doc comment — so this branch's `catch` is effectively dead
            // for this provider today, but is kept for the same reason
            // every other provider here has one: `Provider.sample()` is a
            // `throws` interface, and `Sampler` must not assume any given
            // conformer never exercises it.)
            thermalSnapshot = try thermalProvider.sample()
            health[ThermalProvider.providerID] = .ok
        } catch {
            health[ThermalProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        var npuSnapshot: NPUSnapshot?
        do {
            // Same reasoning as `cpuProvider.sample()` above: a plain
            // synchronous `throws` function, called directly (no `await`)
            // since `npuProvider` is held here as its concrete type.
            // (`NPUProvider.sample()` never actually throws — see its doc
            // comment — so this branch's `catch` is effectively dead for
            // this provider today, but is kept for the same reason every
            // other provider here has one: `Provider.sample()` is a
            // `throws` interface, and `Sampler` must not assume any given
            // conformer never exercises it.)
            npuSnapshot = try npuProvider.sample()
            health[NPUProvider.providerID] = .ok
        } catch {
            health[NPUProvider.providerID] = .degraded(reason: error.localizedDescription)
        }

        let snapshot = Snapshot(
            generation: generation,
            timestamp: Date(),
            providersHealth: health,
            cpu: cpuSnapshot,
            memory: memorySnapshot,
            gpu: gpuSnapshot,
            disk: diskSnapshot,
            network: networkSnapshot,
            energy: energySnapshot,
            thermal: thermalSnapshot,
            npu: npuSnapshot
        )
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }
}
