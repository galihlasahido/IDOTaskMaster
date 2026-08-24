import Foundation

/// Health of a single provider as of its most recent sample. Keyed into
/// `Snapshot.providersHealth` and surfaced in the bottom info bar
/// (PLAN.md §1.1: "1 provider degraded").
///
/// `Provider` itself (the M2+ `sample()` interface implemented by
/// `CPUProvider`, `MemoryProvider`, etc.) is introduced alongside the
/// first concrete provider rather than here, since nothing in M0 samples
/// anything yet — `Sampler` just needs somewhere to report health.
enum ProviderHealth: Sendable, Equatable {
    /// Sampled successfully this tick.
    case ok
    /// Sampling failed, or this Mac doesn't expose the underlying data
    /// source. `reason` backs the metric's honest "Unavailable" label
    /// (PLAN.md §2/§3 "honest degradation") — never a guessed value.
    case degraded(reason: String)
}

/// One tick's worth of merged data, published by `Sampler` to every UI
/// subscriber (PLAN.md §3 data flow: "merged into one `Snapshot`
/// { generation, providersHealth, … }").
///
/// M0 shipped only the tick bookkeeping — `generation`, `timestamp`, and an
/// always-empty `providersHealth` map. M2 starts adding per-domain payloads
/// as stored properties here, one per `Provider` as it lands: `cpu` is the
/// first (`CPUProvider`), `memory` the second (`MemoryProvider`), `gpu`
/// the third (`GPUProvider`), `disk` the fourth (`DiskProvider`), `network`
/// the fifth (`NetworkProvider`), `energy` the sixth (`EnergyProvider`),
/// `thermal` the seventh (`ThermalProvider`), `npu` the eighth
/// (`NPUProvider`).
struct Snapshot: Sendable {
    /// Monotonically increasing tick counter, shown in the bottom info
    /// bar per PLAN.md §1.1 ("data 'Generation' counter"). Starts at 1
    /// for the first published snapshot.
    let generation: UInt64
    /// Wall-clock time this snapshot was assembled.
    let timestamp: Date
    /// Per-provider health as of this tick, keyed by the provider's
    /// stable id (e.g. "cpu", "memory"). Drives the info bar's
    /// "N providers degraded" message. Empty until a domain's `Provider`
    /// is wired into `Sampler`.
    let providersHealth: [String: ProviderHealth]
    /// This tick's CPU reading (`CPUProvider`) — utilization, uptime,
    /// topology. `nil` when `CPUProvider.sample()` threw this tick
    /// (`providersHealth["cpu"]` is `.degraded` in that case); individual
    /// fields *inside* a non-`nil` `CPUSnapshot` may still be `nil` for
    /// readings that domain can't take on this Mac (PLAN.md's "honest
    /// degradation").
    let cpu: CPUSnapshot?
    /// This tick's memory reading (`MemoryProvider`) — used/cached/swap/
    /// pressure. `nil` when `MemoryProvider.sample()` threw this tick
    /// (`providersHealth["memory"]` is `.degraded` in that case);
    /// individual fields inside a non-`nil` `MemorySnapshot` may still be
    /// `nil` for readings that sysctl call couldn't take.
    let memory: MemorySnapshot?
    /// This tick's GPU reading (`GPUProvider`) — utilization, VRAM-ish
    /// memory usage, temperature. `nil` when `GPUProvider.sample()` threw
    /// this tick (`providersHealth["gpu"]` is `.degraded` in that case,
    /// e.g. no `IOAccelerator` service found); individual fields inside a
    /// non-`nil` `GPUSnapshot` may still be `nil` for `PerformanceStatistics`
    /// keys this Mac's driver doesn't publish.
    let gpu: GPUSnapshot?
    /// This tick's disk reading (`DiskProvider`) — per-device % active,
    /// R/W rates, cumulative totals, and per-volume capacity. `nil` when
    /// `DiskProvider.sample()` threw this tick (`providersHealth["disk"]`
    /// is `.degraded` in that case, e.g. no `IOBlockStorageDriver` found);
    /// individual fields inside a non-`nil` `DiskSnapshot` may still be
    /// `nil` for readings that need a previous tick to diff against (rates,
    /// % active on the very first tick) or that a given device/volume
    /// doesn't publish.
    let disk: DiskSnapshot?
    /// This tick's network reading (`NetworkProvider`) — per-interface and
    /// combined send/receive rates and totals. `nil` when
    /// `NetworkProvider.sample()` threw this tick (`providersHealth["network"]`
    /// is `.degraded` in that case, e.g. the `NET_RT_IFLIST2` sysctl
    /// failed); individual fields inside a non-`nil` `NetworkSnapshot` may
    /// still be `nil` for rates that need a previous tick to diff against
    /// (the very first tick after launch, or the first tick after a new
    /// interface appears).
    let network: NetworkSnapshot?
    /// This tick's energy reading (`EnergyProvider`) — SMC wattage, power
    /// source/mode, battery state. `nil` when `EnergyProvider.sample()`
    /// threw this tick (`providersHealth["energy"]` is `.degraded` in that
    /// case, e.g. `IOPSCopyPowerSourcesInfo` itself failed); individual
    /// fields inside a non-`nil` `EnergySnapshot` may still be `nil` for
    /// readings that source can't take on this Mac (e.g. every SMC
    /// wattage key when the AppleSMC connection can't be opened, or the
    /// whole `battery` block on a Mac with none).
    let energy: EnergySnapshot?
    /// This tick's thermal reading (`ThermalProvider`) — SMC hotspot/
    /// per-die temperatures and OS thermal pressure. In practice this is
    /// always non-`nil`: `ThermalProvider.sample()` never actually throws
    /// (see that type's doc comment), so `providersHealth["thermal"]` is
    /// always `.ok` once this domain is wired in; a `nil` `hotspotCelsius`/
    /// empty `dieSensors` *inside* a non-`nil` `ThermalSnapshot` is how
    /// this domain's own "honest degradation" (no AppleSMC connection, or
    /// no temperature keys found) surfaces instead.
    let thermal: ThermalSnapshot?
    /// This tick's NPU reading (`NPUProvider`) — Apple Neural Engine
    /// device presence and, where the private IOReport framework exposes
    /// it, a raw energy-delta/activity signal. In practice this is always
    /// non-`nil`: like `ThermalProvider`, `NPUProvider.sample()` never
    /// actually throws (see that type's doc comment on why "no ANE on
    /// this Mac" is an honest snapshot value, not a provider failure), so
    /// `providersHealth["npu"]` is always `.ok` once this domain is wired
    /// in; `devicePresent: false` or a non-`nil`
    /// `NPUSnapshot.unavailableReason` *inside* a non-`nil` `NPUSnapshot`
    /// is how this domain's "honest degradation" surfaces instead.
    let npu: NPUSnapshot?
    /// System-wide process count for the bottom info bar (PLAN.md §1.1
    /// "live process count"). Read via a cheap `proc_listallpids(nil, 0)`
    /// call each tick — an estimate count with no buffer allocation, not
    /// `ProcessProvider`'s full tree walk (that provider is deliberately
    /// excluded from `Sampler`'s per-tick loop; see its doc comment).
    /// `nil` when that call fails, read as "Unavailable" like every other
    /// honest-degradation reading.
    let processCount: Int?

    init(
        generation: UInt64,
        timestamp: Date,
        providersHealth: [String: ProviderHealth],
        cpu: CPUSnapshot? = nil,
        memory: MemorySnapshot? = nil,
        gpu: GPUSnapshot? = nil,
        disk: DiskSnapshot? = nil,
        network: NetworkSnapshot? = nil,
        energy: EnergySnapshot? = nil,
        thermal: ThermalSnapshot? = nil,
        npu: NPUSnapshot? = nil,
        processCount: Int? = nil
    ) {
        self.generation = generation
        self.timestamp = timestamp
        self.providersHealth = providersHealth
        self.cpu = cpu
        self.memory = memory
        self.gpu = gpu
        self.disk = disk
        self.network = network
        self.energy = energy
        self.thermal = thermal
        self.npu = npu
        self.processCount = processCount
    }

    /// Count of providers reporting `.degraded` this tick — the number
    /// the info bar surfaces as "N provider(s) degraded".
    var degradedProviderCount: Int {
        providersHealth.values.reduce(into: 0) { count, health in
            if case .degraded = health { count += 1 }
        }
    }
}
