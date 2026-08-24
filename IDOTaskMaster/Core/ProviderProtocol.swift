import Foundation

/// Uniform interface every metric-domain sampler conforms to — PLAN.md §3's
/// `Core/ProviderProtocol.swift "Provider: sample() throws -> DomainSnapshot"`.
/// `Sampler` holds one concrete instance per domain (`CPUProvider`,
/// `MemoryProvider`, ...) and awaits each one's `sample()` every tick,
/// folding the results into one merged `Snapshot` (PLAN.md §3 data flow).
///
/// `sample()` is declared `async` so providers that need to shell out
/// (`system_profiler`, `launchctl`) or otherwise do slow I/O can suspend
/// without blocking `Sampler`'s actor; providers backed by a fast syscall
/// (e.g. `CPUProvider`'s `host_processor_info`) simply implement it as a
/// plain synchronous `throws` function — Swift lets a synchronous witness
/// satisfy an `async` protocol requirement, so no provider pays for
/// suspension it doesn't need.
///
/// Two different failure modes matter here, both serving PLAN.md's "honest
/// degradation" rule (§2/§3: "providers must degrade gracefully ... surface
/// `Unavailable` values instead of guesses"):
/// - A single reading a provider can't take (e.g. Intel Macs have no
///   performance/efficiency core split) is represented as `nil`/"Unavailable"
///   *inside* `Output` — the provider still returns normally with everything
///   else it could read.
/// - The domain being entirely unreadable this tick (the underlying syscall
///   itself failed) is a `throw`. `Sampler` catches it, records
///   `ProviderHealth.degraded(reason:)` for `providerID`, and omits this
///   tick's payload for the domain rather than publishing stale or
///   fabricated data.
protocol Provider {
    /// The per-domain payload this provider produces each tick — one of
    /// `Snapshot`'s fields (`CPUSnapshot`, `MemorySnapshot`, ...).
    associatedtype Output: Sendable

    /// Stable key this provider reports under in `Snapshot.providersHealth`
    /// — e.g. `"cpu"`, `"memory"` — and that `PageInfoBar`'s degraded-count
    /// and the future `AlertsEngine` key rules against. A `static` property
    /// rather than an instance one: it identifies the *domain*, not a
    /// particular provider instance.
    static var providerID: String { get }

    /// Produces this tick's domain snapshot, or throws when the domain is
    /// entirely unreadable this tick (see this protocol's doc comment for
    /// the throw-vs-`nil` split).
    func sample() async throws -> Output
}
