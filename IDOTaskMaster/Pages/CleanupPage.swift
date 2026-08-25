import SwiftUI

/// Clean Up page — finds well-known regenerable caches/logs/build output
/// via `CleanupProvider` and lets the user choose what to clear. Like
/// `DiskSpacePage`, this does **not** scan on `onAppear`: scanning walks
/// real directories, and this app's "a monitor must not be the load" rule
/// applies here too — scanning is always a user-initiated action from the
/// toolbar's Scan button.
///
/// Every item defaults to **unselected**: nothing is ever cleaned without
/// the user explicitly checking it, and "Clean Selected" always opens a
/// confirmation sheet listing exactly what will move to the Trash
/// (reversible) before doing anything. Emptying the Trash is the one
/// irreversible action here, kept as its own separate button with its own,
/// more emphatic confirmation.
struct CleanupPage: View {
    @StateObject private var model = CleanupViewModel()
    @State private var searchText = ""
    @State private var showingCleanConfirmation = false
    @State private var showingEmptyTrashConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Cache Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { scanButton }
            ToolbarItem(placement: .primaryAction) { cleanButton }
            ToolbarItem(placement: .primaryAction) { emptyTrashButton }
        }
        .sheet(isPresented: $showingCleanConfirmation) {
            CleanConfirmationSheet(items: model.selectedItems, model: model)
        }
        .sheet(isPresented: $showingEmptyTrashConfirmation) {
            EmptyTrashConfirmationSheet(model: model)
        }
        .alert(
            "Some Items Couldn\u{2019}t Be Removed",
            isPresented: model.failureAlertBinding,
            presenting: model.lastFailureMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Toolbar

    private var scanButton: some View {
        Button {
            model.scan()
        } label: {
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 16, height: 16)
            } else {
                Label("Scan", systemImage: "magnifyingglass")
            }
        }
        .disabled(model.isScanning || model.isCleaning)
        .help("Find caches, logs, and build output that can be cleared")
    }

    private var cleanButton: some View {
        Button {
            showingCleanConfirmation = true
        } label: {
            Label("Clean Selected\u{2026}", systemImage: "trash")
        }
        .disabled(model.selectedItems.isEmpty || model.isCleaning)
        .help(cleanButtonHelp)
    }

    private var cleanButtonHelp: String {
        model.selectedItems.isEmpty
            ? "Select items to clean"
            : "Move \(model.selectedItems.count) selected item(s) to the Trash\u{2026}"
    }

    private var emptyTrashButton: some View {
        Button {
            showingEmptyTrashConfirmation = true
        } label: {
            Label("Empty Trash\u{2026}", systemImage: "trash.slash")
        }
        .disabled((model.result?.trashItemCount ?? 0) == 0 || model.isCleaning)
        .help("Permanently delete everything currently in the Trash")
    }

    // MARK: - Status line

    private var statusLine: some View {
        HStack(spacing: 8) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusIsProblem ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if model.isScanning || model.isCleaning {
                ProgressView()
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        if model.isScanning { return "Scanning\u{2026}" }
        if model.isCleaning { return "Cleaning\u{2026}" }
        if let reason = model.unavailableReason { return "Unavailable: \(reason)" }
        guard let result = model.result else {
            return "Click Scan to find caches, logs, and build output you can safely clear."
        }
        let total = result.categories.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let itemCount = result.categories.reduce(0) { $0 + $1.items.count }
        return "\(Fmt.bytes(total)) reclaimable across \(Fmt.count(itemCount)) item(s) \u{2014} as of \(Self.timeFormatter.string(from: result.generatedAt))"
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || (model.result == nil && !model.isScanning)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let result = model.result {
            List {
                ForEach(filteredCategories) { summary in
                    if !summary.items.isEmpty {
                        Section {
                            ForEach(summary.items) { item in
                                itemRow(item)
                            }
                        } header: {
                            categoryHeader(summary)
                        }
                    }
                }
                if isFiltering, filteredCategories.allSatisfy({ $0.items.isEmpty }) {
                    Text("No items match \u{201C}\(searchText)\u{201D}.")
                        .foregroundStyle(.secondary)
                }
                Section {
                    trashRow(bytes: result.trashBytes, count: result.trashItemCount)
                } header: {
                    Label(CleanupCategory.trash.displayName, systemImage: CleanupCategory.trash.systemImage)
                }
            }
            .listStyle(.inset)
        } else {
            emptyState
        }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `result.categories`, each narrowed to the items whose name or path
    /// contains the toolbar search text — matching `DiskSpacePage
    /// .filteredByPath`'s own case-insensitive substring rule. A category
    /// with no remaining matches renders nothing (see `content`'s `if
    /// !summary.items.isEmpty` check) rather than an empty header, and
    /// `categoryHeader`'s "select all" checkbox/total-size operate on this
    /// filtered subset, so what's shown is exactly what selecting-all or
    /// the header's size reflects.
    private var filteredCategories: [CleanupCategorySummary] {
        guard let result = model.result else { return [] }
        guard isFiltering else { return result.categories }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return result.categories.map { summary in
            CleanupCategorySummary(
                category: summary.category,
                items: summary.items.filter {
                    $0.name.lowercased().contains(needle) || $0.path.lowercased().contains(needle)
                }
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(model.isScanning ? "Scanning\u{2026}" : "No scan yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func categoryHeader(_ summary: CleanupCategorySummary) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: categorySelectionBinding(summary)) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            Image(systemName: summary.category.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.category.displayName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(summary.category.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(summary.totalBytes))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func itemRow(_ item: CleanupItem) -> some View {
        Toggle(isOn: model.itemSelectionBinding(item)) {
            HStack {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Fmt.bytes(item.sizeBytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }

    private func trashRow(bytes: UInt64, count: Int) -> some View {
        HStack {
            Text(count == 0 ? "Trash is empty." : "\(Fmt.count(count)) item(s)")
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(Fmt.bytes(bytes))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private func categorySelectionBinding(_ summary: CleanupCategorySummary) -> Binding<Bool> {
        Binding(
            get: { model.isCategoryFullySelected(summary) },
            set: { model.setCategorySelected(summary, selected: $0) }
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Clean confirmation sheet

/// The toolbar's "Clean Selected\u{2026}" destination — lists exactly what
/// will move to the Trash, matching `InstalledAppsPage`'s own
/// `UninstallSheet` shape (header, list, Cancel/destructive-action footer)
/// so this reads as the same kind of confirmation the rest of the app
/// already uses for a destructive action.
private struct CleanConfirmationSheet: View {
    let items: [CleanupItem]
    @ObservedObject var model: CleanupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isCleaning = false

    private var totalBytes: UInt64 { items.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 440, height: 380)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "trash")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Clean \(items.count) Item\(items.count == 1 ? "" : "s")?").font(.headline)
                    Text("\(Fmt.bytes(totalBytes)) will be freed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text("These items will be moved to the Trash. You can restore them from Trash until you empty it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var list: some View {
        List(items) { item in
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout)
                Text(item.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive) {
                confirmClean()
            } label: {
                if isCleaning {
                    ProgressView().controlSize(.small).frame(width: 40)
                } else {
                    Text("Move to Trash")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isCleaning)
        }
        .padding(14)
    }

    private func confirmClean() {
        isCleaning = true
        Task {
            await model.clean(items)
            isCleaning = false
            dismiss()
        }
    }
}

// MARK: - Empty Trash confirmation sheet

/// The toolbar's "Empty Trash\u{2026}" destination — deliberately smaller
/// and more emphatic than `CleanConfirmationSheet` (an orange warning
/// glyph, no itemized list) since this is the one irreversible action on
/// this page.
private struct EmptyTrashConfirmationSheet: View {
    @ObservedObject var model: CleanupViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var isEmptying = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 24))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Empty Trash?").font(.headline)
                    Text("This permanently deletes everything in the Trash \u{2014} it can\u{2019}t be undone.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer(minLength: 0)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(role: .destructive) {
                    confirmEmpty()
                } label: {
                    if isEmptying {
                        ProgressView().controlSize(.small).frame(width: 40)
                    } else {
                        Text("Empty Trash")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isEmptying)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func confirmEmpty() {
        isEmptying = true
        Task {
            await model.emptyTrash()
            isEmptying = false
            dismiss()
        }
    }
}

// MARK: - Formatting

private enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let clamped = min(value, UInt64(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped))
    }

    static func count(_ value: Int) -> String {
        countFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

// MARK: - View model

/// Drives `CleanupProvider` for `CleanupPage`: owns the last scan result
/// and which items are currently selected.
@MainActor
final class CleanupViewModel: ObservableObject {
    @Published private(set) var isScanning = false
    @Published private(set) var isCleaning = false
    @Published private(set) var result: CleanupScanResult?
    @Published private(set) var unavailableReason: String?
    @Published private var selectedItemIDs: Set<String> = []
    @Published private(set) var lastFailureMessage: String?

    private let provider = CleanupProvider()

    var selectedItems: [CleanupItem] {
        guard let result else { return [] }
        let all = result.categories.flatMap(\.items)
        return all.filter { selectedItemIDs.contains($0.id) }
    }

    var failureAlertBinding: Binding<Bool> {
        Binding(
            get: { self.lastFailureMessage != nil },
            set: { isPresented in if !isPresented { self.lastFailureMessage = nil } }
        )
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        unavailableReason = nil
        Task {
            let scanResult = await provider.scan()
            result = scanResult
            selectedItemIDs.removeAll()
            isScanning = false
        }
    }

    func isCategoryFullySelected(_ summary: CleanupCategorySummary) -> Bool {
        !summary.items.isEmpty && summary.items.allSatisfy { selectedItemIDs.contains($0.id) }
    }

    func setCategorySelected(_ summary: CleanupCategorySummary, selected: Bool) {
        for item in summary.items {
            if selected {
                selectedItemIDs.insert(item.id)
            } else {
                selectedItemIDs.remove(item.id)
            }
        }
    }

    func itemSelectionBinding(_ item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { self.selectedItemIDs.contains(item.id) },
            set: { isOn in
                if isOn {
                    self.selectedItemIDs.insert(item.id)
                } else {
                    self.selectedItemIDs.remove(item.id)
                }
            }
        )
    }

    /// Moves `items` to the Trash, then rescans so the list (and every
    /// remaining selection) reflects the new, smaller reality rather than
    /// still showing items that no longer exist.
    func clean(_ items: [CleanupItem]) async {
        isCleaning = true
        let outcome = await provider.clean(items)
        if !outcome.failed.isEmpty {
            let names = outcome.failed.map(\.name).joined(separator: ", ")
            lastFailureMessage = "\(outcome.failed.count) item(s) couldn\u{2019}t be moved to the Trash: \(names)"
        }
        isCleaning = false
        scan()
    }

    func emptyTrash() async {
        isCleaning = true
        let outcome = await provider.emptyTrash()
        if !outcome.failed.isEmpty {
            let names = outcome.failed.map(\.name).joined(separator: ", ")
            lastFailureMessage = "\(outcome.failed.count) item(s) in the Trash couldn\u{2019}t be removed: \(names)"
        }
        isCleaning = false
        scan()
    }
}

#Preview {
    CleanupPage()
        .frame(width: 900, height: 640)
}
