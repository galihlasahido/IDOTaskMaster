import SwiftUI

/// Root shell for the main window: native sidebar nav, page routing, and
/// the bottom info bar (PLAN.md §3's `AppShell.swift # sidebar nav, page
/// routing, bottom info bar`). The bottom info bar itself is
/// `Components/PageInfoBar.swift` (PLAN.md §4 M1) — this file just anchors
/// one under every destination, fed live values by `AppShellStatusModel`
/// below (see that type's doc comment for its `Sampler` lifetime).
///
/// A `NavigationSplitView` rather than a hand-rolled `HStack` split: that
/// is what gives the sidebar its native translucent macOS material and
/// standard collapse/resize behavior for free (PLAN.md §2: "translucent
/// native **sidebar** for the pages"), matching System Settings/Mail/
/// Activity Monitor's own chrome with no custom drawing.
///
/// Sidebar rows come from `SidebarPage` (this milestone,
/// `Pages/SidebarPage.swift`), grouped into two `Section`s — an
/// unlabeled top section and a "Tools" section — which is this app's
/// neutral restyle of [name removed]'s "PRO" divider (PLAN.md §2: "the sidebar
/// loses [name removed]'s 'PRO' divider — one flat nav list (or a neutral 'Tools'
/// divider for the same visual rhythm)"). Every row routes to a real,
/// distinct page type (`Pages/*Page.swift`); M1 let each render a
/// `PlaceholderPageView` body, and later milestones have been filling
/// them in one at a time without touching this routing switch.
///
/// Settings is deliberately not a row in that `List`: PLAN.md §1.1 puts
/// it at the sidebar's bottom, separate from the scrollable page list
/// ("Bottom: Settings, Colors (popover)"), and §4's M8 task frames it as
/// its own "Settings window (⌘,)" rather than a page alongside Summary/
/// Performance/etc. This milestone gives it a fixed footer button below
/// the `List` — matching that bottom placement and already routed to its
/// own `SettingsPage` placeholder — so M8 only has to decide whether that
/// button opens a `Settings` scene or keeps showing this page in place;
/// where the button lives doesn't change either way.
struct AppShell: View {
    /// The selected `List` row, if any. `nil` both before first selection
    /// resolves and whenever the Settings footer button is the active
    /// destination instead (see `settingsSelected`) — `List` briefly
    /// clears its own selection when a row outside it becomes current,
    /// which is exactly the "no page row highlighted" look Settings
    /// wants.
    @State private var selection: SidebarPage? = .summary
    /// True while the Settings footer button (rather than a `List` row)
    /// is the active destination. Kept separate from `selection` instead
    /// of folding Settings into `SidebarPage` — see that type's and this
    /// struct's doc comments for why Settings isn't a list row at all.
    @State private var settingsSelected = false
    /// Feeds `PageInfoBar` real health/process-count/generation numbers —
    /// see its doc comment for the shared-`Sampler` lifetime this owns.
    @StateObject private var statusModel = AppShellStatusModel()

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                detail
                // `PageInfoBar` sits under every destination, matching
                // PLAN.md §1.1's bottom status bar being shell chrome
                // rather than a per-page element, fed by `statusModel`'s
                // own always-on `Sampler` (this shell never disappears
                // while the app runs, unlike a per-page one).
                PageInfoBar(
                    degradedProviderCount: statusModel.degradedProviderCount,
                    totalProviderCount: statusModel.totalProviderCount,
                    processCount: statusModel.processCount,
                    generation: statusModel.generation
                )
            }
            .navigationTitle(navigationTitle)
        }
        .frame(minWidth: 920, minHeight: 620)
        // Selecting a page row hands the destination back to `selection`;
        // this clears `settingsSelected` so the two "which destination is
        // showing" flags never disagree with the `List`'s own highlight.
        .onChange(of: selection) { newValue in
            if newValue != nil { settingsSelected = false }
        }
        .onAppear { statusModel.start() }
    }

    private var navigationTitle: String {
        if settingsSelected { return "Settings" }
        return selection?.title ?? "IDOTaskMaster"
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    ForEach(SidebarPage.mainPages) { page in
                        sidebarRow(page)
                    }
                }
                Section("Tools") {
                    ForEach(SidebarPage.toolPages) { page in
                        sidebarRow(page)
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            settingsFooterButton
        }
    }

    private func sidebarRow(_ page: SidebarPage) -> some View {
        Label(page.title, systemImage: page.systemImage)
            .tag(page)
    }

    /// [name removed]'s bottom-of-sidebar Settings entry (PLAN.md §1.1), reproduced
    /// as a plain button below the `List` rather than a row inside it —
    /// see this struct's doc comment for why Settings isn't a
    /// `SidebarPage` case.
    private var settingsFooterButton: some View {
        Button {
            selection = nil
            settingsSelected = true
        } label: {
            Label("Settings", systemImage: "gearshape")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        // Same accent-tint selection language `StatTile` uses for its own
        // selected state, so this footer row reads as part of the same
        // nav rather than a one-off control.
        .background(settingsSelected ? Color.accentColor.opacity(0.15) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityAddTraits(settingsSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if settingsSelected {
            SettingsPage()
        } else if let selection {
            destination(for: selection)
        } else {
            // Reachable only if a future change clears `selection`
            // without setting `settingsSelected` (today nothing does —
            // the footer button always pairs those two writes together,
            // and every `List` row always yields a non-nil `selection`).
            // Kept as a safety net rather than force-unwrapping.
            // Hand-written rather than `ContentUnavailableView`, which
            // needs macOS 14 — this target's minimum is 13.0 (PLAN.md §2).
            VStack(spacing: 10) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("No page selected")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Choose a page from the sidebar.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor))
        }
    }

    @ViewBuilder
    private func destination(for page: SidebarPage) -> some View {
        switch page {
        case .summary: SummaryPage()
        case .performance: PerformancePage()
        case .processes: ProcessesPage()
        case .systemInfo: SystemInfoPage()
        case .startup: StartupPage()
        case .users: UsersPage()
        case .services: ServicesPage()
        case .powerFreq: PowerFreqPage()
        case .connections: ConnectionsPage()
        case .networkUsage: NetworkUsagePage()
        case .installedApps: InstalledAppsPage()
        case .diskSpace: DiskSpacePage()
        case .benchmarks: BenchmarksPage()
        case .history: HistoryPage()
        case .alerts: AlertsPage()
        }
    }
}

#Preview {
    AppShell()
}

// MARK: - Status model

/// Owns the shared `Sampler` behind the bottom `PageInfoBar` — the same
/// `Sampler`-per-owner lifetime pattern `SummaryViewModel`/
/// `PerformanceViewModel` use for their own pages, except this one starts
/// once in `AppShell.onAppear` and simply runs for the app's lifetime
/// (never stopped) since the shell it belongs to never disappears while a
/// window is open, unlike a page that's swapped out when the user
/// navigates elsewhere.
///
/// Deliberately its own `Sampler` instance rather than something pages
/// reach into: each page already owns the one it needs for its own live
/// data (`SummaryViewModel`'s doc comment on why that's per-visit rather
/// than shared), and this model only ever needs the cheap, page-agnostic
/// numbers `PageInfoBar` shows — health, process count, generation — not
/// any page's per-domain payloads.
@MainActor
final class AppShellStatusModel: ObservableObject {
    @Published private(set) var degradedProviderCount = 0
    @Published private(set) var totalProviderCount = 0
    @Published private(set) var processCount: Int?
    @Published private(set) var generation: UInt64?

    private let sampler = Sampler()
    private var streamTask: Task<Void, Never>?

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
    }

    private func ingest(_ snapshot: Snapshot) {
        degradedProviderCount = snapshot.degradedProviderCount
        totalProviderCount = snapshot.providersHealth.count
        processCount = snapshot.processCount
        generation = snapshot.generation
    }
}
