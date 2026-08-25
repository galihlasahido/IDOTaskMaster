import SwiftUI

/// Network Usage page — one of this app's own additions beyond the
/// baseline feature set (PLAN.md §2: "per-process network traffic") /
/// §4 M9's fourth task:
/// "`NetTrafficProvider` + Network Usage page: per-process send/receive
/// rates (nettop-style), sortable, with totals."
///
/// Layout mirrors `ConnectionsPage`'s shape (status line, a `StatTile`
/// row, then the table), plus its own below-the-table `DetailPane` (not
/// trailing, like Connections' — this page's table is already six columns
/// wide with nothing to spare). A traffic row's rate/total fields already
/// read directly off the table, so the pane doesn't repeat those; it adds
/// the two things this page genuinely has nowhere else to show — the same
/// per-pid code-signing identity `ProcessesPage`'s own detail pane looks
/// up (`SigningInfoViewModel`, shared as-is — signing identity isn't a
/// Processes-specific concept), and that pid's own open sockets, looked up
/// from `ConnectionsProvider` the same one-shot-per-selection way (see
/// `NetworkConnectionsLookupViewModel` below) rather than continuously
/// polled — directly answering "what connections make up this traffic."
///
/// `NetworkTrafficMonitor` (`App/NetworkTrafficMonitor.swift`) polls
/// `NetTrafficProvider` on a 1-second cadence — matching that provider's
/// own `nettop -s 1` interval, so (almost) every poll picks up a freshly
/// completed block rather than re-reading one still in flight — the same
/// "poll a standing actor on its own cadence" shape `ConnectionsViewModel`
/// uses for `ConnectionsProvider`. Unlike `ConnectionsViewModel`, it's an
/// app-lifetime `@EnvironmentObject`, not this page's own `@StateObject`
/// — see its doc comment for why.
struct NetworkUsagePage: View {
    @EnvironmentObject private var model: NetworkTrafficMonitor
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "receive", ascending: false)
    @State private var selectedPID: pid_t?
    /// Shared with `ProcessesPage` as-is — a running process's
    /// code-signing identity isn't a Processes-specific concept, and
    /// fetching/caching it per pid works exactly the same way here.
    @StateObject private var signingModel = SigningInfoViewModel()
    @StateObject private var connectionsModel = NetworkConnectionsLookupViewModel()

    /// Matches `ProcessesPage.detailPaneHeight` in spirit — enough room
    /// for a signing summary plus a handful of connection rows without
    /// scrolling on this app's minimum window height.
    private static let detailPaneHeight: CGFloat = 220

    var body: some View {
        VStack(spacing: 0) {
            if model.hasStarted {
                statusLine
                Divider()
                statTileRow
                Divider()
                table
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detailPane
                    .frame(height: Self.detailPaneHeight)
            } else {
                idleState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter by Process or PID")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.columns, rows: filteredReadings, suggestedName: "Network Usage")
            }
        }
        .onChange(of: selectedPID) { pid in
            signingModel.load(pid: pid)
            connectionsModel.load(pid: pid)
        }
    }

    // MARK: - Idle state

    /// Shown in place of everything else until the user clicks "Start
    /// Collecting" — matching `DiskSpacePage`'s own user-initiated-scan
    /// shape (PLAN.md §2's restraint on standing background cost) rather
    /// than starting `nettop` the moment this page — or even the app
    /// itself — appears. See `NetworkTrafficMonitor`'s own doc comment.
    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "network")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Not Collecting Network Traffic")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Samples every process's send and receive rate once a second via nettop. Runs in the background once started, for the rest of this session.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Start Collecting") {
                model.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Status line

    /// Mirrors `ConnectionsPage.statusLine`'s "live, updated at" caption
    /// plus its own "last refresh failed" disclosure — see
    /// `NetTrafficProvider.sample()`'s doc comment for why a stale
    /// `model.snapshot` and a fresh `model.unavailableReason` can be true
    /// at the same time (a `nettop` hiccup mid-session).
    private var statusLine: some View {
        HStack(spacing: 6) {
            if model.snapshot == nil && model.isWarmingUp {
                ProgressView()
                    .controlSize(.small)
            }
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

    /// `isWarmingUp` gets its own, distinctly *not*-"Unavailable" wording
    /// and a `ProgressView` spinner above — worded/styled like a real
    /// problem (as it used to be, folded into `unavailableReason`) reads
    /// as "this app is broken" for however long `nettop`'s first block
    /// takes, rather than the ordinary one-time startup wait it actually
    /// is (see `NetworkTrafficMonitor`'s own doc comment).
    private var statusText: String {
        guard let snapshot = model.snapshot else {
            if model.isWarmingUp { return "Collecting the first traffic sample\u{2026}" }
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

    /// Dims the status line's text only for a genuine problem or the
    /// pre-first-sample gap where the tiles/table are still blank —
    /// *not* while merely `isWarmingUp`'s spinner is the reason nothing's
    /// shown yet, which reads as normal secondary-text loading rather
    /// than something wrong.
    private var statusIsProblem: Bool {
        model.snapshot == nil && !model.isWarmingUp
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
            selection: $selectedPID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        guard model.snapshot != nil else {
            if model.isWarmingUp { return "Collecting the first traffic sample\u{2026}" }
            return "No traffic data available."
        }
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

    // MARK: - Detail pane

    /// Caps how many of a busy process's sockets the "Connections" section
    /// lists individually — a browser or sync client can easily have
    /// dozens open at once, and past this many, "which exact ones" matters
    /// far less than "roughly how many" (the section's own title already
    /// states the true total).
    private static let connectionListLimit = 20

    @ViewBuilder
    private var detailPane: some View {
        if let reading = selectedReading {
            DetailPane(
                title: reading.processName ?? "Unavailable",
                subtitle: "PID \(reading.pid)",
                systemImage: "network",
                sections: detailSections(for: reading)
            )
        } else {
            DetailPane(emptyMessage: "Select a process to view its signing identity and open connections.")
        }
    }

    private var selectedReading: NetTrafficReading? {
        guard let selectedPID else { return nil }
        return model.snapshot?.readings.first(where: { $0.pid == selectedPID })
    }

    private func detailSections(for reading: NetTrafficReading) -> [DetailPaneSection] {
        [signingSection(for: reading.pid), connectionsSection(for: reading.pid)]
    }

    /// Mirrors `ProcessesPage.signingSection(for:)` field-for-field — see
    /// `SigningInfoViewModel`'s own doc comment for the shared lazy-fetch/
    /// cache-forever shape both pages rely on.
    private func signingSection(for pid: pid_t) -> DetailPaneSection {
        let info = signingModel.info(for: pid)
        return DetailPaneSection(title: "Signing", fields: [
            DetailPaneField(label: "Status", value: info?.statusLabel ?? "", isUnavailable: info == nil),
            DetailPaneField(label: "Notarized", value: notarizedLabel(info?.isNotarized), isUnavailable: info?.isNotarized == nil),
            DetailPaneField(label: "Team ID", value: info?.teamIdentifier ?? "", isUnavailable: info?.teamIdentifier == nil, isMonospaced: true),
            DetailPaneField(label: "Signing ID", value: info?.signingIdentifier ?? "", isUnavailable: info?.signingIdentifier == nil),
        ])
    }

    private func notarizedLabel(_ isNotarized: Bool?) -> String {
        guard let isNotarized else { return "" }
        return isNotarized ? "Yes" : "No"
    }

    /// This pid's own open sockets, from `NetworkConnectionsLookupViewModel`
    /// — the same three states `signingSection` already distinguishes
    /// (still loading / genuinely failed / loaded) rather than treating
    /// "no data yet" and "confirmed zero connections" as the same thing.
    private func connectionsSection(for pid: pid_t) -> DetailPaneSection {
        if connectionsModel.hasFailed(pid) {
            return DetailPaneSection(title: "Connections", fields: [
                DetailPaneField(label: "Status", value: "", isUnavailable: true),
            ])
        }
        guard let sockets = connectionsModel.sockets(for: pid) else {
            return DetailPaneSection(title: "Connections", fields: [
                DetailPaneField(label: "Status", value: "Loading\u{2026}"),
            ])
        }
        guard !sockets.isEmpty else {
            return DetailPaneSection(title: "Connections", fields: [
                DetailPaneField(label: "Open Sockets", value: "None"),
            ])
        }

        let shown = sockets.prefix(Self.connectionListLimit)
        var fields = shown.map { socket in
            DetailPaneField(
                id: "\(socket.descriptor)",
                label: connectionProtocolLabel(socket),
                value: connectionSummary(socket),
                isMonospaced: true
            )
        }
        if sockets.count > shown.count {
            fields.append(DetailPaneField(id: "more", label: "", value: "+\(sockets.count - shown.count) more\u{2026}"))
        }
        return DetailPaneSection(title: "Connections (\(sockets.count))", fields: fields)
    }

    /// "TCP4"/"UDP6"/"Unix" — same compact shape as `ConnectionsPage`'s own
    /// (private, so not directly reusable) `protocolLabel`.
    private func connectionProtocolLabel(_ socket: ConnectionSocket) -> String {
        guard let ipVersion = socket.ipVersion else { return socket.transport.rawValue }
        return "\(socket.transport.rawValue)\(ipVersion.rawValue)"
    }

    private func connectionSummary(_ socket: ConnectionSocket) -> String {
        if socket.transport == .unixDomain {
            return socket.unixPath ?? "Unavailable"
        }
        var text = "\(socket.localEndpoint) \u{2192} \(socket.remoteEndpoint)"
        if let exposure = socket.exposure {
            text += " (\(exposure.label))"
        }
        return text
    }
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
//
// `NetworkUsagePage`'s live data comes from `App/NetworkTrafficMonitor.swift`
// now — an app-lifetime `@EnvironmentObject` (owned by `AppDelegate`,
// started once at launch) rather than a per-page `@StateObject` started in
// `onAppear`/stopped in `onDisappear`. See that type's own doc comment for
// why: the backing `nettop` subprocess's slow first-block warm-up used to
// get paid on every single page visit.

/// Backs `NetworkUsagePage`'s detail pane's "Connections" section: fetches
/// `ConnectionsProvider.sample()` once per selected pid rather than
/// continuously polling it — a running process's socket list doesn't need
/// re-fetching every second just because this page's own traffic rates do,
/// the same reasoning `SigningInfoViewModel` gives for code-signing
/// identity. Filters `ConnectionsProvider`'s whole-system catalog down to
/// one pid client-side, the same shape `ConnectionsPage` itself already
/// uses (its filter chips), just scoped to a single process here. Results
/// are cached in `socketsByPID` for the life of this view model, same
/// never-evicted policy as `SigningInfoViewModel.infoByPID`.
@MainActor
final class NetworkConnectionsLookupViewModel: ObservableObject {
    @Published private(set) var socketsByPID: [pid_t: [ConnectionSocket]] = [:]
    /// Pids whose fetch threw — kept separate from `socketsByPID` so a
    /// genuine failure never reads as "confirmed zero connections," the
    /// same honest-gap distinction `NetTrafficReading`'s own rate fields
    /// draw between "no reading yet" and "measured zero."
    @Published private(set) var failedPIDs: Set<pid_t> = []

    private let provider = ConnectionsProvider()
    private var pendingPIDs: Set<pid_t> = []

    func sockets(for pid: pid_t) -> [ConnectionSocket]? {
        socketsByPID[pid]
    }

    func hasFailed(_ pid: pid_t) -> Bool {
        failedPIDs.contains(pid)
    }

    /// Starts a fetch for `pid` unless it's already cached, already
    /// known-failed, or already in flight. `pid == nil` (nothing selected)
    /// is a no-op.
    func load(pid: pid_t?) {
        guard let pid, socketsByPID[pid] == nil, !failedPIDs.contains(pid), !pendingPIDs.contains(pid) else { return }
        pendingPIDs.insert(pid)
        let provider = provider
        Task { [weak self] in
            guard let self else { return }
            do {
                let catalog = try await provider.sample()
                self.socketsByPID[pid] = catalog.sockets.filter { $0.pid == pid }
            } catch {
                self.failedPIDs.insert(pid)
            }
            self.pendingPIDs.remove(pid)
        }
    }
}

#Preview {
    NetworkUsagePage()
        .environmentObject(NetworkTrafficMonitor())
        .frame(width: 900, height: 600)
}
