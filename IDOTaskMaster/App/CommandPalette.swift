import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Shared presentation state for `CommandPaletteView` — PLAN.md §3's
/// `App/CommandPalette.swift "⌘K: jump to page / process by name or
/// PID"` and §4 M10's fourth task. Owned by `AppDelegate` alongside
/// `settings`/`alertsEngine`/`menuBarStatus` (see that class's own doc
/// comment for the pattern) rather than living as `AppShell`-local
/// `@State`: it needs to be reachable both from `AppCommands`' "Command
/// Palette…" ⌘K menu item — a `Commands` scene with no access to any
/// one window's local state — and from `AppShell`'s `.sheet`, which
/// actually presents the palette over the main window. The two stay in
/// sync through this one instance the same way View ▸ Update Frequency
/// and Settings ▸ General stay in sync through `SettingsStore
/// .updateSpeed`.
@MainActor
final class CommandPaletteController: ObservableObject {
    @Published var isPresented = false
    /// Set by any page wanting to jump straight to one process on the
    /// Processes page — e.g. `NetworkMonitorPage`'s detail pane, clicking
    /// a PID — not just the palette itself. `AppShell` observes this via
    /// `onChange` the same way it reacts to a palette pick, switching
    /// `selection` to `.processes` and handing the pid down through
    /// `ProcessesPage`'s own `pendingSelectionPID` binding.
    @Published private(set) var pendingProcessJumpPID: pid_t?

    /// Opens the palette. Safe to call when it's already open — the menu
    /// item's ⌘K firing twice (or a future second trigger) just
    /// idempotently sets the same `true`.
    func present() {
        isPresented = true
    }

    /// Requests a jump to `pid` on the Processes page, from anywhere in
    /// the app — the same destination `CommandPaletteView`'s own process
    /// rows activate, just reachable without opening the palette first.
    func jumpToProcess(pid: pid_t) {
        pendingProcessJumpPID = pid
    }
}

/// One row `CommandPaletteView` can jump to — either a `SidebarPage` or a
/// live `ProcessReading`, PLAN.md's own "page or process by name/PID"
/// phrasing turned into a type.
enum CommandPaletteItem: Identifiable {
    case page(SidebarPage)
    case process(ProcessReading)

    var id: String {
        switch self {
        case .page(let page): return "page-\(page.rawValue)"
        case .process(let reading): return "process-\(reading.pid)"
        }
    }

    /// Which of `CommandPaletteView`'s two result sections this row
    /// belongs under.
    var sectionTitle: String {
        switch self {
        case .page: return "Pages"
        case .process: return "Processes"
        }
    }

    var title: String {
        switch self {
        case .page(let page): return page.title
        case .process(let reading): return reading.name ?? "PID \(reading.pid)"
        }
    }

    /// `nil` for a page row — only a process row has a second line worth
    /// showing.
    var subtitle: String? {
        switch self {
        case .page:
            return nil
        case .process(let reading):
            guard let userName = reading.userName else { return "PID \(reading.pid)" }
            return "PID \(reading.pid) \u{00B7} \(userName)"
        }
    }
}

/// The ⌘K palette itself — a fixed-size `.sheet` (the same modal
/// mechanism `AlertsPage`'s rule editor and `PerformancePage`'s Storage/
/// Connection detail sheets already use elsewhere in this app), opened by
/// `AppCommands`' "Command Palette…" menu item via
/// `CommandPaletteController.present()` and presented by `AppShell`.
///
/// Two kinds of jump target, matching PLAN.md's own phrasing exactly:
/// - **A page** — every `SidebarPage`, matched against the query by
///   title. Picking one calls `onSelectPage`, which `AppShell` wires
///   straight to its own `selection` — identical to clicking that page's
///   sidebar row.
/// - **A process** — matched by name or PID against a fresh
///   `ProcessProvider` sample taken the moment this view appears (a
///   plain one-shot fetch, not a poll loop: this palette is on screen
///   for a few seconds at most, and `ProcessesPage`'s own
///   `ProcessesViewModel` already owns the continuously-polled tree).
///   Picking one calls `onSelectProcess`, which `AppShell` uses to both
///   switch `selection` to `.processes` and hand the pid down through
///   `ProcessesPage`'s `pendingSelectionPID` binding, so that page
///   selects — and scrolls to — the row the moment it can find it in the
///   tree (see `ProcessOutlineView.Coordinator.restoreSelection`'s own
///   "newly jumped-to selection" scroll behavior).
///
/// Keyboard-first, like Spotlight/Quick Open: the search field is
/// focused the instant this view appears, Up/Down move
/// `highlightedIndex`, Return activates whichever row is highlighted,
/// and Escape dismisses — all via a local `NSEvent` key-down monitor
/// (`installKeyMonitor()`). This is the same "no `onKeyPress`, this
/// app's minimum target is macOS 13" constraint `GlobalShortcutManager`
/// already works around with Carbon's global hotkey API, except this one
/// only needs a plain `NSEvent` *local* monitor — it never has to fire
/// while some other app is frontmost, unlike that one.
struct CommandPaletteView: View {
    @Binding var isPresented: Bool
    var onSelectPage: (SidebarPage) -> Void
    var onSelectProcess: (ProcessReading) -> Void

    @State private var query = ""
    @State private var processReadings: [ProcessReading] = []
    @State private var highlightedIndex = 0
    @State private var provider = ProcessProvider()
    @State private var keyMonitor: Any?
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if results.isEmpty {
                emptyState
            } else {
                resultsList
            }
            Divider()
            footerHint
        }
        .frame(width: 480, height: 380)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            isSearchFieldFocused = true
            loadProcesses()
            installKeyMonitor()
        }
        .onDisappear {
            removeKeyMonitor()
        }
        .onChange(of: query) { _ in highlightedIndex = 0 }
    }

    // MARK: - Search field

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search pages and processes by name or PID", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($isSearchFieldFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Results

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every `SidebarPage` whose title contains the query — every page
    /// when the query is blank, matching Spotlight's own "show something
    /// useful before you type" behavior.
    private var matchingPages: [SidebarPage] {
        guard !trimmedQuery.isEmpty else { return SidebarPage.allCases }
        let needle = trimmedQuery.lowercased()
        return SidebarPage.allCases.filter { $0.title.lowercased().contains(needle) }
    }

    /// No process results for a blank query — unlike pages, dumping every
    /// running process into the list before the user has typed anything
    /// would swamp it.
    private var matchingProcesses: [ProcessReading] {
        Self.matchingProcesses(processReadings, trimmedQuery: trimmedQuery)
    }

    /// Pages first, then processes — `resultsList`'s section order below
    /// follows this array's order directly rather than re-deriving it.
    private var results: [CommandPaletteItem] {
        matchingPages.map { .page($0) } + matchingProcesses.map { .process($0) }
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                        if index == 0 || results[index - 1].sectionTitle != item.sectionTitle {
                            sectionHeader(item.sectionTitle)
                        }
                        row(item: item, index: index)
                            .id(item.id)
                    }
                }
                .padding(.bottom, 6)
            }
            .onChange(of: highlightedIndex) { newValue in
                guard results.indices.contains(newValue) else { return }
                proxy.scrollTo(results[newValue].id, anchor: .center)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    /// One selectable row. Mouse click and keyboard Return both funnel
    /// through `activate(_:)`; clicking a row also moves the keyboard
    /// highlight to it first, so the two selection mechanisms never
    /// disagree about which row is "current."
    private func row(item: CommandPaletteItem, index: Int) -> some View {
        HStack(spacing: 10) {
            icon(for: item)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(index == highlightedIndex ? Color.accentColor.opacity(0.18) : Color.clear)
                .padding(.horizontal, 6)
        )
        .onTapGesture {
            highlightedIndex = index
            activate(item)
        }
    }

    @ViewBuilder
    private func icon(for item: CommandPaletteItem) -> some View {
        switch item {
        case .page(let page):
            Image(systemName: page.systemImage)
                .foregroundStyle(.secondary)
        case .process(let reading):
            if let data = reading.iconPNGData, let nsImage = NSImage(data: data) {
                Image(nsImage: nsImage)
                    .resizable()
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: reading.isApplication ? "app.dashed" : "gearshape")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No pages or processes match \u{201C}\(trimmedQuery)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footerHint: some View {
        HStack(spacing: 12) {
            hint("\u{2191}\u{2193}", "Navigate")
            hint("\u{21A9}", "Open")
            hint("esc", "Close")
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Color(nsColor: .separatorColor).opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Activation

    private func activate(_ item: CommandPaletteItem) {
        switch item {
        case .page(let page):
            onSelectPage(page)
        case .process(let reading):
            onSelectProcess(reading)
        }
        isPresented = false
    }

    private func moveHighlight(by delta: Int) {
        guard !results.isEmpty else { return }
        highlightedIndex = min(max(highlightedIndex + delta, 0), results.count - 1)
    }

    private func activateHighlighted() {
        guard results.indices.contains(highlightedIndex) else { return }
        activate(results[highlightedIndex])
    }

    // MARK: - Process loading

    /// One-shot `ProcessProvider.sample()` on appear — see this type's own
    /// doc comment for why this isn't a poll loop.
    private func loadProcesses() {
        let provider = provider
        Task {
            guard let forest = try? await provider.sample() else { return }
            processReadings = forest.all
        }
    }

    /// Ranks and filters `readings` against `trimmedQuery` by exact PID,
    /// then name (exact, prefix, substring), then PID substring — same
    /// "best match first" convention as `ProcessesPage.filtered(_:query:)`'s
    /// own name/user/PID matching, capped to 20 rows so a broad query
    /// (e.g. a single common letter) doesn't dump the whole process list
    /// into a palette meant for a quick jump.
    private static func matchingProcesses(_ readings: [ProcessReading], trimmedQuery: String) -> [ProcessReading] {
        guard !trimmedQuery.isEmpty else { return [] }
        let needle = trimmedQuery.lowercased()

        func rank(_ reading: ProcessReading) -> Int? {
            let pidString = String(reading.pid)
            if pidString == trimmedQuery { return 0 }
            if let name = reading.name?.lowercased() {
                if name == needle { return 1 }
                if name.hasPrefix(needle) { return 2 }
                if name.contains(needle) { return 3 }
            }
            if pidString.contains(needle) { return 4 }
            return nil
        }

        return readings
            .compactMap { reading -> (ProcessReading, Int)? in
                guard let rank = rank(reading) else { return nil }
                return (reading, rank)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                return (lhs.0.name ?? "").localizedCaseInsensitiveCompare(rhs.0.name ?? "") == .orderedAscending
            }
            .prefix(20)
            .map(\.0)
    }

    // MARK: - Keyboard navigation

    /// Installs a local `NSEvent` key-down monitor for the four keys this
    /// palette cares about, returning `nil` for each to consume it (so
    /// e.g. Up/Down don't also move the search field's text cursor) and
    /// passing every other key through untouched. Raw `kVK_*` codes from
    /// `Carbon.HIToolbox`, the same constants (and the same "hardcode the
    /// kernel/HIToolbox value rather than depend on a higher-level API
    /// existing" style) `GlobalShortcutManager` already uses for Escape.
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch Int(event.keyCode) {
            case kVK_DownArrow:
                moveHighlight(by: 1)
                return nil
            case kVK_UpArrow:
                moveHighlight(by: -1)
                return nil
            case kVK_Return, kVK_ANSI_KeypadEnter:
                activateHighlighted()
                return nil
            case kVK_Escape:
                isPresented = false
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }
}

#Preview {
    CommandPaletteView(
        isPresented: .constant(true),
        onSelectPage: { _ in },
        onSelectProcess: { _ in }
    )
}
