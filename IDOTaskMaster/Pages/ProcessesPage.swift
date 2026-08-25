import Foundation
import SwiftUI

/// Processes page — PLAN.md §1.1 "Processes" / §4 M4's second task
/// ("Processes page: NSOutlineView tree, filter by name/user/PID,
/// sortable columns"). Polls `ProcessProvider` on its own cadence (this
/// file's `ProcessesViewModel`, mirroring `SummaryPage`'s
/// `startTopProcessesPolling`) and renders the resulting `ProcessForest`
/// through `Components/ProcessOutlineView.swift`'s native
/// `NSOutlineView` tree.
///
/// Filtering by name/user/PID (PLAN.md's own phrasing) happens here, not
/// inside `ProcessOutlineView` — matching `PageToolbar`'s "a page owns
/// what 'search' filters" rule (see that type's doc comment) — via
/// `Self.filtered(_:query:)` below, wired to `PageToolbar`'s search field
/// through `.pageToolbar(searchText:)`.
///
/// A `Components/DetailPane.swift` sits below the tree (PLAN.md §1.1:
/// "Detail pane (bottom) for selection"), fed by `selectedPID` and built
/// from `ProcessReading` in `detailSections(for:)` — Identity (parent,
/// user, status, architecture), Lifetime (started, uptime, threads,
/// priority), Processor (CPU %, CPU time, GPU, NPU), Memory (footprint,
/// private, page faults), Disk (read/write rates and totals), per §4 M4's
/// third task. Looks the reading up in `readingsByPID` (built from the
/// *unfiltered* forest) rather than the search-narrowed tree, so an active
/// filter never blanks out an already-selected process's detail —
/// matching `ProcessOutlineView`'s own "leave the selection binding alone
/// when the pid isn't currently visible" rule. Fields with no backing
/// provider data (GPU/NPU per-process load, private memory — neither
/// exposed by any public macOS API) render "Unavailable" per PLAN.md's
/// honest-degradation rule rather than a guess.
///
/// A segmented `detailTabPicker` splits that bottom area into two tabs —
/// PLAN.md §4 M10's "Open Files & Ports tab in process detail (lsof-style,
/// like Activity Monitor's Inspect window)" — "Info" (the `DetailPane`
/// above) and "Open Files & Ports" (`openFilesPortsPane`, a `DataTable` of
/// `OpenFileEntry` rows polled from `OpenFilesProvider` by
/// `OpenFilesViewModel`, only while that tab is the one showing for the
/// current selection — see `syncOpenFilesPolling()`'s own doc comment for
/// why it isn't polled unconditionally alongside `ProcessesViewModel`).
///
/// The toolbar's ⓧ button (PLAN.md §4 M4's "Actions: Quit, Force Quit,
/// Reveal in Finder, Copy path (context menu + toolbar)") is wired to
/// `selectedPID`: clicking it opens `quitConfirmation`, a native
/// Quit/Force Quit/Cancel dialog mirroring Activity Monitor's own
/// quit-process sheet, backed by `Components/ProcessOutlineView.swift`'s
/// `ProcessActions.quit(pid:)`/`forceQuit(pid:)` — the same
/// implementation the process tree's own right-click context menu calls,
/// which additionally offers Reveal in Finder / Copy Path (no toolbar slot
/// for those two: `PageToolbar` reserves exactly the ⓧ/ⓘ pair Activity
/// Monitor's own toolbar has). ⓘ Inspect stays present-but-disabled
/// (`inspectAction` left `nil`) — this app's always-visible detail pane
/// below already fills the role a separate Inspect window would.
struct ProcessesPage: View {
    /// Set by `AppShell` when the ⌘K command palette (PLAN.md §4 M10,
    /// `App/CommandPalette.swift`) jumps straight to a process: the pid
    /// to select the moment this page can. `applyPendingSelection()`
    /// consumes it (writing `selectedPID`, then clearing this binding
    /// back to `nil`) from both `.onAppear` — covering the case this page
    /// is only being created *because* of the jump — and
    /// `.onChange(of: pendingSelectionPID)` — covering the case this page
    /// was already the visible one when a second jump landed on it.
    @Binding var pendingSelectionPID: pid_t?
    @StateObject private var model = ProcessesViewModel()
    @State private var searchText = ""
    /// Starts CPU % descending, matching `SummaryPage`'s own top-processes
    /// default and PLAN.md §1.1's own usage-ranked framing; the tree stays
    /// user-sortable (click any header) the same as every other sortable
    /// table in the app.
    @State private var sort: DataTableSort? = DataTableSort(columnID: "cpu", ascending: false)
    @State private var selectedPID: pid_t?
    /// Set while the toolbar's ⓧ button-driven Quit/Force Quit/Cancel
    /// dialog (`quitConfirmationDialog`) is on screen — the pid it's
    /// asking about, captured at the moment the button was clicked so a
    /// selection change (or the process itself exiting) while the dialog
    /// is open can't retarget which process "Quit"/"Force Quit" acts on.
    @State private var pendingQuitPID: pid_t?
    /// Which of the bottom area's two tabs is showing — see this file's
    /// own doc comment for `detailTabPicker`/`openFilesPortsPane`.
    @State private var detailTab: ProcessDetailTab = .info
    @StateObject private var openFilesModel = OpenFilesViewModel()
    /// Backs the Identity section's "Signing" field — PLAN.md §4 M10's
    /// "`SigningInfoProvider`: code-signing status (signed/notarized/
    /// unsigned, team ID) shown in process detail". Fetched lazily per
    /// selected pid (`syncSigningInfoLoad()`), not on a poll loop — see
    /// `SigningInfoProvider`'s own doc comment for why.
    @StateObject private var signingModel = SigningInfoViewModel()
    @State private var openFilesSort: DataTableSort? = DataTableSort(columnID: "fd", ascending: true)
    /// Fixed detail-pane height, matching PLAN.md §1.1's "Detail pane
    /// (bottom)" placement — tall enough to show all five sections'
    /// header rows (Identity/Lifetime/Processor/Memory/Disk) without
    /// scrolling on this app's minimum 620pt window height.
    private static let detailPaneHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detailArea
                .frame(height: Self.detailPaneHeight)
        }
        .pageToolbar(
            searchText: $searchText,
            searchPrompt: "Filter by Name, User, or PID",
            showsProcessActions: true,
            quitAction: selectedPID.map { pid in { pendingQuitPID = pid } }
        )
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(
                    columns: Self.openFilesColumns,
                    rows: openFilesModel.catalog?.entries ?? [],
                    suggestedName: "Open Files"
                )
            }
        }
        .quitConfirmationDialog(pendingPID: $pendingQuitPID, name: pendingQuitProcessName)
        .onAppear {
            model.start()
            syncOpenFilesPolling()
            signingModel.load(pid: selectedPID)
            applyPendingSelection()
        }
        .onDisappear {
            model.stop()
            openFilesModel.stop()
        }
        .onChange(of: selectedPID) { pid in
            syncOpenFilesPolling()
            signingModel.load(pid: pid)
        }
        .onChange(of: detailTab) { _ in syncOpenFilesPolling() }
        .onChange(of: pendingSelectionPID) { _ in applyPendingSelection() }
    }

    /// Consumes `pendingSelectionPID` — see that property's own doc
    /// comment for the two call sites this covers. A no-op whenever
    /// nothing is pending, so it's safe to call unconditionally from both.
    private func applyPendingSelection() {
        guard let pid = pendingSelectionPID else { return }
        selectedPID = pid
        pendingSelectionPID = nil
    }

    /// Starts/stops `openFilesModel`'s polling loop to track exactly
    /// "Open Files & Ports" tab visible + a process selected — the same
    /// "only poll a heavier per-selection reading while its own view is
    /// actually on screen" discipline `ConnectionsPage`'s traffic sampler
    /// and `PerformancePage`'s per-domain detail graphs already follow,
    /// so switching back to the "Info" tab (or clearing the selection)
    /// stops walking the previously-selected process's fd table every
    /// tick for no reason.
    private func syncOpenFilesPolling() {
        guard detailTab == .openFiles, let pid = selectedPID else {
            openFilesModel.stop()
            return
        }
        openFilesModel.start(pid: pid)
    }

    /// `pendingQuitPID`'s display name for the confirmation dialog's
    /// title, looked up the same `readingsByPID` way the detail pane's own
    /// title does — `nil` falls back to a plain "this process" phrasing
    /// (`quitConfirmationDialog`'s own default) rather than a blank name,
    /// covering the rare case a process exits in the instant between the
    /// ⓧ click and this being read.
    private var pendingQuitProcessName: String? {
        guard let pid = pendingQuitPID else { return nil }
        return readingsByPID[pid]?.name
    }

    @ViewBuilder
    private var content: some View {
        if let forest = model.forest {
            let display = Self.filtered(forest, query: searchText)
            if isFilterActive, display.applicationCount == 0, display.backgroundCount == 0 {
                noMatchesState
            } else {
                ProcessOutlineView(
                    forest: display,
                    isFiltering: isFilterActive,
                    sort: $sort,
                    selection: $selectedPID
                )
            }
        } else if let reason = model.unavailableReason {
            unavailableState(reason: reason)
        } else {
            loadingState
        }
    }

    private var isFilterActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: - Detail pane

    /// Every current reading keyed by pid — built from `model.forest`
    /// (unfiltered; see this file's own doc comment for why) rather than
    /// `Self.filtered(_:query:)`'s narrowed tree. Cheap to rebuild on each
    /// access: `ProcessesViewModel` polls at most once a second, and this
    /// dictionary construction only runs when SwiftUI re-renders `detailPane`
    /// after a forest update or a selection change.
    private var readingsByPID: [pid_t: ProcessReading] {
        guard let forest = model.forest else { return [:] }
        return Dictionary(uniqueKeysWithValues: forest.all.map { ($0.pid, $0) })
    }

    /// The bottom area as a whole: `detailTabPicker` over whichever of
    /// `infoDetailPane`/`openFilesPortsPane` `detailTab` selects.
    private var detailArea: some View {
        VStack(spacing: 0) {
            detailTabPicker
            Divider()
            Group {
                switch detailTab {
                case .info: infoDetailPane
                case .openFiles: openFilesPortsPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Native stand-in for Activity Monitor's separate Inspect *window*
    /// tabs — this app keeps one always-visible bottom pane rather than a
    /// second window (see this file's own top-of-file doc comment on why
    /// ⓘ Inspect stays disabled), so the tab switch lives here instead.
    private var detailTabPicker: some View {
        Picker("Detail Tab", selection: $detailTab) {
            ForEach(ProcessDetailTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var infoDetailPane: some View {
        if let pid = selectedPID, let reading = readingsByPID[pid] {
            DetailPane(
                title: reading.name ?? "PID \(reading.pid)",
                subtitle: reading.executablePath,
                systemImage: reading.isApplication ? "app.fill" : "gearshape",
                sections: detailSections(for: reading)
            )
        } else {
            DetailPane(emptyMessage: "Select a process to view its details.")
        }
    }

    // MARK: - Open Files & Ports tab

    /// PLAN.md §4 M10's "Open Files & Ports tab in process detail
    /// (lsof-style, like Activity Monitor's Inspect window)" — a compact
    /// `DataTable` of `OpenFileEntry` rows (FD / Kind / Name) for
    /// `selectedPID`, polled by `openFilesModel` only while this tab is
    /// the one showing (`syncOpenFilesPolling()`).
    @ViewBuilder
    private var openFilesPortsPane: some View {
        if selectedPID == nil {
            DetailPane(emptyMessage: "Select a process to view its open files and ports.")
        } else if let catalog = openFilesModel.catalog {
            VStack(spacing: 0) {
                openFilesStatusLine(catalog)
                Divider()
                DataTable(
                    columns: Self.openFilesColumns,
                    rows: catalog.entries,
                    sort: $openFilesSort,
                    rowHeight: 18,
                    emptyMessage: "No open files or ports."
                )
            }
        } else if let reason = openFilesModel.unavailableReason {
            openFilesUnavailableState(reason: reason)
        } else {
            openFilesLoadingState
        }
    }

    private func openFilesStatusLine(_ catalog: OpenFilesCatalog) -> some View {
        let count = catalog.entries.count
        let countText = count == 1 ? "1 open file/port" : "\(count) open files/ports"
        return HStack(spacing: 4) {
            Text("\(countText) \u{2014} as of \(Self.timeFormatter.string(from: catalog.generatedAt))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var openFilesLoadingState: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Reading open files\u{2026}")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func openFilesUnavailableState(reason: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private static let openFilesColumns: [DataTableColumn<OpenFileEntry>] = [
        DataTableColumn(id: "fd", title: "FD", width: 40, alignment: .trailing, value: { $0.descriptor }) { entry in
            Text("\(entry.descriptor)").monospacedDigit()
        },
        DataTableColumn(id: "kind", title: "Kind", width: 92, value: { $0.kind }) { entry in
            Text(entry.kind)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        },
        DataTableColumn(id: "name", title: "Name", value: { $0.name ?? "" }) { entry in
            Text(entry.name ?? "Unavailable")
                .foregroundStyle(entry.name == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        },
    ]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// Builds the Identity/Lifetime/Processor/Memory/Disk sections PLAN.md
    /// §1.1 calls for out of one `ProcessReading` — see this file's own
    /// doc comment for which fields are real data versus an honest
    /// "Unavailable".
    private func detailSections(for reading: ProcessReading) -> [DetailPaneSection] {
        let architectureValue = architecture(for: reading)
        let uptimeInterval = Date().timeIntervalSince(reading.startedAt)

        return [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Parent", value: parentLabel(for: reading)),
                DetailPaneField(label: "User", value: reading.userName ?? "", isUnavailable: reading.userName == nil),
                DetailPaneField(label: "Status", value: reading.status.displayLabel),
                DetailPaneField(label: "Architecture", value: architectureValue ?? "", isUnavailable: architectureValue == nil),
            ]),
            signingSection(for: reading),
            DetailPaneSection(title: "Lifetime", fields: [
                DetailPaneField(label: "Started", value: Fmt.startedAt(reading.startedAt)),
                DetailPaneField(label: "Uptime", value: Fmt.uptime(uptimeInterval), isMonospaced: true),
                DetailPaneField(label: "Threads", value: reading.threadCount.map { String($0) } ?? "", isUnavailable: reading.threadCount == nil, isMonospaced: true),
                DetailPaneField(label: "Priority", value: priorityLabel(reading.niceValue)),
            ]),
            DetailPaneSection(title: "Processor", fields: [
                DetailPaneField(label: "CPU", value: Fmt.percent(reading.cpuPercent), isUnavailable: reading.cpuPercent == nil, isMonospaced: true),
                DetailPaneField(label: "CPU Time", value: Fmt.cpuTime(reading.cpuTimeSeconds), isUnavailable: reading.cpuTimeSeconds == nil, isMonospaced: true),
                // Per-process GPU/NPU load has no public macOS API this
                // app can read (PLAN.md's honest-degradation rule) — the
                // system-wide GPU/NPU providers (M2) sample the whole
                // device, not one process's share of it.
                DetailPaneField(label: "GPU", value: "", isUnavailable: true),
                DetailPaneField(label: "NPU", value: "", isUnavailable: true),
            ]),
            DetailPaneSection(title: "Memory", fields: [
                DetailPaneField(label: "Footprint", value: Fmt.bytes(reading.memoryFootprintBytes), isUnavailable: reading.memoryFootprintBytes == nil, isMonospaced: true),
                // Private (non-shared dirty) memory needs `task_info`'s
                // `TASK_VM_INFO` phys-footprint breakdown, which
                // `ProcessProvider` doesn't read today — honestly
                // "Unavailable" rather than reusing Footprint as a stand-in.
                DetailPaneField(label: "Private", value: "", isUnavailable: true),
                DetailPaneField(label: "Page Faults", value: reading.pageFaultCount.map { String($0) } ?? "", isUnavailable: reading.pageFaultCount == nil, isMonospaced: true),
            ]),
            DetailPaneSection(title: "Disk", fields: [
                DetailPaneField(label: "Reads", value: Fmt.bytesPerSecond(reading.diskReadBytesPerSecond), isUnavailable: reading.diskReadBytesPerSecond == nil, isMonospaced: true),
                DetailPaneField(label: "Writes", value: Fmt.bytesPerSecond(reading.diskWriteBytesPerSecond), isUnavailable: reading.diskWriteBytesPerSecond == nil, isMonospaced: true),
                DetailPaneField(label: "Total Read", value: Fmt.bytes(reading.totalDiskBytesRead), isUnavailable: reading.totalDiskBytesRead == nil, isMonospaced: true),
                DetailPaneField(label: "Total Written", value: Fmt.bytes(reading.totalDiskBytesWritten), isUnavailable: reading.totalDiskBytesWritten == nil, isMonospaced: true),
            ]),
        ]
    }

    /// "\(name) (\(pid))" when the parent is a currently-known process,
    /// "PID \(pid)" when it exited or its own read failed but the kernel
    /// still reports a ppid, or "None" for `launchd`/kernel-owned
    /// processes whose `parentPID` is `nil` — not treated as a missing
    /// read (`isUnavailable`), since "no parent" is itself the honest
    /// answer for those.
    private func parentLabel(for reading: ProcessReading) -> String {
        guard let parentPID = reading.parentPID else { return "None" }
        guard let parentName = readingsByPID[parentPID]?.name else { return "PID \(parentPID)" }
        return "\(parentName) (\(parentPID))"
    }

    /// BSD nice-value label: `0` is the default scheduling priority every
    /// unmodified process starts at, negative values are elevated
    /// (`renice`d up), positive values are lowered — the same sense
    /// `top`/Activity Monitor read it in.
    private func priorityLabel(_ niceValue: Int) -> String {
        switch niceValue {
        case 0: return "Normal"
        case ..<0: return "High (\(niceValue))"
        default: return "Low (\(niceValue))"
        }
    }

    /// Delegates to `ProcessesViewModel`'s cached lookup so re-rendering
    /// the detail pane on every ~1s poll tick doesn't re-open and re-read
    /// the same executable file each time.
    private func architecture(for reading: ProcessReading) -> String? {
        guard let path = reading.executablePath else { return nil }
        return model.architectureLabel(forExecutablePath: path)
    }

    /// PLAN.md §4 M10's "`SigningInfoProvider`: code-signing status
    /// (signed/notarized/unsigned, team ID) shown in process detail" — a
    /// standalone section rather than folded into Identity, since it's the
    /// one set of fields backed by its own separate (lazily-loaded, not
    /// per-tick) provider read. While that read is still in flight for
    /// `reading.pid` (`signingModel.info(for:)` returns `nil`), every field
    /// shows the same "Unavailable" placeholder the pane already uses for
    /// any other not-yet-known value — it flips to real data the moment
    /// `SigningInfoViewModel`'s `@Published` cache fills in, no separate
    /// loading state needed for four short-lived fields.
    private func signingSection(for reading: ProcessReading) -> DetailPaneSection {
        let info = signingModel.info(for: reading.pid)
        return DetailPaneSection(title: "Signing", fields: [
            DetailPaneField(label: "Status", value: info?.statusLabel ?? "", isUnavailable: info == nil),
            DetailPaneField(label: "Notarized", value: notarizedLabel(info?.isNotarized), isUnavailable: info?.isNotarized == nil),
            DetailPaneField(label: "Team ID", value: info?.teamIdentifier ?? "", isUnavailable: info?.teamIdentifier == nil, isMonospaced: true),
            DetailPaneField(label: "Signing ID", value: info?.signingIdentifier ?? "", isUnavailable: info?.signingIdentifier == nil),
        ])
    }

    /// "Yes"/"No" for a definite notarization read, "Unavailable" for `nil`
    /// (still loading, or not a meaningful question for this code — see
    /// `SigningInfo.isNotarized`'s own doc comment for exactly when that
    /// is) — `DetailPaneField.isUnavailable` renders that last case the
    /// same dimmed way regardless of which of the two `nil` reasons it is.
    private func notarizedLabel(_ isNotarized: Bool?) -> String {
        guard let isNotarized else { return "" }
        return isNotarized ? "Yes" : "No"
    }

    // MARK: - Non-tree states

    private var loadingState: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("Gathering process data…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func unavailableState(reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text("Process Data Unavailable")
                .font(.headline)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    /// Same "No processes match “…”." wording `DataTable`'s own empty-state
    /// preview already establishes for this app, kept consistent here
    /// rather than inventing separate phrasing for the tree case.
    private var noMatchesState: some View {
        VStack {
            Spacer(minLength: 0)
            Text("No processes match \u{201C}\(searchText)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filtering

    /// Prunes `forest` to nodes matching `query` by name, username, or PID
    /// (PLAN.md's "filter by name, user, or PID"), keeping any ancestor
    /// needed to reach a matching descendant so the tree stays navigable
    /// rather than orphaning a match — `ProcessOutlineView` auto-expands
    /// every node while a filter is active (its `isFiltering` parameter)
    /// so a kept-for-context ancestor never hides its matching child.
    private static func filtered(_ forest: ProcessForest, query: String) -> ProcessForest {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return forest }
        let needle = trimmed.lowercased()

        func matches(_ reading: ProcessReading) -> Bool {
            if let name = reading.name, name.lowercased().contains(needle) { return true }
            if let userName = reading.userName, userName.lowercased().contains(needle) { return true }
            return String(reading.pid).contains(needle)
        }
        func prune(_ node: ProcessNode) -> ProcessNode? {
            let children = node.children.compactMap(prune)
            guard matches(node.reading) || !children.isEmpty else { return nil }
            return ProcessNode(reading: node.reading, children: children)
        }
        func countNodes(_ nodes: [ProcessNode]) -> Int {
            nodes.reduce(0) { $0 + 1 + countNodes($1.children) }
        }

        let applications = forest.applications.compactMap(prune)
        let background = forest.background.compactMap(prune)
        return ProcessForest(
            applications: applications,
            background: background,
            all: forest.all.filter(matches),
            applicationCount: countNodes(applications),
            backgroundCount: countNodes(background)
        )
    }
}

// MARK: - Quit confirmation dialog

private extension View {
    /// Quit/Force Quit/Cancel confirmation, mirroring Activity Monitor's
    /// own quit-process sheet — `ProcessesPage`'s toolbar ⓧ button opens
    /// it by setting `pendingPID`. Picking Quit or Force Quit calls
    /// straight through to `Components/ProcessOutlineView.swift`'s
    /// `ProcessActions.quit(pid:)`/`forceQuit(pid:)` — the same
    /// implementation the process tree's own right-click context menu
    /// uses — then clears `pendingPID`; Cancel (or dismissing the dialog
    /// any other way) clears it without acting.
    func quitConfirmationDialog(pendingPID: Binding<pid_t?>, name: String?) -> some View {
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
            Text("Quitting a process without saving may lose unsaved work. Force Quit terminates it immediately.")
        }
    }
}

// MARK: - Detail tabs

/// `ProcessesPage`'s bottom-area tabs — see that type's own doc comment
/// for `detailTabPicker`.
private enum ProcessDetailTab: CaseIterable, Identifiable, Hashable {
    case info
    case openFiles

    var id: Self { self }

    var title: String {
        switch self {
        case .info: return "Info"
        case .openFiles: return "Open Files & Ports"
        }
    }
}

// MARK: - View model

/// Polls `ProcessProvider` on its own cadence, independent of any
/// `Sampler` — there's no `process` field on `Snapshot` (see
/// `ProcessProvider`'s own doc comment: "a full process tree with icons is
/// much heavier than the 2×/sec domains `Sampler` folds together"). Mirrors
/// `SummaryPage.SummaryViewModel`'s `startTopProcessesPolling`: a plain
/// `while !Task.isCancelled` loop calling the provider's `actor`-isolated
/// `sample()`, sleeping `pollInterval` between ticks, torn down in `stop()`
/// so this page's own polling doesn't keep running while another page is
/// showing (PLAN.md §2's "lowest idle overhead").
@MainActor
final class ProcessesViewModel: ObservableObject {
    @Published private(set) var forest: ProcessForest?
    /// Set when `provider.sample()` last threw, cleared on the next
    /// success — PLAN.md's "honest degradation" message in place of a
    /// blank or fabricated tree. Left alone (not cleared) when a later
    /// tick fails after at least one success, so a single missed tick
    /// doesn't blank out an otherwise-populated tree.
    @Published private(set) var unavailableReason: String?

    private let provider = ProcessProvider()
    private var pollTask: Task<Void, Never>?
    /// Reuses `Sampler.Interval.slow` (1 sample/sec) rather than a fresh
    /// magic number, for the same reason `SummaryPage`'s own
    /// `topProcessesPollInterval` does: enumerating every process is
    /// heavier work than any single fixed-syscall-count domain provider.
    private static let pollInterval = Sampler.Interval.slow.seconds
    /// Successfully-detected executable architectures, keyed by path —
    /// mirrors `ProcessProvider`'s own icon/username caches: without it,
    /// `ProcessesPage.detailSections(for:)` would re-open and re-read the
    /// selected process's executable on every ~1s poll tick just to redraw
    /// the same "Identity → Architecture" field. Only successes are
    /// cached; a failed read is cheap enough to just retry next tick
    /// rather than also caching a negative result.
    private var architectureCache: [String: String] = [:]

    /// See `architectureCache`'s doc comment. `nil` when
    /// `ExecutableArchitecture.label(forExecutableAt:)` couldn't determine
    /// one for `path` — "Unavailable" in the detail pane, not a guess.
    func architectureLabel(forExecutablePath path: String) -> String? {
        if let cached = architectureCache[path] { return cached }
        guard let value = ExecutableArchitecture.label(forExecutableAt: path) else { return nil }
        architectureCache[path] = value
        return value
    }

    func start() {
        guard pollTask == nil else { return }
        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let forest = try await provider.sample()
                    guard let self, !Task.isCancelled else { return }
                    self.forest = forest
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

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// Drives `openFilesPortsPane`: polls `OpenFilesProvider` for one pid at a
/// time, started/stopped by `ProcessesPage.syncOpenFilesPolling()` rather
/// than running continuously the way `ProcessesViewModel` does — see that
/// method's own doc comment for why. `start(pid:)` is safe to call again
/// with a different pid while already polling (e.g. the selection changed
/// while the Open Files & Ports tab was already showing): it tears down
/// the previous loop and clears the previous pid's stale `catalog` first,
/// so the pane never briefly shows one process's fd table under another's
/// title.
@MainActor
final class OpenFilesViewModel: ObservableObject {
    @Published private(set) var catalog: OpenFilesCatalog?
    /// Same "one bad tick doesn't blank an otherwise-good table" rule as
    /// `ProcessesViewModel.unavailableReason`'s own doc comment, except
    /// `start(pid:)` itself always clears both this and `catalog` up
    /// front — a *pid change* should blank the table (it's a different
    /// process's data now stale), only a same-pid poll failure should
    /// leave a still-good `catalog` in place.
    @Published private(set) var unavailableReason: String?

    private let provider = OpenFilesProvider()
    private var pollTask: Task<Void, Never>?
    /// Slower than `ProcessesViewModel.pollInterval`: walking one
    /// process's whole fd table (and, for every socket fd, its kernel
    /// state) is heavier than that view model's single `proc_pidinfo`
    /// call per pid, and this reading is only ever needed for the one
    /// process currently showing the Open Files & Ports tab.
    private static let pollInterval: TimeInterval = 2.0

    func start(pid: pid_t) {
        pollTask?.cancel()
        catalog = nil
        unavailableReason = nil

        let provider = provider
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await provider.openFiles(forPID: pid)
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

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// Backs `ProcessesPage.signingSection(for:)`: fetches `SigningInfoProvider`
/// once per pid rather than polling it, matching that provider's own doc
/// comment on why (a running process's signing identity doesn't change out
/// from under it the way its CPU/memory readings do, and a full signature
/// verification is too heavy to repeat every tick). Results are cached in
/// `infoByPID` for the life of this view model — like `ProcessesViewModel
/// .architectureCache`, entries are never evicted, bounded in practice by
/// however many distinct processes the user actually selects in one
/// session, not by how often they're re-selected.
@MainActor
final class SigningInfoViewModel: ObservableObject {
    @Published private(set) var infoByPID: [pid_t: SigningInfo] = [:]

    private let provider = SigningInfoProvider()
    /// Pids with a fetch currently in flight, so `load(pid:)` called again
    /// for one already being fetched (e.g. a SwiftUI re-render re-reading
    /// `signingModel.info(for:)` while that fetch hasn't finished yet, or
    /// the user re-selecting a pid whose earlier fetch is still running)
    /// doesn't spawn a redundant second `Task`. A `Set`, not a single
    /// scalar: switching the selection back and forth (A → B → A) before
    /// either finishes leaves both A's and B's fetches running
    /// independently — each writes its own `infoByPID[pid]` key, so
    /// there's nothing to cancel or serialize between them.
    private var pendingPIDs: Set<pid_t> = []

    /// The cached reading for `pid`, or `nil` while it's still loading (or
    /// hasn't been requested at all — `ProcessesPage` always calls
    /// `load(pid:)` on selection change before this is read, so that
    /// second case is transient). Doesn't itself trigger a fetch — reading
    /// a `@Published` property from inside view *body* evaluation should
    /// stay side-effect-free; `load(pid:)` is the one place that starts
    /// work, called from `.onAppear`/`.onChange(of: selectedPID)` instead.
    func info(for pid: pid_t) -> SigningInfo? {
        infoByPID[pid]
    }

    /// Starts a fetch for `pid` unless it's already cached or already in
    /// flight. `pid == nil` (nothing selected) is a no-op.
    func load(pid: pid_t?) {
        guard let pid, infoByPID[pid] == nil, !pendingPIDs.contains(pid) else { return }
        pendingPIDs.insert(pid)
        let provider = provider
        Task { [weak self] in
            let result = await provider.signingInfo(forPID: pid)
            guard let self else { return }
            self.infoByPID[pid] = result
            self.pendingPIDs.remove(pid)
        }
    }
}

// MARK: - Formatting

/// Number/byte/duration formatting for the detail pane — this file's own
/// copy of `PerformancePage.swift`'s `Fmt` convention (each page keeps a
/// small file-scoped formatter set rather than sharing one across the
/// app), rendering a missing reading as the literal string "Unavailable"
/// like every other honest-degradation display in this app.
private enum Fmt {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f%%", value)
    }

    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        let clamped = min(value, UInt64(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped))
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func uptime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "Unavailable" }
        return uptimeFormatter.string(from: interval) ?? "Unavailable"
    }

    /// `H:MM:SS` (or `M:SS` under an hour) cumulative CPU time, matching
    /// Activity Monitor's own "CPU Time" column convention — finer-grained
    /// than `uptime`'s day/hour/minute breakdown, since a process's total
    /// CPU time is usually well under an hour even for long-running ones.
    static func cpuTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "Unavailable" }
        let totalSeconds = Int(seconds)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// Time-only ("9:14:02 AM") for a process started today, full
    /// date-and-time for one started earlier — a bare time would be
    /// ambiguous (which day?) for anything long-running.
    static func startedAt(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? timeOnlyFormatter.string(from: date)
            : dateTimeFormatter.string(from: date)
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter
    }()

    private static let timeOnlyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Executable architecture

/// Best-effort executable architecture, read straight from a Mach-O
/// header rather than inferred — PLAN.md §1.1's Identity "architecture
/// arm64" example. `ProcessReading` carries no such field itself (unlike
/// `ProcessProvider`'s per-tick readings, this means opening and reading a
/// few bytes of a file, so it's computed lazily by
/// `ProcessesPage.architecture(for:)`/`ProcessesViewModel.architectureLabel(
/// forExecutablePath:)` for just the selected process, not every row on
/// every tick). `nil` on any read failure, an unrecognized magic, or a
/// universal binary with no recognized slice — "Unavailable" rather than a
/// guessed answer, matching every other honest-degradation reading in this
/// app.
private enum ExecutableArchitecture {
    static func label(forExecutableAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let bytes = [UInt8](header)

        // Thin 64-bit Mach-O — the only kind current Apple toolchains
        // emit for a non-universal binary — stores its header in the
        // host's own byte order: magic at offset 0, cputype at offset 4.
        // macOS is little-endian on every architecture it runs, so a
        // native (non-byte-swapped) header always reads as little-endian
        // here.
        if readUInt32(bytes, at: 0, bigEndian: false) == 0xfeedfacf,
           let cpuType = readUInt32(bytes, at: 4, bigEndian: false) {
            return name(forCPUType: cpuType)
        }

        // Universal (fat) binary: the fat header — and every `fat_arch`
        // entry that follows it — is always stored big-endian, regardless
        // of host byte order, per the Mach-O fat format's own convention.
        guard
            let fatMagic = readUInt32(bytes, at: 0, bigEndian: true),
            fatMagic == 0xcafebabe || fatMagic == 0xcafebabf,
            let archCount = readUInt32(bytes, at: 4, bigEndian: true),
            archCount > 0, archCount <= 8
        else { return nil }

        let is64 = fatMagic == 0xcafebabf
        let entrySize = is64 ? 32 : 20
        let bodyLength = Int(archCount) * entrySize
        guard let body = try? handle.read(upToCount: bodyLength), body.count == bodyLength else { return nil }
        let bodyBytes = [UInt8](body)

        var cpuTypes: Set<UInt32> = []
        for index in 0..<Int(archCount) {
            guard let cpuType = readUInt32(bodyBytes, at: index * entrySize, bigEndian: true) else { continue }
            cpuTypes.insert(cpuType)
        }
        let names = [cpuTypeARM64, cpuTypeX86_64].compactMap { cpuTypes.contains($0) ? name(forCPUType: $0) : nil }
        guard !names.isEmpty else { return nil }
        return names.count > 1 ? "Universal (\(names.joined(separator: " + ")))" : "\(names[0]) (Universal)"
    }

    // `CPU_TYPE_ARM64`/`CPU_TYPE_X86_64` from `<mach/machine.h>` —
    // hardcoded the same way `ProcessStatus`'s `init(bsdStatus:)` hardcodes
    // its own kernel constants, rather than importing the C header for two
    // stable, decades-old values.
    private static let cpuTypeARM64: UInt32 = 0x0100_000C
    private static let cpuTypeX86_64: UInt32 = 0x0100_0007

    private static func name(forCPUType cpuType: UInt32) -> String? {
        switch cpuType {
        case cpuTypeARM64: return "arm64"
        case cpuTypeX86_64: return "Intel (x86_64)"
        default: return nil
        }
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let b0 = UInt32(bytes[offset])
        let b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2])
        let b3 = UInt32(bytes[offset + 3])
        return bigEndian
            ? (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
            : (b3 << 24) | (b2 << 16) | (b1 << 8) | b0
    }
}

#Preview {
    ProcessesPage(pendingSelectionPID: .constant(nil))
        .frame(width: 900, height: 640)
}
