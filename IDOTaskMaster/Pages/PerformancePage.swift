import SwiftUI

/// Performance master-detail page — PLAN.md §1.1 "Performance
/// (master-detail)" / §4 M2, the heart of the app: a left rail of
/// selectable mini-cards with live sparkline thumbnails for every domain
/// (CPU, Memory, GPU 0, NPU 0, Disks, Network, Energy, Thermals), and a
/// detail view on the right matching §1.1's per-domain layout — stats
/// grids, GPU's Overall/Engines tabs, and the Disk/Network pages' "Storage
/// details…"/"Connection details…" buttons.
///
/// This is the first page to own a live `Sampler`: `PerformanceViewModel`
/// starts one in `onAppear` and stops it in `onDisappear`, matching
/// `AppShell`'s note that "whichever page first owns a live snapshot
/// stream" is free to do so without any change to the shell itself. Every
/// reading below either comes straight from a `Snapshot` field or is
/// rendered as an explicit "Unavailable" — never guessed — per PLAN.md's
/// honest-degradation rule; a handful of [name removed]-inventoried fields
/// (CPU cache/virtualization, GPU clock/API versions, memory module
/// speed/slots, disk response time/NVMe type, interface IPv4/IPv6, and the
/// per-process energy ranking that needs M4's `ProcessProvider`) have no
/// backing provider field at all yet and are shown the same honest way.
struct PerformancePage: View {
    @StateObject private var model = PerformanceViewModel()

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(MetricDomain.allCases) { domain in
                    railTile(for: domain)
                }
            }
            .padding(10)
        }
        .frame(width: 230)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func railTile(for domain: MetricDomain) -> some View {
        switch domain {
        case .cpu: cpuTile
        case .memory: memoryTile
        case .gpu: gpuTile
        case .npu: npuTile
        case .disk: diskTile
        case .network: networkTile
        case .energy: energyTile
        case .thermal: thermalTile
        }
    }

    private var cpuTile: some View {
        let cpu = model.latest?.cpu
        return StatTile(
            title: "CPU",
            systemImage: "cpu",
            color: DomainPalette.cpuUser,
            value: Fmt.percent(cpu?.totalUtilization),
            secondaryText: cpu?.topology.logicalCoreCount.map { "\($0) cores" },
            isUnavailable: cpu?.totalUtilization == nil,
            isSelected: model.selectedDomain == .cpu,
            action: { model.selectedDomain = .cpu }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "cpu", color: DomainPalette.cpuUser, values: model.history("cpu.total"))],
                gridLineCount: 0,
                accessibilityLabel: "CPU history"
            )
            .frame(height: 32)
        }
    }

    private var memoryTile: some View {
        let memory = model.latest?.memory
        return StatTile(
            title: "Memory",
            systemImage: "memorychip",
            color: DomainPalette.memoryPressureNormal,
            value: Fmt.bytes(memory?.usedBytes),
            secondaryText: memory?.totalBytes.map { "of \(Fmt.bytes($0))" },
            isUnavailable: memory?.usedBytes == nil,
            isSelected: model.selectedDomain == .memory,
            action: { model.selectedDomain = .memory }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "memory", color: DomainPalette.memoryPressureNormal, values: model.history("memory.usedPercent"))],
                gridLineCount: 0,
                accessibilityLabel: "Memory history"
            )
            .frame(height: 32)
        }
    }

    private var gpuTile: some View {
        let gpu = model.latest?.gpu
        return StatTile(
            title: "GPU 0",
            systemImage: "square.stack.3d.up.fill",
            color: DomainPalette.gpu,
            value: Fmt.percent(gpu?.utilizationPercent),
            secondaryText: gpu?.deviceClassName,
            isUnavailable: gpu?.utilizationPercent == nil,
            isSelected: model.selectedDomain == .gpu,
            action: { model.selectedDomain = .gpu }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "gpu", color: DomainPalette.gpu, values: model.history("gpu.utilization"))],
                gridLineCount: 0,
                accessibilityLabel: "GPU history"
            )
            .frame(height: 32)
        }
    }

    private var npuTile: some View {
        let npu = model.latest?.npu
        return StatTile(
            title: "NPU 0",
            systemImage: "brain",
            color: DomainPalette.npu,
            value: npu?.isActive.map { $0 ? "Active" : "Idle" } ?? "Unavailable",
            secondaryText: npu?.deviceName,
            isUnavailable: npu?.isActive == nil,
            isSelected: model.selectedDomain == .npu,
            action: { model.selectedDomain = .npu }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "npu", color: DomainPalette.npu, values: model.history("npu.active"))],
                gridLineCount: 0,
                accessibilityLabel: "NPU history"
            )
            .frame(height: 32)
        }
    }

    private var diskTile: some View {
        let disk = model.latest?.disk
        let combined = combinedRate(disk?.readBytesPerSecond, disk?.writeBytesPerSecond)
        return StatTile(
            title: "Disks",
            systemImage: "internaldrive",
            color: DomainPalette.diskRead,
            value: Fmt.bytesPerSecond(combined),
            secondaryText: disk?.activePercent.map { "\(Fmt.percent($0)) active" },
            isUnavailable: combined == nil,
            isSelected: model.selectedDomain == .disk,
            action: { model.selectedDomain = .disk }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "disk", color: DomainPalette.diskRead, values: model.history("disk.active"))],
                gridLineCount: 0,
                accessibilityLabel: "Disk history"
            )
            .frame(height: 32)
        }
    }

    private var networkTile: some View {
        let network = model.latest?.network
        let combined = combinedRate(network?.receiveBytesPerSecond, network?.sendBytesPerSecond)
        return StatTile(
            title: "Network",
            systemImage: "network",
            color: DomainPalette.networkIn,
            value: Fmt.bytesPerSecond(combined),
            secondaryText: secondaryNetworkText(network),
            isUnavailable: combined == nil,
            isSelected: model.selectedDomain == .network,
            action: { model.selectedDomain = .network }
        ) {
            HistoryGraph(
                series: [
                    HistoryGraphSeries(id: "receive", color: DomainPalette.networkIn, values: model.history("network.receive")),
                    HistoryGraphSeries(id: "send", color: DomainPalette.networkOut, values: model.history("network.send")),
                ],
                valueRange: model.dynamicRange(for: ["network.receive", "network.send"]),
                gridLineCount: 0,
                accessibilityLabel: "Network history"
            )
            .frame(height: 32)
        }
    }

    private func secondaryNetworkText(_ network: NetworkSnapshot?) -> String? {
        guard let receive = network?.receiveBytesPerSecond, let send = network?.sendBytesPerSecond else { return nil }
        return "↓ \(Fmt.bytesPerSecond(receive)) · ↑ \(Fmt.bytesPerSecond(send))"
    }

    private var energyTile: some View {
        let energy = model.latest?.energy
        return StatTile(
            title: "Energy",
            systemImage: "bolt.fill",
            color: DomainPalette.energy,
            value: Fmt.watts(energy?.systemPowerWatts),
            secondaryText: energy.map { $0.isLowPowerModeEnabled ? "Low Power Mode" : "Normal" },
            isUnavailable: energy?.systemPowerWatts == nil,
            isSelected: model.selectedDomain == .energy,
            action: { model.selectedDomain = .energy }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "energy", color: DomainPalette.energy, values: model.history("energy.watts"))],
                valueRange: model.dynamicRange(for: ["energy.watts"]),
                gridLineCount: 0,
                accessibilityLabel: "Energy history"
            )
            .frame(height: 32)
        }
    }

    private var thermalTile: some View {
        let thermal = model.latest?.thermal
        return StatTile(
            title: "Thermals",
            systemImage: "thermometer",
            color: DomainPalette.thermal,
            value: Fmt.celsius(thermal?.hotspotCelsius),
            secondaryText: thermal.map { thermalPressureLabel($0.thermalPressure) },
            isUnavailable: thermal?.hotspotCelsius == nil,
            isSelected: model.selectedDomain == .thermal,
            action: { model.selectedDomain = .thermal }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "thermal", color: DomainPalette.thermal, values: model.history("thermal.hotspot"))],
                valueRange: 0...110,
                gridLineCount: 0,
                accessibilityLabel: "Thermal history"
            )
            .frame(height: 32)
        }
    }

    private func combinedRate(_ a: Double?, _ b: Double?) -> Double? {
        guard let a, let b else { return nil }
        return a + b
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selectedDomain {
        case .cpu: CPUDetailView(model: model)
        case .memory: MemoryDetailView(model: model)
        case .gpu: GPUDetailView(model: model)
        case .npu: NPUDetailView(model: model)
        case .disk: DiskDetailView(model: model)
        case .network: NetworkDetailView(model: model)
        case .energy: EnergyDetailView(model: model)
        case .thermal: ThermalDetailView(model: model)
        }
    }
}

/// Shared "thermal pressure" label used by both the rail and the
/// Energy/Thermal detail views, kept here rather than duplicated per call
/// site since `ThermalPressureLevel` is a plain (non-`CustomStringConvertible`)
/// enum with no display name of its own.
private func thermalPressureLabel(_ pressure: ThermalPressureLevel) -> String {
    switch pressure {
    case .nominal: "Nominal"
    case .fair: "Fair"
    case .serious: "Serious"
    case .critical: "Critical"
    case .unknown: "Unknown"
    }
}

// MARK: - View model

/// Owns this page's live `Sampler`, republishing its snapshot stream onto
/// `@Published` state for SwiftUI (PLAN.md §3 data flow: "UI ... subscribes
/// via `stream()` and republishes onto `@Observable` state") and
/// maintaining a bounded in-memory history per plotted series for the rail
/// sparklines and detail graphs. `ObservableObject`/`@Published` rather
/// than the `@Observable` macro since this target's minimum is macOS 13.0
/// (`@Observable` needs 14+), matching `SettingsStore`'s own convention.
///
/// A fresh `Sampler` is created and torn down with this view model's
/// lifetime rather than sharing one app-wide instance: no other page reads
/// live data yet, and starting/stopping sampling exactly while this page is
/// visible keeps this monitor from being its own load while the user is
/// looking at a different page (PLAN.md §2's "lowest idle overhead"
/// rationale).
@MainActor
final class PerformanceViewModel: ObservableObject {
    /// Ticks of history kept per series — enough for a readable trend at
    /// every `Sampler.Interval` preset (90s at Fast, 3min at Normal, 6min
    /// at Slow) without unbounded growth.
    private static let historyCapacity = 180

    @Published private(set) var latest: Snapshot?
    /// Per-series ring buffers, keyed by a dotted id this file assigns
    /// (e.g. `"cpu.user"`, `"thermal.sensor.TPD3"`) — plain arrays rather
    /// than a shared `Core/History.swift` type, since only this page reads
    /// them today. `nil` entries are gaps left by a tick this domain
    /// couldn't sample, matching `HistoryGraphSeries.values`' own
    /// "honest gap, not an interpolated guess" contract.
    @Published private(set) var seriesHistory: [String: [Double?]] = [:]

    /// The rail's current selection — which detail view is showing.
    @Published var selectedDomain: MetricDomain = .cpu
    /// GPU detail's own Overall/Engines sub-selection (PLAN.md §1.1).
    @Published var selectedGPUTab: GPUEngineTab = .overall
    @Published var showsStorageDetails = false
    @Published var showsConnectionDetails = false

    private let sampler = Sampler()
    private var streamTask: Task<Void, Never>?

    /// Starts the live snapshot stream if it isn't already running. Safe
    /// to call repeatedly (`SwiftUI.onAppear` can fire more than once for
    /// the same view instance).
    func start() {
        guard streamTask == nil else { return }
        let sampler = sampler
        streamTask = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.stream() {
                guard let self else { return }
                self.ingest(snapshot)
            }
        }
    }

    /// Stops the stream and the underlying `Sampler`'s tick loop. Called
    /// from `onDisappear` so this page's own sampling doesn't keep running
    /// (and costing CPU) while another page is showing.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
        let sampler = sampler
        Task { await sampler.stop() }
    }

    /// One series' full history, oldest first — `HistoryGraph`'s expected
    /// order. An unknown id (nothing sampled for it yet) reads as an empty
    /// array, which `HistoryGraph` already renders as a blank chart rather
    /// than a crash.
    func history(_ id: String) -> [Double?] {
        seriesHistory[id] ?? []
    }

    /// A `0...max` range sized to the largest sample seen so far across the
    /// given series ids — for byte-rate/watt-scale series that have no
    /// natural fixed ceiling the way a percentage does. Floors at `1` so a
    /// series with no samples yet (or all zeros) still gets a valid,
    /// non-degenerate range rather than `0...0`.
    func dynamicRange(for ids: [String]) -> ClosedRange<Double> {
        let maxValue = ids.flatMap { seriesHistory[$0] ?? [] }.compactMap { $0 }.max() ?? 0
        return 0...max(maxValue, 1)
    }

    // MARK: - Ingest

    private func ingest(_ snapshot: Snapshot) {
        latest = snapshot

        // Mutated locally and assigned back once at the end so every
        // series update in one tick becomes a single `@Published` change
        // notification rather than one per series.
        var history = seriesHistory
        func append(_ id: String, _ value: Double?) {
            var values = history[id] ?? []
            values.append(value)
            if values.count > Self.historyCapacity {
                values.removeFirst(values.count - Self.historyCapacity)
            }
            history[id] = values
        }

        append("cpu.total", snapshot.cpu?.totalUtilization)
        append("cpu.user", snapshot.cpu?.userUtilization)
        append("cpu.system", snapshot.cpu?.systemUtilization)
        for core in snapshot.cpu?.perCoreUtilization ?? [] {
            append("cpu.core.\(core.id).user", core.userUtilization)
            append("cpu.core.\(core.id).system", core.systemUtilization)
        }

        append("memory.usedPercent", Self.usedPercent(snapshot.memory))

        append("gpu.utilization", snapshot.gpu?.utilizationPercent)
        append("gpu.renderer", snapshot.gpu?.rendererUtilizationPercent)
        append("gpu.tiler", snapshot.gpu?.tilerUtilizationPercent)

        append("npu.active", snapshot.npu?.isActive.map { $0 ? 100.0 : 0.0 })

        append("disk.active", snapshot.disk?.activePercent)
        append("disk.read", snapshot.disk?.readBytesPerSecond)
        append("disk.write", snapshot.disk?.writeBytesPerSecond)

        append("network.receive", snapshot.network?.receiveBytesPerSecond)
        append("network.send", snapshot.network?.sendBytesPerSecond)

        append("energy.watts", snapshot.energy?.systemPowerWatts)

        append("thermal.hotspot", snapshot.thermal?.hotspotCelsius)
        for sensor in snapshot.thermal?.dieSensors ?? [] {
            append("thermal.sensor.\(sensor.key)", sensor.celsius)
        }

        seriesHistory = history
    }

    private static func usedPercent(_ memory: MemorySnapshot?) -> Double? {
        guard let memory, let total = memory.totalBytes, total > 0, let used = memory.usedBytes else { return nil }
        return Double(used) / Double(total) * 100
    }
}

/// GPU detail's Overall/Engines sub-tabs (PLAN.md §1.1: "GPU detail:
/// Overall/Engines tabs").
enum GPUEngineTab: String, CaseIterable, Identifiable {
    case overall
    case engines

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overall: "Overall"
        case .engines: "Engines"
        }
    }
}

// MARK: - Shared detail-layout building blocks

/// Grid columns shared by every domain's stat grid, sized so 2–4 cards fit
/// a typical detail-pane width depending on how wide the window currently
/// is.
private let statGridColumns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

/// One titled group within a detail view's scrolling body — the "stats
/// grids" this task calls for, and the graphs/lists that sit alongside
/// them. Deliberately not `Components/DetailPane.swift`'s
/// `DetailPaneSection`: that component is styled for a narrow selection
/// inspector (Processes' bottom pane, PLAN.md §1.1), while this page's
/// detail area is the main content column for a whole domain, closer in
/// spirit to Activity Monitor's own per-tab body than to a side panel.
private struct DetailSection<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
            content
        }
    }
}

/// One label/value cell inside a stat grid — this file's equivalent of
/// `DetailPaneField`, sized and styled for a `LazyVGrid` card rather than a
/// `Grid` row.
private struct MetricCard: View {
    let label: String
    let value: String
    var isUnavailable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(isUnavailable ? "Unavailable" : value)
                .font(.body)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(isUnavailable ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A domain detail view's big icon/name/headline-reading row, shared by
/// every `*DetailView` below.
private struct DetailHeadline: View {
    let systemImage: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(value)
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .monospacedDigit()
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Formatting

/// Number/byte/duration formatting shared by every detail view below —
/// this file's counterpart to `CapacityBar`/`StatTile`'s own convention of
/// rendering a missing reading as the literal string `"Unavailable"`
/// rather than a blank or a fabricated placeholder.
private enum Fmt {
    static func percent(_ value: Double?, decimals: Int = 0) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.\(decimals)f%%", value)
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        let clamped = min(value, UInt64(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped))
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f W", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.0f°C", value)
    }

    static func count(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return "\(value)"
    }

    static func milliampHours(_ value: Int?) -> String {
        guard let value else { return "Unavailable" }
        return "\(value) mAh"
    }

    static func uptime(_ interval: TimeInterval?) -> String {
        guard let interval, interval.isFinite, interval >= 0 else { return "Unavailable" }
        return uptimeFormatter.string(from: interval) ?? "Unavailable"
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()
}

// MARK: - CPU detail

private struct CPUDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var cpu: CPUSnapshot? { model.latest?.cpu }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "cpu",
                    color: DomainPalette.cpuUser,
                    title: cpu?.topology.brandString ?? "CPU",
                    value: Fmt.percent(cpu?.totalUtilization)
                )

                DetailSection(title: "Utilization") {
                    HistoryGraph(
                        series: [
                            HistoryGraphSeries(id: "user", color: DomainPalette.cpuUser, values: model.history("cpu.user")),
                            HistoryGraphSeries(id: "system", color: DomainPalette.cpuSystem, values: model.history("cpu.system")),
                        ],
                        accessibilityLabel: "CPU history, \(Fmt.percent(cpu?.userUtilization)) user, \(Fmt.percent(cpu?.systemUtilization)) system"
                    )
                    .frame(height: 140)
                }

                DetailSection(title: "Details") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Utilization", value: Fmt.percent(cpu?.totalUtilization), isUnavailable: cpu?.totalUtilization == nil)
                        MetricCard(label: "User", value: Fmt.percent(cpu?.userUtilization), isUnavailable: cpu?.userUtilization == nil)
                        MetricCard(label: "System", value: Fmt.percent(cpu?.systemUtilization), isUnavailable: cpu?.systemUtilization == nil)
                        MetricCard(label: "Processes", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Threads", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Uptime", value: Fmt.uptime(cpu?.uptime), isUnavailable: cpu?.uptime == nil)
                    }
                }

                if let perCore = cpu?.perCoreUtilization, !perCore.isEmpty {
                    DetailSection(title: "Per-Core Utilization") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 8)], spacing: 8) {
                            ForEach(perCore) { core in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Core \(core.id)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    HistoryGraph(
                                        series: [
                                            HistoryGraphSeries(id: "user", color: DomainPalette.cpuUser, values: model.history("cpu.core.\(core.id).user")),
                                            HistoryGraphSeries(id: "system", color: DomainPalette.cpuSystem, values: model.history("cpu.core.\(core.id).system")),
                                        ],
                                        gridLineCount: 0,
                                        accessibilityLabel: "Core \(core.id), \(Fmt.percent(core.totalUtilization))"
                                    )
                                    .frame(height: 36)
                                }
                            }
                        }
                    }
                }

                DetailSection(title: "Static Info") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Logical Processors", value: Fmt.count(cpu?.topology.logicalCoreCount), isUnavailable: cpu?.topology.logicalCoreCount == nil)
                        MetricCard(label: "Physical Cores", value: Fmt.count(cpu?.topology.physicalCoreCount), isUnavailable: cpu?.topology.physicalCoreCount == nil)
                        MetricCard(label: "Performance Cores", value: Fmt.count(cpu?.topology.performanceCoreCount), isUnavailable: cpu?.topology.performanceCoreCount == nil)
                        MetricCard(label: "Efficiency Cores", value: Fmt.count(cpu?.topology.efficiencyCoreCount), isUnavailable: cpu?.topology.efficiencyCoreCount == nil)
                        MetricCard(label: "Sockets", value: Fmt.count(cpu?.topology.packageCount), isUnavailable: cpu?.topology.packageCount == nil)
                        MetricCard(label: "Base Speed", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "L1/L2/L3 Cache", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Virtualization", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Frequency Governor", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Power Preference", value: "Unavailable", isUnavailable: true)
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Memory detail

private struct MemoryDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var memory: MemorySnapshot? { model.latest?.memory }

    private var usedPercent: Double? {
        guard let memory, let total = memory.totalBytes, total > 0, let used = memory.usedBytes else { return nil }
        return Double(used) / Double(total) * 100
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    DetailHeadline(
                        systemImage: "memorychip",
                        color: DomainPalette.memoryPressureNormal,
                        title: "Memory",
                        value: Fmt.percent(usedPercent)
                    )
                    Spacer()
                    pressureBadge
                }

                if let memory, let total = memory.totalBytes, total > 0 {
                    DetailSection(title: "Composition") {
                        compositionBar(memory: memory, total: total)
                    }
                }

                DetailSection(title: "Utilization") {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "used", color: DomainPalette.memoryPressureNormal, values: model.history("memory.usedPercent"))],
                        accessibilityLabel: "Memory utilization, \(Fmt.percent(usedPercent))"
                    )
                    .frame(height: 140)
                }

                DetailSection(title: "Usage") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "In Use", value: Fmt.bytes(memory?.usedBytes), isUnavailable: memory?.usedBytes == nil)
                        MetricCard(label: "Available", value: Fmt.bytes(memory?.availableBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Cached Files", value: Fmt.bytes(memory?.cachedBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Active", value: Fmt.bytes(memory?.activeBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Inactive", value: Fmt.bytes(memory?.inactiveBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Wired", value: Fmt.bytes(memory?.wiredBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Compressed", value: Fmt.bytes(memory?.compressedBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Purgeable", value: Fmt.bytes(memory?.purgeableBytes), isUnavailable: memory == nil)
                        MetricCard(label: "Total", value: Fmt.bytes(memory?.totalBytes), isUnavailable: memory?.totalBytes == nil)
                    }
                }

                DetailSection(title: "Swap") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Swap Used", value: Fmt.bytes(memory?.swapUsedBytes), isUnavailable: memory?.swapUsedBytes == nil)
                        MetricCard(label: "Swap Available", value: Fmt.bytes(memory?.swapFreeBytes), isUnavailable: memory?.swapFreeBytes == nil)
                        MetricCard(label: "Swap Total", value: Fmt.bytes(memory?.swapTotalBytes), isUnavailable: memory?.swapTotalBytes == nil)
                    }
                }

                DetailSection(title: "Hardware") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Speed", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Slots", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Form Factor", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Type", value: "Unavailable", isUnavailable: true)
                    }
                }
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private var pressureBadge: some View {
        if let pressure = memory?.pressureLevel {
            Text(pressureLabel(pressure))
                .font(.caption)
                .fontWeight(.semibold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(pressureColor(pressure).opacity(0.15), in: Capsule())
                .foregroundStyle(pressureColor(pressure))
        }
    }

    private func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: DomainPalette.memoryPressureNormal
        case .warning: DomainPalette.memoryPressureWarning
        case .critical: DomainPalette.memoryPressureCritical
        }
    }

    private func compositionBar(memory: MemorySnapshot, total: UInt64) -> some View {
        let totalD = Double(total)
        return CapacityBar(
            segments: [
                CapacityBarSegment(id: "active", fraction: Double(memory.activeBytes) / totalD, color: DomainPalette.memoryPressureNormal, label: "Active"),
                CapacityBarSegment(id: "wired", fraction: Double(memory.wiredBytes) / totalD, color: DomainPalette.memorySwap, label: "Wired"),
                CapacityBarSegment(id: "compressed", fraction: Double(memory.compressedBytes) / totalD, color: DomainPalette.memoryPressureWarning, label: "Compressed"),
                CapacityBarSegment(id: "free", fraction: Double(memory.freeBytes) / totalD, color: Color(nsColor: .systemGray), label: "Free"),
            ],
            thickness: 14,
            accessibilityLabel: "Memory composition"
        )
    }
}

// MARK: - GPU detail

private struct GPUDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var gpu: GPUSnapshot? { model.latest?.gpu }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "square.stack.3d.up.fill",
                    color: DomainPalette.gpu,
                    title: gpu?.deviceClassName ?? "GPU",
                    value: Fmt.percent(gpu?.utilizationPercent)
                )

                Picker("GPU Metrics", selection: $model.selectedGPUTab) {
                    ForEach(GPUEngineTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)

                switch model.selectedGPUTab {
                case .overall: overallTab
                case .engines: enginesTab
                }
            }
            .padding(16)
        }
    }

    private var overallTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailSection(title: "Utilization") {
                HistoryGraph(
                    series: [HistoryGraphSeries(id: "utilization", color: DomainPalette.gpu, values: model.history("gpu.utilization"))],
                    accessibilityLabel: "GPU utilization, \(Fmt.percent(gpu?.utilizationPercent))"
                )
                .frame(height: 140)
            }

            DetailSection(title: "Details") {
                LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                    MetricCard(label: "Utilization", value: Fmt.percent(gpu?.utilizationPercent), isUnavailable: gpu?.utilizationPercent == nil)
                    MetricCard(label: "Clock", value: "Unavailable", isUnavailable: true)
                    MetricCard(label: "Power Draw", value: "Unavailable", isUnavailable: true)
                    MetricCard(label: "Memory In Use", value: Fmt.bytes(gpu?.vramUsedBytes), isUnavailable: gpu?.vramUsedBytes == nil)
                    MetricCard(label: "Memory Allocated", value: Fmt.bytes(gpu?.vramAllocatedBytes), isUnavailable: gpu?.vramAllocatedBytes == nil)
                    MetricCard(label: "VRAM Total", value: Fmt.bytes(gpu?.vramTotalBytes), isUnavailable: gpu?.vramTotalBytes == nil)
                    MetricCard(label: "Temperature", value: Fmt.celsius(gpu?.temperatureCelsius), isUnavailable: gpu?.temperatureCelsius == nil)
                    MetricCard(label: "Metal", value: "Unavailable", isUnavailable: true)
                    MetricCard(label: "OpenGL", value: "Unavailable", isUnavailable: true)
                    MetricCard(label: "Vulkan", value: "Unavailable", isUnavailable: true)
                }
            }
        }
    }

    private var enginesTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            DetailSection(title: "Renderer") {
                VStack(alignment: .leading, spacing: 10) {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "renderer", color: DomainPalette.gpu, values: model.history("gpu.renderer"))],
                        accessibilityLabel: "Renderer utilization, \(Fmt.percent(gpu?.rendererUtilizationPercent))"
                    )
                    .frame(height: 100)
                    MetricCard(label: "Renderer Utilization", value: Fmt.percent(gpu?.rendererUtilizationPercent), isUnavailable: gpu?.rendererUtilizationPercent == nil)
                }
            }
            DetailSection(title: "Tiler") {
                VStack(alignment: .leading, spacing: 10) {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "tiler", color: DomainPalette.gpuSecondary, values: model.history("gpu.tiler"))],
                        accessibilityLabel: "Tiler utilization, \(Fmt.percent(gpu?.tilerUtilizationPercent))"
                    )
                    .frame(height: 100)
                    MetricCard(label: "Tiler Utilization", value: Fmt.percent(gpu?.tilerUtilizationPercent), isUnavailable: gpu?.tilerUtilizationPercent == nil)
                }
            }
        }
    }
}

// MARK: - NPU detail

private struct NPUDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var npu: NPUSnapshot? { model.latest?.npu }

    private var stateText: String {
        guard let isActive = npu?.isActive else { return "Unavailable" }
        return isActive ? "Active (blocks powered)" : "Idle"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "brain",
                    color: DomainPalette.npu,
                    title: "Neural Engine",
                    value: npu?.devicePresent == true ? stateText : "Not Present"
                )

                if npu?.devicePresent == true {
                    DetailSection(title: "Activity") {
                        HistoryGraph(
                            series: [HistoryGraphSeries(id: "active", color: DomainPalette.npu, values: model.history("npu.active"))],
                            accessibilityLabel: "Neural Engine activity, \(stateText)"
                        )
                        .frame(height: 100)
                    }
                }

                DetailSection(title: "Apple Neural Engine") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Device", value: npu?.deviceName ?? "Unavailable", isUnavailable: npu?.deviceName == nil)
                        MetricCard(label: "Compatible", value: npu?.compatibleString ?? "Unavailable", isUnavailable: npu?.compatibleString == nil)
                        MetricCard(label: "State", value: stateText, isUnavailable: npu?.isActive == nil)
                        MetricCard(label: "Energy Delta (raw)", value: npu?.energyDeltaRaw.map { "\($0)" } ?? "Unavailable", isUnavailable: npu?.energyDeltaRaw == nil)
                    }
                }

                if let reason = npu?.unavailableReason {
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Disk detail

private struct DiskDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var disk: DiskSnapshot? { model.latest?.disk }

    private var headlineUnit: DiskUnitSnapshot? {
        disk?.units.first { $0.isInternal == true } ?? disk?.units.first
    }

    private var systemVolume: DiskCapacity? {
        disk?.volumes.first { $0.isSystemVolume } ?? disk?.volumes.first
    }

    private var systemDiskLabel: String {
        guard let isInternal = headlineUnit?.isInternal else { return "Unavailable" }
        return isInternal ? "Yes" : "No"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "internaldrive",
                    color: DomainPalette.diskRead,
                    title: headlineUnit?.mediaName ?? "Disks",
                    value: Fmt.percent(disk?.activePercent)
                )

                DetailSection(title: "Activity") {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "active", color: DomainPalette.diskRead, values: model.history("disk.active"))],
                        accessibilityLabel: "Disk percent active, \(Fmt.percent(disk?.activePercent))"
                    )
                    .frame(height: 100)
                }

                DetailSection(title: "Transfer Rate") {
                    HistoryGraph(
                        series: [
                            HistoryGraphSeries(id: "read", color: DomainPalette.diskRead, values: model.history("disk.read")),
                            HistoryGraphSeries(id: "write", color: DomainPalette.diskWrite, values: model.history("disk.write")),
                        ],
                        valueRange: model.dynamicRange(for: ["disk.read", "disk.write"]),
                        accessibilityLabel: "Disk transfer rate"
                    )
                    .frame(height: 100)
                }

                DetailSection(title: "Details") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Read Speed", value: Fmt.bytesPerSecond(disk?.readBytesPerSecond), isUnavailable: disk?.readBytesPerSecond == nil)
                        MetricCard(label: "Write Speed", value: Fmt.bytesPerSecond(disk?.writeBytesPerSecond), isUnavailable: disk?.writeBytesPerSecond == nil)
                        MetricCard(label: "% Active", value: Fmt.percent(disk?.activePercent), isUnavailable: disk?.activePercent == nil)
                        MetricCard(label: "Total Read", value: Fmt.bytes(disk?.totalBytesRead), isUnavailable: disk == nil)
                        MetricCard(label: "Total Written", value: Fmt.bytes(disk?.totalBytesWritten), isUnavailable: disk == nil)
                        MetricCard(label: "Response Time", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "Capacity", value: Fmt.bytes(systemVolume?.totalBytes), isUnavailable: systemVolume?.totalBytes == nil)
                        MetricCard(label: "System Disk", value: systemDiskLabel, isUnavailable: headlineUnit?.isInternal == nil)
                        MetricCard(label: "NVMe Type", value: "Unavailable", isUnavailable: true)
                    }
                }

                Button("Storage Details…") { model.showsStorageDetails = true }
            }
            .padding(16)
        }
        .sheet(isPresented: $model.showsStorageDetails) {
            StorageDetailsSheet(disk: disk)
        }
    }
}

private struct StorageDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let disk: DiskSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Storage Details").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if let disk, !(disk.units.isEmpty && disk.volumes.isEmpty) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if !disk.units.isEmpty {
                            DetailSection(title: "Devices") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(disk.units) { unit in
                                        unitRow(unit)
                                    }
                                }
                            }
                        }
                        if !disk.volumes.isEmpty {
                            DetailSection(title: "Volumes") {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(disk.volumes) { volume in
                                        volumeRow(volume)
                                    }
                                }
                            }
                        }
                    }
                    .padding()
                }
            } else {
                Spacer(minLength: 0)
                Text("No storage devices found.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .frame(width: 460, height: 420)
    }

    private func unitRow(_ unit: DiskUnitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(unit.mediaName ?? unit.id).fontWeight(.medium)
            Text("\(unit.id) · Read \(Fmt.bytesPerSecond(unit.readBytesPerSecond)) · Write \(Fmt.bytesPerSecond(unit.writeBytesPerSecond))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func volumeRow(_ volume: DiskCapacity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(volume.volumeName ?? volume.id).fontWeight(.medium)
            Text("\(Fmt.bytes(volume.usedBytes)) of \(Fmt.bytes(volume.totalBytes)) used")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Network detail

private struct NetworkDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var network: NetworkSnapshot? { model.latest?.network }

    private var combinedText: String {
        guard let receive = network?.receiveBytesPerSecond, let send = network?.sendBytesPerSecond else { return "Unavailable" }
        return Fmt.bytesPerSecond(receive + send)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "network",
                    color: DomainPalette.networkIn,
                    title: "Network",
                    value: combinedText
                )

                DetailSection(title: "Throughput") {
                    HistoryGraph(
                        series: [
                            HistoryGraphSeries(id: "receive", color: DomainPalette.networkIn, values: model.history("network.receive")),
                            HistoryGraphSeries(id: "send", color: DomainPalette.networkOut, values: model.history("network.send")),
                        ],
                        valueRange: model.dynamicRange(for: ["network.receive", "network.send"]),
                        accessibilityLabel: "Network throughput"
                    )
                    .frame(height: 140)
                }

                DetailSection(title: "Details") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Receive", value: Fmt.bytesPerSecond(network?.receiveBytesPerSecond), isUnavailable: network?.receiveBytesPerSecond == nil)
                        MetricCard(label: "Send", value: Fmt.bytesPerSecond(network?.sendBytesPerSecond), isUnavailable: network?.sendBytesPerSecond == nil)
                        MetricCard(label: "Total Received", value: Fmt.bytes(network?.totalBytesReceived), isUnavailable: network == nil)
                        MetricCard(label: "Total Sent", value: Fmt.bytes(network?.totalBytesSent), isUnavailable: network == nil)
                        MetricCard(label: "IPv4 Address", value: "Unavailable", isUnavailable: true)
                        MetricCard(label: "IPv6 Address", value: "Unavailable", isUnavailable: true)
                    }
                }

                if let interfaces = network?.interfaces, !interfaces.isEmpty {
                    DetailSection(title: "Interfaces") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(interfaces) { interface in
                                interfaceRow(interface)
                            }
                        }
                    }
                }

                Button("Connection Details…") { model.showsConnectionDetails = true }
            }
            .padding(16)
        }
        .sheet(isPresented: $model.showsConnectionDetails) {
            ConnectionDetailsSheet(interfaces: network?.interfaces ?? [])
        }
    }

    private func interfaceRow(_ interface: NetworkInterfaceSnapshot) -> some View {
        HStack {
            Text(interface.id)
                .monospacedDigit()
                .frame(width: 60, alignment: .leading)
            Text(interface.isUp ? "Up" : "Down")
                .font(.caption)
                .foregroundStyle(interface.isUp ? StatusPalette.healthy : .secondary)
            if interface.isLoopback {
                Text("Loopback").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text("↓ \(Fmt.bytesPerSecond(interface.receiveBytesPerSecond)) · ↑ \(Fmt.bytesPerSecond(interface.sendBytesPerSecond))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ConnectionDetailsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let interfaces: [NetworkInterfaceSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Connection Details").font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()

            if interfaces.isEmpty {
                Spacer(minLength: 0)
                Text("No network interfaces found.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(interfaces) { interface in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(interface.id).fontWeight(.medium)
                                Text("\(interface.isUp ? "Up" : "Down")\(interface.isLoopback ? " · Loopback" : "") · Sent \(Fmt.bytes(interface.totalBytesSent)) · Received \(Fmt.bytes(interface.totalBytesReceived))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text("IPv4/IPv6: Unavailable")
                                    .font(.caption2)
                                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(width: 460, height: 420)
    }
}

// MARK: - Energy detail

private struct EnergyDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    @Environment(\.historyStore) private var historyStore
    /// This domain's slice of `HistoryStore`'s own separate
    /// `battery_health_log` table (PLAN.md §4 M10's last task) — reloaded
    /// on appear and every `batteryHealthRefreshInterval` while this detail
    /// view stays visible, matching `HistoryPageViewModel`'s own
    /// slow-polling convention for data that isn't part of the live
    /// `Sampler` stream `model` already owns.
    @State private var batteryHealthLog: [HistoryStore.BatteryHealthPoint] = []

    private var energy: EnergySnapshot? { model.latest?.energy }
    private var thermal: ThermalSnapshot? { model.latest?.thermal }

    /// This store dedups on *change*, not on a fixed cadence (see
    /// `HistoryStore.recordBatteryHealthIfChanged`'s doc comment), so
    /// polling much slower than `HistoryPageViewModel.autoRefreshInterval`
    /// is still plenty responsive for a reading that itself only changes
    /// every few days.
    private static let batteryHealthRefreshInterval: TimeInterval = 60

    private var powerSourceText: String {
        guard let source = energy?.powerSource else { return "Unavailable" }
        switch source {
        case .acPower: return "AC Power"
        case .batteryPower: return "Battery Power"
        case .unknown: return "Unknown"
        }
    }

    /// `fullChargeCapacityMAh / designCapacityMAh * 100`, computed straight
    /// off the live snapshot (not the last logged row, which can lag by up
    /// to `batteryHealthRefreshInterval`) — the same formula
    /// `HistoryStore.BatteryHealthPoint.capacityPercent` uses for every
    /// past reading, so the headline figure and the chart's own trailing
    /// point read consistently.
    private var currentCapacityPercent: Double? {
        guard let battery = energy?.battery,
              let designCapacityMAh = battery.designCapacityMAh, designCapacityMAh > 0,
              let fullChargeCapacityMAh = battery.fullChargeCapacityMAh
        else { return nil }
        return Double(fullChargeCapacityMAh) / Double(designCapacityMAh) * 100
    }

    /// Newest-first, capped to a handful of rows — the "log ... over time"
    /// half of this task, shown as plain text rows under the capacity
    /// chart rather than a full `DataTable` (this table is expected to stay
    /// tiny; see `HistoryStore`'s own doc comment on why it dedups on
    /// change).
    private var recentBatteryHealthLog: [HistoryStore.BatteryHealthPoint] {
        Array(batteryHealthLog.suffix(12).reversed())
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "bolt.fill",
                    color: DomainPalette.energy,
                    title: "Energy",
                    value: Fmt.watts(energy?.systemPowerWatts)
                )

                DetailSection(title: "Power Consumption") {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "watts", color: DomainPalette.energy, values: model.history("energy.watts"))],
                        valueRange: model.dynamicRange(for: ["energy.watts"]),
                        accessibilityLabel: "System power draw"
                    )
                    .frame(height: 120)
                }

                DetailSection(title: "Details") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Thermal State", value: thermalPressureLabel(thermal?.thermalPressure ?? .unknown), isUnavailable: thermal?.thermalPressure == nil)
                        MetricCard(label: "Power Mode", value: energy?.isLowPowerModeEnabled == true ? "Low Power Mode" : "Normal", isUnavailable: energy == nil)
                        MetricCard(label: "Power Source", value: powerSourceText, isUnavailable: energy == nil)
                        MetricCard(label: "Battery", value: Fmt.percent(energy?.battery?.percent), isUnavailable: energy?.battery?.percent == nil)
                        MetricCard(label: "Cycle Count", value: Fmt.count(energy?.battery?.cycleCount), isUnavailable: energy?.battery?.cycleCount == nil)
                        MetricCard(label: "Battery Condition", value: energy?.battery?.condition ?? "Unavailable", isUnavailable: energy?.battery?.condition == nil)
                        MetricCard(label: "System Power", value: Fmt.watts(energy?.systemPowerWatts), isUnavailable: energy?.systemPowerWatts == nil)
                        MetricCard(label: "Adapter Power", value: Fmt.watts(energy?.adapterPowerWatts), isUnavailable: energy?.adapterPowerWatts == nil)
                        MetricCard(label: "Battery Power", value: Fmt.watts(energy?.batteryPowerWatts), isUnavailable: energy?.batteryPowerWatts == nil)
                    }
                }

                batteryHealthSection

                DetailSection(title: "Processes With Highest Estimated Energy Demand") {
                    Text("Requires per-process energy accounting, which arrives with the Processes provider (M4).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .task {
            await refreshBatteryHealthLog()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.batteryHealthRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await refreshBatteryHealthLog()
            }
        }
    }

    private func refreshBatteryHealthLog() async {
        guard let historyStore else { return }
        batteryHealthLog = await historyStore.batteryHealthLog()
    }

    // MARK: - Battery health

    /// PLAN.md §4 M10's last task: "log cycle count/condition over time,
    /// capacity chart on Energy page." `nil` on any Mac with no battery
    /// (`energy?.battery == nil`) shows the same honest "no battery" note
    /// every other Energy tile already gives a desktop Mac, rather than an
    /// empty chart implying one exists.
    @ViewBuilder
    private var batteryHealthSection: some View {
        if energy?.battery != nil {
            DetailSection(title: "Battery Health") {
                VStack(alignment: .leading, spacing: 12) {
                    batteryHealthChart
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Capacity (of Design)", value: Fmt.percent(currentCapacityPercent), isUnavailable: currentCapacityPercent == nil)
                        MetricCard(label: "Design Capacity", value: Fmt.milliampHours(energy?.battery?.designCapacityMAh), isUnavailable: energy?.battery?.designCapacityMAh == nil)
                        MetricCard(label: "Full-Charge Capacity", value: Fmt.milliampHours(energy?.battery?.fullChargeCapacityMAh), isUnavailable: energy?.battery?.fullChargeCapacityMAh == nil)
                    }
                    batteryHealthLogList
                }
            }
        } else {
            DetailSection(title: "Battery Health") {
                Text("No battery on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Full-charge capacity as a percent of design capacity, plotted across
    /// every logged `battery_health_log` row — this task's "capacity chart
    /// on Energy page." A flat trace near 100% early in a battery's life is
    /// the expected, uninteresting case; what this chart is for is the slow
    /// downward drift as cycles accumulate. Needs at least two logged
    /// points with a readable ratio to draw a line at all
    /// (`HistoryGraph.drawRun` skips single-point runs the same honest way
    /// every other chart in this app does), so a fresh install shows the
    /// placeholder below until enough history has accumulated.
    @ViewBuilder
    private var batteryHealthChart: some View {
        let capacityValues = batteryHealthLog.map(\.capacityPercent)
        if capacityValues.compactMap({ $0 }).count > 1 {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "capacity", color: DomainPalette.energyBattery, values: capacityValues)],
                valueRange: 0...100,
                accessibilityLabel: "Battery capacity trend, currently \(Fmt.percent(currentCapacityPercent)) of design capacity"
            )
            .frame(height: 100)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("Capacity trend builds up over time as this app logs cycle count and condition changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        }
    }

    /// "Log cycle count/condition over time" as plain rows — most recent
    /// first, so the newest change (what a user checking this page
    /// actually wants to know) is always the top row.
    @ViewBuilder
    private var batteryHealthLogList: some View {
        if recentBatteryHealthLog.isEmpty {
            Text("No cycle count or condition changes logged yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(recentBatteryHealthLog.enumerated()), id: \.element.timestamp) { index, point in
                    if index > 0 {
                        Divider()
                    }
                    BatteryHealthLogRow(point: point)
                }
            }
            .padding(.top, 4)
        }
    }
}

/// One `EnergyDetailView.batteryHealthLogList` row: when a change was
/// logged, the cycle count and condition at that moment, and the capacity
/// ratio computed from the same row — this file's equivalent of
/// `HistoryPage`'s own `HistoryStatCard`, laid out as a table row instead
/// of a grid cell since every field here is a short scalar.
private struct BatteryHealthLogRow: View {
    let point: HistoryStore.BatteryHealthPoint

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.dateFormatter.string(from: point.timestamp))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(point.cycleCount.map { "Cycle \($0)" } ?? "Unavailable")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(point.cycleCount == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .frame(width: 100, alignment: .leading)
            Text(point.condition ?? "Unavailable")
                .font(.caption)
                .foregroundStyle(point.condition == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.percent(point.capacityPercent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Thermal detail

private struct ThermalDetailView: View {
    @ObservedObject var model: PerformanceViewModel
    private var thermal: ThermalSnapshot? { model.latest?.thermal }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                DetailHeadline(
                    systemImage: "thermometer",
                    color: DomainPalette.thermal,
                    title: "Thermals",
                    value: Fmt.celsius(thermal?.hotspotCelsius)
                )

                DetailSection(title: "Hotspot") {
                    HistoryGraph(
                        series: [HistoryGraphSeries(id: "hotspot", color: DomainPalette.thermal, values: model.history("thermal.hotspot"))],
                        valueRange: 0...110,
                        accessibilityLabel: "Hotspot temperature, \(Fmt.celsius(thermal?.hotspotCelsius))"
                    )
                    .frame(height: 120)
                }

                DetailSection(title: "Details") {
                    LazyVGrid(columns: statGridColumns, alignment: .leading, spacing: 12) {
                        MetricCard(label: "Hotspot", value: Fmt.celsius(thermal?.hotspotCelsius), isUnavailable: thermal?.hotspotCelsius == nil)
                        MetricCard(label: "Thermal Pressure", value: thermalPressureLabel(thermal?.thermalPressure ?? .unknown), isUnavailable: thermal?.thermalPressure == nil)
                    }
                }

                if let sensors = thermal?.dieSensors, !sensors.isEmpty {
                    DetailSection(title: "Sensors") {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                            ForEach(Array(sensors.enumerated()), id: \.offset) { index, sensor in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Die \(index + 1)")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    HistoryGraph(
                                        series: [HistoryGraphSeries(id: sensor.key, color: DomainPalette.thermal, values: model.history("thermal.sensor.\(sensor.key)"))],
                                        valueRange: 0...110,
                                        gridLineCount: 0,
                                        accessibilityLabel: "Die \(index + 1), \(Fmt.celsius(sensor.celsius))"
                                    )
                                    .frame(height: 36)
                                    Text(Fmt.celsius(sensor.celsius))
                                        .font(.caption2)
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Text("No individual sensor readings available.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
    }
}

#Preview {
    PerformancePage()
        .frame(width: 1100, height: 760)
}
