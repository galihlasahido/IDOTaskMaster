import AppKit
import SwiftUI

/// Benchmarks page — PLAN.md §1.1 "Benchmarks" (a former [name removed] Pro page,
/// unlocked here per §2) / §4 M7's first task: "native progress during
/// runs, large numeric results, history table."
///
/// PLAN.md §2's design language spells out exactly what those two UI
/// pieces replace: "Dropped from [name removed]: ... analog benchmark gauges
/// (become native progress + large numeric results)." So each benchmark
/// gets a plain card — icon, title, a Run/Cancel button, a system
/// `ProgressView` while it's running, and its latest result as a big
/// `.monospacedDigit()` number (the same headline-reading typography
/// `SummaryPage`'s CPU Overview readout uses) once it has one — rather
/// than [name removed]'s odometer-digit dial. Every completed run, across every
/// kind, also lands in a `DataTable` history list below the cards.
///
/// PLAN.md §4 M7's third task — "Score page: aggregate score card,
/// baseline constant, 'Run All'" — lives as this same page's second tab
/// rather than its own sidebar row: [name removed]'s own sidebar inventory (§1.1)
/// never lists a standalone "Score" entry, only "Benchmarks," with its
/// "[name removed] Score page" described as part of that same section. The
/// segmented `tabPicker` below switches between `.tests` (the card grid
/// + history table described above) and `.score` (`ScoreCard` — one
/// number folding every kind's latest result onto `BenchmarkBaseline`'s
/// shared points scale, plus a per-kind breakdown and the page-level "Run
/// All" control). Both tabs share one `BenchmarksViewModel`, so a result
/// produced from either tab is immediately visible on the other.
///
/// This page's `BenchmarkCatalog` registers a real `BenchmarkRunner` per
/// `BenchmarkKind` (`CPUBenchmarkRunner`, `GPUBenchmarkRunner`,
/// `DiskBenchmarkRunner`, `InternetBenchmarkRunner` — PLAN.md §4 M7's
/// second task), each still following the same "Unavailable, never a
/// fabricated score" rule for whatever it can't measure (no Metal-capable
/// GPU, no internet connection, ...) via `BenchmarkRunEvent.failed` — the
/// same reason `BenchmarkBaseline`'s own aggregate never interpolates a
/// number for a kind that hasn't completed a run.
struct BenchmarksPage: View {
    @StateObject private var model = BenchmarksViewModel()
    @State private var diskTestFolderPath = FileManager.default.homeDirectoryForCurrentUser.path
    @State private var historySort: DataTableSort? = DataTableSort(columnID: "date", ascending: false)
    @State private var selectedHistoryID: UUID?

    private static let cardGridColumns = [GridItem(.adaptive(minimum: 240), spacing: 10)]

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            tabPicker
            Divider()
            switch model.selectedTab {
            case .tests:
                cardsSection
                Divider()
                historySection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .score:
                scoreSection
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { chooseFolderButton }
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.historyColumns, rows: model.history, suggestedName: "Benchmark History")
            }
        }
        // Stops a Run All sequence from silently continuing to start its
        // next kind after this page is gone, not just the single run in
        // flight — `cancelRunAll()` clears `runAllQueue` before cancelling,
        // `cancelActiveRun()` alone would not.
        .onDisappear { model.cancelRunAll() }
    }

    // MARK: - Tabs

    /// PLAN.md §4 M7's Benchmarks-page tests vs. its Score-page tab —
    /// same segmented-`Picker` shape `SummaryPage`'s `CPUOverviewTab` and
    /// `PerformancePage`'s `GPUEngineTab` already use for an in-page
    /// switch.
    private var tabPicker: some View {
        Picker("Benchmarks Tab", selection: $model.selectedTab) {
            ForEach(BenchmarksTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        if let runningKind = model.runningKind {
            return "Running \(runningKind.title)\u{2026}"
        }
        let completedCount = BenchmarkKind.allCases.filter { model.latestResult(for: $0) != nil }.count
        var text = "\(completedCount) of \(BenchmarkKind.allCases.count) benchmarks have a result"
        if !model.history.isEmpty {
            text += " \u{2014} " + (model.history.count == 1 ? "1 run in history" : "\(model.history.count) runs in history")
        }
        return text
    }

    // MARK: - Toolbar

    private var chooseFolderButton: some View {
        Button {
            chooseDiskTestFolder()
        } label: {
            Label("Choose Disk Test Folder\u{2026}", systemImage: "folder")
        }
        .disabled(model.isRunning)
        .help("Choose the folder the Disk benchmark reads and writes its test file in \u{2014} currently \u{201C}\((diskTestFolderPath as NSString).lastPathComponent)\u{201D}")
    }

    private func chooseDiskTestFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: diskTestFolderPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        diskTestFolderPath = url.path
    }

    // MARK: - Cards

    /// One `BenchmarkCard` per `BenchmarkKind`, in that enum's declaration
    /// order — mirrors `ConnectionsPage.statTileRow`'s own non-scrolling
    /// `LazyVGrid` shape (a handful of fixed cards above an expanding
    /// table), rather than giving five cards their own `ScrollView`.
    private var cardsSection: some View {
        LazyVGrid(columns: Self.cardGridColumns, spacing: 10) {
            ForEach(BenchmarkKind.allCases) { kind in
                BenchmarkCard(
                    kind: kind,
                    result: model.latestResult(for: kind),
                    progress: model.progress(for: kind),
                    unavailableReason: model.unavailableReason(for: kind),
                    isRunning: model.runningKind == kind,
                    runDisabled: model.isRunning,
                    runAction: {
                        model.start(kind, context: BenchmarkRunContext(diskTestFolderPath: diskTestFolderPath))
                    },
                    cancelAction: { model.cancelActiveRun() }
                )
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - History

    /// PLAN.md's "results History table" — every completed run, across
    /// every kind, most recent first. Mirrors `DiskSpacePage
    /// .historySection`'s own header-row-plus-`DataTable` shape.
    private var historySection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Every completed benchmark run, most recent first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear History") {
                    model.clearHistory()
                }
                .disabled(model.history.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            DataTable(
                columns: Self.historyColumns,
                rows: model.history,
                sort: $historySort,
                selection: $selectedHistoryID,
                emptyMessage: "No benchmark runs yet."
            )
        }
    }

    private static let historyColumns: [DataTableColumn<BenchmarkResult>] = [
        DataTableColumn(id: "test", title: "Test", value: { $0.kind.title }) { result in
            HStack(spacing: 6) {
                Image(systemName: result.kind.systemImage)
                    .foregroundStyle(result.kind.domain.accentColor)
                    .frame(width: 14)
                Text(result.kind.title)
            }
        },
        DataTableColumn(id: "result", title: "Result", width: 240, value: { $0.metrics.first?.value ?? 0 }) { result in
            Text(Fmt.metricsSummary(result.metrics))
                .monospacedDigit()
        },
        DataTableColumn(id: "date", title: "Date", width: 150, value: { $0.generatedAt }) { result in
            Text(Self.historyTimeFormatter.string(from: result.generatedAt))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        },
        DataTableColumn(id: "detail", title: "Detail", value: { $0.detail ?? "" }) { result in
            Text(result.detail ?? "\u{2014}")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        },
    ]

    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    // MARK: - Score

    /// PLAN.md §4 M7's third task, laid out as `ScoreCard` (the "aggregate
    /// score card") over `BenchmarkBreakdownList` (what the card's one
    /// number is made of) — computed fresh from `model.latestResult(for:)`
    /// every time this tab draws, so it always reflects whichever kind
    /// most recently finished on either tab.
    private var scoreSection: some View {
        let aggregate = BenchmarkAggregateScore.compute(latestResult: model.latestResult)
        return ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ScoreCard(
                    aggregate: aggregate,
                    isRunningAll: model.isRunningAll,
                    runAllProgress: model.runAllProgress,
                    // Only a *different*, single-kind run blocks starting
                    // Run All — while Run All itself is in progress the
                    // button stays enabled as the Cancel action instead
                    // (`ScoreCard.runAllButton` picks the action/label from
                    // `isRunningAll`, this only gates whether it's tappable
                    // at all).
                    runAllDisabled: model.isRunning && !model.isRunningAll,
                    runAllAction: {
                        model.runAll(context: BenchmarkRunContext(diskTestFolderPath: diskTestFolderPath))
                    },
                    cancelAllAction: { model.cancelRunAll() }
                )
                BenchmarkBreakdownList(perKind: aggregate.perKind)
            }
            .padding(14)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

// MARK: - Benchmarks tab

/// `BenchmarksPage.tabPicker`'s two segments — see that page's own doc
/// comment for why Score is a tab here rather than its own sidebar row.
enum BenchmarksTab: String, CaseIterable, Identifiable {
    case tests
    case score

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tests: "Tests"
        case .score: "Score"
        }
    }
}

// MARK: - Score card

/// PLAN.md's "aggregate score card" — `BenchmarksPage.scoreSection`'s
/// headline number, plus the page-level "Run All" control. Pure like
/// `BenchmarkCard`: it only draws whatever `BenchmarkAggregateScore` /
/// run-all state it's handed, with no idea where either came from.
private struct ScoreCard: View {
    let aggregate: BenchmarkAggregateScore
    let isRunningAll: Bool
    /// `(1-based index of the kind currently running, total kinds)` —
    /// non-`nil` exactly while `isRunningAll` is `true`.
    let runAllProgress: (index: Int, total: Int)?
    let runAllDisabled: Bool
    let runAllAction: () -> Void
    let cancelAllAction: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            scoreReadout
            Text(footerText)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        // Same dynamic chrome `BenchmarkCard`/`StatTile` already use — no
        // custom hex values here either.
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "rosette")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("IDOTaskMaster Score")
                .font(.headline)
            Spacer(minLength: 8)
            runAllButton
        }
    }

    private var runAllButton: some View {
        Button {
            isRunningAll ? cancelAllAction() : runAllAction()
        } label: {
            Label(isRunningAll ? "Cancel" : "Run All", systemImage: isRunningAll ? "xmark.circle" : "play.fill")
        }
        .controlSize(.small)
        .disabled(!isRunningAll && runAllDisabled)
        .help(isRunningAll ? "Cancel the Run All sequence" : "Run every benchmark, one after another, then update the aggregate score")
    }

    @ViewBuilder
    private var scoreReadout: some View {
        if isRunningAll, let runAllProgress {
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: Double(runAllProgress.index - 1), total: Double(runAllProgress.total))
                Text("Running \(runAllProgress.index) of \(runAllProgress.total)\u{2026}")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } else if let overallPoints = aggregate.overallPoints {
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(Fmt.number(overallPoints))
                    .font(.system(size: 40, weight: .semibold))
                    .monospacedDigit()
                Text("pts")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Not enough results yet \u{2014} run at least one benchmark on the Tests tab, or tap Run All.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var footerText: String {
        var text = "\(aggregate.completedCount) of \(aggregate.totalCount) tests included \u{00B7} \(BenchmarkBaseline.referenceLabel)"
        if let generatedAt = aggregate.generatedAt {
            text += " \u{2014} newest result \(Self.timeFormatter.string(from: generatedAt))"
        }
        return text
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Score breakdown

/// `BenchmarksPage.scoreSection`'s per-test list under `ScoreCard` — what
/// the aggregate's one number is made of, each row showing that kind's
/// own points on `BenchmarkBaseline`'s shared scale or "Not run yet"
/// rather than a blank/zero row.
private struct BenchmarkBreakdownList: View {
    let perKind: [BenchmarkKindScore]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Per-Test Breakdown")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(Array(perKind.enumerated()), id: \.element.id) { index, entry in
                    row(entry)
                    if index < perKind.count - 1 {
                        Divider()
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func row(_ entry: BenchmarkKindScore) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entry.kind.systemImage)
                .foregroundStyle(entry.kind.domain.accentColor)
                .frame(width: 16)
            Text(entry.kind.title)
                .font(.callout)
            Spacer(minLength: 8)
            if let points = entry.points {
                Text("\(Fmt.number(points)) pts")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("Not run yet")
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

// MARK: - Benchmark card

/// One benchmark's card in `BenchmarksPage.cardsSection` — icon, title, a
/// Run/Cancel button, and whichever of PLAN.md's "native progress during
/// runs" / "large numeric results" states currently applies. Pure like
/// `StatTile`/`DataTable`: it only knows how to lay out the state it's
/// given, with no idea where a result or a running-progress tick came
/// from — `BenchmarksViewModel` owns that.
private struct BenchmarkCard: View {
    let kind: BenchmarkKind
    /// This kind's most recent result, whether from this launch's own run
    /// or reloaded from persisted history. `nil` before any run has ever
    /// completed for this kind.
    let result: BenchmarkResult?
    /// Non-`nil` only while `isRunning` is `true`.
    let progress: BenchmarkProgress?
    /// Set when this kind's most recent run attempt failed (e.g. no
    /// Metal-capable GPU, no internet connection — each runner's own
    /// `BenchmarkRunEvent.failed` reason, never a fabricated result). Left
    /// in place alongside a still-populated `result` from an earlier
    /// successful run, the same "one bad attempt doesn't blank an
    /// otherwise-good result" rule `DiskSpaceViewModel.unavailableReason`
    /// follows.
    let unavailableReason: String?
    /// `true` while this exact kind is the one currently running.
    let isRunning: Bool
    /// `true` when some *other* kind is running — disables this card's Run
    /// button (only one benchmark runs at a time) without touching a
    /// currently-running card's own Cancel button.
    let runDisabled: Bool
    let runAction: () -> Void
    let cancelAction: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        // Same dynamic `NSColor.controlBackgroundColor`/`.separatorColor`
        // chrome `StatTile`'s own card uses — no custom hex values here
        // either.
        .background(shape.fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(shape.strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1))
        .clipShape(shape)
        .accessibilityElement(children: .combine)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: kind.systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(kind.domain.accentColor)
                .frame(width: 16)
            Text(kind.title)
                .font(.callout)
                .fontWeight(.medium)
                .lineLimit(1)
            Spacer(minLength: 8)
            runButton
        }
    }

    private var runButton: some View {
        Button {
            isRunning ? cancelAction() : runAction()
        } label: {
            Label(isRunning ? "Cancel" : "Run", systemImage: isRunning ? "xmark.circle" : "play.fill")
        }
        .controlSize(.small)
        .disabled(!isRunning && runDisabled)
        .help(isRunning ? "Cancel this benchmark run" : "Run the \(kind.title) benchmark")
    }

    // MARK: - Body content per state

    @ViewBuilder
    private var content: some View {
        if isRunning {
            runningState
        } else if let result {
            resultState(result)
        } else if let unavailableReason {
            unavailableState(unavailableReason)
        } else {
            notRunState
        }
    }

    /// PLAN.md's "native progress during runs": a system `ProgressView`,
    /// determinate whenever the runner knows a real fraction and
    /// indeterminate otherwise — the same `fraction == nil` ⇒ spinner rule
    /// `DiskSpacePage.progressBanner` uses for its own always-indeterminate
    /// scan progress.
    private var runningState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let fraction = progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Text(progress?.phase ?? "Running\u{2026}")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    /// PLAN.md's "large numeric results": one big `.monospacedDigit()`
    /// reading per `BenchmarkMetric` (a lone "Score" for CPU/GPU, a
    /// Read/Write or Download/Upload pair for Disk/Internet).
    private func resultState(_ result: BenchmarkResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            metricsRow(result.metrics)
            Text(footerText(result))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func metricsRow(_ metrics: [BenchmarkMetric]) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 20) {
            ForEach(metrics) { metric in
                VStack(alignment: .leading, spacing: 0) {
                    Text(metric.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .lastTextBaseline, spacing: 3) {
                        Text(Fmt.number(metric.value))
                            .font(.system(size: 26, weight: .semibold))
                            .monospacedDigit()
                        if !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func footerText(_ result: BenchmarkResult) -> String {
        var text = "as of \(Self.timeFormatter.string(from: result.generatedAt))"
        if let detail = result.detail {
            text += " \u{2014} \(detail)"
        }
        return text
    }

    private func unavailableState(_ reason: String) -> some View {
        Text("Unavailable: \(reason)")
            .font(.caption)
            .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
            .lineLimit(2)
    }

    private var notRunState: some View {
        Text("Not run yet.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Formatting

private enum Fmt {
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "\u{2014}" }
        return numberFormatter.string(from: NSNumber(value: value)) ?? String(format: "%.1f", value)
    }

    /// One-line summary of every metric in a result, e.g. "Score 12,480" or
    /// "Read 512.0 MB/s \u{00B7} Write 480.2 MB/s" — the history table's
    /// "Result" column.
    static func metricsSummary(_ metrics: [BenchmarkMetric]) -> String {
        guard !metrics.isEmpty else { return "\u{2014}" }
        return metrics.map { metric in
            let valueText = number(metric.value)
            return metric.unit.isEmpty ? "\(metric.label) \(valueText)" : "\(metric.label) \(valueText) \(metric.unit)"
        }.joined(separator: " \u{00B7} ")
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

// MARK: - View model

/// Drives every `BenchmarkRunner` in `BenchmarkCatalog` for
/// `BenchmarksPage`: runs at most one benchmark at a time, relays its live
/// `.progress`/terminal events into per-kind `@Published` state, and
/// maintains the persisted results history.
///
/// History is stored as JSON under one `UserDefaults` key rather than
/// through `SettingsStore` — it's run *data*, not a user preference —
/// mirroring `DiskSpaceViewModel`'s own reasoning and persisted eagerly on
/// every change so a completed run survives a crash or force-quit, not
/// just a clean exit.
@MainActor
final class BenchmarksViewModel: ObservableObject {
    /// `BenchmarksPage.tabPicker`'s current selection — lives here (rather
    /// than a plain `@State` on the page) so it survives whichever tab's
    /// `View` value gets recreated by SwiftUI, matching where
    /// `SummaryPage`'s own `CPUOverviewTab` selection and
    /// `PerformancePage`'s `GPUEngineTab` selection already live.
    @Published var selectedTab: BenchmarksTab = .tests
    /// The kind currently running, or `nil` when nothing is — only one run
    /// is ever active at a time.
    @Published private(set) var runningKind: BenchmarkKind?
    @Published private var latestResults: [BenchmarkKind: BenchmarkResult] = [:]
    @Published private var liveProgress: [BenchmarkKind: BenchmarkProgress] = [:]
    @Published private var unavailableReasons: [BenchmarkKind: String] = [:]
    @Published private(set) var history: [BenchmarkResult] = []
    /// Non-`nil` exactly while a "Run All" sequence (PLAN.md's Score-page
    /// task) is in progress — the kinds still queued behind whichever one
    /// is `runningKind` right now, in the order they'll start. `nil` both
    /// before a sequence starts and once it (or its last kind) finishes.
    @Published private(set) var runAllQueue: [BenchmarkKind]?

    private let runners: [BenchmarkKind: BenchmarkRunner]
    private var runTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let historyDefaultsKey = "benchmarkHistory"
    private static let historyLimit = 200

    /// - Parameters:
    ///   - runners: Which `BenchmarkRunner` backs each kind. Defaults to
    ///     `BenchmarkCatalog.makeRunners()`; a test can substitute its own
    ///     to exercise a run without touching real hardware.
    ///   - defaults: The `UserDefaults` suite history is persisted to.
    ///     Defaults to `.standard`; tests should pass an isolated suite,
    ///     matching `SettingsStore.init(defaults:)`'s own reasoning.
    init(
        runners: [BenchmarkKind: BenchmarkRunner] = BenchmarkCatalog.makeRunners(),
        defaults: UserDefaults = .standard
    ) {
        self.runners = runners
        self.defaults = defaults
        let loadedHistory = Self.loadHistory(from: defaults)
        history = loadedHistory
        // Seed each kind's headline card from its most recent history
        // entry (history is stored most-recent-first) so a relaunch still
        // shows the last result rather than reading as "Not run yet."
        for result in loadedHistory where latestResults[result.kind] == nil {
            latestResults[result.kind] = result
        }
    }

    var isRunning: Bool { runningKind != nil }
    /// `true` for the whole span of a "Run All" sequence, including the
    /// brief gaps between one kind finishing and the next one starting —
    /// distinct from `isRunning`, which is only `true` while some kind's
    /// runner is actually mid-run.
    var isRunningAll: Bool { runAllQueue != nil }

    func latestResult(for kind: BenchmarkKind) -> BenchmarkResult? { latestResults[kind] }
    func progress(for kind: BenchmarkKind) -> BenchmarkProgress? { liveProgress[kind] }
    func unavailableReason(for kind: BenchmarkKind) -> String? { unavailableReasons[kind] }

    /// Starts `kind`'s run, unless one is already active (the Run button
    /// for every other kind is disabled while `isRunning`, so this guard
    /// is a safety net, not the primary gate). `context` is only consulted
    /// by the Disk runner today (PLAN.md's "choose test folder"); every
    /// other kind ignores it.
    func start(_ kind: BenchmarkKind, context: BenchmarkRunContext) {
        guard runningKind == nil, let runner = runners[kind] else { return }
        runningKind = kind
        liveProgress[kind] = nil
        unavailableReasons[kind] = nil

        // `runner` (a plain local from the `guard` above, not a property
        // access) is captured into the `Task` below as-is, and
        // `run(context:)` called fresh inside the `Task`'s own body — the
        // same shape `DiskSpaceViewModel.startScan()` uses for
        // `DiskSpaceScanner`.
        runTask = Task { [weak self] in
            for await event in runner.run(context: context) {
                guard let self else { return }
                self.handle(event, kind: kind)
            }
            self?.runningKind = nil
            self?.runTask = nil
            // If this run was one step of a "Run All" sequence, start its
            // next queued kind now — however this run ended (completed,
            // failed, or cancelled): one bad/skipped test shouldn't abort
            // the rest of the suite, the same reasoning [name removed]'s own
            // Start-the-whole-suite behavior implies. A no-op when
            // `runAllQueue` is `nil` (this was an ordinary single-kind
            // run, or `cancelRunAll()` already cleared the queue).
            self?.advanceRunAllQueue(context: context)
        }
    }

    /// Cancels whichever run is active, if any (a no-op otherwise) —
    /// mirrors `DiskSpaceViewModel.cancelScan()`. Leaves `runAllQueue`
    /// alone, so a Run All sequence in progress continues to its next
    /// kind once this cancellation lands — use `cancelRunAll()` to stop
    /// the whole sequence instead.
    func cancelActiveRun() {
        guard let runningKind else { return }
        runners[runningKind]?.cancelActiveRun()
    }

    /// Starts every `BenchmarkKind`, one at a time in `BenchmarkKind
    /// .allCases` order — PLAN.md §4 M7's "Run All." A no-op if a run
    /// (single-kind or an already-active Run All) is in progress.
    /// `context` is forwarded to every kind's `start(_:context:)` call the
    /// same way a single Run does.
    func runAll(context: BenchmarkRunContext) {
        guard runningKind == nil, runAllQueue == nil else { return }
        var queue = BenchmarkKind.allCases
        let first = queue.removeFirst()
        runAllQueue = queue
        start(first, context: context)
    }

    /// Stops a Run All sequence: clears `runAllQueue` (so the currently
    /// running kind's own termination won't advance to a next one), then
    /// cancels that kind's run exactly like `cancelActiveRun()`. A no-op
    /// if no Run All sequence is active.
    func cancelRunAll() {
        guard runAllQueue != nil else { return }
        runAllQueue = nil
        cancelActiveRun()
    }

    /// `(1-based index of the kind currently running or about to start,
    /// total kinds)` while a Run All sequence is active — `nil` otherwise.
    /// Feeds the Score page's "Running N of 5\u{2026}" caption.
    var runAllProgress: (index: Int, total: Int)? {
        guard let runAllQueue else { return nil }
        let total = BenchmarkKind.allCases.count
        let remaining = runAllQueue.count + (runningKind != nil ? 1 : 0)
        return (total - remaining + 1, total)
    }

    /// If a Run All sequence is active, starts its next queued kind now
    /// that the previous one has finished; ends the sequence
    /// (`runAllQueue = nil`) once the queue runs out. A no-op if no
    /// sequence is active.
    private func advanceRunAllQueue(context: BenchmarkRunContext) {
        guard var queue = runAllQueue else { return }
        guard !queue.isEmpty else {
            runAllQueue = nil
            return
        }
        let next = queue.removeFirst()
        runAllQueue = queue
        start(next, context: context)
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private func handle(_ event: BenchmarkRunEvent, kind: BenchmarkKind) {
        switch event {
        case .progress(let progress):
            liveProgress[kind] = progress
        case .completed(let result):
            liveProgress[kind] = nil
            latestResults[kind] = result
            recordHistory(result)
        case .failed(let reason):
            liveProgress[kind] = nil
            unavailableReasons[kind] = reason
        case .cancelled:
            liveProgress[kind] = nil
        }
    }

    /// Records a completed run at the front of `history`, then trims to
    /// `historyLimit`. Unlike `DiskSpaceViewModel.recordHistory(_:)` this
    /// never de-duplicates by kind — every run is its own history row,
    /// since comparing runs over time is the whole point of a benchmark
    /// history table.
    private func recordHistory(_ result: BenchmarkResult) {
        history.insert(result, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyDefaultsKey)
    }

    private static func loadHistory(from defaults: UserDefaults) -> [BenchmarkResult] {
        guard let data = defaults.data(forKey: historyDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([BenchmarkResult].self, from: data)) ?? []
    }
}

// MARK: - Previews

#Preview("Live page") {
    BenchmarksPage()
        .frame(width: 900, height: 700)
}

/// Preview-only fixture data — mirrors `StatTile`/`DataTable`'s own
/// preview fixtures, none of which round-trips through a real
/// `BenchmarkRunner`. Demonstrates the "large numeric results" and
/// history-table states before any real engine lands.
private enum BenchmarksPagePreviewFixture {
    /// Builds an isolated `UserDefaults` suite pre-seeded with fixture
    /// history, for `BenchmarksPageSeededPreview`'s `@StateObject` default
    /// value to load — kept as a plain (non-`@MainActor`) function
    /// returning `UserDefaults` rather than the `@MainActor`
    /// `BenchmarksViewModel` itself, so the actor-isolated
    /// `BenchmarksViewModel.init` is only ever called directly from a
    /// View's own stored-property default (as `DiskSpacePage`'s
    /// `@StateObject private var model = DiskSpaceViewModel()` does),
    /// never through an intermediate nonisolated static method.
    static func seededDefaults() -> UserDefaults {
        let suiteName = "BenchmarksPagePreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        let history: [BenchmarkResult] = [
            BenchmarkResult(
                id: UUID(), kind: .cpuMultiCore, generatedAt: Date(),
                metrics: [BenchmarkMetric(label: "Score", value: 18420, unit: "pts")],
                detail: "14 cores"
            ),
            BenchmarkResult(
                id: UUID(), kind: .cpuSingleCore, generatedAt: Date().addingTimeInterval(-40),
                metrics: [BenchmarkMetric(label: "Score", value: 2840, unit: "pts")],
                detail: nil
            ),
            BenchmarkResult(
                id: UUID(), kind: .diskReadWrite, generatedAt: Date().addingTimeInterval(-3600),
                metrics: [
                    BenchmarkMetric(label: "Read", value: 5120, unit: "MB/s"),
                    BenchmarkMetric(label: "Write", value: 4380, unit: "MB/s"),
                ],
                detail: "~/Downloads"
            ),
            BenchmarkResult(
                id: UUID(), kind: .internetSpeed, generatedAt: Date().addingTimeInterval(-86400),
                metrics: [
                    BenchmarkMetric(label: "Download", value: 412.6, unit: "Mbps"),
                    BenchmarkMetric(label: "Upload", value: 38.2, unit: "Mbps"),
                ],
                detail: nil
            ),
        ]
        if let data = try? JSONEncoder().encode(history) {
            defaults.set(data, forKey: "benchmarkHistory")
        }
        return defaults
    }
}

private struct BenchmarksPageSeededPreview: View {
    @StateObject private var model = BenchmarksViewModel(
        runners: BenchmarkCatalog.makeRunners(),
        defaults: BenchmarksPagePreviewFixture.seededDefaults()
    )

    var body: some View {
        VStack(spacing: 0) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 10)], spacing: 10) {
                ForEach(BenchmarkKind.allCases) { kind in
                    BenchmarkCard(
                        kind: kind,
                        result: model.latestResult(for: kind),
                        progress: model.progress(for: kind),
                        unavailableReason: model.unavailableReason(for: kind),
                        isRunning: model.runningKind == kind,
                        runDisabled: model.isRunning,
                        runAction: {},
                        cancelAction: {}
                    )
                }
            }
            .padding(10)
        }
    }
}

#Preview("Cards with results (fixture data)") {
    BenchmarksPageSeededPreview()
        .frame(width: 760, height: 260)
}

#Preview("Card states") {
    VStack(spacing: 10) {
        BenchmarkCard(
            kind: .cpuMultiCore,
            result: BenchmarkResult(
                id: UUID(), kind: .cpuMultiCore, generatedAt: Date(),
                metrics: [BenchmarkMetric(label: "Score", value: 18420, unit: "pts")],
                detail: "14 cores"
            ),
            progress: nil, unavailableReason: nil, isRunning: false, runDisabled: false,
            runAction: {}, cancelAction: {}
        )
        BenchmarkCard(
            kind: .diskReadWrite,
            result: nil,
            progress: BenchmarkProgress(fraction: 0.42, phase: "Measuring writes\u{2026}"),
            unavailableReason: nil, isRunning: true, runDisabled: false,
            runAction: {}, cancelAction: {}
        )
        BenchmarkCard(
            kind: .gpuCompute,
            result: nil, progress: nil,
            unavailableReason: "No Metal-capable GPU was found on this Mac.",
            isRunning: false, runDisabled: false,
            runAction: {}, cancelAction: {}
        )
        BenchmarkCard(
            kind: .internetSpeed,
            result: nil, progress: nil, unavailableReason: nil,
            isRunning: false, runDisabled: true,
            runAction: {}, cancelAction: {}
        )
    }
    .padding()
    .frame(width: 340)
}
