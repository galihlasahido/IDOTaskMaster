import Foundation

/// Serializes access to the eight `Core/Provider*.swift` "core" domain
/// providers (`CPUProvider`, `MemoryProvider`, ...) — every one of them is a
/// plain, non-actor `final class` that carries mutable diff state across
/// samples (e.g. `CPUProvider.previousCoreTicks`), matching how `Sampler`
/// itself only ever calls them from inside its own actor-isolated `tick()`.
/// The MCP SDK dispatches each `tools/call` request in its own `Task`
/// (`Server.swift`'s receive loop), so two overlapping calls to
/// `get_summary` are a real possibility here in a way they aren't for
/// `Sampler`'s single tick loop; wrapping every core provider in this one
/// actor gives every tool handler the same "one long-lived instance, safe
/// under concurrent callers" guarantee the actor-based providers
/// (`ProcessProvider`, `ConnectionsProvider`, ...) already get for free from
/// their own `actor` declaration.
actor CoreProviderHub {
    private let cpuProvider = CPUProvider()
    private let memoryProvider = MemoryProvider()
    private let gpuProvider = GPUProvider()
    private let diskProvider = DiskProvider()
    private let networkProvider = NetworkProvider()
    private let energyProvider = EnergyProvider()
    private let thermalProvider = ThermalProvider()
    private let npuProvider = NPUProvider()

    func sampleCPU() throws -> CPUSnapshot { try cpuProvider.sample() }
    func sampleMemory() throws -> MemorySnapshot { try memoryProvider.sample() }
    func sampleGPU() throws -> GPUSnapshot { try gpuProvider.sample() }
    func sampleDisk() throws -> DiskSnapshot { try diskProvider.sample() }
    func sampleNetwork() throws -> NetworkSnapshot { try networkProvider.sample() }
    func sampleEnergy() throws -> EnergySnapshot { try energyProvider.sample() }
    func sampleThermal() throws -> ThermalSnapshot { try thermalProvider.sample() }
    func sampleNPU() throws -> NPUSnapshot { try npuProvider.sample() }

    /// One throwaway sample from each provider, so the diffing ones
    /// (CPU/disk/network/NPU) have a baseline before any real caller
    /// arrives — see `ProviderRegistry.warmUp()`.
    func warmUp() {
        _ = try? cpuProvider.sample()
        _ = try? memoryProvider.sample()
        _ = try? gpuProvider.sample()
        _ = try? diskProvider.sample()
        _ = try? networkProvider.sample()
        _ = try? energyProvider.sample()
        _ = try? thermalProvider.sample()
        _ = try? npuProvider.sample()
    }
}

/// One long-lived instance of every provider this MCP server's tools query,
/// created once at process startup (see `main.swift`) and reused for every
/// `tools/call` request for the server's whole lifetime. Several providers
/// (`CoreProviderHub`'s eight, plus `ProcessProvider`/`TopProcessesProvider`)
/// diff each sample against the previous one to compute rates — a fresh
/// instance per call would always report first-tick `nil` rates, so every
/// handler in `MCPServer/Handlers/*.swift` reaches its provider through this
/// one shared registry rather than constructing its own.
///
/// `NetTrafficProvider` (per-process network rates via a standing `nettop`
/// subprocess) is deliberately **not** held here: none of this server's
/// tools expose it, and instantiating it would launch a live child process
/// this server has no use for.
final class ProviderRegistry: @unchecked Sendable {
    let core = CoreProviderHub()

    let process = ProcessProvider()
    let topProcesses = TopProcessesProvider()
    let startup = StartupProvider()
    let services = ServicesProvider()
    let systemInfo = SystemInfoProvider()
    let connections = ConnectionsProvider()
    let installedApps = InstalledAppsProvider()
    let openFiles = OpenFilesProvider()
    let signingInfo = SigningInfoProvider()

    /// `nil`-fileURL default resolves to the SAME
    /// `~/Library/Application Support/IDOTaskMaster/History.sqlite` file the
    /// GUI app's own `HistoryStore` instance writes to — this server only
    /// ever queries it (`series`/`distinctSeries`), never calls `.start()`,
    /// so it never becomes a second writer against that file. If the GUI
    /// app has never run, the file doesn't exist yet and every query below
    /// just returns an empty result (see `HistoryStore`'s own doc comment)
    /// rather than throwing.
    let history = HistoryStore()

    /// Reads the SAME `AlertRule` set the GUI app has configured, by
    /// opening the app's own shared `UserDefaults` suite
    /// (`com.idotaskmaster.mac`) rather than a private/default one. Built
    /// once here and never `.start()`d — see `Handlers/AlertsHandlers.swift`
    /// for why starting it would begin a live sampling+notification loop
    /// this read-only server has no business running.
    let alerts: AlertsEngine

    private init(alerts: AlertsEngine) {
        self.alerts = alerts
    }

    /// Async factory rather than a plain `init()`: `AlertsEngine`'s own
    /// initializer is `@MainActor`-isolated (it's an `ObservableObject`), so
    /// building one has to hop onto the main actor even though this
    /// registry itself is an ordinary background object.
    static func make() async -> ProviderRegistry {
        let alertsEngine = await MainActor.run {
            AlertsEngine(defaults: UserDefaults(suiteName: "com.idotaskmaster.mac") ?? .standard)
        }
        let registry = ProviderRegistry(alerts: alertsEngine)
        await registry.warmUp()
        return registry
    }

    /// Takes one throwaway sample from every rate-diffing provider right
    /// after construction, so the *first* real `tools/call` a client makes
    /// — not just the second — already has a previous sample to diff
    /// against. Without this, `CPUProvider`/`DiskProvider`/
    /// `NetworkProvider`/`NPUProvider` (rate/delta fields) and
    /// `ProcessProvider`/`TopProcessesProvider` (per-process CPU %) would
    /// honestly report `nil` for their very first caller — correct
    /// per-provider behavior (no previous tick to diff against, see each
    /// provider's own doc comment), but a needless gap for an MCP client
    /// that typically calls a tool once and expects a real number back.
    /// Errors are discarded here: a provider that can't be read at all
    /// (e.g. no `IOAccelerator` service) will report that honestly on the
    /// caller's own request instead.
    private func warmUp() async {
        await core.warmUp()
        _ = try? await process.sample()
        _ = try? await topProcesses.sample()
    }
}
