import SwiftUI

/// One column of a `DataTable` — its header title, layout, optional
/// sort rule, and how to render a `Value` row into that column's cell.
///
/// Generic over `Value` the same way `HistoryGraphSeries`/
/// `CapacityBarSegment` are generic over their host component's element
/// type, so one `DataTable` implementation serves every flat list page in
/// PLAN.md §1.1 (Startup apps, Services, Users, Connections, System Info
/// catalogs, Power & Freq's sensor tree, ...). The tree-structured
/// Processes page gets its own `ProcessOutlineView` (PLAN.md §3) since
/// `DataTable` only knows how to lay out a flat row list.
struct DataTableColumn<Value: Identifiable>: Identifiable {
    let id: String
    let title: String
    /// Fixed width in points for a numeric/status column (e.g. "PID",
    /// "CPU %"). `nil` lets the column stretch to fill remaining width —
    /// the role a Name column usually plays in Activity Monitor's own
    /// tables.
    var width: CGFloat? = nil
    var alignment: HorizontalAlignment = .leading
    /// `nil` marks a column that can't be sorted by (its header renders as
    /// plain, unclickable text) — e.g. an icon-only or actions column.
    var comparator: ((Value, Value) -> Bool)?
    let cell: (Value) -> AnyView

    /// General initializer: supply your own ascending two-row comparator
    /// (or `nil` for an unsortable column).
    init<Content: View>(
        id: String,
        title: String,
        width: CGFloat? = nil,
        alignment: HorizontalAlignment = .leading,
        comparator: ((Value, Value) -> Bool)? = nil,
        @ViewBuilder cell: @escaping (Value) -> Content
    ) {
        self.id = id
        self.title = title
        self.width = width
        self.alignment = alignment
        self.comparator = comparator
        self.cell = { AnyView(cell($0)) }
    }

    /// Convenience for the common case: sort ascending by a `Comparable`
    /// property read off `Value`, e.g. `value: { $0.cpuPercent }`.
    init<T: Comparable, Content: View>(
        id: String,
        title: String,
        width: CGFloat? = nil,
        alignment: HorizontalAlignment = .leading,
        value: @escaping (Value) -> T,
        @ViewBuilder cell: @escaping (Value) -> Content
    ) {
        self.init(
            id: id,
            title: title,
            width: width,
            alignment: alignment,
            comparator: { lhs, rhs in value(lhs) < value(rhs) },
            cell: cell
        )
    }
}

/// Which column a `DataTable` is currently sorted by, and in which
/// direction. Exposed as a `Binding` so a caller can set an initial sort
/// (e.g. Processes defaulting to CPU % descending, per PLAN.md §1.1's
/// "usage-tinted cells, sortable headers") and read the live state back
/// out — e.g. to keep a paired summary in sync with the visible order.
struct DataTableSort: Equatable {
    var columnID: String
    var ascending: Bool
}

/// Native-styled sortable table — PLAN.md §4's `DataTable`. Backed by
/// `List` (itself `NSTableView`-backed on macOS) for its rows, under a
/// header row of clickable column buttons that set or flip the sort
/// direction on click — the same interaction as Finder/Activity Monitor
/// list headers. Alternating row backgrounds and standard row chrome come
/// from `.listStyle(.inset(alternatesRowBackgrounds:))` rather than any
/// custom drawing, so the table matches every other native list in the
/// app automatically in light, dark, and increased-contrast — the same
/// "no custom hex values, ride the dynamic system colors" approach
/// `HistoryGraph` and `CapacityBar` take for their own chrome.
///
/// Pure in the same sense as those siblings: it only knows how to lay out
/// and sort whatever `rows` it's given; a page owns the actual data (a
/// `ProcessProvider` sample, a `StartupProvider` scan, ...) and just hands
/// this view an array plus a column list.
struct DataTable<Value: Identifiable>: View {
    let columns: [DataTableColumn<Value>]
    let rows: [Value]
    @Binding var sort: DataTableSort?
    /// Single-row selection, e.g. to drive a page's `DetailPane`. `nil`
    /// omits selection entirely (a plain read-only table).
    var selection: Binding<Value.ID?>?
    var rowHeight: CGFloat = 20
    /// Read in place of the row list when `rows` is empty, e.g.
    /// "No processes match “chrome”." — mirrors `CapacityBar`/
    /// `HistoryGraph`'s "say so, don't guess" treatment for the
    /// nothing-to-show case.
    var emptyMessage: String = "No items."

    init(
        columns: [DataTableColumn<Value>],
        rows: [Value],
        sort: Binding<DataTableSort?>,
        selection: Binding<Value.ID?>? = nil,
        rowHeight: CGFloat = 20,
        emptyMessage: String = "No items."
    ) {
        self.columns = columns
        self.rows = rows
        self._sort = sort
        self.selection = selection
        self.rowHeight = rowHeight
        self.emptyMessage = emptyMessage
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if rows.isEmpty {
                emptyState
            } else if let selection = selection {
                List(selection: selection) {
                    ForEach(sortedRows) { row in
                        rowView(row)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            } else {
                List {
                    ForEach(sortedRows) { row in
                        rowView(row)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text(emptyMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Sorting

    private var sortedRows: [Value] {
        guard
            let sort = sort,
            let column = columns.first(where: { $0.id == sort.columnID }),
            let comparator = column.comparator
        else {
            return rows
        }
        return rows.sorted { lhs, rhs in
            sort.ascending ? comparator(lhs, rhs) : comparator(rhs, lhs)
        }
    }

    private func toggleSort(_ column: DataTableColumn<Value>) {
        if let current = sort, current.columnID == column.id {
            sort = DataTableSort(columnID: column.id, ascending: !current.ascending)
        } else {
            sort = DataTableSort(columnID: column.id, ascending: true)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                headerCell(column)
            }
        }
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func headerCell(_ column: DataTableColumn<Value>) -> some View {
        sizedCell(headerContent(column), column: column)
            .padding(.horizontal, 6)
    }

    @ViewBuilder
    private func headerContent(_ column: DataTableColumn<Value>) -> some View {
        if column.comparator != nil {
            Button {
                toggleSort(column)
            } label: {
                headerLabel(column)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(sortAccessibilityLabel(column))
        } else {
            headerLabel(column)
        }
    }

    private func headerLabel(_ column: DataTableColumn<Value>) -> some View {
        HStack(spacing: 3) {
            Text(column.title)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if sort?.columnID == column.id {
                Image(systemName: sort?.ascending == true ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func sortAccessibilityLabel(_ column: DataTableColumn<Value>) -> String {
        if sort?.columnID == column.id {
            return "\(column.title), sorted \(sort?.ascending == true ? "ascending" : "descending")"
        }
        return "Sort by \(column.title)"
    }

    // MARK: - Rows

    private func rowView(_ row: Value) -> some View {
        HStack(spacing: 0) {
            ForEach(columns) { column in
                sizedCell(column.cell(row), column: column)
                    .padding(.horizontal, 6)
            }
        }
        .frame(height: rowHeight)
    }

    // MARK: - Shared column sizing

    /// Applies a column's fixed width (or, when `width` is `nil`, a
    /// flexible fill) and horizontal alignment to `content`. Shared by
    /// both `headerCell` and `rowView` so a column's header and its cells
    /// always line up.
    @ViewBuilder
    private func sizedCell<Content: View>(_ content: Content, column: DataTableColumn<Value>) -> some View {
        if let width = column.width {
            content.frame(width: width, alignment: Alignment(horizontal: column.alignment, vertical: .center))
        } else {
            content.frame(maxWidth: .infinity, alignment: Alignment(horizontal: column.alignment, vertical: .center))
        }
    }
}

// MARK: - Previews

private struct DataTablePreviewProcess: Identifiable {
    let id: Int
    let name: String
    let cpu: Double
    let memoryMB: Double
}

private let dataTablePreviewRows: [DataTablePreviewProcess] = [
    DataTablePreviewProcess(id: 1421, name: "Safari", cpu: 12.4, memoryMB: 420),
    DataTablePreviewProcess(id: 233, name: "Xcode", cpu: 48.2, memoryMB: 1820),
    DataTablePreviewProcess(id: 88, name: "Finder", cpu: 0.3, memoryMB: 90),
    DataTablePreviewProcess(id: 902, name: "Music", cpu: 2.1, memoryMB: 150),
    DataTablePreviewProcess(id: 55, name: "WindowServer", cpu: 6.8, memoryMB: 310),
]

private let dataTablePreviewColumns: [DataTableColumn<DataTablePreviewProcess>] = [
    DataTableColumn(id: "name", title: "Name", value: { $0.name }) { row in
        Text(row.name)
    },
    DataTableColumn(id: "pid", title: "PID", width: 60, alignment: .trailing, value: { $0.id }) { row in
        Text("\(row.id)").monospacedDigit()
    },
    DataTableColumn(id: "cpu", title: "CPU %", width: 70, alignment: .trailing, value: { $0.cpu }) { row in
        Text(String(format: "%.1f", row.cpu)).monospacedDigit()
    },
    DataTableColumn(id: "memory", title: "Memory", width: 90, alignment: .trailing, value: { $0.memoryMB }) { row in
        Text(String(format: "%.0f MB", row.memoryMB)).monospacedDigit()
    },
]

private struct DataTablePreview: View {
    @State private var sort: DataTableSort? = DataTableSort(columnID: "cpu", ascending: false)

    var body: some View {
        DataTable(
            columns: dataTablePreviewColumns,
            rows: dataTablePreviewRows,
            sort: $sort
        )
    }
}

private struct DataTableEmptyPreview: View {
    @State private var sort: DataTableSort? = nil

    var body: some View {
        DataTable(
            columns: dataTablePreviewColumns,
            rows: [],
            sort: $sort,
            emptyMessage: "No processes match “chrome”."
        )
    }
}

#Preview("Populated, sortable") {
    DataTablePreview()
        .frame(width: 480, height: 220)
}

#Preview("Empty") {
    DataTableEmptyPreview()
        .frame(width: 480, height: 220)
}
