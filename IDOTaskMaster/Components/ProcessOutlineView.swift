import AppKit
import Darwin
import Foundation
import SwiftUI

/// Human-readable label for `ProcessOutlineView`'s Status column (and any
/// later Processes/Users detail pane) — PLAN.md §1.1's Processes "Status"
/// column. `.other` surfaces its raw kernel value rather than a vague
/// "Unknown" alone, so an unrecognized `pbi_status` stays diagnosable.
extension ProcessStatus {
    var displayLabel: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .sleeping: return "Sleeping"
        case .stopped: return "Stopped"
        case .zombie: return "Zombie"
        case .other(let rawValue): return "Unknown (\(rawValue))"
        }
    }
}

/// Native process actions — PLAN.md §4 M4's "Actions: Quit, Force Quit,
/// Reveal in Finder, Copy path (context menu + toolbar)" and §2's process
/// context menu list ("Quit, Force Quit, Inspect, Reveal in Finder, Copy
/// path"). Four operations on a bare pid/path — no dependency on
/// `ProcessOutlineView`/`ProcessesPage` state — so both halves of that
/// requirement call through the same implementation: this file's own
/// `Coordinator.contextMenu(for:)` (right-click a row) and
/// `ProcessesPage`'s toolbar ⓧ button (driven by its `selectedPID`
/// binding, via its own quit-confirmation dialog).
enum ProcessActions {
    /// Sends `SIGTERM` — the same signal Activity Monitor's "Quit" sends —
    /// asking the process to terminate itself.
    static func quit(pid: pid_t) {
        send(signal: SIGTERM, to: pid, actionLabel: "Quit")
    }

    /// Sends `SIGKILL` — Activity Monitor's "Force Quit" — an
    /// un-ignorable, immediate termination.
    static func forceQuit(pid: pid_t) {
        send(signal: SIGKILL, to: pid, actionLabel: "Force Quit")
    }

    /// Reveals `path` in a new Finder window with the item pre-selected —
    /// PLAN.md's "Reveal in Finder". A silent no-op (not an alert) when
    /// `path` is `nil`/empty: every call site already disables its
    /// button/menu item whenever `ProcessReading.executablePath` is `nil`
    /// (another user's process this app couldn't read a path for), so
    /// reaching here with nothing to reveal never happens through the UI.
    static func revealInFinder(path: String?) {
        guard let path, !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Copies `path` to the general pasteboard as plain text — PLAN.md's
    /// "Copy path". Same no-op-when-missing rule as `revealInFinder`.
    static func copyPath(_ path: String?) {
        guard let path, !path.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    /// Shared `kill(2)` call plus its honest-failure surface: a native
    /// `NSAlert` naming why (`ESRCH` — the process already exited between
    /// the click and this call — or anything else, almost always `EPERM`:
    /// a cross-user or system process this app has no privilege over,
    /// matching PLAN.md §3's "No sudo/helper tool in v1" note) rather than
    /// silently doing nothing, so the user isn't left wondering why a
    /// stubborn process didn't quit. `pid <= 0` is refused before ever
    /// reaching `kill(2)`: PID 0 is the kernel's own scheduler slot and a
    /// negative pid is `kill`'s process-group broadcast form — neither is
    /// ever a real process this app lists, so failing those quietly (no
    /// alert) is correct rather than diagnostic.
    private static func send(signal: Int32, to pid: pid_t, actionLabel: String) {
        guard pid > 0 else { return }
        let result = kill(pid, signal)
        guard result != 0 else { return }
        let failureCode = errno
        presentFailureAlert(actionLabel: actionLabel, pid: pid, errno: failureCode)
    }

    private static func presentFailureAlert(actionLabel: String, pid: pid_t, errno failureCode: Int32) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn\u{2019}t \(actionLabel) Process (\(pid))"
        alert.informativeText = failureCode == ESRCH
            ? "This process has already quit."
            : "IDOTaskMaster doesn\u{2019}t have permission to \(actionLabel.lowercased()) this process."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

/// Native `NSOutlineView`-backed process tree — PLAN.md §3's
/// `Components/ProcessOutlineView.swift "NSOutlineView via
/// NSViewRepresentable"` and §4 M4's "Processes page: NSOutlineView tree,
/// ... sortable columns". `DataTable`'s own doc comment already reserves
/// this file for exactly this role: "The tree-structured Processes page
/// gets its own ProcessOutlineView ... since DataTable only knows how to
/// lay out a flat row list."
///
/// Renders `ProcessForest`'s Applications/Background grouping (PLAN.md
/// §1.1's "Grouped tree: Applications (17) / Background processes (467)
/// with expandable children") as two native group rows, each holding its
/// own root processes with real nested children beneath — exactly the
/// shape `ProcessProvider.buildForest(from:)` already produces. Six
/// columns (Name with app icon, PID, Status, User, CPU %, Memory) match
/// PLAN.md's own column list; every column but Name is fixed-width, and
/// clicking any header sorts via `NSTableColumn.sortDescriptorPrototype` —
/// native AppKit header sorting, kept in sync with a `DataTableSort`
/// binding so the rest of the app can read the same shape `DataTable`'s
/// own sort binding already exposes.
///
/// Pure like `DataTable`/`DetailPane`: it only knows how to lay out and
/// sort whatever `forest` it's handed. Filtering by name/user/PID
/// (PLAN.md §1.1) is `ProcessesPage`'s job, matching `PageToolbar`'s own
/// "a page owns what 'search' filters" rule — this view just needs
/// `isFiltering` so it knows whether to keep the tree auto-expanded to
/// reveal filtered matches, or to leave the user's own expand/collapse
/// choices alone.
///
/// `NSOutlineView` needs reference-typed, `isEqual`/`hash`-comparable
/// items to track expansion and selection across a `reloadData()` — see
/// `ProcessOutlineItem` below for how a value-typed `ProcessNode` is
/// wrapped to satisfy that without ever needing the *same* object
/// instance back on a later call.
struct ProcessOutlineView: NSViewRepresentable {
    let forest: ProcessForest
    /// Whether `ProcessesPage`'s search field currently holds non-blank
    /// text. While `true`, every reload force-expands the whole tree so a
    /// match nested several levels down (kept visible only because
    /// `ProcessesPage`'s own filter keeps non-matching ancestors for
    /// context) is never hidden behind a collapsed disclosure triangle.
    /// While `false`, only the two top-level Applications/Background
    /// groups are (idempotently) expanded, leaving whatever the user did
    /// to nested rows alone.
    let isFiltering: Bool
    @Binding var sort: DataTableSort?
    /// Selected process's pid, or `nil` when nothing (or a group header)
    /// is selected — a future task's `DetailPane` reads this the same way
    /// `DataTable`'s own `selection` binding drives one today.
    @Binding var selection: pid_t?
    var rowHeight: CGFloat = 20

    func makeNSView(context: Context) -> NSScrollView {
        let outlineView = ProcessOutlineNSView()
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

        let nameColumn = Self.flexibleColumn(id: "name", title: "Name", minWidth: 180)
        let pidColumn = Self.fixedColumn(id: "pid", title: "PID", width: 64)
        let statusColumn = Self.fixedColumn(id: "status", title: "Status", width: 90)
        let userColumn = Self.fixedColumn(id: "user", title: "User", width: 110)
        let cpuColumn = Self.fixedColumn(id: "cpu", title: "CPU %", width: 70)
        let memoryColumn = Self.fixedColumn(id: "memory", title: "Memory", width: 90)
        for column in [nameColumn, pidColumn, statusColumn, userColumn, cpuColumn, memoryColumn] {
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

    /// Recursively re-sorts every level of `forest`'s two trees by
    /// `sort`'s column/direction — siblings at every depth, not just the
    /// two top-level group roots, so e.g. a browser's helper processes
    /// stay CPU-sorted among themselves under their parent exactly like
    /// the top-level Applications list is. `nil` leaves `forest`'s own
    /// order alone (`ProcessProvider.buildForest(from:)`'s
    /// name-alphabetical default).
    fileprivate static func sortedForest(_ forest: ProcessForest, sort: DataTableSort?) -> ProcessForest {
        guard let sort else { return forest }
        let compare = comparator(for: sort.columnID)
        return ProcessForest(
            applications: sortedNodes(forest.applications, compare: compare, ascending: sort.ascending),
            background: sortedNodes(forest.background, compare: compare, ascending: sort.ascending),
            all: forest.all,
            applicationCount: forest.applicationCount,
            backgroundCount: forest.backgroundCount
        )
    }

    private static func sortedNodes(
        _ nodes: [ProcessNode],
        compare: @escaping (ProcessReading, ProcessReading) -> Bool,
        ascending: Bool
    ) -> [ProcessNode] {
        nodes
            .map { ProcessNode(reading: $0.reading, children: sortedNodes($0.children, compare: compare, ascending: ascending)) }
            .sorted { ascending ? compare($0.reading, $1.reading) : compare($1.reading, $0.reading) }
    }

    /// Ascending two-reading comparator for one column id — mirrors
    /// `DataTableColumn`'s own per-column comparator convention. An
    /// unrecognized id (there is none today) falls back to the Name
    /// comparator rather than crashing.
    private static func comparator(for columnID: String) -> (ProcessReading, ProcessReading) -> Bool {
        switch columnID {
        case "pid":
            return { $0.pid < $1.pid }
        case "status":
            return { $0.status.displayLabel < $1.status.displayLabel }
        case "user":
            return { ($0.userName ?? "").localizedCaseInsensitiveCompare($1.userName ?? "") == .orderedAscending }
        case "cpu":
            return { ($0.cpuPercent ?? -1) < ($1.cpuPercent ?? -1) }
        case "memory":
            return { ($0.memoryFootprintBytes ?? 0) < ($1.memoryFootprintBytes ?? 0) }
        default:
            return { ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending }
        }
    }
}

// MARK: - Context-menu outline view

/// `NSOutlineView` subclass whose only job is supplying a right-click
/// context menu per row — PLAN.md §4 M4's "context menu" half of "Actions:
/// Quit, Force Quit, Reveal in Finder, Copy path (context menu +
/// toolbar)". AppKit calls `NSView.menu(for:)` itself on a right/ctrl
/// click, so no `NSMenuDelegate` plumbing is needed; this override just
/// has to find which row (if any) sits under the click and hand back the
/// menu `Coordinator.contextMenu(for:)` builds for it.
private final class ProcessOutlineNSView: NSOutlineView {
    /// Weak: `Coordinator` owns this view (as `NSScrollView.documentView`)
    /// indirectly through SwiftUI's own view graph, not the other way
    /// around.
    weak var coordinator: ProcessOutlineView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard
            clickedRow >= 0,
            let item = item(atRow: clickedRow) as? ProcessOutlineItem,
            case .process(let node) = item.kind
        else {
            // No row (empty area) or a group header: no menu, matching
            // `outlineView(_:shouldSelectItem:)`'s own "group rows aren't
            // selectable" rule — there's nothing on a group row to act on.
            return nil
        }
        // Right-clicking a row outside the current selection re-targets
        // the selection to it first, matching Finder/Activity Monitor's
        // own right-click behavior, so the menu (and the selection the
        // rest of the page reads afterward) always follows the row under
        // the pointer rather than a stale prior selection.
        if selectedRow != clickedRow {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return coordinator?.contextMenu(for: node)
    }
}

// MARK: - Coordinator

extension ProcessOutlineView {
    /// `NSOutlineViewDataSource`/`Delegate` bridge — see this file's own
    /// doc comment for why tree items are wrapped in `ProcessOutlineItem`
    /// rather than handed to AppKit as raw `ProcessNode` values.
    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        var parent: ProcessOutlineView
        private var displayForest: ProcessForest

        init(_ parent: ProcessOutlineView) {
            self.parent = parent
            self.displayForest = ProcessOutlineView.sortedForest(parent.forest, sort: parent.sort)
        }

        // MARK: Reload

        func reload(outlineView: NSOutlineView) {
            displayForest = ProcessOutlineView.sortedForest(parent.forest, sort: parent.sort)
            outlineView.reloadData()
            applyExpansion(outlineView: outlineView)
            restoreSelection(outlineView: outlineView)
        }

        /// Keeps `NSTableColumn.sortDescriptorPrototype`'s own click-driven
        /// state in sync with `parent.sort` when it changed from *outside*
        /// this view (e.g. `ProcessesPage`'s initial default) — guarded so
        /// this never fights the opposite-direction sync a header click
        /// itself triggers in `outlineView(_:sortDescriptorsDidChange:)`.
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
        /// comment. `expandItem` never collapses anything, so calling this
        /// every reload is safe even when nothing changed.
        private func applyExpansion(outlineView: NSOutlineView) {
            if parent.isFiltering {
                outlineView.expandItem(nil, expandChildren: true)
            } else {
                for group in groupItems {
                    outlineView.expandItem(group)
                }
            }
        }

        // MARK: Selection

        func outlineViewSelectionDidChange(_ notification: Notification) {
            guard let outlineView = notification.object as? NSOutlineView else { return }
            let row = outlineView.selectedRow
            guard
                row >= 0,
                let item = outlineView.item(atRow: row) as? ProcessOutlineItem,
                case .process(let node) = item.kind
            else {
                if parent.selection != nil { parent.selection = nil }
                return
            }
            if parent.selection != node.reading.pid {
                parent.selection = node.reading.pid
            }
        }

        /// Reselects `parent.selection`'s pid after a reload by scanning
        /// the outline view's *current* (post-expansion) visible rows —
        /// simpler, and just as correct, as constructing a matching
        /// `ProcessOutlineItem` to hand `NSOutlineView.row(forItem:)`,
        /// since this view's row counts stay small enough (hundreds, not
        /// thousands) for a linear scan on every ~1s poll to be free.
        /// Leaves the binding alone (rather than clearing it) when the pid
        /// isn't currently visible — a collapsed ancestor or a
        /// momentarily-gone process shouldn't silently drop a future
        /// `DetailPane`'s selection.
        private func restoreSelection(outlineView: NSOutlineView) {
            guard let pid = parent.selection else {
                if outlineView.selectedRow >= 0 { outlineView.deselectAll(nil) }
                return
            }
            for row in 0..<outlineView.numberOfRows {
                guard
                    let item = outlineView.item(atRow: row) as? ProcessOutlineItem,
                    case .process(let node) = item.kind,
                    node.reading.pid == pid
                else { continue }
                if outlineView.selectedRow != row {
                    outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                return
            }
        }

        // MARK: Context menu

        /// Builds one process row's right-click menu — see
        /// `ProcessOutlineNSView.menu(for:)` for how this gets invoked, and
        /// `ProcessActions`' own doc comment for why every item here calls
        /// straight through to that shared, `pid`/path-only implementation
        /// rather than duplicating it. Reveal/Copy Path disable themselves
        /// when this node has no `executablePath` (another user's process
        /// this app couldn't read a path for) instead of acting on
        /// nothing.
        fileprivate func contextMenu(for node: ProcessNode) -> NSMenu {
            let reading = node.reading
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

        private var groupItems: [ProcessOutlineItem] {
            [
                ProcessOutlineItem(kind: .group(title: "Applications (\(displayForest.applicationCount))", id: "applications")),
                ProcessOutlineItem(kind: .group(title: "Background Processes (\(displayForest.backgroundCount))", id: "background")),
            ]
        }

        private func children(of item: Any?) -> [ProcessOutlineItem] {
            guard let processItem = item as? ProcessOutlineItem else { return groupItems }
            switch processItem.kind {
            case .group(_, let id):
                let roots = id == "applications" ? displayForest.applications : displayForest.background
                return roots.map { ProcessOutlineItem(kind: .process($0)) }
            case .process(let node):
                return node.children.map { ProcessOutlineItem(kind: .process($0)) }
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

        func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
            guard let processItem = item as? ProcessOutlineItem else { return false }
            if case .group = processItem.kind { return true }
            return false
        }

        func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
            guard let processItem = item as? ProcessOutlineItem else { return false }
            if case .group = processItem.kind { return false }
            return true
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
            guard let processItem = item as? ProcessOutlineItem else { return nil }
            guard let tableColumn else {
                guard case .group(let title, _) = processItem.kind else { return nil }
                return ProcessOutlineCells.groupCell(outlineView: outlineView, title: title)
            }
            guard case .process(let node) = processItem.kind else { return nil }
            if tableColumn.identifier.rawValue == "name" {
                return ProcessOutlineCells.nameCell(outlineView: outlineView, node: node)
            }
            return ProcessOutlineCells.textCell(outlineView: outlineView, columnID: tableColumn.identifier.rawValue, reading: node.reading)
        }
    }
}

// MARK: - Outline item identity

/// Reference-typed wrapper `NSOutlineView`'s data source hands back and
/// forth — needed because AppKit tracks a row's expansion/selection state
/// across a `reloadData()` by comparing items with `-isEqual:`/`-hash`,
/// not by object identity, so a *freshly constructed* wrapper around the
/// same pid (or the same group id) still reads as "the same row" to
/// AppKit even though `Coordinator.children(of:)` builds a brand-new
/// instance on every call rather than caching one per pid across ticks.
private final class ProcessOutlineItem: NSObject {
    enum Kind {
        case group(title: String, id: String)
        case process(ProcessNode)
    }

    let kind: Kind

    init(kind: Kind) {
        self.kind = kind
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ProcessOutlineItem else { return false }
        switch (kind, other.kind) {
        case let (.group(_, id), .group(_, otherID)):
            return id == otherID
        case let (.process(node), .process(otherNode)):
            return node.reading.pid == otherNode.reading.pid
        default:
            return false
        }
    }

    override var hash: Int {
        switch kind {
        case .group(_, let id): return id.hashValue
        case .process(let node): return node.reading.pid.hashValue
        }
    }
}

// MARK: - Cell views

/// Cell construction for `Coordinator.outlineView(_:viewFor:item:)` — kept
/// as free functions on a caseless enum (rather than `Coordinator`
/// methods) since none of it touches `Coordinator`'s own state; every
/// input it needs (the reading, the column id) is already a parameter.
private enum ProcessOutlineCells {
    static func groupCell(outlineView: NSOutlineView, title: String) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier("group")
        let cell = reusedOrNewCell(outlineView: outlineView, identifier: identifier) { cell in
            let textField = NSTextField(labelWithString: "")
            textField.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            textField.textColor = .secondaryLabelColor
            configure(textField, in: cell)
        }
        cell.textField?.stringValue = title
        return cell
    }

    static func nameCell(outlineView: NSOutlineView, node: ProcessNode) -> NSTableCellView {
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

        let reading = node.reading
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

    static func textCell(outlineView: NSOutlineView, columnID: String, reading: ProcessReading) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(columnID)
        let cell = reusedOrNewCell(outlineView: outlineView, identifier: identifier) { cell in
            let textField = NSTextField(labelWithString: "")
            textField.alignment = alignment(for: columnID)
            configure(textField, in: cell)
        }
        let (text, color) = formattedValue(columnID: columnID, reading: reading)
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

    /// Adds `textField` to `cell` as its `.textField`, pinned to the
    /// cell's trailing edge and vertical center. Its *leading* edge is
    /// pinned to the cell's own leading edge here — the common case for
    /// every column but Name, whose `nameCell` builder above adds its own
    /// icon-anchored leading constraint instead (recognized by `cell`
    /// already having an `imageView` at the point this runs).
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
        case "pid", "cpu", "memory": return .right
        default: return .left
        }
    }

    private static func isNumericColumn(_ columnID: String) -> Bool {
        columnID == "pid" || columnID == "cpu" || columnID == "memory"
    }

    /// Cell text and color for one non-Name column. Numeric gaps (a pid's
    /// first tick, or a cross-user permission restriction — see
    /// `ProcessReading`'s own field docs) read as a plain "—" matching
    /// `SummaryPage`'s own table-cell convention for a missing per-process
    /// reading; a missing *identity* string (`userName`) instead reads as
    /// "Unavailable", matching that same file's name-column convention.
    private static func formattedValue(columnID: String, reading: ProcessReading) -> (String, NSColor) {
        switch columnID {
        case "pid":
            return ("\(reading.pid)", .secondaryLabelColor)
        case "status":
            return (reading.status.displayLabel, .secondaryLabelColor)
        case "user":
            guard let userName = reading.userName else { return ("Unavailable", .tertiaryLabelColor) }
            return (userName, .secondaryLabelColor)
        case "cpu":
            guard let cpu = reading.cpuPercent, cpu.isFinite else { return ("—", .secondaryLabelColor) }
            // Same CPU%-usage tint `SummaryPage`'s own top-processes table
            // uses (0.3/0.7 warning/critical thresholds via
            // `CapacityBar.statusColor`), converted to `NSColor` for this
            // AppKit-hosted cell.
            let fraction = min(max(cpu / 100, 0), 1)
            let color = NSColor(CapacityBar.statusColor(forFraction: fraction, warningAt: 0.3, criticalAt: 0.7))
            return (String(format: "%.1f%%", cpu), color)
        case "memory":
            guard let bytes = reading.memoryFootprintBytes else { return ("—", .secondaryLabelColor) }
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
