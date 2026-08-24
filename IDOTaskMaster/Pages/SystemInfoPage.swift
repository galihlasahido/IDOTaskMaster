import SwiftUI

/// System Info catalog — PLAN.md §1.1 "System Info (three-section
/// catalog, like System Profiler)" / §4 M5's first task. A native
/// master-detail split: a `List` of Hardware/Network/Software items on
/// the left (`Providers/SystemInfoProvider.swift`'s `SystemInfoCatalog`,
/// one `Section` per category), `Components/DetailPane.swift`'s key-value
/// inspector on the right for whichever item is selected — the same
/// key-value-detail role `DetailPane` already plays for Processes/Users,
/// per its own doc comment ("Services' and System Info's own key-value
/// detail panes").
///
/// Unlike every polled page (`ProcessesPage`, `UsersPage`), this one does
/// **not** run a repeating poll loop: `SystemInfoProvider`'s doc comment
/// explains why `system_profiler` is too slow to sample on any tick
/// cadence. Instead `SystemInfoViewModel` loads the catalog exactly once
/// per appearance (`loadIfNeeded()`, guarded so navigating away and back
/// doesn't re-run `system_profiler`) and only refreshes again when the
/// toolbar's Reload button is pressed — matching the architecture note's
/// "cached, Reload" and the research inventory's "Key/value detail pane +
/// Reload button" for this exact page.
struct SystemInfoPage: View {
    @StateObject private var model = SystemInfoViewModel()
    @State private var searchText = ""
    @State private var selectedItemID: String?
    /// Fixed master-list width, wide enough for the longest expected row
    /// label ("Thunderbolt Bridge") without truncating — matching
    /// `ProcessesPage`'s own fixed-height detail pane in spirit: a stable
    /// dimension rather than one that jumps around as data loads.
    private static let listWidth: CGFloat = 220

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: Self.listWidth)
            Divider()
            detailPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter System Info")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                reloadButton
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
        .help("Reload from system_profiler")
    }

    // MARK: - Master list

    private var list: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            if filteredCategories.allSatisfy({ $0.items.isEmpty }) {
                emptyListState
            } else {
                List(selection: $selectedItemID) {
                    ForEach(filteredCategories) { category in
                        if !category.items.isEmpty {
                            Section(category.title) {
                                ForEach(category.items) { item in
                                    Label(item.name, systemImage: item.systemImage)
                                        .lineLimit(1)
                                        .tag(item.id)
                                }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Small "as of / Unavailable" caption above the list, the master-list
    /// equivalent of `PageInfoBar`'s honest-degradation convention: a
    /// catalog that's never loaded yet, one that failed, and one that's
    /// showing a possibly-stale-but-still-good previous reading are three
    /// different states, and each says so rather than looking identical.
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
    }

    private var statusText: String {
        if let reason = model.unavailableReason, model.catalog == nil {
            return "Unavailable: \(reason)"
        }
        guard let catalog = model.catalog else {
            return model.isLoading ? "Loading…" : "Not loaded"
        }
        let time = Self.timeFormatter.string(from: catalog.generatedAt)
        if let reason = model.unavailableReason {
            // A catalog from a previous successful sample is still shown
            // (see `SystemInfoProvider.cachedCatalog`'s doc comment on why
            // a failed Reload doesn't blank the page); this both dates
            // that reading and names why it isn't fresher.
            return "As of \(time) — reload failed: \(reason)"
        }
        return "As of \(time)"
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || model.catalog == nil
    }

    private var emptyListState: some View {
        VStack {
            Spacer(minLength: 0)
            Text(searchText.isEmpty ? "No system info loaded." : "No items match \u{201C}\(searchText)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// `model.catalog`'s categories narrowed to items whose name contains
    /// `searchText` (case-insensitive), or every item when the search
    /// field is empty. An empty `model.catalog` (nothing loaded yet, or a
    /// reload that's never once succeeded) reads as three empty
    /// categories rather than nothing at all, so the list still shows the
    /// Hardware/Network/Software section structure while loading.
    private var filteredCategories: [SystemInfoCategory] {
        guard let catalog = model.catalog else {
            return SystemInfoPage.emptySections
        }
        guard !searchText.isEmpty else { return catalog.categories }
        return catalog.categories.map { category in
            SystemInfoCategory(
                id: category.id,
                title: category.title,
                systemImage: category.systemImage,
                items: category.items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
            )
        }
    }

    private static let emptySections: [SystemInfoCategory] = []

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            DetailPane(title: item.name, systemImage: item.systemImage, sections: detailSections(for: item))
        } else {
            DetailPane(emptyMessage: "Select an item to view its details.")
        }
    }

    private var selectedItem: SystemInfoItem? {
        guard let selectedItemID, let catalog = model.catalog else { return nil }
        for category in catalog.categories {
            if let item = category.items.first(where: { $0.id == selectedItemID }) {
                return item
            }
        }
        return nil
    }

    private func detailSections(for item: SystemInfoItem) -> [DetailPaneSection] {
        item.groups.map { group in
            DetailPaneSection(
                id: group.id,
                title: group.title,
                fields: group.fields.map { field in
                    DetailPaneField(id: field.id, label: field.label, value: field.value)
                }
            )
        }
    }

    // MARK: - Formatting

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// Drives `SystemInfoProvider` for `SystemInfoPage` — load-once-then-Reload
/// rather than the repeating poll loop `ProcessesViewModel`/`UsersViewModel`
/// run, matching `SystemInfoProvider`'s own doc comment on why this domain
/// is cached-and-manually-refreshed instead of ticking.
@MainActor
final class SystemInfoViewModel: ObservableObject {
    @Published private(set) var catalog: SystemInfoCatalog?
    @Published private(set) var isLoading = false
    /// Set when the most recent `sample()` threw. Left in place alongside
    /// a still-populated `catalog` after a failed Reload (PLAN.md's
    /// honest degradation: say a refresh failed without discarding the
    /// last real reading) — see `SystemInfoPage.statusText`.
    @Published private(set) var unavailableReason: String?

    private let provider = SystemInfoProvider()
    private var hasLoadedOnce = false

    /// Loads the catalog the first time a `SystemInfoPage` appears; a
    /// no-op on every later call (e.g. navigating away and back) so
    /// re-visiting this page never silently re-runs `system_profiler` —
    /// only an explicit `reload()` does that.
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
    SystemInfoPage()
        .frame(width: 760, height: 480)
}
