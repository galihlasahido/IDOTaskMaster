import SwiftUI

/// History page — one of this app's own beyond-[name removed] additions (PLAN.md
/// §2: "persistent history (SQLite, 24h/7d views)") / §4 M9's third task:
/// "browse 24h / 7d charts per domain ('what spiked while I was away')."
/// [name removed] itself keeps no history at all once a live graph's reading scrolls
/// off-screen — this page is the browsing surface for `HistoryStore`, the
/// M9 task before this one.
///
/// Master-detail, matching `PerformancePage`'s own shape: a left rail of
/// per-domain `StatTile`s (headline reading + sparkline over the selected
/// range) and a detail column on the right with a bigger chart, a
/// Current/Peak/Low/Average stat row — the literal answer to "what spiked
/// while I was away" is the Peak card's value and the time it happened —
/// and a handful of domain-specific extra readings `HistoryStore` also
/// recorded. Unlike `PerformancePage`, nothing here is live: every number
/// comes from one `HistoryStore` query per load, re-run whenever the
/// range picker changes and on a slow timer while this page stays open
/// (`HistoryPageViewModel.autoRefreshInterval`), matching the store's own
/// 30-second recording cadence — polling faster would show nothing new.
///
/// This page only *reads* `HistoryStore` through the environment (see
/// `historyStore` `EnvironmentKey` below) — `AppDelegate` owns starting
/// and stopping the store's own recorder/maintenance loops, per that
/// type's own doc comment.
struct HistoryPage: View {
    @Environment(\.historyStore) private var historyStore
    @StateObject private var model = HistoryPageViewModel()
    @State private var selectedDomain: MetricDomain = .cpu

    var body: some View {
        HStack(spacing: 0) {
            rail
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor))
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { rangePicker }
        }
        .task(id: model.range) {
            await model.reload(store: historyStore)
        }
        .onAppear { model.startAutoRefresh(store: historyStore) }
        .onDisappear { model.stopAutoRefresh() }
    }

    // MARK: - Toolbar

    private var rangePicker: some View {
        Picker("Range", selection: $model.range) {
            ForEach(HistoryStore.Range.allCases, id: \.self) { range in
                Text(range.displayName).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 160)
    }

    // MARK: - Rail

    private var rail: some View {
        ScrollView {
            VStack(spacing: 8) {
                statusLine
                ForEach(HistoryDomainSpec.all) { spec in
                    railTile(spec)
                }
            }
            .padding(10)
        }
        .frame(width: 230)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// Mirrors `AlertsPage.statusLine`/`StartupPage.statusLine`'s "as of /
    /// problem" caption — this store's own honest-degradation surface
    /// (PLAN.md's rule applies to a *recorder's* durability, not just a
    /// provider's readings) rather than a per-domain concern, so it sits
    /// once at the top of the rail instead of being repeated per tile.
    private var statusLine: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(statusHeadline)
                .font(.caption)
                .foregroundStyle(model.databaseUnavailableReason != nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 2)
    }

    private var statusHeadline: String {
        if let reason = model.databaseUnavailableReason {
            return "History unavailable \u{2014} \(reason)"
        }
        guard let lastRecordedAt = model.lastRecordedAt else {
            return "No history recorded yet."
        }
        return "Recording \u{2014} last sample \(HistoryFmt.relativeFormatter.localizedString(for: lastRecordedAt, relativeTo: Date()))"
    }

    private func railTile(_ spec: HistoryDomainSpec) -> some View {
        let stats = model.stats[spec.primary.id]
        let values = model.chartValues[spec.primary.id] ?? []
        return StatTile(
            title: spec.title,
            systemImage: spec.systemImage,
            color: spec.primary.color,
            value: stats?.current.map(spec.primary.format) ?? "Unavailable",
            secondaryText: stats?.peak.map { "Peak \(spec.primary.format($0))" },
            isUnavailable: stats?.current == nil,
            isSelected: selectedDomain == spec.domain,
            action: { selectedDomain = spec.domain }
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: spec.primary.id, color: spec.primary.color, values: values)],
                valueRange: chartRange(for: spec),
                gridLineCount: 0,
                accessibilityLabel: "\(spec.title) history"
            )
            .frame(height: 32)
        }
    }

    // MARK: - Detail

    private var detail: some View {
        let spec = HistoryDomainSpec.all.first(where: { $0.domain == selectedDomain }) ?? HistoryDomainSpec.all[0]
        return HistoryDomainDetailView(spec: spec, model: model, chartRange: chartRange(for: spec))
    }

    /// `spec.fixedRange` for percent/temperature domains; otherwise a
    /// range computed from this load's own data (network/energy, whose
    /// natural units have no fixed ceiling) — the same "grow to fit,
    /// floor at 1" rule `PerformanceViewModel.dynamicRange(for:)` uses for
    /// its own live rail sparklines, so a quiet stretch of history doesn't
    /// render as a flat line pinned to some arbitrary large ceiling.
    private func chartRange(for spec: HistoryDomainSpec) -> ClosedRange<Double> {
        if let fixedRange = spec.fixedRange { return fixedRange }
        return model.dynamicRange(for: spec.chartedSpecs.map(\.id))
    }
}

#Preview {
    HistoryPage()
        .frame(width: 980, height: 720)
}

// MARK: - Detail view

/// The right-hand column for one selected domain — headline, the "what
/// spiked" chart, a Current/Peak/Low/Average stat row, and whatever
/// domain-specific extra readings `HistoryDomainSpec.extras` lists.
/// Deliberately a separate view (not inlined in `HistoryPage`) so its
/// `chartRange` doesn't have to be recomputed by every rail tile too.
private struct HistoryDomainDetailView: View {
    let spec: HistoryDomainSpec
    @ObservedObject var model: HistoryPageViewModel
    let chartRange: ClosedRange<Double>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headline
                chartSection
                statsSection
                if !spec.extras.isEmpty {
                    extrasSection
                }
            }
            .padding(16)
        }
    }

    private var primaryStats: HistorySeriesStats? { model.stats[spec.primary.id] }

    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: spec.systemImage)
                .font(.title2)
                .foregroundStyle(spec.primary.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(spec.title)
                    .font(.title3)
                    .fontWeight(.semibold)
                Text(primaryStats?.current.map(spec.primary.format) ?? "Unavailable")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .foregroundStyle(primaryStats?.current == nil ? .secondary : .primary)
            }
            Spacer(minLength: 0)
            Text(model.range.displayName)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    @ViewBuilder
    private var chartSection: some View {
        HistoryDetailSection(title: "History") {
            if (primaryStats?.pointCount ?? 0) == 0 {
                emptyChartPlaceholder
            } else {
                HistoryGraph(
                    series: chartSeries,
                    valueRange: chartRange,
                    accessibilityLabel: "\(spec.title) history, \(model.range.displayName)"
                )
                .frame(height: 180)
            }
        }
    }

    private var chartSeries: [HistoryGraphSeries] {
        var series = [HistoryGraphSeries(
            id: spec.primary.id,
            color: spec.primary.color,
            values: model.chartValues[spec.primary.id] ?? []
        )]
        if let secondary = spec.secondary {
            series.append(HistoryGraphSeries(
                id: secondary.id,
                color: secondary.color,
                values: model.chartValues[secondary.id] ?? []
            ))
        }
        return series
    }

    private var emptyChartPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(model.databaseUnavailableReason ?? "No history recorded yet for \(spec.title.lowercased()) in this window.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var statsSection: some View {
        HistoryDetailSection(title: "\(model.range.displayName) Summary") {
            LazyVGrid(columns: historyStatGridColumns, alignment: .leading, spacing: 12) {
                HistoryStatCard(label: "Current", value: primaryStats?.current.map(spec.primary.format))
                HistoryStatCard(
                    label: "Peak",
                    value: primaryStats?.peak.map(spec.primary.format),
                    detail: primaryStats?.peakAt.map { "at \(HistoryFmt.timeFormatter.string(from: $0))" }
                )
                HistoryStatCard(label: "Low", value: primaryStats?.low.map(spec.primary.format))
                HistoryStatCard(label: "Average", value: primaryStats?.average.map(spec.primary.format))
            }
        }
    }

    private var extrasSection: some View {
        HistoryDetailSection(title: "Details") {
            LazyVGrid(columns: historyStatGridColumns, alignment: .leading, spacing: 12) {
                ForEach(spec.extras) { extra in
                    let extraStats = model.stats[extra.id]
                    HistoryStatCard(
                        label: extra.title,
                        value: extraStats?.current.map(extra.format),
                        detail: extraStats?.peak.map { "peak \(extra.format($0))" }
                    )
                }
            }
        }
    }
}

private let historyStatGridColumns = [GridItem(.adaptive(minimum: 130), spacing: 12)]

/// This file's counterpart to `PerformancePage`'s own private
/// `DetailSection` — a titled group within the detail column's scrolling
/// body. Not reused from that file: both types are `private` to their own
/// file, matching this codebase's existing per-page-file convention for
/// small layout helpers (see e.g. every page's own private `Fmt`).
private struct HistoryDetailSection<Content: View>: View {
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

/// One stat cell in this page's Current/Peak/Low/Average row — like
/// `PerformancePage`'s private `MetricCard`, plus an optional `detail`
/// line (used by the Peak card's "at 3:42 PM" and each extra reading's
/// "peak ..." caption) that `MetricCard` has no room for.
private struct HistoryStatCard: View {
    let label: String
    let value: String?
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value ?? "Unavailable")
                .font(.body)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail, value != nil {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Domain specs

/// One chartable reading `HistoryStore` recorded for a domain — a plotted
/// `key` (matching `HistoryStore.metrics(from:)`'s own key naming) plus
/// how this page labels, colors, and formats it. `id` is the dotted
/// `"<domain>.<key>"` string this page keys `chartValues`/`stats` by,
/// matching `PerformanceViewModel.seriesHistory`'s own convention.
private struct HistorySeriesSpec: Identifiable {
    let domain: HistoryStore.Domain
    let key: String
    let title: String
    let color: Color
    /// Multiplies every stored value before charting/formatting — only
    /// `npu.active` uses this (see `HistoryDomainSpec.all`'s doc comment
    /// on that entry) to turn a 0/1-per-sample reading, averaged over a
    /// bucket, into "percent of time active."
    var scale: Double = 1
    let format: (Double) -> String

    var id: String { "\(domain.rawValue).\(key)" }
}

/// One rail tile / detail column's worth of `HistoryStore` data — PLAN.md
/// §4 M9's "24h/7d charts per domain," one entry per `MetricDomain`.
/// `primary` drives the rail sparkline, the detail headline, and the
/// Current/Peak/Low/Average row; `secondary` (when present) overlays a
/// second trace on the same detail chart, matching `PerformancePage`'s
/// own CPU user/system and Network receive/send pairing; `extras` are
/// additional readings `HistoryStore` recorded for this domain that don't
/// share `primary`'s chart axis (e.g. Memory's swap bytes alongside its
/// percent-used chart) and are only ever shown as plain stat cards.
private struct HistoryDomainSpec: Identifiable {
    let domain: MetricDomain
    let title: String
    let systemImage: String
    let primary: HistorySeriesSpec
    let secondary: HistorySeriesSpec?
    let extras: [HistorySeriesSpec]
    /// `nil` means "compute from this load's own data" — see
    /// `HistoryPage.chartRange(for:)`.
    let fixedRange: ClosedRange<Double>?

    var id: MetricDomain { domain }

    var chartedSpecs: [HistorySeriesSpec] {
        secondary.map { [primary, $0] } ?? [primary]
    }

    var allSpecs: [HistorySeriesSpec] {
        chartedSpecs + extras
    }

    /// One entry per `MetricDomain`, in the same order `PerformancePage`'s
    /// own rail uses (`MetricDomain.allCases`), so the two pages' domain
    /// lists read the same top to bottom.
    static let all: [HistoryDomainSpec] = [
        HistoryDomainSpec(
            domain: .cpu,
            title: "CPU",
            systemImage: "cpu",
            primary: HistorySeriesSpec(domain: .cpu, key: "total", title: "Total", color: DomainPalette.cpuUser, format: HistoryFmt.percent),
            secondary: HistorySeriesSpec(domain: .cpu, key: "system", title: "System", color: DomainPalette.cpuSystem, format: HistoryFmt.percent),
            extras: [],
            fixedRange: 0...100
        ),
        HistoryDomainSpec(
            domain: .memory,
            title: "Memory",
            systemImage: "memorychip",
            primary: HistorySeriesSpec(domain: .memory, key: "usedPercent", title: "Used", color: DomainPalette.memoryPressureNormal, format: HistoryFmt.percent),
            secondary: nil,
            extras: [
                HistorySeriesSpec(domain: .memory, key: "swapUsedBytes", title: "Swap Used", color: DomainPalette.memorySwap, format: HistoryFmt.bytes),
            ],
            fixedRange: 0...100
        ),
        HistoryDomainSpec(
            domain: .gpu,
            title: "GPU 0",
            systemImage: "square.stack.3d.up.fill",
            primary: HistorySeriesSpec(domain: .gpu, key: "utilization", title: "Utilization", color: DomainPalette.gpu, format: HistoryFmt.percent),
            secondary: nil,
            extras: [
                HistorySeriesSpec(domain: .gpu, key: "temperature", title: "Temperature", color: DomainPalette.thermal, format: HistoryFmt.celsius),
                HistorySeriesSpec(domain: .gpu, key: "vramUsedBytes", title: "VRAM Used", color: DomainPalette.gpuSecondary, format: HistoryFmt.bytes),
            ],
            fixedRange: 0...100
        ),
        HistoryDomainSpec(
            domain: .npu,
            title: "NPU 0",
            systemImage: "brain",
            // Stored as 0/1 per raw sample (`NPUProvider.isActive`); once
            // rolled into a `.minute`/`.hour` bucket, `average` becomes a
            // genuine fraction of that bucket spent active — `scale: 100`
            // turns that fraction into "percent of time active", the only
            // reading that survives downsampling honestly (a raw on/off
            // state doesn't).
            primary: HistorySeriesSpec(domain: .npu, key: "active", title: "Active", color: DomainPalette.npu, scale: 100, format: HistoryFmt.percent),
            secondary: nil,
            extras: [],
            fixedRange: 0...100
        ),
        HistoryDomainSpec(
            domain: .disk,
            title: "Disks",
            systemImage: "internaldrive",
            primary: HistorySeriesSpec(domain: .disk, key: "activePercent", title: "Active", color: DomainPalette.diskRead, format: HistoryFmt.percent),
            secondary: nil,
            extras: [
                HistorySeriesSpec(domain: .disk, key: "readBytesPerSecond", title: "Read", color: DomainPalette.diskRead, format: HistoryFmt.bytesPerSecond),
                HistorySeriesSpec(domain: .disk, key: "writeBytesPerSecond", title: "Write", color: DomainPalette.diskWrite, format: HistoryFmt.bytesPerSecond),
            ],
            fixedRange: 0...100
        ),
        HistoryDomainSpec(
            domain: .network,
            title: "Network",
            systemImage: "network",
            primary: HistorySeriesSpec(domain: .network, key: "receiveBytesPerSecond", title: "Receive", color: DomainPalette.networkIn, format: HistoryFmt.bytesPerSecond),
            secondary: HistorySeriesSpec(domain: .network, key: "sendBytesPerSecond", title: "Send", color: DomainPalette.networkOut, format: HistoryFmt.bytesPerSecond),
            extras: [],
            fixedRange: nil
        ),
        HistoryDomainSpec(
            domain: .energy,
            title: "Energy",
            systemImage: "bolt.fill",
            primary: HistorySeriesSpec(domain: .energy, key: "systemPowerWatts", title: "System Power", color: DomainPalette.energy, format: HistoryFmt.watts),
            secondary: nil,
            extras: [
                HistorySeriesSpec(domain: .energy, key: "batteryPercent", title: "Battery", color: DomainPalette.energyBattery, format: HistoryFmt.percent),
            ],
            fixedRange: nil
        ),
        HistoryDomainSpec(
            domain: .thermal,
            title: "Thermals",
            systemImage: "thermometer",
            primary: HistorySeriesSpec(domain: .thermal, key: "hotspotCelsius", title: "Hotspot", color: DomainPalette.thermal, format: HistoryFmt.celsius),
            secondary: nil,
            extras: [],
            fixedRange: 0...110
        ),
    ]
}

// MARK: - Formatting

/// Shared by `HistoryDomainSpec.all`'s format closures and this file's own
/// relative/absolute-time captions — this file's counterpart to every
/// other page's own private `Fmt` enum (`PerformancePage.Fmt`,
/// `ConnectionsPage.Fmt`, ...). Named distinctly (`HistoryFmt`, not
/// `Fmt`) only because, unlike those, its `percent`/`bytes`/... helpers
/// are referenced from `HistoryDomainSpec.all`'s static initializer
/// outside this file's other private types, where a same-named `Fmt`
/// nested in a different file would still resolve correctly but reads
/// less clearly at the call site.
private enum HistoryFmt {
    static func percent(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return String(format: "%.0f%%", value)
    }

    static func bytes(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded()))
    }

    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func watts(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return String(format: "%.1f W", value)
    }

    static func celsius(_ value: Double) -> String {
        guard value.isFinite else { return "Unavailable" }
        return String(format: "%.0f\u{00B0}C", value)
    }

    static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

// MARK: - View model

/// Current/Peak/Low/Average summary for one `HistorySeriesSpec` over the
/// currently-loaded range — computed once per `reload()` from that
/// series' raw `HistoryStore.SeriesPoint` rows (see
/// `Array<HistoryStore.SeriesPoint>.summarized()` below), not recomputed
/// per view redraw.
private struct HistorySeriesStats {
    /// The most recent point's own average — this spec's "headline"
    /// reading, matching every other page's live-tile convention even
    /// though this page's data isn't live.
    let current: Double?
    /// `sampleCount`-weighted mean across every returned point, giving a
    /// `.minute`/`.hour` aggregate row exactly as much say as the many
    /// individual `.raw` samples it was rolled up from — mirroring
    /// `HistoryStore.compact(from:to:bucketSeconds:olderThan:)`'s own
    /// weighting.
    let average: Double?
    /// The highest `maximum` across every point — this card's literal
    /// answer to "what spiked while I was away": even a point whose own
    /// `average` looks unremarkable can carry a `maximum` far above it.
    let peak: Double?
    let peakAt: Date?
    let low: Double?
    let pointCount: Int

    static let empty = HistorySeriesStats(current: nil, average: nil, peak: nil, peakAt: nil, low: nil, pointCount: 0)
}

private extension Array where Element == HistoryStore.SeriesPoint {
    /// Reduces this query's raw rows into one `HistorySeriesStats`. `self`
    /// is expected sorted oldest-first (`HistoryStore.series` already
    /// guarantees this), so `last` is the most recent sample.
    func summarized() -> HistorySeriesStats {
        guard !isEmpty else { return .empty }
        var weightedSum = 0.0
        var totalWeight = 0.0
        var peak = -Double.infinity
        var peakAt: Date?
        var low = Double.infinity
        for point in self {
            let weight = Double(Swift.max(point.sampleCount, 1))
            weightedSum += point.average * weight
            totalWeight += weight
            if point.maximum > peak {
                peak = point.maximum
                peakAt = point.timestamp
            }
            low = Swift.min(low, point.minimum)
        }
        return HistorySeriesStats(
            current: last?.average,
            average: totalWeight > 0 ? weightedSum / totalWeight : nil,
            peak: peak.isFinite ? peak : nil,
            peakAt: peakAt,
            low: low.isFinite ? low : nil,
            pointCount: count
        )
    }
}

/// Owns this page's `HistoryStore` queries and the resampled arrays
/// `HistoryGraph` plots — `ObservableObject`/`@Published` rather than the
/// `@Observable` macro, matching every other page's view model on this
/// app's macOS 13.0 minimum target (`@Observable` needs 14+).
///
/// Unlike `PerformanceViewModel`, this model has no live `Sampler` of its
/// own: every number it publishes comes from `HistoryStore.series(...)`,
/// an `actor` method this model `await`s from `reload()`. `startAutoRefresh`
/// only exists so a `HistoryPage` left open keeps catching up to newly
/// recorded samples — at `HistoryStore`'s own 30-second raw cadence, never
/// faster, since a query re-run any sooner would almost always return the
/// exact same rows.
@MainActor
final class HistoryPageViewModel: ObservableObject {
    /// Matches `HistoryStore.rawInterval` — polling this store's query
    /// methods faster would just re-read the same rows between that
    /// store's own recording ticks.
    private static let autoRefreshInterval: TimeInterval = 30
    /// How many evenly-spaced points `HistoryGraph` is handed per series.
    /// `HistoryStore.series(...)` returns rows at up to three different
    /// native spacings (30s/5min/1h, see that type's own doc comment) —
    /// resampling onto one uniform grid (`resample(_:since:until:)` below)
    /// is what makes the resulting chart's x-axis actually proportional to
    /// elapsed time, rather than showing the last couple of hours' worth
    /// of finely-spaced raw rows as if they spanned the same width as five
    /// days of hourly ones.
    private static let resampleBucketCount = 240

    @Published var range: HistoryStore.Range = .last24Hours
    @Published private(set) var chartValues: [String: [Double?]] = [:]
    @Published fileprivate private(set) var stats: [String: HistorySeriesStats] = [:]
    @Published private(set) var lastRecordedAt: Date?
    /// Set from `HistoryStore.openError` — a permanent condition for that
    /// store's whole lifetime (its database never opened at all), shown
    /// the same honest way `AlertsPage`'s notification-authorization
    /// caption reads `AlertsEngine.authorizationStatus`.
    @Published private(set) var databaseUnavailableReason: String?

    private var autoRefreshTask: Task<Void, Never>?

    /// Runs one `HistoryStore` load for every domain's every plotted
    /// series (`HistoryDomainSpec.all`), for the currently-selected
    /// `range`. Safe to call with `store == nil` (a `HistoryPage` preview,
    /// or the brief window before `AppDelegate`'s instance reaches the
    /// environment) — every published value simply stays empty, the same
    /// "no data source, no guess" contract every provider follows.
    func reload(store: HistoryStore?) async {
        guard let store else {
            databaseUnavailableReason = "no history database is configured for this window."
            return
        }
        if let openError = await store.openError {
            databaseUnavailableReason = openError
            return
        }
        databaseUnavailableReason = nil
        lastRecordedAt = await store.lastRecordedAt

        let now = Date()
        let since = now.addingTimeInterval(-range.seconds)
        var newValues: [String: [Double?]] = [:]
        var newStats: [String: HistorySeriesStats] = [:]

        for domainSpec in HistoryDomainSpec.all {
            for series in domainSpec.allSpecs {
                let rawPoints = await store.series(domain: series.domain, key: series.key, since: since)
                let points = series.scale == 1 ? rawPoints : rawPoints.map { $0.scaled(by: series.scale) }
                newStats[series.id] = points.summarized()
                if domainSpec.chartedSpecs.contains(where: { $0.id == series.id }) {
                    newValues[series.id] = Self.resample(points, since: since, until: now)
                }
            }
        }

        chartValues = newValues
        stats = newStats
    }

    /// `0...max(largest plotted value, 1)` across the given series ids —
    /// this model's counterpart to `PerformanceViewModel.dynamicRange(for:)`,
    /// used by domains whose natural unit (bytes/sec, watts) has no fixed
    /// ceiling.
    func dynamicRange(for ids: [String]) -> ClosedRange<Double> {
        let maxValue = ids.flatMap { chartValues[$0] ?? [] }.compactMap { $0 }.max() ?? 0
        return 0...max(maxValue, 1)
    }

    func startAutoRefresh(store: HistoryStore?) {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.autoRefreshInterval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                await self.reload(store: store)
            }
        }
    }

    func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    // MARK: - Resampling

    /// Lays `points` (already time-sorted by `HistoryStore.series`) onto
    /// `resampleBucketCount` evenly-spaced timestamps between `since` and
    /// `until`, forward-filling each grid point from the most recent
    /// stored sample at or before it — so a chart bucket that falls
    /// between two sparse stored rows still reads the last known value,
    /// the same way a live line chart holds its last reading between
    /// ticks, rather than needing a stored row at that exact instant.
    ///
    /// `maxGap` is what keeps this forward-fill honest rather than
    /// bridging a real absence of data (the app fully quit for a few
    /// hours, say) with a stale, misleadingly-flat line all the way
    /// across the gap: a grid point more than `maxGap` past the sample it
    /// would otherwise forward-fill from is left `nil` instead, breaking
    /// `HistoryGraph`'s stroke/fill there exactly as a live provider gap
    /// does (see `HistoryGraphSeries.values`'s own doc comment). Floored
    /// at 20 minutes so normal `.minute`-resolution bucket spacing (up to
    /// 5 minutes apart) is never itself mistaken for a gap.
    static func resample(_ points: [HistoryStore.SeriesPoint], since: Date, until: Date) -> [Double?] {
        guard !points.isEmpty, until > since else {
            return Array(repeating: nil, count: resampleBucketCount)
        }
        let span = until.timeIntervalSince(since)
        let maxGap = max(span / Double(resampleBucketCount) * 4, 20 * 60)

        var result: [Double?] = []
        result.reserveCapacity(resampleBucketCount)
        var searchIndex = 0
        for step in 0..<resampleBucketCount {
            let fraction = resampleBucketCount > 1 ? Double(step) / Double(resampleBucketCount - 1) : 1
            let gridTime = since.addingTimeInterval(span * fraction)
            while searchIndex + 1 < points.count, points[searchIndex + 1].timestamp <= gridTime {
                searchIndex += 1
            }
            let candidate = points[searchIndex]
            if candidate.timestamp <= gridTime, gridTime.timeIntervalSince(candidate.timestamp) <= maxGap {
                result.append(candidate.average)
            } else {
                result.append(nil)
            }
        }
        return result
    }
}

private extension HistoryStore.SeriesPoint {
    /// Applies `HistorySeriesSpec.scale` to every column of one stored
    /// point — used only by `npu.active` (see `HistoryDomainSpec.all`) —
    /// keeping `average`/`minimum`/`maximum` consistently scaled so
    /// `summarized()`'s peak/low math and `HistoryPageViewModel.resample`
    /// both operate on the already-scaled value everywhere downstream.
    func scaled(by factor: Double) -> HistoryStore.SeriesPoint {
        HistoryStore.SeriesPoint(
            timestamp: timestamp,
            average: average * factor,
            minimum: minimum * factor,
            maximum: maximum * factor,
            sampleCount: sampleCount
        )
    }
}

// MARK: - Environment

/// Hands the app-lifetime `HistoryStore` instance `AppDelegate` owns down
/// to `HistoryPage` through the environment — this store is an `actor`,
/// not an `ObservableObject`, so it can't ride `.environmentObject` the
/// way `AlertsEngine`/`SettingsStore` do; every access already goes
/// through `await`, matching how the rest of this app already reaches
/// provider data. Defaults to `nil` (never a real store) so `HistoryPage`
/// previews and any window this key isn't explicitly set on still render,
/// degrading the same honest way a provider-less preview already does
/// elsewhere in this app.
private struct HistoryStoreKey: EnvironmentKey {
    static let defaultValue: HistoryStore? = nil
}

extension EnvironmentValues {
    var historyStore: HistoryStore? {
        get { self[HistoryStoreKey.self] }
        set { self[HistoryStoreKey.self] = newValue }
    }
}
