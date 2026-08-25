import SwiftUI

/// Summary dashboard — PLAN.md §1.1 "Summary (dashboard)" / §4 M3.
///
/// M3's first task fills in the left-hand compact CPU/Temp/GPU capacity
/// bars — this app's native restyle of [name removed]'s vertical LED meter towers
/// ("four vertical LED bar meters — CPU %, Clock (Auto), Temp °C, GPU % —
/// with values below", PLAN.md §1.1). Clock is dropped: no provider
/// exposes a live CPU clock speed reading (`CPUProvider`'s `CPUTopology`
/// has no such field, and PLAN.md's own per-task title only calls for
/// "CPU/Temp/GPU"), and honest degradation means not shipping a meter
/// that could only ever read "Unavailable". `CompactMeterTower` below is a
/// thin, vertical-orientation wrapper around `Components/CapacityBar.swift`
/// — the same component doc comment already calls out as the intended
/// home for "Summary's compact CPU/Temp/GPU meters".
///
/// This is the second page (after `PerformancePage`) to own a live
/// `Sampler` — `SummaryViewModel` below follows that same file's
/// start-in-`onAppear`/stop-in-`onDisappear` pattern for the same reason:
/// a monitor shouldn't keep sampling while its own page isn't visible
/// (PLAN.md §2's "lowest idle overhead"). This task adds the CPU Overview
/// card (`cpuOverviewCard`) in the "Center" column, which is why
/// `SummaryViewModel` now also keeps a small `seriesHistory` alongside
/// `latest` — the same "one dotted-id ring buffer per plotted series"
/// pattern `PerformanceViewModel` uses, trimmed to just the three series
/// this card's tabs plot. Later M3 tasks (top CPU processes table, memory
/// band + bottom tile grid) extend this same view model and page body in
/// place.
struct SummaryPage: View {
    @StateObject private var model = SummaryViewModel()
    /// `topProcessesCard`'s table sort — starts CPU % descending, matching
    /// PLAN.md §1.1's own "Top CPU processes" ordering; the table stays
    /// user-sortable (click any header) the same as every other
    /// `DataTable` in the app.
    @State private var topProcessesSort: DataTableSort? = DataTableSort(columnID: "cpu", ascending: false)
    /// Shared height for the top row's three cards — see the `HStack`'s
    /// own comment for why a literal height, not `maxHeight: .infinity`,
    /// is what actually keeps them aligned. `topProcessesCard` is this
    /// row's tallest natural content, not `cpuOverviewCard` (an earlier,
    /// wrong assumption here that undershot by ~18pt and let that card's
    /// background silently overflow past its frame — `.frame(height:)`
    /// proposes a height but does not itself clip a child that renders
    /// taller, so the shortfall bled downward into `memoryUtilizationBand`
    /// instead of registering as a layout error): `SummaryCard`'s 14pt
    /// top/bottom padding(28) + title(~14) + its own 10pt spacing + the
    /// caption row(~14) + 8pt spacing + the embedded `DataTable`'s own
    /// explicit `.frame(height: 264)` ≈ 338, plus headroom for Dynamic
    /// Type/locale variance. `.clipped()` on all three cards below is the
    /// actual hard guarantee — this constant only has to be *generous*,
    /// not pixel-perfect.
    private static let topRowHeight: CGFloat = 352

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    // A literal shared `.frame(height:)` (not
                    // `maxHeight: .infinity`) on each card — this row sits
                    // inside `ScrollView`'s effectively unbounded height,
                    // where `maxHeight: .infinity` has no real ceiling to
                    // stretch against. `.clipped()` right after it is not
                    // optional decoration: `.frame(height:)` only
                    // *proposes* that height to the card — a child that
                    // needs more (as `topProcessesCard`'s title + caption +
                    // its embedded `List`'s own fixed height did once
                    // `topRowHeight` was set too low) still renders at its
                    // full natural size, unclipped, silently overflowing
                    // past the frame's reported bounds and into whatever
                    // sits below in this `VStack` — exactly the "Top CPU
                    // Processes glued to Memory Utilization" bug this pair
                    // of modifiers fixes for good, independent of whether
                    // `topRowHeight` is ever slightly off again. Shorter
                    // content in `meterTowersCard` top-aligns with room to
                    // spare below; `topProcessesCard`'s `List` shows as
                    // many rows as fit and scrolls for the rest — which
                    // the "Top 12 of N" caption already implies is a
                    // capped, scrollable view, not a guarantee all 12 rows
                    // are visible without scrolling.
                    meterTowersCard
                        .frame(height: Self.topRowHeight, alignment: .top)
                        .clipped()
                    cpuOverviewCard
                        .frame(height: Self.topRowHeight, alignment: .top)
                        .clipped()
                    topProcessesCard
                        .frame(height: Self.topRowHeight, alignment: .top)
                        .clipped()
                }
                memoryUtilizationBand
                bottomTileGrid
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
        // PLAN.md §4 M10's fifth task: a CSV/JSON export for
        // `topProcessesCard`'s own table, plus the one-click system
        // snapshot report — this is the one page whose `SummaryViewModel`
        // already keeps a full cross-domain `Snapshot` (`model.latest`)
        // alongside the top-processes list `SnapshotReportButton` also
        // folds in, rather than a single domain the way every other page
        // does (see `Components/Exporter.swift`'s own doc comment).
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.topProcessColumns, rows: model.topProcesses, suggestedName: "Top CPU Processes")
            }
            ToolbarItem(placement: .primaryAction) {
                SnapshotReportButton(
                    snapshot: model.latest,
                    topProcesses: model.topProcesses,
                    liveProcessCount: model.processCount
                )
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Meter towers

    private var cpu: CPUSnapshot? { model.latest?.cpu }
    private var thermal: ThermalSnapshot? { model.latest?.thermal }
    private var gpu: GPUSnapshot? { model.latest?.gpu }

    private var meterTowersCard: some View {
        SummaryCard {
            // `maxHeight: .infinity` here is what lets the towers below
            // actually use the extra room `SummaryCard` now stretches to
            // (matching the row's tallest card, `topProcessesCard`) —
            // without it, this `HStack` just hugs its natural (short)
            // content and top-aligns inside the taller card, leaving the
            // same dead space below the bars that `SummaryCard`'s own fix
            // solved for the card's background.
            HStack(alignment: .top, spacing: 24) {
                CompactMeterTower(
                    title: "CPU",
                    systemImage: "cpu",
                    color: DomainPalette.cpuUser,
                    value: cpu?.totalUtilization ?? 0,
                    total: 100,
                    valueLabel: Fmt.percent(cpu?.totalUtilization),
                    isUnavailable: cpu?.totalUtilization == nil,
                    accessibilityLabel: "CPU usage"
                )
                CompactMeterTower(
                    title: "Temp",
                    systemImage: "thermometer",
                    color: DomainPalette.thermal,
                    value: thermal?.hotspotCelsius ?? 0,
                    total: Self.temperatureCeilingCelsius,
                    valueLabel: Fmt.celsius(thermal?.hotspotCelsius),
                    isUnavailable: thermal?.hotspotCelsius == nil,
                    accessibilityLabel: "Hotspot temperature"
                )
                CompactMeterTower(
                    title: "GPU",
                    systemImage: "square.stack.3d.up.fill",
                    color: DomainPalette.gpu,
                    value: gpu?.utilizationPercent ?? 0,
                    total: 100,
                    valueLabel: Fmt.percent(gpu?.utilizationPercent),
                    isUnavailable: gpu?.utilizationPercent == nil,
                    accessibilityLabel: "GPU usage"
                )
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Upper bound the Temp tower's fill fraction is drawn against. Matches
    /// `ThermalDetailView`'s own `0...110` history-graph range (Performance
    /// page) — a shared, plausible "hot" ceiling for Apple silicon hotspot
    /// readings rather than a value invented fresh for this tower.
    private static let temperatureCeilingCelsius: Double = 110

    // MARK: - CPU Overview card

    /// PLAN.md §1.1 Summary "Center: CPU Overview card — tabs for
    /// Utilization / Temperature / Kernel, big % readout, multi-series
    /// scrolling graph ... '14 logical processors', 'Speed Apple
    /// managed'". Rather than [name removed]'s one fixed three-series/dual-axis
    /// graph, a segmented `Picker` — the same pattern
    /// `PerformancePage`'s GPU detail uses for its Overall/Engines tabs —
    /// switches both the big readout and the single-series graph beneath
    /// it between the three metrics; PLAN.md §2 keeps this app's *subtle*
    /// per-domain color identity rather than [name removed]'s overlaid multi-trace
    /// instrument panel, and one series at a time reads more clearly on a
    /// native, non-glowing graph than three overlapping traces on
    /// mismatched axes would.
    private var cpuOverviewCard: some View {
        SummaryCard(title: "CPU Overview") {
            VStack(alignment: .leading, spacing: 12) {
                Picker("CPU Overview Metric", selection: $model.selectedCPUOverviewTab) {
                    ForEach(CPUOverviewTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Text(cpuOverviewReadout)
                    .font(.system(size: 32, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(cpuOverviewValue == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)

                HistoryGraph(
                    series: [
                        HistoryGraphSeries(
                            id: model.selectedCPUOverviewTab.rawValue,
                            color: model.selectedCPUOverviewTab.color,
                            values: model.history(cpuOverviewSeriesID)
                        )
                    ],
                    valueRange: cpuOverviewRange,
                    accessibilityLabel: "CPU \(model.selectedCPUOverviewTab.title) history, \(cpuOverviewReadout)"
                )
                .frame(height: 120)

                HStack {
                    Text(logicalProcessorsCaption)
                    Spacer(minLength: 8)
                    Text(speedCaption)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
    }

    /// Which series id (`SummaryViewModel.seriesHistory`'s key) the
    /// current tab plots.
    private var cpuOverviewSeriesID: String {
        switch model.selectedCPUOverviewTab {
        case .utilization: return "cpu.total"
        case .temperature: return "thermal.hotspot"
        case .kernel: return "cpu.system"
        }
    }

    /// The current tab's latest reading — `nil` when this tick's backing
    /// domain (`cpu` or `thermal`) is itself `nil`, or when that domain
    /// sampled but this particular field couldn't be read (PLAN.md's
    /// "honest degradation" applies inside a non-`nil` snapshot too, see
    /// `Snapshot`'s doc comment).
    private var cpuOverviewValue: Double? {
        switch model.selectedCPUOverviewTab {
        case .utilization: return cpu?.totalUtilization
        case .temperature: return thermal?.hotspotCelsius
        case .kernel: return cpu?.systemUtilization
        }
    }

    /// Graph value range per tab — `0...100` for the two percentage tabs,
    /// matching `HistoryGraph`'s own default range, and the same
    /// `0...110`°C "hot" ceiling `temperatureCeilingCelsius` already uses
    /// for the Temp meter tower above, kept as one shared constant rather
    /// than a second invented value.
    private var cpuOverviewRange: ClosedRange<Double> {
        switch model.selectedCPUOverviewTab {
        case .utilization, .kernel: return 0...100
        case .temperature: return 0...Self.temperatureCeilingCelsius
        }
    }

    private var cpuOverviewReadout: String {
        switch model.selectedCPUOverviewTab {
        case .utilization, .kernel: return Fmt.percent(cpuOverviewValue)
        case .temperature: return Fmt.celsius(cpuOverviewValue)
        }
    }

    /// PLAN.md's "'14 logical processors'" caption.
    private var logicalProcessorsCaption: String {
        guard let count = cpu?.topology.logicalCoreCount else { return "Logical processors: Unavailable" }
        return "\(count) logical processor\(count == 1 ? "" : "s")"
    }

    /// PLAN.md's "'Speed Apple managed'" caption. No provider exposes a
    /// live CPU clock speed reading — `CompactMeterTower`'s doc comment
    /// above explains why Clock was dropped from the meter towers for the
    /// same reason — so rather than fabricate a number this reports the
    /// one honest thing this app *does* know: whether `CPUTopology` found
    /// Apple silicon's P/E core split (`performanceCoreCount`). Every Mac
    /// that reports one is a Mac where the OS, not a fixed multiplier,
    /// manages clock speed; Intel Macs, where that sysctl doesn't exist,
    /// get an honest "Unavailable" instead of the same claim.
    private var speedCaption: String {
        guard let cpu else { return "Speed: Unavailable" }
        return cpu.topology.performanceCoreCount != nil ? "Speed: Apple-managed" : "Speed: Unavailable"
    }

    // MARK: - Top CPU processes

    /// PLAN.md §1.1 Summary "Right: Top CPU processes table (PID, Name,
    /// CPU, GPU, Memory) — top 12 of N, rows tinted by usage". Backed by
    /// this file's own `TopProcessesProvider` (see that type's doc
    /// comment for why it's a small, Summary-only slice rather than M4's
    /// full `ProcessProvider`) via `model.topProcesses`, already limited
    /// to the top 12 by CPU % and re-sortable by any column through the
    /// same `DataTable` every other list page uses. "Rows tinted by
    /// usage" is restyled per PLAN.md §2 as a `CapacityBar.statusColor`
    /// tint on the CPU % cell's text — this app's native, non-neon
    /// stand-in for [name removed]'s glowing row highlight, reusing the same
    /// healthy/warning/critical thresholds every other status-tinted
    /// reading in the app already uses rather than inventing a one-off
    /// color rule just for this table.
    private var topProcessesCard: some View {
        SummaryCard(title: "Top CPU Processes") {
            VStack(alignment: .leading, spacing: 8) {
                Text(topProcessesCaption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                DataTable(
                    columns: Self.topProcessColumns,
                    rows: model.topProcesses,
                    sort: $topProcessesSort,
                    rowHeight: 18,
                    emptyMessage: topProcessesEmptyMessage
                )
                .frame(height: 264)
            }
        }
        .frame(width: 380, alignment: .leading)
    }

    /// "Top 12 of N" per PLAN.md §1.1, or an honest degraded/loading
    /// message in place of a guessed count.
    private var topProcessesCaption: String {
        if let reason = model.topProcessesUnavailableReason {
            return "Unavailable — \(reason)"
        }
        guard model.processCount > 0 else { return "Gathering process data…" }
        return "Top \(model.topProcesses.count) of \(model.processCount)"
    }

    private var topProcessesEmptyMessage: String {
        model.topProcessesUnavailableReason == nil ? "Gathering process data…" : "Process data unavailable."
    }

    /// Columns for `topProcessesCard`'s table — PLAN.md's own "PID, Name,
    /// CPU, GPU, Memory" order. `static` (shared across every
    /// `SummaryPage` instance) since the column list itself never
    /// changes, matching `DataTablePreviewColumns`' own file-scope
    /// convention in `DataTable.swift`.
    private static let topProcessColumns: [DataTableColumn<TopProcessReading>] = [
        DataTableColumn(id: "name", title: "Name", value: { $0.name ?? "" }) { row in
            Text(row.name ?? "Unavailable")
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(row.name == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
        },
        DataTableColumn(id: "pid", title: "PID", width: 46, alignment: .trailing, value: { $0.pid }) { row in
            Text("\(row.pid)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        },
        DataTableColumn(id: "cpu", title: "CPU %", width: 58, alignment: .trailing, value: { $0.cpuPercent ?? -1 }, exportValue: { Fmt.percentPrecise($0.cpuPercent) }) { row in
            Text(Fmt.percentPrecise(row.cpuPercent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(topProcessCPUColor(row.cpuPercent))
        },
        DataTableColumn(id: "gpu", title: "GPU", width: 46, alignment: .trailing, value: { $0.gpuPercent ?? -1 }, exportValue: { Fmt.percentPrecise($0.gpuPercent) }) { row in
            Text(Fmt.percentPrecise(row.gpuPercent))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
        },
        DataTableColumn(id: "memory", title: "Memory", width: 72, alignment: .trailing, value: { $0.memoryBytes ?? 0 }, exportValue: { Fmt.bytes($0.memoryBytes) }) { row in
            Text(Fmt.bytes(row.memoryBytes))
                .font(.caption)
                .monospacedDigit()
        },
    ]

    /// The CPU % cell's usage tint — `StatusPalette`'s healthy/warning/
    /// critical progression via `CapacityBar.statusColor`, or the neutral
    /// unavailable tone for a `nil` reading (a pid's first tick). Free
    /// function rather than a method so it's usable from the `static`
    /// column closures above, which can't capture `self`.
    private static func topProcessCPUColor(_ cpuPercent: Double?) -> Color {
        guard let cpuPercent, cpuPercent.isFinite else { return StatusPalette.unavailable }
        // Clamped to 0...1: a process busy across several cores can read
        // well past 100%, which should still read as "critical", not spill
        // past `statusColor`'s own 0...1 contract.
        let fraction = min(max(cpuPercent / 100, 0), 1)
        return CapacityBar.statusColor(forFraction: fraction, warningAt: 0.3, criticalAt: 0.7)
    }

    // MARK: - Memory Utilization band

    private var memory: MemorySnapshot? { model.latest?.memory }

    /// `memory.usedBytes / memory.totalBytes * 100` — the band's headline
    /// percentage, and the same value `SummaryViewModel.ingest(_:)` plots
    /// as the `"memory.usedPercent"` series below. `nil` whenever either
    /// input is `nil`, matching `PerformancePage.swift`'s own
    /// `MemoryDetailView.usedPercent` — the Performance page's Memory
    /// detail is this band's own model, PLAN.md's "composition/utilization
    /// graph" shape reused at Summary scale.
    private var memoryUsedPercent: Double? {
        guard let memory, let total = memory.totalBytes, total > 0, let used = memory.usedBytes else { return nil }
        return Double(used) / Double(total) * 100
    }

    /// PLAN.md §1.1 Summary's "Memory Utilization full-width band graph
    /// with total/available/cached/swap readouts" — this M3 task's
    /// namesake. A wide card spanning the page below the three-column row
    /// above, pairing the same Active/Wired/Compressed/Free composition
    /// bar `MemoryDetailView` draws on the Performance page with a
    /// scrolling utilization history and the four readouts PLAN.md's own
    /// text names.
    private var memoryUtilizationBand: some View {
        SummaryCard(title: "Memory Utilization") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(Fmt.percent(memoryUsedPercent))
                        .font(.system(size: 28, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(memoryUsedPercent == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                    if let pressureLevel = memory?.pressureLevel {
                        memoryPressureBadge(pressureLevel)
                    }
                    Spacer(minLength: 0)
                }

                if let memory, let total = memory.totalBytes, total > 0 {
                    memoryCompositionBar(memory: memory, total: total)
                } else {
                    CapacityBar(
                        value: 0,
                        color: DomainPalette.memoryPressureNormal,
                        thickness: 14,
                        isUnavailable: true,
                        accessibilityLabel: "Memory composition"
                    )
                }

                HistoryGraph(
                    series: [
                        HistoryGraphSeries(id: "memory.usedPercent", color: DomainPalette.memoryPressureNormal, values: model.history("memory.usedPercent")),
                    ],
                    accessibilityLabel: "Memory utilization history, \(Fmt.percent(memoryUsedPercent))"
                )
                .frame(height: 90)

                HStack(spacing: 24) {
                    MemoryReadout(label: "Total", value: Fmt.bytes(memory?.totalBytes))
                    MemoryReadout(label: "Available", value: Fmt.bytes(memory?.availableBytes))
                    MemoryReadout(label: "Cached", value: Fmt.bytes(memory?.cachedBytes))
                    MemoryReadout(label: "Swap Used", value: Fmt.bytes(memory?.swapUsedBytes))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The same Active/Wired/Compressed/Free four-segment breakdown
    /// `MemoryDetailView.compositionBar(memory:total:)` draws on the
    /// Performance page (`PerformancePage.swift`) — kept as its own small
    /// copy here rather than shared, since that method is private to that
    /// file and this is the only other call site so far.
    private func memoryCompositionBar(memory: MemorySnapshot, total: UInt64) -> some View {
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

    /// Small pill mirroring `MemoryDetailView`'s own pressure badge on the
    /// Performance page — same three `MemoryPressureLevel` colors, kept as
    /// a local copy for the same "that file's helper is private" reason as
    /// `memoryCompositionBar` above.
    private func memoryPressureBadge(_ level: MemoryPressureLevel) -> some View {
        let (label, color): (String, Color) = {
            switch level {
            case .normal: return ("Normal", DomainPalette.memoryPressureNormal)
            case .warning: return ("Warning", DomainPalette.memoryPressureWarning)
            case .critical: return ("Critical", DomainPalette.memoryPressureCritical)
            }
        }()
        return Text(label)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    // MARK: - Bottom tile grid

    private var disk: DiskSnapshot? { model.latest?.disk }
    private var network: NetworkSnapshot? { model.latest?.network }
    private var energy: EnergySnapshot? { model.latest?.energy }
    private var npu: NPUSnapshot? { model.latest?.npu }

    private static let tileGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// PLAN.md §1.1 Summary's "bottom tile grid of mini LED-bar cards:
    /// Disks (R/W speed, % active), Network (S/R rate), Energy (watts,
    /// thermal/power state), GPU 0 (model, %), NPU 0 (status), Thermals
    /// (°C)" — this M3 task's other namesake, six static `StatTile`s in
    /// PLAN.md's own order (PLAN.md §2's restyle drops the "LED-bar" glow
    /// but keeps one tile per domain, matching `PerformancePage.swift`'s
    /// own rail tiles for the same six domains, minus that rail's
    /// selection/sparkline behavior — `StatTile`'s own doc comment
    /// documents this grid as the *static*, `CapacityBar`-embedding shape).
    ///
    /// Every tile embeds a `CapacityBar` drawn against a real, bounded
    /// quantity — never a guessed maximum (PLAN.md's honest-degradation
    /// rule): disk `activePercent` and GPU `utilizationPercent` are
    /// already `0...100`; Thermals reuses `meterTowersCard`'s own
    /// `0...110`°C ceiling rather than inventing a second one; Network has
    /// no known maximum bandwidth to measure against, so its bar instead
    /// shows the honest send/receive *split* of this tick's own combined
    /// rate (`networkShare(_:of:)`) — a real ratio, not a fabricated
    /// percentage. Energy's headline watts figure has no such ceiling
    /// either, so its bar instead draws `battery.percent` — a real,
    /// already-`0...100` reading, `Unavailable` on a battery-less Mac
    /// rather than bounding watts against a made-up draw limit. NPU has no
    /// bounded reading at all (`NPUSnapshot`'s own doc comment on why:
    /// Apple exposes no ANE wattage/utilization API), so its bar is a
    /// deliberately binary full/empty one echoing the same `isActive`
    /// boolean the tile's headline text already reads as "Active"/"Idle"
    /// — not a fabricated utilization percentage in disguise.
    private var bottomTileGrid: some View {
        SummaryCard(title: "System") {
            LazyVGrid(columns: Self.tileGridColumns, spacing: 10) {
                diskTile
                networkTile
                energyTile
                gpuTile
                npuTile
                thermalTile
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var diskCombinedRate: Double? {
        guard let read = disk?.readBytesPerSecond, let write = disk?.writeBytesPerSecond else { return nil }
        return read + write
    }

    private var diskTile: some View {
        StatTile(
            title: "Disks",
            systemImage: "internaldrive",
            color: DomainPalette.diskRead,
            value: Fmt.bytesPerSecond(diskCombinedRate),
            secondaryText: disk?.activePercent.map { "\(Fmt.percent($0)) active" },
            isUnavailable: diskCombinedRate == nil
        ) {
            CapacityBar(
                value: disk?.activePercent ?? 0,
                color: DomainPalette.diskRead,
                isUnavailable: disk?.activePercent == nil,
                accessibilityLabel: "Disk activity"
            )
        }
    }

    private var networkCombinedRate: Double? {
        guard let receive = network?.receiveBytesPerSecond, let send = network?.sendBytesPerSecond else { return nil }
        return receive + send
    }

    private var networkSecondaryText: String? {
        guard let receive = network?.receiveBytesPerSecond, let send = network?.sendBytesPerSecond else { return nil }
        return "↓ \(Fmt.bytesPerSecond(receive)) · ↑ \(Fmt.bytesPerSecond(send))"
    }

    private var networkTile: some View {
        let combined = networkCombinedRate
        return StatTile(
            title: "Network",
            systemImage: "network",
            color: DomainPalette.networkIn,
            value: Fmt.bytesPerSecond(combined),
            secondaryText: networkSecondaryText,
            isUnavailable: combined == nil
        ) {
            CapacityBar(
                segments: [
                    CapacityBarSegment(id: "receive", fraction: networkShare(network?.receiveBytesPerSecond, of: combined), color: DomainPalette.networkIn, label: "Received"),
                    CapacityBarSegment(id: "send", fraction: networkShare(network?.sendBytesPerSecond, of: combined), color: DomainPalette.networkOut, label: "Sent"),
                ],
                isUnavailable: combined == nil,
                accessibilityLabel: "Network send/receive split"
            )
        }
    }

    /// `part`'s share of `total`, `0...1` — the fraction `networkTile`'s
    /// embedded bar draws for each direction. Not a percentage of some
    /// assumed maximum bandwidth (this app has no such figure to draw
    /// against honestly, see `bottomTileGrid`'s doc comment); just how much
    /// of *this tick's own* combined rate each direction accounts for. `0`
    /// whenever either input is missing or `total` is `0` (no traffic to
    /// split), never a negative or > 1 fraction for `CapacityBar` to clamp.
    private func networkShare(_ part: Double?, of total: Double?) -> Double {
        guard let part, let total, total > 0 else { return 0 }
        return part / total
    }

    private var energySecondaryText: String? {
        guard let energy else { return nil }
        let source: String
        switch energy.powerSource {
        case .acPower: source = "AC Power"
        case .batteryPower: source = "Battery Power"
        case .unknown: source = "Unknown Source"
        }
        return energy.isLowPowerModeEnabled ? "\(source) · Low Power" : source
    }

    private var energyTile: some View {
        StatTile(
            title: "Energy",
            systemImage: "bolt.fill",
            color: DomainPalette.energy,
            value: Fmt.watts(energy?.systemPowerWatts),
            secondaryText: energySecondaryText,
            isUnavailable: energy?.systemPowerWatts == nil
        ) {
            CapacityBar(
                value: energy?.battery?.percent ?? 0,
                color: DomainPalette.energy,
                isUnavailable: energy?.battery?.percent == nil,
                accessibilityLabel: "Battery charge"
            )
        }
    }

    private var gpuTile: some View {
        StatTile(
            title: "GPU 0",
            systemImage: "square.stack.3d.up.fill",
            color: DomainPalette.gpu,
            value: Fmt.percent(gpu?.utilizationPercent),
            secondaryText: gpu?.deviceClassName,
            isUnavailable: gpu?.utilizationPercent == nil
        ) {
            CapacityBar(
                value: gpu?.utilizationPercent ?? 0,
                color: DomainPalette.gpu,
                isUnavailable: gpu?.utilizationPercent == nil,
                accessibilityLabel: "GPU usage"
            )
        }
    }

    private var npuTile: some View {
        StatTile(
            title: "NPU 0",
            systemImage: "brain",
            color: DomainPalette.npu,
            value: npu?.isActive.map { $0 ? "Active" : "Idle" } ?? "Unavailable",
            secondaryText: npu?.deviceName,
            isUnavailable: npu?.isActive == nil
        ) {
            // Binary full/empty, not a percentage — see `bottomTileGrid`'s
            // doc comment on why NPU has no bounded reading to draw a real
            // fraction against.
            CapacityBar(
                value: npu?.isActive == true ? 100 : 0,
                color: DomainPalette.npu,
                isUnavailable: npu?.isActive == nil,
                accessibilityLabel: "Neural Engine activity"
            )
        }
    }

    private var thermalTile: some View {
        StatTile(
            title: "Thermals",
            systemImage: "thermometer",
            color: DomainPalette.thermal,
            value: Fmt.celsius(thermal?.hotspotCelsius),
            secondaryText: thermal.map { thermalPressureLabel($0.thermalPressure) },
            isUnavailable: thermal?.hotspotCelsius == nil
        ) {
            CapacityBar(
                value: thermal?.hotspotCelsius ?? 0,
                total: Self.temperatureCeilingCelsius,
                color: DomainPalette.thermal,
                isUnavailable: thermal?.hotspotCelsius == nil,
                accessibilityLabel: "Hotspot temperature"
            )
        }
    }

    /// Display name for `ThermalSnapshot.thermalPressure` — mirrors
    /// `PerformancePage.swift`'s own private `thermalPressureLabel(_:)`
    /// (kept as a local copy rather than shared, for the same "private to
    /// that file" reason as `memoryCompositionBar` above); `ThermalPressureLevel`
    /// itself has no display name of its own to fall back on.
    private func thermalPressureLabel(_ pressure: ThermalPressureLevel) -> String {
        switch pressure {
        case .nominal: "Nominal"
        case .fair: "Fair"
        case .serious: "Serious"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }
}

// MARK: - Compact meter tower

/// One vertical LED-tower-shaped meter — [name removed]'s "CPU %", "Temp °C", "GPU
/// %" columns (PLAN.md §1.1), restyled per PLAN.md §2 as a native
/// `CapacityBar` in its `.vertical` orientation instead of a glowing
/// segmented strip. A domain icon sits above the bar, the bar's own
/// `valueLabel` prints the current reading below it (matching
/// `CapacityBar`'s documented vertical convention — "value below" — which
/// is itself [name removed]'s own layout), and a small caption names the domain
/// underneath that, so the tower reads top-to-bottom as icon → bar →
/// value → name without needing a title above the bar to compete with the
/// icon.
private struct CompactMeterTower: View {
    let title: String
    let systemImage: String
    let color: Color
    /// Current reading, honestly `0` and paired with `isUnavailable: true`
    /// when the backing provider couldn't sample this tick — `CapacityBar`
    /// itself suppresses any fill in that case regardless of this value,
    /// matching every other bar in this codebase.
    let value: Double
    let total: Double
    let valueLabel: String
    let isUnavailable: Bool
    let accessibilityLabel: String

    /// Bar track thickness — a touch narrower than the 14pt used by
    /// Memory's composition bar on the Performance page (PLAN.md's
    /// "compact" in this task's title), sized for three towers to sit
    /// comfortably side by side in a dashboard card.
    private static let thickness: CGFloat = 12
    /// Floor for the bar's height — its old fixed height, now a minimum
    /// rather than the literal size, so it still reads as a proper tower
    /// if this view is ever placed somewhere shorter than the Summary
    /// page's own 352pt row. `maxHeight: .infinity` below is what lets it
    /// grow past that floor to actually fill `meterTowersCard`'s card,
    /// which now stretches to match its row's tallest sibling.
    private static let minTowerHeight: CGFloat = 96

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isUnavailable ? Color(nsColor: .tertiaryLabelColor) : color)
            CapacityBar(
                value: value,
                total: total,
                color: color,
                orientation: .vertical,
                thickness: Self.thickness,
                valueLabel: valueLabel,
                isUnavailable: isUnavailable,
                accessibilityLabel: accessibilityLabel
            )
            .frame(minHeight: Self.minTowerHeight, maxHeight: .infinity)
            Text(title)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
        }
        .frame(width: 56)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - CPU Overview tab

/// PLAN.md §1.1 Summary's "tabs for Utilization / Temperature / Kernel" —
/// switches `cpuOverviewCard`'s big readout and single-series graph
/// between total CPU utilization, thermal hotspot temperature, and
/// kernel (system) CPU time. Not `private`: `SummaryViewModel` exposes it
/// via an internal `@Published var selectedCPUOverviewTab`, matching
/// `PerformancePage.swift`'s `GPUEngineTab` (also internal, for the same
/// reason — a property can't be more visible than its own type).
enum CPUOverviewTab: String, CaseIterable, Identifiable {
    case utilization
    case temperature
    case kernel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utilization: "Utilization"
        case .temperature: "Temperature"
        case .kernel: "Kernel"
        }
    }

    /// [name removed]'s own utilization/temp/kernel graph colors are green/amber/red
    /// (PLAN.md §1.1); reusing `DomainPalette`'s existing CPU/Thermal
    /// tokens keeps the same red-for-kernel, warm-for-temperature identity
    /// while staying inside this app's native palette (PLAN.md §2)
    /// instead of introducing a one-off green token no other CPU view
    /// uses.
    var color: Color {
        switch self {
        case .utilization: DomainPalette.cpuUser
        case .temperature: DomainPalette.thermal
        case .kernel: DomainPalette.cpuSystem
        }
    }
}

// MARK: - Summary dashboard card

/// Shared bordered-card chrome for this page's dashboard sections —
/// visually distinct from the page's own `.controlBackgroundColor`
/// background the same way `StatTile`'s card reads as a discrete tile
/// against its container, so the meter towers, CPU Overview card,
/// top-processes table, memory band, and tile grid each read as one
/// dashboard block rather than bare content floating on the page
/// background.
private struct SummaryCard<Content: View>: View {
    let title: String?
    let content: Content

    init(title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(14)
        // `.frame(maxHeight: .infinity, alignment: .top)` here, BEFORE
        // `.background`, is what makes an outer `.frame(height:)` (the
        // Summary top row's shared-height cards) actually stretch this
        // card's background/border — not just its invisible layout box.
        // Without it, wrapping a `SummaryCard` in a taller outer frame
        // only repositions this already content-sized view inside extra
        // blank space; the `RoundedRectangle` below is drawn from THIS
        // view's own size, so it has to be the one that grows. Content
        // stays top-aligned inside the (now possibly taller) card, same
        // as a call site with no outer frame at all sees no change — an
        // unconstrained `maxHeight: .infinity` just resolves to this
        // VStack's own intrinsic height, exactly as before.
        .frame(maxHeight: .infinity, alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
        )
    }
}

// MARK: - Memory readout

/// One label/value pair in `memoryUtilizationBand`'s bottom readout row —
/// a compact cousin of `PerformancePage.swift`'s private `MetricCard`
/// (not reusable from here, since that type is private to that file).
/// Skips `MetricCard`'s own `isUnavailable`-driven "Unavailable"
/// substitution: `Fmt.bytes` below already resolves a missing reading to
/// this file's own "—" convention, so there's no second state to carry.
private struct MemoryReadout: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .fontWeight(.medium)
                .monospacedDigit()
        }
    }
}

// MARK: - Formatting

/// Minimal reading-to-string formatting for this page's meter towers —
/// this file's counterpart to `PerformancePage.swift`'s private `Fmt`
/// enum (not shared across files, matching that type's own "Unavailable"
/// convention rather than a guessed/blank value).
private enum Fmt {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f°C", value)
    }

    /// `bottomTileGrid`'s Disks/Network throughput readings — the same
    /// `ByteCountFormatter` + "/s" suffix `PerformancePage.swift`'s own
    /// `Fmt.bytesPerSecond` uses, kept as a local copy for this file's own
    /// "—" (not "Unavailable") missing-value convention.
    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    /// `bottomTileGrid`'s Energy tile headline — one decimal place, same as
    /// `PerformancePage.swift`'s own `Fmt.watts`.
    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f W", value)
    }

    /// One-decimal percentage for `topProcessesCard`'s CPU/GPU cells — a
    /// process's own %CPU can meaningfully vary at the tenths place (unlike
    /// the whole-system meter towers above, `percent(_:)`'s 12.4% vs. 12%
    /// distinguishes a genuinely idle process from a busy one at this
    /// table's scale) and can also read past 100% for a multi-threaded
    /// process (PLAN.md's per-process convention, see `TopProcessReading`'s
    /// doc comment), so this doesn't clamp the way a 0...100 meter would.
    static func percentPrecise(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.1f%%", value)
    }

    /// `topProcessesCard`'s Memory column — `ByteCountFormatter`'s
    /// `.memory` style, the same native, locale-correct byte formatting
    /// `PerformancePage.swift`'s own `Fmt.bytes` uses, rather than
    /// hand-rolled MB/GB math.
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return bytesFormatter.string(fromByteCount: Int64(value))
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - View model

/// Subscribes to `Sampler.shared` — the app-wide instance also behind
/// `AppShellStatusModel`'s info bar and every other page's own live view
/// model (`Sampler.shared`'s doc comment); `start()`/`stop()` still open
/// and close only *this* view model's own subscription while this page is
/// on screen (`PerformancePage.swift`'s `stop()` doc comment explains why
/// that no longer means calling `sampler.stop()`). `latest`
/// alone was enough for the first M3 task's capacity-bar readings;
/// `cpuOverviewCard` and `memoryUtilizationBand` also need a scrolling
/// history each, so `seriesHistory` tracks those too — the same "dotted-id
/// ring buffer per series" pattern `PerformanceViewModel` uses, trimmed to
/// just the four series this page currently plots (`CPUOverviewTab`'s
/// three plus memory's own `"memory.usedPercent"`).
@MainActor
final class SummaryViewModel: ObservableObject {
    /// Ticks of history kept per series — same capacity
    /// `PerformanceViewModel` uses, enough for a readable trend at every
    /// `Sampler.Interval` preset without unbounded growth.
    private static let historyCapacity = 180

    @Published private(set) var latest: Snapshot?
    /// Per-series ring buffers backing `cpuOverviewCard`'s graph, keyed by
    /// a dotted id this file assigns (`"cpu.total"`, `"cpu.system"`,
    /// `"thermal.hotspot"`). `nil` entries are gaps left by a tick that
    /// domain couldn't sample, matching `HistoryGraphSeries.values`' own
    /// "honest gap, not an interpolated guess" contract.
    @Published private(set) var seriesHistory: [String: [Double?]] = [:]
    /// `cpuOverviewCard`'s current tab selection.
    @Published var selectedCPUOverviewTab: CPUOverviewTab = .utilization
    /// `topProcessesCard`'s rows — already limited to the top
    /// `topProcessesLimit` by CPU % descending; the card's own `DataTable`
    /// re-sorts within just those rows on a header click.
    @Published private(set) var topProcesses: [TopProcessReading] = []
    /// Total live process count this tick, for `topProcessesCard`'s
    /// "Top 12 of N" caption. `0` before the first successful sample.
    @Published private(set) var processCount = 0
    /// Set when `topProcessesProvider.sample()` last threw, cleared on the
    /// next success — `topProcessesCard`'s honest-degradation message in
    /// place of a guessed count (PLAN.md's "honest degradation").
    @Published private(set) var topProcessesUnavailableReason: String?

    private let sampler = Sampler.shared
    private var streamTask: Task<Void, Never>?

    private let topProcessesProvider = TopProcessesProvider()
    private var topProcessesTask: Task<Void, Never>?
    /// How many rows `topProcessesCard` shows — PLAN.md §1.1's own
    /// "top 12 of N".
    private static let topProcessesLimit = 12
    /// `topProcessesProvider`'s poll cadence. Reuses `Sampler.Interval`'s
    /// existing `.slow` (1 sample/sec) preset rather than a fresh magic
    /// number: enumerating every process is heavier work than any single
    /// fixed-syscall-count domain provider, and a top-12 leaderboard
    /// doesn't need to refresh as fast as this page's live graphs do.
    private static let topProcessesPollInterval = Sampler.Interval.slow.seconds

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
        startTopProcessesPolling()
    }

    /// Ends this view model's own subscription to the shared sampler.
    /// Called from `onDisappear` so this page stops reading live data
    /// while another page is showing — see `PerformanceViewModel.stop()`'s
    /// doc comment for why this cancels only this task rather than calling
    /// `sampler.stop()`, which would end every other subscriber's stream
    /// too.
    func stop() {
        streamTask?.cancel()
        streamTask = nil

        topProcessesTask?.cancel()
        topProcessesTask = nil
    }

    /// Polls `topProcessesProvider` on its own cadence, independent of
    /// `sampler`'s stream. Not folded into `ingest(_:)`/`Sampler` itself:
    /// `TopProcessesProvider` is an `actor` precisely so this loop's
    /// `await provider.sample()` call runs its `proc_listallpids` +
    /// per-pid `proc_pidinfo`/`proc_pidpath` work on that actor's own
    /// executor, off this view model's main-actor isolation — seeing
    /// this `Task {}` was created from a `@MainActor` method, only the
    /// `await`ed call itself hops away; the loop's bookkeeping and the
    /// `@Published` writes below stay on the main actor exactly like
    /// `ingest(_:)`'s.
    private func startTopProcessesPolling() {
        guard topProcessesTask == nil else { return }
        let provider = topProcessesProvider
        topProcessesTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let readings = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.processCount = readings.count
                    self.topProcesses = Array(
                        readings
                            .sorted { ($0.cpuPercent ?? -1) > ($1.cpuPercent ?? -1) }
                            .prefix(Self.topProcessesLimit)
                    )
                    self.topProcessesUnavailableReason = nil
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.topProcessesUnavailableReason = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.topProcessesPollInterval * 1_000_000_000))
            }
        }
    }

    /// One series' full history, oldest first — `HistoryGraph`'s expected
    /// order. An unknown id (nothing sampled for it yet) reads as an empty
    /// array, which `HistoryGraph` already renders as a blank chart rather
    /// than a crash.
    func history(_ id: String) -> [Double?] {
        seriesHistory[id] ?? []
    }

    // MARK: - Ingest

    private func ingest(_ snapshot: Snapshot) {
        latest = snapshot

        // Mutated locally and assigned back once at the end so every
        // series update in one tick becomes a single `@Published` change
        // notification rather than one per series — same batching
        // `PerformanceViewModel.ingest(_:)` uses.
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
        append("cpu.system", snapshot.cpu?.systemUtilization)
        append("thermal.hotspot", snapshot.thermal?.hotspotCelsius)

        // Same `usedBytes / totalBytes * 100` formula as this file's own
        // `memoryUsedPercent` (and `PerformancePage.swift`'s
        // `MemoryDetailView.usedPercent`), computed here from `snapshot`
        // directly rather than from `latest` so this tick's history point
        // lands in the same `@Published` update as `latest` itself.
        let memoryUsedPercent: Double? = {
            guard let memory = snapshot.memory, let total = memory.totalBytes, total > 0, let used = memory.usedBytes else {
                return nil
            }
            return Double(used) / Double(total) * 100
        }()
        append("memory.usedPercent", memoryUsedPercent)

        seriesHistory = history
    }
}

#Preview {
    SummaryPage()
        .frame(width: 900, height: 640)
}
