import AppKit
import SwiftUI

/// Network Monitor page — this app's own Little Snitch-inspired addition:
/// "which app has talked to which server, and when." Reuses
/// `ConnectionsProvider` (the same per-process socket scan `ConnectionsPage`
/// already polls) grouped by process, then by remote host, with each
/// remote IP resolved to a hostname where possible (`HostnameResolver`) —
/// the one thing neither `ConnectionsPage`'s flat table nor
/// `NetworkUsagePage`'s per-process rates show on their own.
///
/// Unlike `ConnectionsPage`'s point-in-time table (which only ever shows
/// *currently open* sockets), this page keeps a running log for as long as
/// it's been polling: a host a process briefly connected to and closed
/// stays listed (dimmed, with a "last seen" time) instead of vanishing the
/// moment the socket closes — a quick HTTPS request can easily complete
/// between one 3-second poll and the next, and a monitor that only shows
/// this instant's open sockets would miss it entirely. `NetworkMonitor
/// ViewModel.groupsByPID` is that accumulating log; `Clear` resets it.
///
/// Deliberately monitoring-only, matching this app's whole MCP-server-style
/// "read-only" posture for anything it can't honestly promise: blocking a
/// connection *before* it happens the way Little Snitch does needs Apple's
/// Network Extension framework, which requires a paid Apple Developer
/// Program membership (for the `com.apple.developer.networking
/// .networkextension` entitlement) and a notarized System Extension —
/// out of scope for this app's ad-hoc-signed, free distribution model.
/// Ending an already-open connection's owning process is still available,
/// via the same action `ConnectionsPage`'s own toolbar offers.
///
/// Traffic rates use the same app-lifetime, opt-in `NetworkTrafficMonitor`
/// `NetworkUsagePage` does (started once via its own "Start Collecting"
/// button) rather than starting a second `nettop` — this page works
/// without it (showing which apps talk to which hosts), and rates/totals
/// simply fill in once traffic collection is running. A live rate reading
/// zero is often perfectly real (an app that only talks in short bursts is
/// idle most 1-second samples) — the cumulative "Total" figure next to it
/// is what actually proves data moved, so both are always shown together.
struct NetworkMonitorPage: View {
    @EnvironmentObject private var model: NetworkMonitorViewModel
    @StateObject private var iconModel = AppIconLookupViewModel()
    @EnvironmentObject private var trafficModel: NetworkTrafficMonitor
    @EnvironmentObject private var commandPalette: CommandPaletteController
    @State private var searchText = ""
    @State private var selection: HostSelection?

    private static let detailPanelWidth: CGFloat = 300

    var body: some View {
        Group {
            if !model.isWatching && model.groups.isEmpty {
                idleState
            } else {
                VStack(spacing: 0) {
                    statusLine
                    Divider()
                    statTileRow
                    Divider()
                    if !trafficModel.hasStarted {
                        trafficHint
                        Divider()
                    }
                    HStack(spacing: 0) {
                        content
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        Divider()
                        detailPane
                            .frame(width: Self.detailPanelWidth)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter by App or Host")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if model.isWatching { model.stop() } else { model.start() }
                } label: {
                    Label(
                        model.isWatching ? "Stop Watching" : "Start Watching",
                        systemImage: model.isWatching ? "pause.circle" : "play.circle"
                    )
                }
                .help(model.isWatching ? "Stop watching for new connections" : "Watch which apps talk to which hosts, even while you're on another page")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.setCountryLookupEnabled(!model.isCountryLookupEnabled)
                } label: {
                    Label(
                        model.isCountryLookupEnabled ? "Hide Country" : "Show Country",
                        systemImage: model.isCountryLookupEnabled ? "flag.fill" : "flag"
                    )
                }
                .help(countryToggleHelp)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.clear()
                    selection = nil
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .disabled(model.groups.isEmpty)
                .help("Forget every host seen so far")
            }
        }
    }

    // MARK: - Idle state

    /// Shown until the toolbar's "Start Watching" is clicked at least
    /// once — matching `NetworkUsagePage`/`DiskSpacePage`'s own
    /// user-initiated-start shape (PLAN.md §2's restraint on standing
    /// background cost) rather than polling connections just because this
    /// page happened to be opened. Once anything's been accumulated
    /// (`model.groups` non-empty), this stays out of the way even after
    /// `Stop Watching` — the log itself is still worth showing.
    private var idleState: some View {
        VStack(spacing: 10) {
            Image(systemName: "globe")
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)
            Text("Not Watching Network Activity")
                .font(.title2)
                .fontWeight(.semibold)
            Text("Logs which apps talk to which remote hosts. Keeps watching \u{2014} and keeps what it's already seen \u{2014} even while you're on a different page, until you stop it or click Clear.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button("Start Watching") {
                model.start()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Status line

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
        guard model.hasReceivedFirstSample else {
            if let reason = model.unavailableReason { return "Unavailable: \(reason)" }
            return "Loading\u{2026}"
        }
        var text = "\(Fmt.count(model.groups.count)) app(s) \u{2014} \(Fmt.count(allHosts.count)) host(s) seen (\(Fmt.count(openHostCount)) currently open)"
        if let reason = model.unavailableReason {
            text += " \u{2014} last refresh failed: \(reason)"
        }
        return text
    }

    private var statusIsProblem: Bool {
        !model.hasReceivedFirstSample || model.unavailableReason != nil
    }

    private var allHosts: [MonitorHost] {
        model.groups.flatMap(\.hosts)
    }

    private var openHostCount: Int {
        allHosts.filter(\.isCurrentlyOpen).count
    }

    // MARK: - Stat tiles

    private static let tileGridColumns = [GridItem(.adaptive(minimum: 150), spacing: 10)]

    private var statTileRow: some View {
        LazyVGrid(columns: Self.tileGridColumns, spacing: 10) {
            StatTile(
                title: "Apps Seen",
                systemImage: "app.badge",
                color: Color(nsColor: .systemGray),
                value: model.hasReceivedFirstSample ? "\(model.groups.count)" : "",
                secondaryText: "since watching started",
                isUnavailable: !model.hasReceivedFirstSample
            )
            StatTile(
                title: "Hosts Seen",
                systemImage: "globe",
                color: DomainPalette.networkOut,
                value: model.hasReceivedFirstSample ? "\(allHosts.count)" : "",
                secondaryText: "\(openHostCount) currently open",
                isUnavailable: !model.hasReceivedFirstSample
            )
            StatTile(
                title: "Internet-Exposed",
                systemImage: "globe.americas",
                color: Color(nsColor: .systemRed),
                value: model.hasReceivedFirstSample ? "\(allHosts.filter { $0.exposure == .internet }.count)" : "",
                secondaryText: "of the hosts above",
                isUnavailable: !model.hasReceivedFirstSample
            )
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Traffic opt-in hint

    private var trafficHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
            Text("Live send/receive rates and totals need traffic collection running.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Start Collecting") {
                trafficModel.start()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Grouped content

    @ViewBuilder
    private var content: some View {
        if !model.hasReceivedFirstSample {
            emptyState(message: model.unavailableReason.map { "Unavailable: \($0)" } ?? "Loading\u{2026}")
        } else if filteredGroups.isEmpty {
            emptyState(message: model.groups.isEmpty ? "No outbound connections seen yet." : "No apps or hosts match the current filter.")
        } else {
            List {
                ForEach(filteredGroups) { group in
                    Section {
                        ForEach(group.hosts) { host in
                            hostRow(host, in: group)
                        }
                    } header: {
                        groupHeader(group)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private func emptyState(message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var filteredGroups: [MonitorGroup] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return model.groups }
        return model.groups.compactMap { group -> MonitorGroup? in
            let matchesApp = group.processName?.lowercased().contains(needle) ?? false
            let matchingHosts = group.hosts.filter { host in
                matchesApp || displayName(for: host).lowercased().contains(needle)
            }
            guard matchesApp || !matchingHosts.isEmpty else { return nil }
            var filtered = group
            filtered.hosts = matchesApp ? group.hosts : matchingHosts
            return filtered
        }
    }

    private func groupHeader(_ group: MonitorGroup) -> some View {
        let traffic = trafficReading(for: group.pid)
        return HStack(spacing: 8) {
            appIcon(for: group.pid)
                .frame(width: 16, height: 16)
                .onAppear { iconModel.load(pid: group.pid) }
            Text(group.processName ?? "Unavailable")
                .font(.callout.weight(.semibold))
                .foregroundStyle(group.processName == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
            Text("PID \(group.pid)")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            if let traffic {
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 6) {
                        Label(Fmt.bytesPerSecond(traffic.sendBytesPerSecond), systemImage: "arrow.up")
                        Label(Fmt.bytesPerSecond(traffic.receiveBytesPerSecond), systemImage: "arrow.down")
                    }
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    Text("\(Fmt.bytes(traffic.totalBytesSent)) up / \(Fmt.bytes(traffic.totalBytesReceived)) down total")
                        .font(.caption2)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text("\(Fmt.count(group.hosts.count)) host(s)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// The calling app's own icon, via `AppIconLookupViewModel` — `nil`
    /// for anything that isn't a registered "application" in
    /// `NSWorkspace`'s sense (most background daemons/CLI tools, e.g. a
    /// bare `java` process), which falls back to a plain SF Symbol rather
    /// than a blank space.
    @ViewBuilder
    private func appIcon(for pid: pid_t) -> some View {
        if let icon = iconModel.icon(for: pid) {
            Image(nsImage: icon).resizable()
        } else {
            Image(systemName: "app.badge").foregroundStyle(.secondary)
        }
    }

    private var countryToggleHelp: String {
        model.isCountryLookupEnabled
            ? "Stop looking up which country each host is in"
            : "Look up which country each host is in by sending its IP to a public geolocation service (ipwho.is) \u{2014} off by default"
    }

    private func hostRow(_ host: MonitorHost, in group: MonitorGroup) -> some View {
        let isSelected = selection == HostSelection(pid: group.pid, ip: host.ip)
        return Button {
            selection = HostSelection(pid: group.pid, ip: host.ip)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(exposureColor(host.exposure))
                    .frame(width: 7, height: 7)
                    .opacity(host.isCurrentlyOpen ? 1 : 0.4)
                if model.isCountryLookupEnabled, let country = model.country(forIP: host.ip) {
                    Text(country.flagEmoji ?? country.countryCode)
                        .font(.caption)
                        .help(country.countryName)
                }
                Text(displayName(for: host))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(rowTextColor(host))
                Spacer(minLength: 8)
                if !host.isCurrentlyOpen {
                    Text("closed \(Self.relativeFormatter.localizedString(for: host.lastSeenAt, relativeTo: Date()))")
                        .font(.caption2)
                        .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                }
                Text(host.transport)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(host.ports.sorted().map(String.init).joined(separator: ", "))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 60, alignment: .trailing)
                Text(host.exposure?.label ?? "Unavailable")
                    .font(.caption)
                    .foregroundStyle(exposureColor(host.exposure))
                    .frame(width: 64, alignment: .trailing)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
        .listRowBackground(isSelected ? Color.accentColor.opacity(0.15) : Color.clear)
    }

    private func rowTextColor(_ host: MonitorHost) -> Color {
        guard host.isCurrentlyOpen else { return .secondary }
        return model.hostname(forIP: host.ip) != nil ? .primary : .secondary
    }

    private func displayName(for host: MonitorHost) -> String {
        model.hostname(forIP: host.ip) ?? host.ip
    }

    private func exposureColor(_ exposure: SocketExposure?) -> Color {
        switch exposure {
        case .internet: return Color(nsColor: .systemRed)
        case .lan: return Color(nsColor: .systemOrange)
        case .loopback: return .secondary
        case nil: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func trafficReading(for pid: pid_t) -> NetTrafficReading? {
        guard trafficModel.hasStarted else { return nil }
        return trafficModel.snapshot?.readings.first(where: { $0.pid == pid })
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let selection, let (group, host) = lookup(selection) {
            DetailPane(
                title: displayName(for: host),
                subtitle: group.processName.map { "\($0) \u{2014} PID \(group.pid)" },
                systemImage: "globe",
                sections: detailSections(group: group, host: host)
            )
        } else {
            DetailPane(emptyMessage: "Select a host to view its details.")
        }
    }

    private func lookup(_ selection: HostSelection) -> (MonitorGroup, MonitorHost)? {
        guard let group = model.groups.first(where: { $0.pid == selection.pid }),
              let host = group.hosts.first(where: { $0.ip == selection.ip })
        else { return nil }
        return (group, host)
    }

    private func detailSections(group: MonitorGroup, host: MonitorHost) -> [DetailPaneSection] {
        var identityFields = [
            DetailPaneField(label: "Process", value: group.processName ?? "", isUnavailable: group.processName == nil),
            DetailPaneField(label: "PID", value: "\(group.pid)", isMonospaced: true) {
                commandPalette.jumpToProcess(pid: group.pid)
            },
        ]
        if model.hostname(forIP: host.ip) != nil {
            identityFields.append(DetailPaneField(label: "Hostname", value: model.hostname(forIP: host.ip) ?? ""))
        }
        identityFields.append(DetailPaneField(label: "IP Address", value: host.ip, isMonospaced: true))

        var sections = [
            DetailPaneSection(title: "Identity", fields: identityFields),
            DetailPaneSection(title: "Connection", fields: [
                DetailPaneField(label: "Protocol", value: host.transport),
                DetailPaneField(label: "Port(s)", value: host.ports.sorted().map(String.init).joined(separator: ", "), isMonospaced: true),
                DetailPaneField(label: "Exposure", value: host.exposure?.label ?? "", isUnavailable: host.exposure == nil),
                DetailPaneField(label: "Status", value: host.isCurrentlyOpen ? "Open" : "Closed"),
                countryField(for: host),
            ]),
            DetailPaneSection(title: "Timeline", fields: [
                DetailPaneField(label: "First Seen", value: Self.dateTimeFormatter.string(from: host.firstSeenAt)),
                DetailPaneField(label: "Last Seen", value: Self.dateTimeFormatter.string(from: host.lastSeenAt)),
            ]),
        ]

        if let traffic = trafficReading(for: group.pid) {
            sections.append(DetailPaneSection(title: "This App's Traffic", fields: [
                DetailPaneField(label: "Send Rate", value: Fmt.bytesPerSecond(traffic.sendBytesPerSecond), isMonospaced: true),
                DetailPaneField(label: "Receive Rate", value: Fmt.bytesPerSecond(traffic.receiveBytesPerSecond), isMonospaced: true),
                DetailPaneField(label: "Total Sent", value: Fmt.bytes(traffic.totalBytesSent), isMonospaced: true),
                DetailPaneField(label: "Total Received", value: Fmt.bytes(traffic.totalBytesReceived), isMonospaced: true),
            ]))
        } else {
            sections.append(DetailPaneSection(title: "This App's Traffic", fields: [
                DetailPaneField(label: "Status", value: "Start traffic collection to see rates", isUnavailable: true),
            ]))
        }

        return sections
    }

    /// "Unavailable" when country lookup is off (not attempted — this
    /// app never sends an IP anywhere without the toolbar toggle being on
    /// first) or when it's on but hasn't resolved this IP yet/found
    /// nothing — the same three-state honesty `connectionsSection` in
    /// `NetworkUsagePage` already draws for its own lookups.
    private func countryField(for host: MonitorHost) -> DetailPaneField {
        guard model.isCountryLookupEnabled else {
            return DetailPaneField(label: "Country", value: "Country lookup is off", isUnavailable: true)
        }
        guard let country = model.country(forIP: host.ip) else {
            return DetailPaneField(label: "Country", value: "", isUnavailable: true)
        }
        let flag = country.flagEmoji.map { "\($0) " } ?? ""
        return DetailPaneField(label: "Country", value: "\(flag)\(country.countryName)")
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Selection

private struct HostSelection: Equatable {
    let pid: pid_t
    let ip: String
}

// MARK: - Grouped row models

/// One process's accumulated log of remote hosts — see `NetworkMonitorPage`'s
/// own doc comment for why this persists past a socket closing rather than
/// only reflecting this instant's open connections.
struct MonitorGroup: Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    var processName: String?
    var hosts: [MonitorHost]
    var lastSeenAt: Date
}

struct MonitorHost: Identifiable, Equatable {
    var id: String { ip }
    let ip: String
    var exposure: SocketExposure?
    var transport: String
    var ports: Set<UInt16>
    let firstSeenAt: Date
    var lastSeenAt: Date
    var isCurrentlyOpen: Bool
}

// MARK: - Formatting

private enum Fmt {
    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return byteFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func bytes(_ value: UInt64) -> String {
        let clamped = min(value, UInt64(Int64.max))
        return byteFormatter.string(fromByteCount: Int64(clamped))
    }

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - View model

/// Drives `NetworkMonitorPage`: polls `ConnectionsProvider` (its own
/// instance — sockets aren't shared the way `Sampler.shared` readings
/// are) and folds each tick's currently-open sockets into `groupsByPID` —
/// an accumulating log that only ever adds/updates entries, never removes
/// one just because a socket closed (see `NetworkMonitorPage`'s own doc
/// comment). Also kicks off `HostnameResolver` lookups for whatever
/// remote IPs show up.
///
/// Owned by `AppDelegate` (alongside `networkTraffic`) rather than as
/// this page's own `@StateObject`, and deliberately never started there —
/// same "app-lifetime instance, explicit opt-in button starts it" shape
/// `networkTraffic` itself uses. The reason is the toolbar's own "Watch"
/// button: once turned on, watching (and everything accumulated in
/// `groupsByPID`) must survive navigating to a different page and back,
/// not reset just because `NetworkMonitorPage`'s view was torn down and
/// rebuilt — which is exactly what would happen if this were a
/// `@StateObject` stopped in `onDisappear`.
@MainActor
final class NetworkMonitorViewModel: ObservableObject {
    @Published private(set) var isWatching = false
    @Published private(set) var groups: [MonitorGroup] = []
    @Published private(set) var unavailableReason: String?
    @Published private(set) var hasReceivedFirstSample = false
    @Published private(set) var hostnamesByIP: [String: String] = [:]
    /// Off by default — see `CountryResolver`'s own doc comment for why
    /// this is the one thing on this page that makes a real outbound
    /// network request, and therefore the one thing that never starts on
    /// its own.
    @Published private(set) var isCountryLookupEnabled = false
    @Published private(set) var countriesByIP: [String: CountryResolver.CountryInfo] = [:]

    /// The accumulating log itself, keyed for O(1) merge-by-pid — `groups`
    /// above is just this, re-sorted into an array, published after every
    /// merge.
    private var groupsByPID: [pid_t: MonitorGroup] = [:]

    private let provider = ConnectionsProvider()
    private var pollTask: Task<Void, Never>?
    private static let pollInterval: TimeInterval = 3.0

    func hostname(forIP ip: String) -> String? {
        hostnamesByIP[ip]
    }

    func country(forIP ip: String) -> CountryResolver.CountryInfo? {
        countriesByIP[ip]
    }

    /// Flips the country-lookup toggle. Turning it on immediately kicks
    /// off resolution for every IP already known (not just ones seen from
    /// this point forward) so switching it on mid-session fills in right
    /// away rather than waiting for the next poll tick's sockets to
    /// happen to include hosts already in the log.
    func setCountryLookupEnabled(_ enabled: Bool) {
        isCountryLookupEnabled = enabled
        guard enabled else { return }
        let knownIPs = Set(groupsByPID.values.flatMap { $0.hosts.map(\.ip) })
        Task { await refreshCountries(for: knownIPs) }
    }

    func start() {
        guard pollTask == nil else { return }
        isWatching = true
        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.unavailableReason = nil
                    self.hasReceivedFirstSample = true
                    self.merge(result)
                    let ips = Set(result.sockets.compactMap(\.remoteAddress))
                    await self.refreshHostnames(for: ips)
                    if self.isCountryLookupEnabled {
                        await self.refreshCountries(for: ips)
                    }
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.unavailableReason = error.localizedDescription
                    self.hasReceivedFirstSample = true
                }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isWatching = false
    }

    /// Forgets every accumulated host/app — the toolbar's "Clear" button.
    /// Does not touch `hostnamesByIP`: a hostname is a fact about an IP,
    /// not about this log, so there's no reason to re-resolve it after a
    /// clear if the same IP shows up again.
    func clear() {
        groupsByPID.removeAll()
        groups = []
    }

    /// Folds this tick's currently-open sockets into `groupsByPID`: a host
    /// seen for the first time is added with `firstSeenAt == lastSeenAt ==
    /// now`; one already known gets `lastSeenAt` bumped and its ports/
    /// exposure refreshed. Anything previously known but *not* present in
    /// this tick's sockets is marked `isCurrentlyOpen = false` and left in
    /// place rather than removed.
    private func merge(_ catalog: ConnectionsCatalog) {
        let now = catalog.generatedAt
        let remoteSockets = catalog.sockets.filter { $0.remoteAddress != nil }
        let byPID = Dictionary(grouping: remoteSockets, by: \.pid)

        var openIPsByPID: [pid_t: Set<String>] = [:]

        for (pid, sockets) in byPID {
            var group = groupsByPID[pid] ?? MonitorGroup(pid: pid, processName: nil, hosts: [], lastSeenAt: now)
            group.processName = sockets.first?.processName ?? group.processName
            group.lastSeenAt = now

            var hostsByIP = Dictionary(uniqueKeysWithValues: group.hosts.map { ($0.ip, $0) })
            var openIPs: Set<String> = []
            for socket in sockets {
                guard let ip = socket.remoteAddress else { continue }
                var host = hostsByIP[ip] ?? MonitorHost(
                    ip: ip,
                    exposure: socket.exposure,
                    transport: Self.protocolLabel(socket),
                    ports: [],
                    firstSeenAt: now,
                    lastSeenAt: now,
                    isCurrentlyOpen: true
                )
                host.exposure = socket.exposure
                host.transport = Self.protocolLabel(socket)
                host.lastSeenAt = now
                host.isCurrentlyOpen = true
                if let port = socket.remotePort {
                    host.ports.insert(port)
                }
                hostsByIP[ip] = host
                openIPs.insert(ip)
            }
            openIPsByPID[pid] = openIPs
            group.hosts = Array(hostsByIP.values)
            groupsByPID[pid] = group
        }

        // Anything not touched above (a pid with no currently-open remote
        // sockets at all, or a specific host within a still-active pid)
        // gets marked closed rather than dropped.
        for (pid, var group) in groupsByPID {
            let openIPs = openIPsByPID[pid] ?? []
            group.hosts = group.hosts.map { host in
                var host = host
                if !openIPs.contains(host.ip) {
                    host.isCurrentlyOpen = false
                }
                return host
            }
            groupsByPID[pid] = group
        }

        rebuildPublishedGroups()
    }

    private func rebuildPublishedGroups() {
        groups = groupsByPID.values
            .map { group -> MonitorGroup in
                var group = group
                group.hosts.sort { $0.lastSeenAt > $1.lastSeenAt }
                return group
            }
            .sorted { ($0.processName ?? "") < ($1.processName ?? "") }
    }

    /// Kicks off resolution for every remote IP not yet cached, then
    /// merges back whatever `HostnameResolver` already has — including
    /// results from lookups earlier ticks started, which finish in the
    /// background on their own schedule. `hostnamesByIP` only grows
    /// (never evicted) for the life of this view model, matching
    /// `SigningInfoViewModel.infoByPID`'s own "cache forever, bounded in
    /// practice by how many distinct values a session actually sees" rule.
    private func refreshHostnames(for ips: Set<String>) async {
        for ip in ips {
            await HostnameResolver.shared.resolve(ip)
        }
        var updated = hostnamesByIP
        for ip in ips {
            if let hostname = await HostnameResolver.shared.cachedHostname(for: ip) {
                updated[ip] = hostname
            }
        }
        hostnamesByIP = updated
    }

    /// Same shape as `refreshHostnames(for:)`, for `CountryResolver`
    /// instead — only ever called while `isCountryLookupEnabled` is true
    /// (checked by every call site), so this itself doesn't need its own
    /// guard.
    private func refreshCountries(for ips: Set<String>) async {
        for ip in ips {
            await CountryResolver.shared.resolve(ip)
        }
        var updated = countriesByIP
        for ip in ips {
            if let info = await CountryResolver.shared.cachedCountry(for: ip) {
                updated[ip] = info
            }
        }
        countriesByIP = updated
    }

    /// "TCP4"/"UDP6"/"Unix" — same compact shape `ConnectionsPage`'s own
    /// (private, so not directly reusable) `protocolLabel` uses.
    private static func protocolLabel(_ socket: ConnectionSocket) -> String {
        guard let ipVersion = socket.ipVersion else { return socket.transport.rawValue }
        return "\(socket.transport.rawValue)\(ipVersion.rawValue)"
    }
}

/// Backs `NetworkMonitorPage`'s group headers: the calling app's own icon,
/// by pid, via `NSRunningApplication(processIdentifier:)` — the minimal,
/// per-pid form of the same lookup `ProcessProvider`'s own bulk
/// `readRunningApplications(skippingIconsFor:)` does for its whole table
/// at once. `nil` for anything that isn't a registered "application" in
/// `NSWorkspace`'s sense (most background daemons/CLI tools), which
/// `NetworkMonitorPage.appIcon(for:)` falls back to a plain SF Symbol for
/// rather than a blank space. Fetched and cached once per pid — a
/// process's icon doesn't change while it's running.
@MainActor
final class AppIconLookupViewModel: ObservableObject {
    @Published private(set) var iconsByPID: [pid_t: NSImage] = [:]
    private var attemptedPIDs: Set<pid_t> = []

    func icon(for pid: pid_t) -> NSImage? {
        iconsByPID[pid]
    }

    func load(pid: pid_t) {
        guard iconsByPID[pid] == nil, !attemptedPIDs.contains(pid) else { return }
        attemptedPIDs.insert(pid)
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon else { return }
        iconsByPID[pid] = icon
    }
}

#Preview {
    NetworkMonitorPage()
        .environmentObject(NetworkTrafficMonitor())
        .environmentObject(NetworkMonitorViewModel())
        .environmentObject(CommandPaletteController())
        .frame(width: 980, height: 640)
}
