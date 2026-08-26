import SwiftUI

/// Connections page — PLAN.md §1.1 "Connections" (unlocked here with no
/// paywall, per §2) / §4 M6's second task: "stat tiles, filter chips,
/// per-process socket table (proc_pidfdinfo, lsof fallback), exposure
/// classification (loopback/LAN/Internet), detail panel."
///
/// Layout follows PLAN.md's own inventory top to bottom: a status line,
/// this M3-style `StatTile` row (open sockets / listening ports / public
/// endpoints / processes with sockets / a live system-traffic sparkline),
/// a segmented filter control standing in for an "All/Connected/
/// Listening/Public/UDP/Local IPC" filter chip row (PLAN.md §2's own
/// native-restyle rule: keep the *information design*, not a literal
/// chip widget — a segmented control is the native macOS translation of a
/// single-choice filter row, the same role Mail/Photos use one for), the
/// socket table, and — per PLAN.md's own "right detail panel" phrasing for
/// this page specifically (every other master-detail page in this app
/// puts its `DetailPane` *below* the table) — a fixed-width `DetailPane`
/// on the trailing edge instead.
///
/// `ConnectionsViewModel` polls `ConnectionsProvider` on its own cadence
/// (`ProcessesViewModel`'s own "not wired into Sampler's tick, heavier
/// than any single domain, so slower fixed cadence" reasoning, but slower
/// still — walking every process's *entire fd table* is heavier again
/// than `ProcessProvider`'s one-`proc_pidinfo`-call-per-pid listing) and
/// separately subscribes to `Sampler.shared` purely for the traffic
/// sparkline's live network throughput — the same "read `Sampler.shared`
/// for a live reading this page needs but doesn't otherwise poll" pattern
/// `PowerFreqViewModel` uses, rather than a private `Sampler` that would
/// duplicate the whole CPU/memory/GPU/.../NPU sampling round on top of
/// whatever the info bar (and possibly another open page) is already
/// driving for the same wall-clock tick.
struct ConnectionsPage: View {
    @StateObject private var model = ConnectionsViewModel()
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "app", ascending: true)
    @State private var selectedSocketID: String?
    @State private var filter: ConnectionFilterChip = .all
    /// Drives `connectionQuitConfirmationDialog` below — set by the
    /// toolbar's process-action button, the same "state a confirmation
    /// dialog watches" shape `ProcessesPage.pendingQuitPID` uses.
    @State private var pendingKillPID: pid_t?

    /// Fixed detail-panel width — PLAN.md's own "right detail panel"
    /// placement for this page (see this type's own doc comment), sized
    /// like `SystemInfoPage.listWidth`'s fixed dimension in spirit: wide
    /// enough for the longest expected field value ("255.255.255.255:65535")
    /// without truncating.
    private static let detailPanelWidth: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            statTileRow
            Divider()
            filterRow
            Divider()
            HStack(spacing: 0) {
                table
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                detailPane
                    .frame(width: Self.detailPanelWidth)
                    .frame(maxHeight: .infinity)
            }
        }
        .pageToolbar(
            searchText: $searchText,
            searchPrompt: "Filter by App, Address, or Port",
            showsProcessActions: true,
            quitLabel: "Quit Owning Process",
            quitAction: selectedSocket.map { socket in { pendingKillPID = socket.pid } }
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.columns, rows: filteredSockets, suggestedName: "Connections")
            }
        }
        .connectionQuitConfirmationDialog(pendingPID: $pendingKillPID, name: pendingKillProcessName)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// The process name to show in the quit-confirmation dialog. Looked
    /// up by pid rather than reusing `selectedSocket.processName` directly
    /// because the dialog can still be open (its own `pendingKillPID`
    /// already captured) after the underlying socket disappears from the
    /// next poll — matching `ProcessesPage`'s own "the dialog survives
    /// past its trigger" reasoning for looking its name up independently.
    private var pendingKillProcessName: String? {
        guard let pendingKillPID, let sockets = model.catalog?.sockets else { return nil }
        return sockets.first(where: { $0.pid == pendingKillPID })?.processName
    }

    // MARK: - Status line

    /// Mirrors `PowerFreqPage.statusLine`'s "live, updated at" caption,
    /// plus this page's own `usedFallback` disclosure — PLAN.md's honest-
    /// degradation rule extends to *how* a reading was taken, not just
    /// whether one was possible at all (see `ConnectionsCatalog
    /// .usedFallback`'s own doc comment).
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
        guard let catalog = model.catalog else {
            if let reason = model.unavailableReason { return "Unavailable: \(reason)" }
            return "Loading\u{2026}"
        }
        let socketCount = catalog.sockets.count
        let socketsText = socketCount == 1 ? "1 socket" : "\(socketCount) sockets"
        let processText = "\(processesWithSockets(catalog)) of \(catalog.scannedProcessCount) processes"
        let updated = "as of \(Self.timeFormatter.string(from: catalog.generatedAt))"
        var text = "\(socketsText) \u{2014} \(processText) \u{2014} \(updated)"
        if catalog.usedFallback {
            text += " \u{2014} via lsof (proc_pidfdinfo unavailable)"
        }
        if let reason = model.unavailableReason {
            text += " \u{2014} last refresh failed: \(reason)"
        }
        return text
    }

    private var statusIsProblem: Bool {
        model.catalog == nil || model.unavailableReason != nil
    }

    private func processesWithSockets(_ catalog: ConnectionsCatalog) -> Int {
        Set(catalog.sockets.map(\.pid)).count
    }

    // MARK: - Stat tiles

    private static let tileGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    /// PLAN.md's "stat tiles, ... a system traffic sparkline" — four plain
    /// count tiles over this tick's `catalog` plus one live sparkline tile
    /// fed by `model.trafficHistory` (see this type's own doc comment on
    /// why that's a separately-polled reading rather than derived from
    /// `catalog` itself).
    private var statTileRow: some View {
        LazyVGrid(columns: Self.tileGridColumns, spacing: 10) {
            openSocketsTile
            listeningPortsTile
            publicEndpointsTile
            processesTile
            trafficTile
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// All five tiles in `statTileRow` share the same card height only if
    /// they share the same *structure* — `StatTile`'s card sizes itself to
    /// whichever of `secondaryText`/embedded `content` a given call
    /// actually passes (see that type's own doc comment), so a tile with
    /// neither renders visibly shorter than one with a caption line or a
    /// sparkline. Every tile below therefore carries both a real
    /// `secondaryText` line and a fixed-height `content` view — a plain
    /// `Color.clear` spacer standing in for `trafficTile`'s real
    /// `HistoryGraph` at the same height — so the row lines up regardless
    /// of which tile happens to have a chart.
    private static let tileFillerHeight: CGFloat = 28

    private var openSocketsTile: some View {
        StatTile(
            title: "Open Sockets",
            systemImage: "app.connected.to.app.below.fill",
            color: DomainPalette.networkIn,
            value: model.catalog.map { "\($0.sockets.count)" } ?? "",
            secondaryText: "across all processes",
            isUnavailable: model.catalog == nil
        ) {
            Color.clear.frame(height: Self.tileFillerHeight)
        }
    }

    private var listeningPortsTile: some View {
        StatTile(
            title: "Listening Ports",
            systemImage: "antenna.radiowaves.left.and.right",
            color: DomainPalette.networkIn,
            value: model.catalog.map { "\(listeningPortCount($0))" } ?? "",
            secondaryText: "bound for incoming traffic",
            isUnavailable: model.catalog == nil
        ) {
            Color.clear.frame(height: Self.tileFillerHeight)
        }
    }

    /// Distinct (transport, port) pairs among listening/bound sockets —
    /// a dual-stack service (one IPv4 and one IPv6 socket on the same
    /// port, the common case for e.g. a bare `listen()` on macOS) counts
    /// once, matching how a person would describe "how many ports" a Mac
    /// has open rather than how many kernel socket structures back them.
    private func listeningPortCount(_ catalog: ConnectionsCatalog) -> Int {
        let keys = catalog.sockets
            .filter(\.isListening)
            .map { "\($0.transport.rawValue):\($0.localPort ?? 0)" }
        return Set(keys).count
    }

    private var publicEndpointsTile: some View {
        StatTile(
            title: "Public Endpoints",
            systemImage: "globe",
            color: DomainPalette.networkOut,
            value: model.catalog.map { "\($0.sockets.filter { $0.exposure == .internet }.count)" } ?? "",
            secondaryText: "reachable from the internet",
            isUnavailable: model.catalog == nil
        ) {
            Color.clear.frame(height: Self.tileFillerHeight)
        }
    }

    private var processesTile: some View {
        StatTile(
            title: "Processes",
            systemImage: "list.bullet.rectangle",
            color: Color(nsColor: .systemGray),
            value: model.catalog.map { "\(processesWithSockets($0))" } ?? "",
            secondaryText: "with open sockets",
            isUnavailable: model.catalog == nil
        ) {
            Color.clear.frame(height: Self.tileFillerHeight)
        }
    }

    private var trafficTile: some View {
        let latest = model.trafficHistory.last.flatMap { $0 }
        return StatTile(
            title: "System Traffic",
            systemImage: "network",
            color: DomainPalette.networkIn,
            value: Fmt.bytesPerSecond(latest),
            secondaryText: "across all processes",
            isUnavailable: model.trafficHistory.isEmpty
        ) {
            HistoryGraph(
                series: [HistoryGraphSeries(id: "traffic", color: DomainPalette.networkIn, values: model.trafficHistory)],
                gridLineCount: 0,
                accessibilityLabel: "System network traffic history"
            )
            .frame(height: 28)
        }
    }

    // MARK: - Filter row

    /// Native stand-in for PLAN.md's "filter chips" — see this type's own
    /// doc comment for why a segmented control rather than a literal chip
    /// row.
    private var filterRow: some View {
        Picker("Filter", selection: $filter) {
            ForEach(ConnectionFilterChip.allCases) { chip in
                Text(chip.title).tag(chip)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns,
            rows: filteredSockets,
            sort: $sort,
            selection: $selectedSocketID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        guard model.catalog != nil else { return "No sockets available." }
        return searchText.isEmpty && filter == .all
            ? "No open sockets."
            : "No sockets match the current filter."
    }

    private var filteredSockets: [ConnectionSocket] {
        guard let sockets = model.catalog?.sockets else { return [] }
        let chipFiltered = sockets.filter(filter.matches)
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return chipFiltered }
        return chipFiltered.filter { socket in
            (socket.processName?.lowercased().contains(needle) ?? false)
                || (socket.localAddress?.lowercased().contains(needle) ?? false)
                || (socket.remoteAddress?.lowercased().contains(needle) ?? false)
                || (socket.unixPath?.lowercased().contains(needle) ?? false)
                || String(socket.pid).contains(needle)
                || (socket.localPort.map(String.init)?.contains(needle) ?? false)
                || (socket.remotePort.map(String.init)?.contains(needle) ?? false)
        }
    }

    private static let columns: [DataTableColumn<ConnectionSocket>] = [
        DataTableColumn(id: "app", title: "App", value: { $0.processName ?? "" }) { socket in
            Text(socket.processName ?? "Unavailable")
                .foregroundStyle(socket.processName == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
        },
        DataTableColumn(id: "pid", title: "PID", width: 56, alignment: .trailing, value: { $0.pid }) { socket in
            Text("\(socket.pid)").monospacedDigit()
        },
        DataTableColumn(id: "protocol", title: "Protocol", width: 70, value: { protocolLabel($0) }) { socket in
            Text(protocolLabel(socket)).foregroundStyle(.secondary)
        },
        DataTableColumn(id: "state", title: "State", width: 96, value: { $0.statusText }) { socket in
            Text(socket.statusText)
                .foregroundStyle(socket.isConnected ? Color(nsColor: .systemGreen) : .secondary)
                .lineLimit(1)
        },
        DataTableColumn(id: "local", title: "Local", width: 150, value: { $0.localEndpoint }) { socket in
            Text(localColumnText(socket)).monospacedDigit().lineLimit(1).truncationMode(.middle)
        },
        DataTableColumn(id: "remote", title: "Remote", width: 170, value: { $0.remoteEndpoint }) { socket in
            Text(socket.remoteEndpoint).monospacedDigit().lineLimit(1).truncationMode(.middle)
        },
        DataTableColumn(id: "exposure", title: "Exposure", width: 80, value: { $0.exposure?.label ?? "" }) { socket in
            Text(socket.exposure?.label ?? "Unavailable")
                .foregroundStyle(exposureColor(socket.exposure))
                .lineLimit(1)
        },
    ]

    /// "TCP4"/"TCP6"/"UDP4"/"UDP6"/"Unix" — PLAN.md's own "protocol TCP/UDP
    /// + IPv4/6" column phrasing, folded into one compact label.
    private static func protocolLabel(_ socket: ConnectionSocket) -> String {
        guard let ipVersion = socket.ipVersion else { return socket.transport.rawValue }
        return "\(socket.transport.rawValue)\(ipVersion.rawValue)"
    }

    /// The table's "Local" cell: a Unix-domain socket has no IP endpoint
    /// to show, so its bound path stands in for it — still the single
    /// most useful "where is this" fact for that row.
    private static func localColumnText(_ socket: ConnectionSocket) -> String {
        if socket.transport == .unixDomain { return socket.unixPath ?? "Unavailable" }
        return socket.localEndpoint
    }

    private static func exposureColor(_ exposure: SocketExposure?) -> Color {
        switch exposure {
        case .internet: return Color(nsColor: .systemRed)
        case .lan: return Color(nsColor: .systemOrange)
        case .loopback: return .secondary
        case nil: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let socket = selectedSocket {
            DetailPane(
                title: socket.processName ?? "Unavailable",
                subtitle: "PID \(socket.pid)",
                systemImage: "app.connected.to.app.below.fill",
                sections: detailSections(for: socket)
            )
        } else {
            DetailPane(emptyMessage: "Select a socket to view its details.")
        }
    }

    private var selectedSocket: ConnectionSocket? {
        guard let selectedSocketID, let sockets = model.catalog?.sockets else { return nil }
        return sockets.first(where: { $0.id == selectedSocketID })
    }

    /// Identity / Endpoints / Socket sections — PLAN.md's own field list
    /// for this page's detail panel: "endpoints, exposure 'Internet',
    /// socket descriptor, observed time."
    private func detailSections(for socket: ConnectionSocket) -> [DetailPaneSection] {
        var endpointFields: [DetailPaneField] = []
        if socket.transport == .unixDomain {
            endpointFields.append(DetailPaneField(label: "Path", value: socket.unixPath ?? "", isUnavailable: socket.unixPath == nil))
        } else {
            endpointFields.append(DetailPaneField(label: "Local", value: socket.localEndpoint, isMonospaced: true))
            endpointFields.append(DetailPaneField(label: "Remote", value: socket.remoteEndpoint, isMonospaced: true))
            if let service = socket.serviceName {
                endpointFields.append(DetailPaneField(label: "Service", value: service))
            }
        }
        endpointFields.append(DetailPaneField(label: "Exposure", value: socket.exposure?.label ?? "", isUnavailable: socket.exposure == nil))

        return [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Process", value: socket.processName ?? "", isUnavailable: socket.processName == nil),
                DetailPaneField(label: "PID", value: "\(socket.pid)", isMonospaced: true),
                DetailPaneField(label: "Protocol", value: Self.protocolLabel(socket)),
                DetailPaneField(label: "State", value: socket.statusText),
            ]),
            DetailPaneSection(title: "Endpoints", fields: endpointFields),
            DetailPaneSection(title: "Socket", fields: [
                DetailPaneField(label: "Descriptor", value: "\(socket.descriptor)", isMonospaced: true),
                DetailPaneField(label: "Observed", value: Self.timeFormatter.string(from: socket.observedAt)),
            ]),
        ]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Filter chips

/// PLAN.md's "All/Connected/Listening/Public/UDP/Local IPC" filter row —
/// see `ConnectionsPage`'s own doc comment for why it renders as a
/// segmented control rather than a literal chip widget.
enum ConnectionFilterChip: String, CaseIterable, Identifiable {
    case all
    case connected
    case listening
    case publicExposure
    case udp
    case localIPC

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .connected: return "Connected"
        case .listening: return "Listening"
        case .publicExposure: return "Public"
        case .udp: return "UDP"
        case .localIPC: return "Local IPC"
        }
    }

    func matches(_ socket: ConnectionSocket) -> Bool {
        switch self {
        case .all: return true
        case .connected: return socket.isConnected
        case .listening: return socket.isListening
        case .publicExposure: return socket.exposure == .internet
        case .udp: return socket.transport == .udp
        case .localIPC: return socket.transport == .unixDomain
        }
    }
}

// MARK: - Formatting

/// This page's own scoped byte-rate formatter — matches `PowerFreqPage`'s
/// own private `Fmt` enum in shape (a `ByteCountFormatter` wrapper plus an
/// honest "Unavailable" for `nil`), sized to only what this page needs.
private enum Fmt {
    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return formatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - View model

/// Drives `ConnectionsPage`: polls `ConnectionsProvider` on its own fixed
/// cadence (see this file's top-of-file doc comment for why that's
/// slower than `ProcessesViewModel`'s own 1 s poll) and separately
/// ingests `Sampler.shared`'s stream purely for the traffic sparkline's
/// network-throughput history — two independent live sources feeding one
/// page, the same shape `PerformancePage`'s rail (per-domain sparklines)
/// and detail (the selected domain's own graph) already combine. The
/// socket table still doesn't come from `Sampler` at all — only the
/// traffic sparkline reads its stream, via the same app-wide instance
/// every other live-data view model shares (`Sampler.shared`'s doc
/// comment).
@MainActor
final class ConnectionsViewModel: ObservableObject {
    @Published private(set) var catalog: ConnectionsCatalog?
    /// Set when the most recent poll threw; left in place alongside a
    /// still-populated `catalog` after a single missed poll, matching
    /// `ProcessesViewModel.unavailableReason`'s own "one bad tick doesn't
    /// blank an otherwise-good table" rule.
    @Published private(set) var unavailableReason: String?
    /// Oldest-first combined send+receive network throughput, one entry
    /// per `trafficSampler` tick, capped at `trafficHistoryLimit` — feeds
    /// the "System Traffic" tile's sparkline. A `nil` entry marks a tick
    /// `NetworkProvider` couldn't read (`HistoryGraph`'s own "leave a gap,
    /// don't guess" convention).
    @Published private(set) var trafficHistory: [Double?] = []

    private let provider = ConnectionsProvider()
    private var pollTask: Task<Void, Never>?
    /// Walking every process's entire fd table is meaningfully heavier
    /// than `ProcessesViewModel`'s own one-call-per-pid listing (see this
    /// file's top-of-file doc comment), so this cadence is slower than
    /// that page's `Sampler.Interval.slow` — a plain literal rather than
    /// borrowing an `Interval` case that doesn't fit either.
    private static let pollInterval: TimeInterval = 3.0

    private let trafficSampler = Sampler.shared
    private var trafficTask: Task<Void, Never>?
    private static let trafficHistoryLimit = 60

    func start() {
        startSocketPolling()
        startTrafficSampling()
    }

    /// Ends both this view model's socket polling and its traffic
    /// subscription. Deliberately does *not* call `trafficSampler.stop()`:
    /// `trafficSampler` is `Sampler.shared`, and stopping it outright would
    /// cut off every other still-active subscriber (the info bar, and
    /// whichever other page might also be subscribed) — cancelling just
    /// this task ends only this subscription, and `Sampler.shared` itself
    /// goes idle on its own once the last one (of any kind) does the same,
    /// per `removeContinuation`'s doc comment.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        trafficTask?.cancel()
        trafficTask = nil
    }

    private func startSocketPolling() {
        guard pollTask == nil else { return }
        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.catalog = result
                    self.unavailableReason = nil
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.unavailableReason = error.localizedDescription
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    private func startTrafficSampling() {
        guard trafficTask == nil else { return }
        let sampler = trafficSampler
        trafficTask = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.stream() {
                guard let self else { return }
                self.ingestTraffic(snapshot)
            }
        }
    }

    private func ingestTraffic(_ snapshot: Snapshot) {
        let total: Double?
        if let send = snapshot.network?.sendBytesPerSecond, let receive = snapshot.network?.receiveBytesPerSecond {
            total = send + receive
        } else {
            total = nil
        }
        trafficHistory.append(total)
        if trafficHistory.count > Self.trafficHistoryLimit {
            trafficHistory.removeFirst(trafficHistory.count - Self.trafficHistoryLimit)
        }
    }
}

// MARK: - Quit confirmation dialog

private extension View {
    /// Quit/Force Quit/Cancel confirmation for the toolbar's "Quit Owning
    /// Process" button, mirroring `ProcessesPage`'s own
    /// `quitConfirmationDialog` (same `ProcessActions.quit(pid:)`/
    /// `forceQuit(pid:)` calls, same Quit/Force Quit/Cancel shape) but
    /// with copy specific to this page: there's no way to close *just one
    /// socket* without root (this app's own "No sudo/helper tool in v1"
    /// rule — see `ConnectionsProvider`'s doc comments), so "killing a
    /// connection" here always means quitting the process that owns it,
    /// and the dialog says so plainly rather than implying something
    /// narrower than what actually happens.
    func connectionQuitConfirmationDialog(pendingPID: Binding<pid_t?>, name: String?) -> some View {
        confirmationDialog(
            "Quit \u{201C}\(name ?? "This Process")\u{201D}?",
            isPresented: Binding(
                get: { pendingPID.wrappedValue != nil },
                set: { isPresented in
                    if !isPresented { pendingPID.wrappedValue = nil }
                }
            ),
            titleVisibility: .visible
        ) {
            if let pid = pendingPID.wrappedValue {
                Button("Quit") {
                    ProcessActions.quit(pid: pid)
                    pendingPID.wrappedValue = nil
                }
                Button("Force Quit", role: .destructive) {
                    ProcessActions.forceQuit(pid: pid)
                    pendingPID.wrappedValue = nil
                }
                Button("Cancel", role: .cancel) {
                    pendingPID.wrappedValue = nil
                }
            }
        } message: {
            Text("There\u{2019}s no way to close just this one connection \u{2014} quitting ends the whole process. Force Quit terminates it immediately.")
        }
    }
}

#Preview {
    ConnectionsPage()
        .frame(width: 980, height: 640)
}
