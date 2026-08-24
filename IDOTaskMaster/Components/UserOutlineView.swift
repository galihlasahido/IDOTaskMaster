import AppKit
import Foundation
import SwiftUI

/// One user's aggregated rollup — PLAN.md §1.1 Users "Per-user grouping
/// (status, process count, total CPU, total Memory)" and §4 M4's final
/// task. Built by `UsersPage`'s view model from a `ProcessProvider`
/// sample's flat `ProcessForest.all` list, grouped by owning uid rather
/// than by the Applications/Background split `ProcessOutlineView` groups
/// by.
struct UserRollup: Identifiable, Equatable {
    /// Owning uid (`ProcessReading.userID`) — stable group identity across
    /// a tick even when `displayName` is a synthesized "UID n" fallback
    /// (see that property's doc comment), so `UserOutlineView`'s own
    /// `UserOutlineItem.isEqual` keeps tracking the same real user across
    /// reloads regardless of whether `getpwuid_r` starts or stops
    /// resolving a name for it.
    var id: uid_t { userID }
    let userID: uid_t
    /// Resolved short username (`ProcessReading.userName`) shared by this
    /// uid's processes, or a "UID n" fallback when every one of them
    /// failed that lookup — PLAN.md's honest-degradation rule applied to a
    /// *group* label rather than a single field: this app still knows
    /// exactly which user owns these processes (the uid), just not their
    /// name.
    let displayName: String
    let isNameResolved: Bool
    /// This user's processes, unsorted (display order is
    /// `UserOutlineView.sortedRollups(_:sort:)`'s job).
    let processes: [ProcessReading]

    var processCount: Int { processes.count }

    /// Sum of every process's `cpuPercent` that had one this tick; `nil`
    /// only when *none* of this user's processes had a readable CPU
    /// percent this tick (e.g. every one of them is a first-tick or
    /// permission-denied reading) — an honest "Unavailable" rather than a
    /// rollup read as a real zero over zero data points.
    var totalCPUPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    /// Sum of every process's resident memory footprint that had one this
    /// tick; `nil` under the same all-missing condition as
    /// `totalCPUPercent`.
    var totalMemoryBytes: UInt64? {
        let values = processes.compactMap(\.memoryFootprintBytes)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    /// One-word rollup status for the group row — PLAN.md's per-user
    /// "status" column. "Running" once any of this user's processes is
    /// running or idle (the states `top`/Activity Monitor treat as "doing
    /// something"), else the single state every process shares when they
    /// all agree, else "Mixed" for a genuinely mixed bag (e.g. some
    /// sleeping, some stopped) rather than picking one of them arbitrarily.
    var statusLabel: String {
        guard !processes.isEmpty else { return "\u{2014}" }
        if processes.contains(where: { $0.status == .running || $0.status == .idle }) { return "Running" }
        let distinctLabels = Set(processes.map(\.status.displayLabel))
        if distinctLabels.count == 1, let only = distinctLabels.first { return only }
        return "Mixed"
    }
}

/// Native `NSOutlineView`-backed per-user process tree — PLAN.md §3's
/// `Components/ProcessOutlineView.swift "NSOutlineView via
/// NSViewRepresentable"` (the same technique, applied to §4 M4's final
/// task: "Users page: same data grouped by user with per-user rollups").
///
/// Two levels, unlike `ProcessOutlineView`'s arbitrarily-nested process
/// tree: a top row per `UserRollup` (real column values — Status, Processes
/// count, total CPU, total Memory — not a spanning group-header label, so
/// PLAN.md's rollup numbers can sit in their own sortable, aligned
/// columns), each holding that user's processes as flat children (a
/// process's real parent/child edges aren't reproduced here — a child
/// process can belong to a different uid than its parent, e.g. a
/// root-owned `launchd` spawning a user's agent, so re-nesting by
/// ownership wouldn't reflect anything real). Six columns — Name,
/// Processes, Status, PID, CPU %, Memory — shared by both row kinds, each
/// with one unambiguous meaning at both levels (see each column's builder
/// below); clicking a header sorts both levels via
/// `NSTableColumn.sortDescriptorPrototype`, kept in sync with a
/// `DataTableSort` binding the same way `ProcessOutlineView` does.
///
/// Pure like `DataTable`/`ProcessOutlineView`: it only knows how to lay out
/// and sort whatever `rollups` it's handed. Filtering (PLAN.md's "Filter
/// Users" search field) is `UsersPage`'s job, matching `PageToolbar`'s own
/// "a page owns what 'search' filters" rule — this view just needs
/// `isFiltering` so it knows whether to keep every rollup force-expanded to
/// reveal filtered matches, or leave the user's own expand/collapse
/// choices alone.
struct UserOutlineView: NSViewRepresentable {
    let rollups: [UserRollup]
    /// See `ProcessOutlineView.isFiltering`'s doc comment — same rule,
    /// applied to this view's own two levels.
    let isFiltering: Bool
    @Binding var sort: DataTableSort?
    /// Selected process's pid, or `nil` when nothing (or a user rollup
    /// row) is selected — feeds `UsersPage`'s `DetailPane` the same way
    /// `ProcessOutlineView.selection` feeds `ProcessesPage`'s. Rollup rows
    /// are real, information-bearing rows (unlike `ProcessOutlineView`'s
    /// spanning group headers) but aren't selectable (see
    /// `outlineView(_:shouldSelectItem:)`): there's no process behind one
    /// for the detail pane to show, and allowing a selection that always
    /// reads back as `nil` would make this binding flicker false-deselects
    /// on every ~1s reload (`Coordinator.restoreSelection`'s own
    /// nil-means-deselect-everything rule).
    @Binding var selection: pid_t?
    var rowHeight: CGFloat = 20

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = UserOutlineNSView()
        outlineView.coordinator = context.coordinator
        outlineView.style = .inset
        outlineView.usesAlternatingRowBackgroundColors = true
        outlineView.rowHeight = rowHeight
        outlineView.indentationPerLevel = 14
        outlineView.headerView = NSTableHeaderView()
        outlineView.allowsMultipleSelection = false
        outlineView.allowsColumnReordering = false
        outlineView.floatsGroupRows = false
        outlineView.gridStyleMask = []
        outlineView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let nameColumn = Self.flexibleColumn(id: "name", title: "Name", minWidth: 160)
        let processesColumn = Self.fixedColumn(id: "processes", title: "Processes", width: 78)
        let statusColumn = Self.fixedColumn(id: "status", title: "Status", width: 90)
        let pidColumn = Self.fixedColumn(id: "pid", title: "PID", width: 64)
        let cpuColumn = Self.fixedColumn(id: "cpu", title: "CPU %", width: 70)
        let memoryColumn = Self.fixedColumn(id: "memory", title: "Memory", width: 90)
        for column in [nameColumn, processesColumn, statusColumn, pidColumn, cpuColumn, memoryColumn] {
            outlineView.addTableColumn(column)
        }
        outlineView.outlineTableColumn = nameColumn

        outlineView.dataSource = context.coordinator
        outlineView.delegate = context.coordinator

        if let sort {
            // Triggers `outlineView(_:sortDescriptorsDidChange:)`, which
            // performs this view's first `reload(outlineView:)` — no
            // separate initial reload call needed on this branch.
            outlineView.sortDescriptors = [NSSortDescriptor(key: sort.columnID, ascending: sort.ascending)]
        } else {
            context.coordinator.reload(outlineView: outlineView)
        }

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let outlineView = nsView.documentView as? NSOutlineView else { return }
        context.coordinator.parent = self
        context.coordinator.syncSortDescriptors(outlineView: outlineView)
        context.coordinator.reload(outlineView: outlineView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Column construction

    private static func fixedColumn(id: String, title: String, width: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.width = width
        column.minWidth = width
        column.maxWidth = width
        column.resizingMask = []
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        return column
    }

    private static func flexibleColumn(id: String, title: String, minWidth: CGFloat) -> NSTableColumn {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        column.title = title
        column.minWidth = minWidth
        column.width = minWidth + 100
        column.resizingMask = [.autoresizingMask, .userResizingMask]
        column.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        return column
    }

    // MARK: - Sorting

    /// Ascending two-rollup comparator for one column id, used to order the
    /// top-level rows. `"pid"` has no rollup meaning (a group isn't one
    /// process) so — like `"name"` — it falls back to `displayName`, the
    /// same "no natural field, sort by name" fallback
    /// `processComparator(for:)` uses for its own unmatched columns.
    private static func rollupComparator(for columnID: String) -> (UserRollup, UserRollup) -> Bool {
        switch columnID {
        case "processes":
            return { $0.processCount < $1.processCount }
        case "status":
            return { $0.statusLabel < $1.statusLabel }
        case "cpu":
            return { ($0.totalCPUPercent ?? -1) < ($1.totalCPUPercent ?? -1) }
        case "memory":
            return { ($0.totalMemoryBytes ?? 0) < ($1.totalMemoryBytes ?? 0) }
        default:
            return { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    /// Ascending two-reading comparator for one column id, used to order
    /// each rollup's child processes. `"processes"` has no per-process
    /// meaning (that's a rollup-only figure), so it falls back to `"name"`
    /// the same way `"pid"` falls back to `"name"` in
    /// `rollupComparator(for:)` above.
    private static func processComparator(for columnID: String) -> (ProcessReading, ProcessReading) -> Bool {
        switch columnID {
        case "pid":
            return { $0.pid < $1.pid }
        case "status":
            return { $0.status.displayLabel < $1.status.displayLabel }
        case "cpu":
            return { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
        case "memory":
            return { ($0.memoryFootprintBytes ?? 0) < ($1.memoryFootprintBytes ?? 0) }
        default:
            return { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        }
    }

    /// Re-sorts both levels of `rollups` by `sort`'s column/direction —
    /// the top-level rollup rows by `rollupComparator(for:)`, and each
    /// one's child processes by `processComparator(for:)`. `nil` orders
    /// both levels by name ascending, matching
    /// `ProcessProvider.buildForest(from:)`'s own name-alphabetical
    /// default for the sibling Processes page.
    fileprivate static func sortedRollups(_ rollups: [UserRollup], sort: DataTableSort?) -> [UserRollup] {
        let ascending = sort?.ascending ?? true
        let groupCompare = rollupComparator(for: sort?.columnID ?? "name")
        let leafCompare = processComparator(for: sort?.columnID ?? "name")
        return rollups
            .map { rollup in
                UserRollup(
                    userID: rollup.userID,
                    displayName: rollup.displayName,
                    isNameResolved: rollup.isNameResolved,
                    processes: rollup.processes.sorted { ascending ? leafCompare($0, $1) : leafCompare($1, $0) }
                )
            }
            .sorted { ascending ? groupCompare($0, $1) : groupCompare($1, $0) }
    }
}

// MARK: - Context-menu outline view

/// `NSOutlineView` subclass whose only job is supplying a right-click
/// context menu per *process* row — mirrors
/// `ProcessOutlineView.ProcessOutlineNSView`; see that type's doc comment.
/// A rollup row hands back `nil` the same way a group row does there —
/// there's no single process behind it to Quit/Reveal/Copy Path for.
private final class UserOutlineNSView: NSOutlineView {
    /// Weak: `Coordinator` owns this view (as `NSScrollView.documentView`)
    /// indirectly through SwiftUI's own view graph, not the other way
    /// around.
    weak var coordinator: UserOutlineView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard
            clickedRow >= 0,
            let item = item(atRow: clickedRow) as? UserOutlineItem,
            case .process(let reading) = item.kind
        else {
            return nil
        }
        // Right-clicking a row outside the current selection re-targets
        // the selection to it first, matching Finder/Activity Monitor's
        // own right-click behavior and `ProcessOutlineNSView`'s.
        if selectedRow != clickedRow {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return coordinator?.contextMenu(for: reading)
    }
}

// MARK: - Coordinator

extension UserOutlineView {
    /// `NSOutlineViewDataSource`/`Delegate` bridge — mirrors
    /// `ProcessOutlineView.Coordinator`; see that type's own doc comment
    /// for why tree items are wrapped in a reference-typed
    /// `NSObject` (`UserOutlineItem` here) rather than handed to AppKit as
    /// raw value types.
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: UserOutlineView
        private var displayRollups: [UserRollup]

        init(_ parent: UserOutlineView) {
            self.parent = parent
            self.displayRollups = UserOutlineView.sortedRollups(parent.rollups, sort: parent.sort)
        }

        // MARK: Reload

        func reload(outlineView: NSOutlineView) {
            displayRollups = UserOutlineView.sortedRollups(parent.rollups, sort: parent.sort)
            outlineView.reloadData()
            applyExpansion(outlineView: outlineView)
            restoreSelection(outlineView: outlineView)
        }

        /// See `ProcessOutlineView.Coordinator.syncSortDescriptors`'s doc
        /// comment — same guarded external-vs-header-click sync.
        func syncSortDescriptors(outlineView: NSOutlineView) {
            let current = outlineView.sortDescriptors.first.flatMap { descriptor -> DataTableSort? in
                guard let key = descriptor.key else { return nil }
                return DataTableSort(columnID: key, ascending: descriptor.ascending)
            }
            guard current != parent.sort else { return }
            if let sort = parent.sort {
                outlineView.sortDescriptors = [NSSortDescriptor(key: sort.columnID, ascending: sort.ascending)]
            } else {
                outlineView.sortDescriptors = []
            }
        }

        /// Expansion policy — see `ProcessOutlineView.isFiltering`'s doc
        /// comment, applied to this view's per-user top level instead of
        /// its two fixed groups. `expandItem` never collapses anything, so
        /// calling this every reload is safe even when nothing changed.
        private func applyExpansion(outlineView: NSOutlineView) {
            if parent.isFiltering {
                outlineView.expandItem(nil, expandChildren: true)
            } else {
                for rollup in displayRollups {
                    outlineView.expandItem(UserOutlineItem(kind: .user(rollup)))
                }
            }
        }

        // MARK: Selection

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            let row = outlineView.selectedRow
            guard
                row >= 0,
                let item = outlineView.item(atRow: row) as? UserOutlineItem,
                case .process(let reading) = item.kind
            else {
                if parent.selection != nil { parent.selection = nil }
                return
            }
            if parent.selection != reading.pid {
                parent.selection = reading.pid
            }
        }

        /// Same linear-scan approach as
        /// `ProcessOutlineView.Coordinator.restoreSelection` — see that
        /// method's doc comment for why a scan over this view's own
        /// (small, hundreds-not-thousands) row count is fine to repeat on
        /// every ~1s poll-driven reload.
        private func restoreSelection(outlineView: NSOutlineView) {
            guard let pid = parent.selection else {
                if outlineView.selectedRow >= 0 { outlineView.deselectAll(nil) }
                return
            }
            for row in 0..<outlineView.numberOfRows {
                guard
                    let item = outlineView.item(atRow: row) as? UserOutlineItem,
                    case .process(let reading) = item.kind,
                    reading.pid == pid
                else { continue }
                if outlineView.selectedRow != row {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                return
            }
        }

        // MARK: Context menu

        /// Builds one process row's right-click menu — identical action
        /// set to `ProcessOutlineView.Coordinator.contextMenu(for:)`,
        /// calling straight through to the same shared `ProcessActions`
        /// implementation (pid/path-only, no dependency on which page's
        /// outline view is asking) rather than duplicating it.
        fileprivate func contextMenu(for reading: ProcessReading) -> NSMenu {
            let menu = NSMenu()
            let processLabel = reading.name ?? "Process \(reading.pid)"

            menu.addItem(actionItem(
                title: "Quit \u{201C}\(processLabel)\u{201D}",
                action: #selector(handleQuit(_:)),
                reading: reading
            ))
            menu.addItem(actionItem(
                title: "Force Quit",
                action: #selector(handleForceQuit(_:)),
                reading: reading
            ))
            menu.addItem(.separator())
            menu.addItem(actionItem(
                title: "Reveal in Finder",
                action: #selector(handleReveal(_:)),
                reading: reading,
                enabled: reading.executablePath != nil
            ))
            menu.addItem(actionItem(
                title: "Copy Path",
                action: #selector(handleCopyPath(_:)),
                reading: reading,
                enabled: reading.executablePath != nil
            ))
            return menu
        }

        private func actionItem(
            title: String,
            action: Selector,
            reading: ProcessReading,
            enabled: Bool = true
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = reading
            item.isEnabled = enabled
            return item
        }

        @objc private func handleQuit(_ sender: NSMenuItem) {
            guard let reading = sender.representedObject as? ProcessReading else { return }
            ProcessActions.quit(pid: reading.pid)
        }

        @objc private func handleForceQuit(_ sender: NSMenuItem) {
            guard let reading = sender.representedObject as? ProcessReading else { return }
            ProcessActions.forceQuit(pid: reading.pid)
        }

        @objc private func handleReveal(_ sender: NSMenuItem) {
            guard let reading = sender.representedObject as? ProcessReading else { return }
            ProcessActions.revealInFinder(path: reading.executablePath)
        }

        @objc private func handleCopyPath(_ sender: NSMenuItem) {
            guard let reading = sender.representedObject as? ProcessReading else { return }
            ProcessActions.copyPath(reading.executablePath)
        }

        // MARK: Tree contents

        private func children(of item: Any?) -> [UserOutlineItem] {
            guard let outlineItem = item as? UserOutlineItem else {
                return displayRollups.map { UserOutlineItem(kind: .user($0)) }
            }
            switch outlineItem.kind {
            case .user(let rollup):
                return rollup.processes.map { UserOutlineItem(kind: .process($0)) }
            case .process:
                return []
            }
        }

        // MARK: NSOutlineViewDataSource

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            children(of: item).count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            children(of: item)[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !children(of: item).isEmpty
        }

        // MARK: NSOutlineViewDelegate

        /// Rollup rows are real, column-bearing rows (see this file's own
        /// doc comment), not `NSOutlineView`'s spanning-header "group
        /// items" — always `false`, unlike
        /// `ProcessOutlineView.Coordinator`'s equivalent.
        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            false
        }

        /// Only process rows are selectable — see
        /// `UserOutlineView.selection`'s doc comment for why a rollup row
        /// deliberately isn't, even though (unlike `ProcessOutlineView`'s
        /// group headers) it's real per-user data rather than a decorative
        /// label.
        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let outlineItem = item as? UserOutlineItem else { return false }
            if case .process = outlineItem.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let descriptor = outlineView.sortDescriptors.first, let key = descriptor.key else { return }
            let newSort = DataTableSort(columnID: key, ascending: descriptor.ascending)
            if parent.sort != newSort {
                parent.sort = newSort
            }
            reload(outlineView: outlineView)
        }

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let outlineItem = item as? UserOutlineItem, let tableColumn else { return nil }
            let columnID = tableColumn.identifier.rawValue
            switch outlineItem.kind {
            case .user(let rollup):
                return UserOutlineCells.rollupCell(outlineView: outlineView, columnID: columnID, rollup: rollup)
            case .process(let reading):
                if columnID == "name" {
                    return UserOutlineCells.nameCell(outlineView: outlineView, reading: reading)
                }
                return UserOutlineCells.processCell(outlineView: outlineView, columnID: columnID, reading: reading)
            }
        }
    }
}

// MARK: - Outline item identity

/// Reference-typed wrapper `NSOutlineView`'s data source hands back and
/// forth — see `ProcessOutlineView`'s equivalent `ProcessOutlineItem` for
/// why AppKit needs one at all (it tracks expansion/selection across a
/// `reloadData()` by `-isEqual:`/`-hash`, not object identity).
private final class UserOutlineItem: NSObject {
    enum Kind {
        case user(UserRollup)
        case process(ProcessReading)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? UserOutlineItem else { return false }
        switch (kind, other.kind) {
        case let (.user(rollup), .user(otherRollup)):
            return rollup.userID == otherRollup.userID
        case let (.process(reading), .process(otherReading)):
            return reading.pid == otherReading.pid
        default:
            return false
        }
    }

    override var hash: Int {
        switch kind {
        case .user(let rollup): return rollup.userID.hashValue
        case .process(let reading): return reading.pid.hashValue
        }
    }
}

// MARK: - Cell views

/// Cell construction for `Coordinator.outlineView(_:viewFor:item:)` — kept
/// as free functions on a caseless enum, mirroring
/// `ProcessOutlineView`'s own `ProcessOutlineCells` (this file's own copy
/// rather than a shared one, per that file's own "each page/component
/// keeps its own" convention already established for `Fmt`-style helpers
/// elsewhere in this app).
private enum UserOutlineCells {
    /// One column of a user rollup row — PLAN.md's per-user "status,
    /// process count, total CPU, total Memory", rendered in semibold text
    /// so a rollup row reads as a summary rather than an ordinary process
    /// row even without `NSOutlineView`'s spanning group-row style. The
    /// PID column has no rollup meaning (see
    /// `UserOutlineView.rollupComparator(for:)`'s own doc comment) and
    /// renders as a plain em dash.
    static func rollupCell(outlineView: NSOutlineView, columnID: String, rollup: UserRollup) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("rollup-\(columnID)")
        let cell = reusedOrNewCell(outlineView: outlineView, identifier: identifier) { cell in
            let textField = NSTextField(labelWithString: "")
            textField.alignment = alignment(for: columnID)
            configure(textField, in: cell)
        }
        let (text, color) = rollupValue(columnID: columnID, rollup: rollup)
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
        // Semibold throughout — a rollup row reads as a summary rather
        // than an ordinary process row (see this type's own doc comment)
        // — with the same monospaced-digit treatment `processCell` gives
        // its own numeric columns, so a rollup's CPU%/Memory/PID figures
        // still line up digit-for-digit as they change.
        cell.textField?.font = isNumericColumn(columnID)
            ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            : .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        return cell
    }

    static func nameCell(outlineView: NSOutlineView, reading: ProcessReading) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("name")
        let cell = reusedOrNewCell(outlineView: outlineView, identifier: identifier) { cell in
            let imageView = NSImageView()
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(imageView)
            cell.imageView = imageView

            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            textField.lineBreakMode = .byTruncatingTail
            configure(textField, in: cell)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                textField.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
            ])
        }

        cell.textField?.stringValue = reading.name ?? "Unavailable"
        cell.textField?.textColor = reading.name == nil ? .tertiaryLabelColor : .labelColor

        if let iconData = reading.iconPNGData, let image = NSImage(data: iconData) {
            cell.imageView?.image = image
        } else if reading.isApplication {
            cell.imageView?.image = NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil)
        } else {
            cell.imageView?.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        }
        return cell
    }

    static func processCell(outlineView: NSOutlineView, columnID: String, reading: ProcessReading) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(columnID)
        let cell = reusedOrNewCell(outlineView: outlineView, identifier: identifier) { cell in
            let textField = NSTextField(labelWithString: "")
            textField.alignment = alignment(for: columnID)
            configure(textField, in: cell)
        }
        let (text, color) = processValue(columnID: columnID, reading: reading)
        cell.textField?.stringValue = text
        cell.textField?.textColor = color
        cell.textField?.font = isNumericColumn(columnID)
            ? .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            : .systemFont(ofSize: NSFont.smallSystemFontSize)
        return cell
    }

    // MARK: Shared cell plumbing

    private static func reusedOrNewCell(
        outlineView: NSOutlineView,
        identifier: NSUserInterfaceItemIdentifier,
        build: (NSTableCellView) -> Void
    ) -> NSTableCellView {
        if let reused = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView {
            return reused
        }
        let cell = NSTableCellView()
        cell.identifier = identifier
        build(cell)
        return cell
    }

    /// See `ProcessOutlineView`'s own `configure(_:in:)` doc comment —
    /// identical leading/trailing pinning convention.
    private static func configure(_ textField: NSTextField, in cell: NSTableCellView) {
        textField.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(textField)
        cell.textField = textField
        NSLayoutConstraint.activate([
            textField.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor),
            textField.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        if cell.imageView == nil {
            textField.leadingAnchor.constraint(equalTo: cell.leadingAnchor).isActive = true
        }
    }

    // MARK: Formatting

    private static func alignment(for columnID: String) -> NSTextAlignment {
        switch columnID {
        case "processes", "pid", "cpu", "memory": return .right
        default: return .left
        }
    }

    /// Shared by both `rollupCell` (where `"processes"` is a real count)
    /// and `processCell` (where it's always blank — see `processValue`'s
    /// doc comment) — harmless to monospace a blank string there.
    private static func isNumericColumn(_ columnID: String) -> Bool {
        columnID == "processes" || columnID == "pid" || columnID == "cpu" || columnID == "memory"
    }

    /// Cell text and color for one rollup-row column — see `UserRollup`'s
    /// own field docs for what each figure means and when it reads as
    /// "Unavailable" versus a real zero.
    private static func rollupValue(columnID: String, rollup: UserRollup) -> (String, NSColor) {
        switch columnID {
        case "processes":
            return ("\(rollup.processCount)", .secondaryLabelColor)
        case "status":
            return (rollup.statusLabel, .secondaryLabelColor)
        case "pid":
            return ("\u{2014}", .tertiaryLabelColor)
        case "cpu":
            guard let cpu = rollup.totalCPUPercent, cpu.isFinite else { return ("\u{2014}", .secondaryLabelColor) }
            let fraction = min(max(cpu / 100, 0), 1)
            let color = NSColor(CapacityBar.statusColor(forFraction: fraction, warningAt: 0.3, criticalAt: 0.7))
            return (String(format: "%.1f%%", cpu), color)
        case "memory":
            guard let bytes = rollup.totalMemoryBytes else { return ("\u{2014}", .secondaryLabelColor) }
            return (bytesFormatter.string(fromByteCount: Int64(bytes)), .secondaryLabelColor)
        default:
            return ("", .secondaryLabelColor)
        }
    }

    /// Cell text and color for one process (leaf) row's non-Name column —
    /// identical convention to `ProcessOutlineView`'s own
    /// `formattedValue(columnID:reading:)`. `"processes"` has no
    /// per-process meaning (see `UserOutlineView`'s doc comment) and
    /// renders blank.
    private static func processValue(columnID: String, reading: ProcessReading) -> (String, NSColor) {
        switch columnID {
        case "pid":
            return ("\(reading.pid)", .secondaryLabelColor)
        case "status":
            return (reading.status.displayLabel, .secondaryLabelColor)
        case "cpu":
            guard let cpu = reading.cpuPercent, cpu.isFinite else { return ("\u{2014}", .secondaryLabelColor) }
            let fraction = min(max(cpu / 100, 0), 1)
            let color = NSColor(CapacityBar.statusColor(forFraction: fraction, warningAt: 0.3, criticalAt: 0.7))
            return (String(format: "%.1f%%", cpu), color)
        case "memory":
            guard let bytes = reading.memoryFootprintBytes else { return ("\u{2014}", .secondaryLabelColor) }
            return (bytesFormatter.string(fromByteCount: Int64(bytes)), .secondaryLabelColor)
        default:
            return ("", .secondaryLabelColor)
        }
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
