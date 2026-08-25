import SwiftUI

/// Services page — PLAN.md §1.1 "Services" / §4 M5's third task: "Services
/// page: `launchctl print` listing, running state, filter, detail pane."
/// A `DataTable` (Running checkbox / Name / Description-Path / Group
/// columns, matching §1.1's "LaunchDaemons/agents table: Running checkbox,
/// Name, Description/path, Group; filter") over `Components/DetailPane
/// .swift` below the fold — the same table-over-detail layout `StartupPage`
/// uses for its own, differently-scoped launchd listing.
///
/// Search-only `PageToolbar` (no quit/inspect-style row actions, matching
/// `PageToolbar`'s own doc comment listing "Services" among the filterable-
/// but-not-process-actionable pages), and like `StartupPage`/`SystemInfoPage`
/// this is a load-once-then-Reload page rather than a polled one:
/// `ServicesProvider`'s own doc comment explains why two `launchctl print`
/// shell-outs plus a five-directory plist scan are too slow for `Sampler`'s
/// tick cadence.
struct ServicesPage: View {
    @StateObject private var model = ServicesViewModel()
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "name", ascending: true)
    @State private var selectedItemID: String?
    /// Matches `StartupPage.detailPaneHeight` — enough room for this
    /// domain's own, shorter detail sections without scrolling on the
    /// app's minimum window height.
    private static let detailPaneHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            table
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detailPane
                .frame(height: Self.detailPaneHeight)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Services")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                reloadButton
            }
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.columns, rows: filteredItems, suggestedName: "Services")
            }
        }
        .onAppear {
            Task { await model.loadIfNeeded() }
        }
    }

    // MARK: - Toolbar

    private var reloadButton: some View {
        Button {
            Task { await model.reload() }
        } label: {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Label("Reload", systemImage: "arrow.clockwise")
            }
        }
        .disabled(model.isLoading)
        .help("Reload from launchctl print")
    }

    // MARK: - Status line

    /// Mirrors `StartupPage.statusLine`: an "as of / Unavailable" caption
    /// above the table rather than `PageInfoBar` (which reports
    /// `Sampler`-driven generation/health this page has neither of).
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
        if let reason = model.unavailableReason, model.catalog == nil {
            return "Unavailable: \(reason)"
        }
        guard let catalog = model.catalog else {
            return model.isLoading ? "Loading\u{2026}" : "Not loaded"
        }
        let count = catalog.items.count
        let runningCount = catalog.items.filter(\.isRunning).count
        let itemsText = count == 1 ? "1 service" : "\(count) services"
        let runningText = "\(runningCount) running"
        if let reason = model.unavailableReason {
            return "\(itemsText), \(runningText) \u{2014} reload failed: \(reason)"
        }
        return "\(itemsText), \(runningText) \u{2014} as of \(Self.timeFormatter.string(from: catalog.generatedAt))"
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || model.catalog == nil
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns,
            rows: filteredItems,
            sort: $sort,
            selection: $selectedItemID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        searchText.isEmpty ? "No services found." : "No services match \u{201C}\(searchText)\u{201D}."
    }

    private var filteredItems: [ServiceItem] {
        guard let catalog = model.catalog else { return [] }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return catalog.items }
        let needle = searchText.lowercased()
        return catalog.items.filter { item in
            item.label.lowercased().contains(needle)
                || (item.programPath?.lowercased().contains(needle) ?? false)
                || (item.plistPath?.lowercased().contains(needle) ?? false)
                || item.group.lowercased().contains(needle)
        }
    }

    private static let columns: [DataTableColumn<ServiceItem>] = [
        // `Bool` isn't `Comparable`, so this column uses the general
        // initializer with an explicit `comparator: nil` (unsortable — a
        // read-only status indicator, scanned visually rather than sorted)
        // rather than `DataTableColumn`'s `value:`-based convenience
        // initializer every other column below uses. Matches
        // `StartupPage`'s own "Enabled" column shape, but permanently
        // disabled: PLAN.md's "Running checkbox" is this job's live state,
        // not a control this unprivileged app can safely flip (unlike
        // Startup's own login-time enable/disable, starting or stopping an
        // arbitrary loaded service has real side effects this app makes
        // no promise about).
        DataTableColumn(id: "running", title: "Running", width: 60, alignment: .center, comparator: nil) { item in
            Toggle("", isOn: .constant(item.isRunning))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(true)
                .help(item.isRunning ? "Running" : "Not running")
                .accessibilityLabel("Running, \(item.label)")
                .accessibilityValue(item.isRunning ? "Yes" : "No")
        },
        DataTableColumn(id: "name", title: "Name", value: { $0.label }) { item in
            Text(item.label)
                .lineLimit(1)
                .truncationMode(.middle)
        },
        DataTableColumn(id: "path", title: "Description / Path", value: { pathText(for: $0) }) { item in
            Text(pathText(for: item))
                .font(.callout)
                .foregroundStyle(item.programPath == nil && item.plistPath == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        },
        DataTableColumn(id: "group", title: "Group", width: 150, value: { $0.group }) { item in
            Text(item.group)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        },
    ]

    private static func pathText(for item: ServiceItem) -> String {
        item.programPath ?? item.plistPath ?? "\u{2014}"
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            DetailPane(
                title: item.label,
                subtitle: item.plistPath ?? item.programPath,
                systemImage: "gearshape.2",
                sections: detailSections(for: item)
            )
        } else {
            DetailPane(emptyMessage: "Select a service to view its details.")
        }
    }

    private var selectedItem: ServiceItem? {
        guard let selectedItemID, let catalog = model.catalog else { return nil }
        return catalog.items.first(where: { $0.id == selectedItemID })
    }

    /// Identity / Status sections — PLAN.md §1.1 leaves "Services"'s
    /// detail-pane contents unspecified beyond "detail pane on selection,"
    /// so this mirrors the shape of its two closest siblings' panes
    /// (`StartupPage`'s Identity/Status groups, `SystemInfoPage`'s flat
    /// key-value rows) using exactly the fields `ServicesProvider` can
    /// honestly report.
    private func detailSections(for item: ServiceItem) -> [DetailPaneSection] {
        [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Label", value: item.label),
                DetailPaneField(label: "Domain", value: item.runtimeDomain.displayName),
                DetailPaneField(label: "Group", value: item.group),
                DetailPaneField(label: "Program", value: item.programPath ?? "", isUnavailable: item.programPath == nil),
                DetailPaneField(label: "Plist Path", value: item.plistPath ?? "", isUnavailable: item.plistPath == nil),
            ]),
            DetailPaneSection(title: "Status", fields: [
                DetailPaneField(label: "Running", value: item.isRunning ? "Yes" : "No"),
                DetailPaneField(label: "PID", value: item.pid.map { "\($0)" } ?? "", isUnavailable: item.pid == nil, isMonospaced: true),
                DetailPaneField(label: "Last Exit Status", value: item.lastExitStatus.map { "\($0)" } ?? "", isUnavailable: item.lastExitStatus == nil, isMonospaced: true),
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

// MARK: - View model

/// Drives `ServicesProvider` for `ServicesPage` — load-once-then-
/// Reload, the same pattern `StartupViewModel`/`SystemInfoViewModel`
/// establish; simpler than `StartupViewModel` since this page has no
/// toggle to plumb through.
@MainActor
final class ServicesViewModel: ObservableObject {
    @Published private(set) var catalog: ServicesCatalog?
    @Published private(set) var isLoading = false
    /// Set when the most recent `sample()` threw. Left in place alongside
    /// a still-populated `catalog` after a failed Reload, matching
    /// `StartupViewModel.unavailableReason`'s honest-degradation behavior.
    @Published private(set) var unavailableReason: String?

    private let provider = ServicesProvider()
    private var hasLoadedOnce = false

    func loadIfNeeded() async {
        guard !hasLoadedOnce else { return }
        hasLoadedOnce = true
        await reload()
    }

    func reload() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            catalog = try await provider.sample()
            unavailableReason = nil
        } catch {
            unavailableReason = error.localizedDescription
        }
    }
}

#Preview {
    ServicesPage()
        .frame(width: 820, height: 620)
}
