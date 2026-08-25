import AppKit
import SwiftUI

/// Menu bar live readout + popover mini-dashboard — PLAN.md §3's
/// `MenuBarExtraView.swift # menu bar live readout + popover mini-dashboard`
/// and §4 M8's third task: "compact live CPU/mem/network readout + popover
/// mini-dashboard (works while main window is closed)". Also one of this
/// app's own additions beyond the baseline feature set (PLAN.md §2,
/// M8–M10) — most comparable system monitors have no menu bar presence
/// at all.
///
/// "Works while main window is closed" is the one requirement this file
/// can't satisfy on its own: `MenuBarStatusModel.start()` is called once
/// from `AppDelegate.applicationDidFinishLaunching` (see that model's own
/// doc comment), not from any view's `onAppear`, so the live readout keeps
/// sampling for the whole process lifetime regardless of whether the main
/// `WindowGroup` window exists, is hidden (Settings ▸ Window's "Hide on
/// Close"), or was fully closed. The other half is
/// `AppDelegate.applicationShouldTerminateAfterLastWindowClosed`, changed
/// alongside this file to stop quitting the app just because that window
/// closed — see its doc comment for why a persistent menu bar item changes
/// that default.
///
/// Two views share one `MenuBarStatusModel`, wired together in
/// `IDOTaskMasterApp`'s new `MenuBarExtra` scene:
/// - `MenuBarExtraLabel` — the compact always-visible readout drawn into
///   the actual system menu bar (PLAN.md's "compact live CPU/mem/network
///   readout").
/// - `MenuBarPopoverView` — the mini-dashboard shown when that item is
///   clicked (PLAN.md's "popover mini-dashboard"), reusing this app's own
///   `StatTile`/`HistoryGraph`/`PageInfoBar` components rather than
///   inventing new chrome for a second, miniature copy of the app.
///
/// `.menuBarExtraStyle(.window)` (set on the scene in `IDOTaskMasterApp`)
/// is what makes the popover a real SwiftUI view — a plain
/// `.menuBarExtraStyle(.menu)` extra can only host `NSMenuItem`s, not a
/// `HistoryGraph` `Canvas` or a live `StatTile`.

// MARK: - Status model

/// Owns the single `Sampler` behind both `MenuBarExtraLabel` and
/// `MenuBarPopoverView`. Unlike every other `Sampler`-owning model in this
/// app (`AppShellStatusModel`, `SummaryViewModel`, `PerformanceViewModel`),
/// which start in a page's `onAppear` and stop in its `onDisappear` — "a
/// monitor shouldn't keep sampling while its own page isn't visible"
/// (`SummaryPage`'s doc comment) — this one has no such page: the menu bar
/// label is meant to read live at all times, specifically *including*
/// while nothing else is on screen, so `start()` is called exactly once,
/// from `AppDelegate.applicationDidFinishLaunching`, and is never paired
/// with a `stop()`. `Sampler`'s own `deinit` already cancels its tick task
/// and finishes every subscriber's stream, so nothing leaks — there's just
/// no earlier point in this app's lifetime where it would be correct to
/// stop it.
///
/// Fixed at `Sampler.Interval.slow` (1/sec) rather than following
/// `SettingsStore.updateSpeed` like the View menu's ⌘-1/2/3 commands are
/// meant to (that wiring is still a TODO for every `Sampler` in the app —
/// see `SettingsStore.updateSpeed`'s own doc comment): this one runs for
/// the app's entire lifetime, including whenever the main window is
/// closed, so it should default to the cheapest rate that still reads as
/// "live" for a glanceable menu bar number — PLAN.md §2's "lowest idle
/// overhead (a monitor must not be the load)" applies most to the one
/// `Sampler` that can never be paused.
///
/// Keeps a short `seriesHistory` (the same dotted-id ring-buffer pattern
/// `SummaryViewModel`/`PerformanceViewModel` use) for `MenuBarPopoverView`'s
/// three sparklines — CPU %, memory used %, and network send/receive —
/// trimmed to a much shorter capacity than those pages' full history since
/// a menu bar sparkline only needs to show "what just happened", not a
/// scrollable trend.
@MainActor
final class MenuBarStatusModel: ObservableObject {
    /// ~1 minute of history at this model's 1/sec rate — enough for
    /// `MenuBarPopoverView`'s sparklines to read as a trend without
    /// growing unbounded while the app (and this model) runs for hours.
    private static let historyCapacity = 60

    @Published private(set) var latest: Snapshot?
    /// `nil` entries are honest gaps (a tick that domain couldn't sample),
    /// matching `HistoryGraphSeries.values`' own contract — never
    /// backfilled with a guessed value.
    @Published private(set) var seriesHistory: [String: [Double?]] = [:]

    private let sampler = Sampler(interval: .slow)
    private var streamTask: Task<Void, Never>?

    /// Starts the live snapshot stream if it isn't already running. Safe
    /// to call repeatedly. See this type's doc comment for why the only
    /// caller is `AppDelegate.applicationDidFinishLaunching`, not any
    /// view's `onAppear`.
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

    /// One series' full history, oldest first — `HistoryGraph`'s expected
    /// order. An unknown id reads as an empty array (a blank sparkline),
    /// matching `SummaryViewModel.history(_:)`.
    func history(_ id: String) -> [Double?] {
        seriesHistory[id] ?? []
    }

    /// `HistoryGraph.valueRange` for a series pair with no fixed scale
    /// (network throughput, unlike CPU/memory's natural 0...100) — the
    /// same "0 to the highest sample currently in view, floored at 1 so a
    /// silent series doesn't divide by zero" formula
    /// `PerformanceViewModel.dynamicRange(for:)` uses.
    func dynamicRange(for ids: [String]) -> ClosedRange<Double> {
        let maxValue = ids.flatMap { seriesHistory[$0] ?? [] }.compactMap { $0 }.max() ?? 0
        return 0...max(maxValue, 1)
    }

    // MARK: - Convenience readings

    var cpuPercent: Double? { latest?.cpu?.totalUtilization }
    var memoryPercent: Double? { Self.usedPercent(latest?.memory) }
    var receiveBytesPerSecond: Double? { latest?.network?.receiveBytesPerSecond }
    var sendBytesPerSecond: Double? { latest?.network?.sendBytesPerSecond }
    var processCount: Int? { latest?.processCount }

    // MARK: - Ingest

    private func ingest(_ snapshot: Snapshot) {
        latest = snapshot

        // Mutated locally and assigned back once, batching every series'
        // update into a single `@Published` change notification — same
        // reasoning as `SummaryViewModel.ingest(_:)`.
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
        append("memory.usedPercent", Self.usedPercent(snapshot.memory))
        append("network.receive", snapshot.network?.receiveBytesPerSecond)
        append("network.send", snapshot.network?.sendBytesPerSecond)

        seriesHistory = history
    }

    /// `memory.usedBytes / memory.totalBytes * 100` — same formula as
    /// `SummaryPage.swift`'s own `memoryUsedPercent`, kept as a local copy
    /// per this codebase's own "not shared across files" `Fmt` convention
    /// (`SummaryPage.swift`'s `Fmt` doc comment).
    private static func usedPercent(_ memory: MemorySnapshot?) -> Double? {
        guard let memory, let total = memory.totalBytes, total > 0, let used = memory.usedBytes else { return nil }
        return Double(used) / Double(total) * 100
    }
}

// MARK: - Menu bar label

/// The always-visible readout drawn into the system menu bar — PLAN.md's
/// "compact live CPU/mem/network readout". No icon: at the menu bar's own
/// small scale, three short `C`/`M`/`↓` fields already read clearly as
/// this app's status item once seen once, and every character here is
/// screen real estate shared with every other menu bar item the user has.
struct MenuBarExtraLabel: View {
    @ObservedObject var model: MenuBarStatusModel

    var body: some View {
        Text(compactText)
            .monospacedDigit()
            .accessibilityLabel(accessibilityText)
    }

    private var compactText: String {
        "C \(MenuBarFmt.percent(model.cpuPercent))  M \(MenuBarFmt.percent(model.memoryPercent))  ↓\(MenuBarFmt.rateCompact(model.receiveBytesPerSecond))"
    }

    private var accessibilityText: String {
        "IDOTaskMaster. CPU \(MenuBarFmt.percent(model.cpuPercent)), Memory \(MenuBarFmt.percent(model.memoryPercent)), Network download \(MenuBarFmt.rateCompact(model.receiveBytesPerSecond)) per second."
    }
}

// MARK: - Popover mini-dashboard

/// The mini-dashboard shown when the menu bar item is clicked — PLAN.md's
/// "popover mini-dashboard". Three `StatTile`s (CPU, Memory, Network) over
/// a `PageInfoBar` footer: the same components and honest-degradation
/// conventions the full app's own pages use, at a width (`popoverWidth`)
/// that reads as a compact companion to the main window rather than a
/// second copy of it.
struct MenuBarPopoverView: View {
    @ObservedObject var model: MenuBarStatusModel
    /// Brings the main window forward — wired in `IDOTaskMasterApp` to
    /// `appDelegate.windowController.show()`, the same call
    /// `GlobalShortcutManager`'s Ctrl+Shift+Esc action and
    /// `AppDelegate.applicationShouldHandleReopen` already use to reach
    /// the app's one main window. A closure (rather than reaching into
    /// `AppDelegate` directly) keeps this view's dependency exactly what
    /// it uses, matching `Components/`'s pure-view convention even though
    /// this type lives in `App/`.
    var onOpenMainWindow: () -> Void

    private static let popoverWidth: CGFloat = 260
    private static let sparklineHeight: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            cpuTile
            memoryTile
            networkTile
            PageInfoBar(
                degradedProviderCount: model.latest?.degradedProviderCount ?? 0,
                totalProviderCount: model.latest?.providersHealth.count ?? 0,
                processCount: model.processCount,
                generation: model.latest?.generation
            )
            actionRow
        }
        .padding(12)
        .frame(width: Self.popoverWidth)
    }

    private var header: some View {
        Text("IDOTaskMaster")
            .font(.system(size: 13, weight: .semibold))
    }

    // MARK: - Tiles

    private var cpuTile: some View {
        StatTile(
            title: "CPU",
            systemImage: "cpu",
            color: DomainPalette.cpuUser,
            value: MenuBarFmt.percent(model.cpuPercent),
            isUnavailable: model.cpuPercent == nil
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "cpu.total", color: DomainPalette.cpuUser, values: model.history("cpu.total"))],
                gridLineCount: 0,
                accessibilityLabel: "CPU history, \(MenuBarFmt.percent(model.cpuPercent))"
            )
            .frame(height: Self.sparklineHeight)
        }
    }

    private var memoryTile: some View {
        StatTile(
            title: "Memory",
            systemImage: "memorychip",
            color: DomainPalette.memoryPressureNormal,
            value: MenuBarFmt.percent(model.memoryPercent),
            isUnavailable: model.memoryPercent == nil
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "memory.usedPercent", color: DomainPalette.memoryPressureNormal, values: model.history("memory.usedPercent"))],
                gridLineCount: 0,
                accessibilityLabel: "Memory history, \(MenuBarFmt.percent(model.memoryPercent))"
            )
            .frame(height: Self.sparklineHeight)
        }
    }

    /// Both rates share one tile — down as the headline `value` (the more
    /// commonly-watched of the two), up as `secondaryText` — rather than
    /// two separate tiles, keeping this popover's total height in
    /// proportion with the other two single-reading tiles above it.
    private var networkTile: some View {
        StatTile(
            title: "Network",
            systemImage: "network",
            color: DomainPalette.networkIn,
            value: "↓ \(MenuBarFmt.bytesPerSecond(model.receiveBytesPerSecond))",
            secondaryText: "↑ \(MenuBarFmt.bytesPerSecond(model.sendBytesPerSecond))",
            isUnavailable: model.receiveBytesPerSecond == nil && model.sendBytesPerSecond == nil
        ) {
            HistoryGraph(
                series: [
                    HistoryGraphSeries(id: "network.receive", color: DomainPalette.networkIn, values: model.history("network.receive")),
                    HistoryGraphSeries(id: "network.send", color: DomainPalette.networkOut, values: model.history("network.send")),
                ],
                valueRange: model.dynamicRange(for: ["network.receive", "network.send"]),
                gridLineCount: 0,
                accessibilityLabel: "Network history, download \(MenuBarFmt.bytesPerSecond(model.receiveBytesPerSecond)), upload \(MenuBarFmt.bytesPerSecond(model.sendBytesPerSecond))"
            )
            .frame(height: Self.sparklineHeight)
        }
    }

    // MARK: - Actions

    /// This style's popover has no built-in Quit the way a plain
    /// `.menuBarExtraStyle(.menu)` extra would — these two buttons are
    /// this window's entire chrome for "bring the app forward" and "leave
    /// it running no more", the popover's counterpart to `AppShell`'s
    /// Settings-footer button and the app's standard ⌘Q.
    private var actionRow: some View {
        HStack {
            Button("Open IDOTaskMaster", action: onOpenMainWindow)
                .buttonStyle(.bordered)
            Spacer(minLength: 8)
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Formatting

/// This file's own reading-to-string formatting — not shared across files,
/// matching every other page's private `Fmt` enum (`SummaryPage.swift`'s
/// doc comment on why).
private enum MenuBarFmt {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.0f%%", value)
    }

    /// A byte rate squeezed for the menu bar label's own tight horizontal
    /// space — a single-letter magnitude (K/M/G) and no "/s" suffix
    /// (implied: everything in the label is a live rate), unlike
    /// `bytesPerSecond(_:)` below's full `ByteCountFormatter` output used
    /// where the popover has room to spell it out.
    static func rateCompact(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let units: [(threshold: Double, suffix: String)] = [
            (1_073_741_824, "G"),
            (1_048_576, "M"),
            (1_024, "K"),
        ]
        for unit in units where value >= unit.threshold {
            return String(format: "%.1f%@", value / unit.threshold, unit.suffix)
        }
        return String(format: "%.0fB", value)
    }

    /// The popover tiles' network readouts — same `ByteCountFormatter`
    /// recipe as `SummaryPage.swift`'s own `Fmt.bytesPerSecond`.
    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - Previews

#Preview("Menu bar label") {
    MenuBarExtraLabel(model: MenuBarStatusModel())
        .padding(4)
        .background(Color(nsColor: .windowBackgroundColor))
}

#Preview("Popover mini-dashboard") {
    MenuBarPopoverView(model: MenuBarStatusModel(), onOpenMainWindow: {})
}
