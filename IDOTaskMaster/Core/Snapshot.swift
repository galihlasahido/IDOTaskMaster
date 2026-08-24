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
/// M0: only the tick bookkeeping exists here — `generation`, `timestamp`,
/// and an (always-empty-for-now) `providersHealth` map, enough for
/// `Sampler`'s skeleton loop to publish something real. Per-domain
/// payloads (`cpu`, `memory`, `gpu`, ...) get added as stored properties
/// here starting M2, once each corresponding `Provider` exists to fill
/// them in.
struct Snapshot: Sendable {
    /// Monotonically increasing tick counter, shown in the bottom info
    /// bar per PLAN.md §1.1 ("data 'Generation' counter"). Starts at 1
    /// for the first published snapshot.
    let generation: UInt64
    /// Wall-clock time this snapshot was assembled.
    let timestamp: Date
    /// Per-provider health as of this tick, keyed by the provider's
    /// stable id (e.g. "cpu", "memory"). Drives the info bar's
    /// "N providers degraded" message. Empty until M2 wires in real
    /// providers.
    let providersHealth: [String: ProviderHealth]

    /// Count of providers reporting `.degraded` this tick — the number
    /// the info bar surfaces as "N provider(s) degraded".
    var degradedProviderCount: Int {
        providersHealth.values.reduce(into: 0) { count, health in
            if case .degraded = health { count += 1 }
        }
    }
}
