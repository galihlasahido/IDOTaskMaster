import SwiftUI

/// Network Usage page — one of this app's own beyond-[name removed] additions
/// (PLAN.md §2: "per-process network traffic") / §4 M9's fourth task:
/// "`NetTrafficProvider` + Network Usage page: per-process send/receive
/// rates (nettop-style), sortable, with totals."
///
/// Layout mirrors `ConnectionsPage`'s shape (status line, a `StatTile`
/// row, then the table) minus that page's trailing `DetailPane` — a
/// traffic row's every field already reads directly off the table
/// (process, PID, two rates, two cumulative totals), so a separate detail
/// panel would just repeat what's already on screen rather than add
/// anything, unlike Connections' own multi-field socket detail.
///
/// `NetworkUsageViewModel` polls `NetTrafficProvider` on a 1-second
/// cadence — matching that provider's own `nettop -s 1` interval, so
/// (almost) every poll picks up a freshly completed block rather than
/// re-reading one still in flight — the same "poll a standing actor on
/// its own cadence" shape `ConnectionsViewModel` uses for
/// `ConnectionsProvider`.
struct NetworkUsagePage: View {
    @StateObject private var model = NetworkUsageViewModel()
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "receive", ascending: false)

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            statTileRow
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter by Process or PID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.columns, rows: filteredReadings, suggestedName: "Network Usage")
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Status line

    /// Mirrors `ConnectionsPage.statusLine`'s "live, updated at" caption
    /// plus its own "last refresh failed" disclosure — see
    /// `NetTrafficProvider.sample()`'s doc comment for why a stale
    /// `model.snapshot` and a fresh `model.unavailableReason` can be true
    /// at the same time (a `nettop` hiccup mid-session).
    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusIsProblem ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        guard let snapshot = model.snapshot else {
            if let reason = model.unavailableReason { return "Unavailable: \(reason)" }
            return "Loading\u{2026}"
        }
        let processText = snapshot.readings.count == 1 ? "1 process" : "\(snapshot.readings.count) processes"
        let updated = "as of \(Self.timeFormatter.string(from: snapshot.generatedAt))"
        var text = "\(processText) \u{2014} \(updated)"
        if let reason = model.unavailableReason {
            text += " \u{2014} last refresh failed: \(reason)"
        }
        return text
    }

    private var statusIsProblem: Bool {
        model.snapshot == nil || model.unavailableReason != nil
    }

    // MARK: - Stat tiles

    private static let tileGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// PLAN.md's "with totals": two live-rate tiles (each with its own
    /// sparkline, matching `ConnectionsPage.trafficTile`'s shape) plus
    /// two cumulative-since-observed byte totals and a process count —
    /// the page-level totals the per-process table's own "Total Sent"/
    /// "Total Received" columns roll up from.
    private var statTileRow: some View {
        LazyVGrid(columns: Self.tileGridColumns, spacing: 10) {
            sendRateTile
            receiveRateTile
            processesTile
            totalSentTile
            totalReceivedTile
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var sendRateTile: some View {
        StatTile(
            title: "Send Rate",
            systemImage: "arrow.up.circle",
            color: DomainPalette.networkOut,
            value: Fmt.bytesPerSecond(model.snapshot?.totalSendBytesPerSecond),
            isUnavailable: model.snapshot == nil
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "send", color: DomainPalette.networkOut, values: model.sendHistory)],
                valueRange: model.combinedRateRange,
                gridLineCount: 0,
                accessibilityLabel: "Total send rate history"
            )
            .frame(height: 28)
        }
    }

    private var receiveRateTile: some View {
        StatTile(
            title: "Receive Rate",
            systemImage: "arrow.down.circle",
            color: DomainPalette.networkIn,
            value: Fmt.bytesPerSecond(model.snapshot?.totalReceiveBytesPerSecond),
            isUnavailable: model.snapshot == nil
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "receive", color: DomainPalette.networkIn, values: model.receiveHistory)],
                valueRange: model.combinedRateRange,
                gridLineCount: 0,
                accessibilityLabel: "Total receive rate history"
            )
            .frame(height: 28)
        }
    }

    private var processesTile: some View {
        StatTile(
            title: "Processes",
            systemImage: "list.bullet.rectangle",
            color: Color(nsColor: .systemGray),
            value: model.snapshot.map { "\($0.readings.count)" } ?? "",
            secondaryText: "with network activity",
            isUnavailable: model.snapshot == nil
        )
    }

    private var totalSentTile: some View {
        StatTile(
            title: "Total Sent",
            systemImage: "arrow.up",
            color: DomainPalette.networkOut,
            value: model.snapshot.map { Fmt.bytes(Self.combinedBytesSent($0)) } ?? "",
            secondaryText: "since observed",
            isUnavailable: model.snapshot == nil
        )
    }

    private var totalReceivedTile: some View {
        StatTile(
            title: "Total Received",
            systemImage: "arrow.down",
            color: DomainPalette.networkIn,
            value: model.snapshot.map { Fmt.bytes(Self.combinedBytesReceived($0)) } ?? "",
            secondaryText: "since observed",
            isUnavailable: model.snapshot == nil
        )
    }

    private static func combinedBytesSent(_ snapshot: NetTrafficSnapshot) -> UInt64 {
        snapshot.readings.reduce(0) { $0 + $1.totalBytesSent }
    }

    private static func combinedBytesReceived(_ snapshot: NetTrafficSnapshot) -> UInt64 {
        snapshot.readings.reduce(0) { $0 + $1.totalBytesReceived }
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns,
            rows: filteredReadings,
            sort: $sort,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        guard model.snapshot != nil else { return "No traffic data available." }
        return searchText.isEmpty
            ? "No processes with network activity."
            : "No processes match the current filter."
    }

    private var filteredReadings: [NetTrafficReading] {
        guard let readings = model.snapshot?.readings else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return readings }
        return readings.filter { reading in
            (reading.processName?.lowercased().contains(needle) ?? false)
                || String(reading.pid).contains(needle)
        }
    }

    private static let columns: [DataTableColumn<NetTrafficReading>] = [
        DataTableColumn(id: "process", title: "Process", value: { $0.processName ?? "" }) { reading in
            Text(reading.processName ?? "Unavailable")
                .foregroundStyle(reading.processName == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        },
        DataTableColumn(id: "pid", title: "PID", width: 64, alignment: .trailing, value: { $0.pid }) { reading in
            Text("\(reading.pid)").monospacedDigit()
        },
        DataTableColumn(
            id: "send",
            title: "Send",
            width: 96,
            alignment: .trailing,
            comparator: { ($0.sendBytesPerSecond ?? -1) < ($1.sendBytesPerSecond ?? -1) }
        ) { reading in
            Text(Fmt.bytesPerSecond(reading.sendBytesPerSecond))
                .monospacedDigit()
                .foregroundStyle(reading.sendBytesPerSecond == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
        },
        DataTableColumn(
            id: "receive",
            title: "Receive",
            width: 96,
            alignment: .trailing,
            comparator: { ($0.receiveBytesPerSecond ?? -1) < ($1.receiveBytesPerSecond ?? -1) }
        ) { reading in
            Text(Fmt.bytesPerSecond(reading.receiveBytesPerSecond))
                .monospacedDigit()
                .foregroundStyle(reading.receiveBytesPerSecond == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
        },
        DataTableColumn(id: "totalSent", title: "Total Sent", width: 96, alignment: .trailing, value: { $0.totalBytesSent }) { reading in
            Text(Fmt.bytes(reading.totalBytesSent))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        },
        DataTableColumn(id: "totalReceived", title: "Total Received", width: 104, alignment: .trailing, value: { $0.totalBytesReceived }) { reading in
            Text(Fmt.bytes(reading.totalBytesReceived))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        },
    ]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Formatting

/// This page's own scoped byte/byte-rate formatter — matches
/// `ConnectionsPage`/`PowerFreqPage`'s own private `Fmt` enum in shape (a
/// `ByteCountFormatter` wrapper plus an honest "Unavailable" for `nil`),
/// extended with a plain cumulative-bytes formatter for this page's
/// "Total Sent"/"Total Received" columns and tiles (those are never
/// `nil` — `NetTrafficReading.totalBytesSent`/`totalBytesReceived` start
/// at `0`, not "Unavailable", the moment a pid is first seen).
private enum Fmt {
    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return byteFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func bytes(_ value: UInt64) -> String {
        let clamped = min(value, UInt64(Int64.max))
        return byteFormatter.string(fromByteCount: Int64(clamped))
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - View model

/// Drives `NetworkUsagePage`: polls `NetTrafficProvider` on a fixed 1-second
/// cadence and keeps a short combined-rate history per direction for the
/// stat tiles' sparklines — the same "own a private polling loop, keep a
/// capped history array" shape `ConnectionsViewModel` uses for its own
/// traffic sparkline, just with the polled provider *being* this page's
/// primary data source rather than a side reading alongside a different
/// one.
@MainActor
final class NetworkUsageViewModel: ObservableObject {
    @Published private(set) var snapshot: NetTrafficSnapshot?
    /// Set when the most recent poll threw; left in place alongside a
    /// still-populated `snapshot` after a single missed poll, matching
    /// `ConnectionsViewModel.unavailableReason`'s own rule.
    @Published private(set) var unavailableReason: String?
    /// Oldest-first combined-across-processes rate history, one entry per
    /// poll that produced a snapshot, capped at `historyLimit`. A `nil`
    /// entry marks a poll whose snapshot had no rate-bearing reading yet
    /// (`HistoryGraph`'s own "leave a gap, don't guess" convention).
    @Published private(set) var sendHistory: [Double?] = []
    @Published private(set) var receiveHistory: [Double?] = []

    /// `HistoryGraph`'s `valueRange` maps straight to pixel height with no
    /// auto-scaling of its own (see that type's doc comment) — its
    /// `0...100` default fits a percentage, not a byte rate that can run
    /// from zero to tens of megabytes/sec, so both sparkline tiles share
    /// this dynamically-sized range instead. Same "`0...max(peak, 1)`"
    /// shape `PerformancePage.PerformanceViewModel.dynamicRange(for:)`
    /// uses for its own network graph, and shared across both tiles
    /// (rather than each scaling to its own peak) so their heights stay
    /// visually comparable.
    var combinedRateRange: ClosedRange<Double> {
        let peak = (sendHistory + receiveHistory).compactMap { $0 }.max() ?? 0
        return 0...max(peak, 1)
    }

    private let provider = NetTrafficProvider()
    private var pollTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 1.0
    private static let historyLimit = 60

    func start() {
        guard pollTask == nil else { return }
        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.snapshot = result
                    self.unavailableReason = nil
                    self.appendHistory(result)
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.unavailableReason = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        let provider = provider
        Task { await provider.stop() }
    }

    private func appendHistory(_ snapshot: NetTrafficSnapshot) {
        sendHistory.append(snapshot.totalSendBytesPerSecond)
        receiveHistory.append(snapshot.totalReceiveBytesPerSecond)
        if sendHistory.count > Self.historyLimit {
            sendHistory.removeFirst(sendHistory.count - Self.historyLimit)
        }
        if receiveHistory.count > Self.historyLimit {
            receiveHistory.removeFirst(receiveHistory.count - Self.historyLimit)
        }
    }
}

#Preview {
    NetworkUsagePage()
        .frame(width: 900, height: 600)
}
