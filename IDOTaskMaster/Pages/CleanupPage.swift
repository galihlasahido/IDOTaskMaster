import SwiftUI

/// `CleanupPage`'s segmented tab picker — see that type's own doc comment
/// for why these two share one page instead of splitting into separate
/// sidebar entries.
private enum CleanupTab: String, CaseIterable, Identifiable {
    case wellKnown
    case projectFolders

    var id: String { rawValue }

    var title: String {
        switch self {
        case .wellKnown: return "Well-Known Locations"
        case .projectFolders: return "Project Folders"
        }
    }
}

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
///
/// Two tabs share one `CleanupViewModel` and one history log: **Well-Known
/// Locations** (this type's original scope — fixed, well-known system
/// paths this app already knows how to find) and **Project Folders**
/// (`ProjectArtifactsScanner` — dependency/build-output directories like
/// `node_modules` or a Python `.venv`, which live at unpredictable paths
/// inside whatever project folder the user points this at, so they need
/// their own user-chosen-root scan rather than a fixed location). Kept as
/// two tabs of the same page rather than a separate sidebar entry: both
/// are "find things safe to clear and let me choose," just with a
/// different *source* of candidates.
struct CleanupPage: View {
    @StateObject private var model = CleanupViewModel()
    @State private var searchText = ""
    @State private var showingCleanConfirmation = false
    @State private var showingCleanProjectArtifactsConfirmation = false
    @State private var showingEmptyTrashConfirmation = false
    @State private var showingHistory = false
    @State private var selectedTab: CleanupTab = .wellKnown

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            tabPicker
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Cache Items")
        .toolbar {
            switch selectedTab {
            case .wellKnown:
                ToolbarItem(placement: .primaryAction) { scanButton }
                ToolbarItem(placement: .primaryAction) { cleanButton }
                ToolbarItem(placement: .primaryAction) { emptyTrashButton }
            case .projectFolders:
                ToolbarItem(placement: .primaryAction) { chooseProjectFolderButton }
                ToolbarItem(placement: .primaryAction) { scanProjectFolderButton }
                ToolbarItem(placement: .primaryAction) { cleanProjectArtifactsButton }
            }
            ToolbarItem(placement: .primaryAction) { historyButton }
        }
        .sheet(isPresented: $showingCleanConfirmation) {
            CleanConfirmationSheet(items: model.selectedItems) { items in
                await model.clean(items)
            }
        }
        .sheet(isPresented: $showingCleanProjectArtifactsConfirmation) {
            CleanConfirmationSheet(items: model.selectedProjectArtifactItems) { items in
                await model.cleanProjectArtifacts(items)
            }
        }
        .sheet(isPresented: $showingEmptyTrashConfirmation) {
            EmptyTrashConfirmationSheet(model: model)
        }
        .sheet(isPresented: $showingHistory) {
            CleanupHistorySheet(model: model)
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

    // MARK: - Tabs

    private var tabPicker: some View {
        Picker("Clean Up Tab", selection: $selectedTab) {
            ForEach(CleanupTab.allCases) { tab in
                Text(tab.title).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .wellKnown:
            content
        case .projectFolders:
            projectFoldersContent
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

    private var historyButton: some View {
        Button {
            showingHistory = true
        } label: {
            Label("History\u{2026}", systemImage: "clock.arrow.circlepath")
        }
        .help("See past clean and empty-trash runs")
    }

    // MARK: - Toolbar (Project Folders tab)

    private var chooseProjectFolderButton: some View {
        Button {
            chooseProjectFolder()
        } label: {
            Label("Choose Folder\u{2026}", systemImage: "folder")
        }
        .disabled(model.isScanningProjectFolder || model.isCleaning)
        .help(model.projectFolderPath.map { "Currently \u{201C}\(($0 as NSString).lastPathComponent)\u{201D}" } ?? "Choose a project folder to scan for dependency/build-output directories")
    }

    private func chooseProjectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let current = model.projectFolderPath {
            panel.directoryURL = URL(fileURLWithPath: current, isDirectory: true)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseProjectFolder(url.path)
    }

    private var scanProjectFolderButton: some View {
        Button {
            if model.isScanningProjectFolder {
                model.cancelProjectScan()
            } else {
                model.scanProjectFolder()
            }
        } label: {
            if model.isScanningProjectFolder {
                Label("Cancel", systemImage: "xmark.circle")
            } else {
                Label("Scan", systemImage: "magnifyingglass")
            }
        }
        .disabled(model.projectFolderPath == nil || model.isCleaning)
        .help(model.isScanningProjectFolder ? "Cancel the current scan" : "Scan for node_modules, target, .venv, and similar directories")
    }

    private var cleanProjectArtifactsButton: some View {
        Button {
            showingCleanProjectArtifactsConfirmation = true
        } label: {
            Label("Clean Selected\u{2026}", systemImage: "trash")
        }
        .disabled(model.selectedProjectArtifactItems.isEmpty || model.isCleaning)
        .help(
            model.selectedProjectArtifactItems.isEmpty
                ? "Select items to clean"
                : "Move \(model.selectedProjectArtifactItems.count) selected item(s) to the Trash\u{2026}"
        )
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

    // MARK: - Content (Project Folders tab)

    @ViewBuilder
    private var projectFoldersContent: some View {
        if model.isScanningProjectFolder, let progress = model.projectScanProgress {
            projectScanProgressBanner(progress)
        }
        if let result = model.projectScanResult {
            if result.entries.isEmpty {
                projectFoldersEmptyState(message: "No dependency or build-output directories found under \u{201C}\((result.rootPath as NSString).lastPathComponent)\u{201D}.")
            } else {
                List {
                    Section {
                        ForEach(filteredProjectArtifacts) { entry in
                            projectArtifactRow(entry)
                        }
                    } header: {
                        projectArtifactsHeader(result)
                    }
                    if isFiltering, filteredProjectArtifacts.isEmpty {
                        Text("No items match \u{201C}\(searchText)\u{201D}.")
                            .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.inset)
            }
        } else if let reason = model.projectScanUnavailableReason {
            projectFoldersEmptyState(message: reason)
        } else if model.projectFolderPath == nil {
            projectFoldersEmptyState(message: "Choose a project folder, then Scan to find node_modules, target, .venv, and similar directories inside it.")
        } else {
            projectFoldersEmptyState(message: model.isScanningProjectFolder ? "Scanning\u{2026}" : "Click Scan to look inside \u{201C}\((model.projectFolderPath! as NSString).lastPathComponent)\u{201D}.")
        }
    }

    /// `model.projectScanResult`'s entries narrowed to the toolbar search
    /// text — same case-insensitive substring rule `filteredCategories`
    /// uses on the Well-Known Locations tab.
    private var filteredProjectArtifacts: [ProjectArtifactEntry] {
        guard let entries = model.projectScanResult?.entries else { return [] }
        guard isFiltering else { return entries }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return entries.filter { $0.path.lowercased().contains(needle) || $0.kind.lowercased().contains(needle) }
    }

    private func projectScanProgressBanner(_ progress: ProjectArtifactsScanProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Scanned \(Fmt.count(progress.foldersScanned)) folder(s) \u{2014} found \(Fmt.count(progress.artifactsFound)) (\(Fmt.bytes(progress.bytesFound)))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func projectFoldersEmptyState(message: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func projectArtifactsHeader(_ result: ProjectArtifactsScanResult) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: projectArtifactsSelectAllBinding) {
                EmptyView()
            }
            .toggleStyle(.checkbox)
            .labelsHidden()
            VStack(alignment: .leading, spacing: 1) {
                Text((result.rootPath as NSString).lastPathComponent)
                    .font(.callout.weight(.semibold))
                Text("\(Fmt.count(result.entries.count)) item(s) found")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Text(Fmt.bytes(result.totalBytes))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var projectArtifactsSelectAllBinding: Binding<Bool> {
        Binding(
            get: { model.areAllProjectArtifactsSelected },
            set: { model.setAllProjectArtifactsSelected($0) }
        )
    }

    private func projectArtifactRow(_ entry: ProjectArtifactEntry) -> some View {
        Toggle(isOn: model.projectArtifactSelectionBinding(entry)) {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(entry.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Fmt.bytes(entry.sizeBytes))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
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
    /// Shared by both `CleanupPage` tabs — a plain `[CleanupItem]` in,
    /// nothing back out — rather than an `@ObservedObject var model
    /// CleanupViewModel` + a hardcoded `model.clean(items)` call: the two
    /// tabs' post-clean behavior differs (Well-Known Locations rescans
    /// the fixed locations; Project Folders rescans whichever folder is
    /// still chosen) and each already knows which of its own two `clean`
    /// methods to hand in.
    let onConfirm: ([CleanupItem]) async -> Void
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
            await onConfirm(items)
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

// MARK: - History sheet

/// The toolbar's "History…" destination — every past `clean(_:)`/
/// `emptyTrash()` call, most-recent-first, read straight from
/// `model.log`. Purely informational (no destructive action lives here),
/// so unlike the two confirmation sheets above this is just a header,
/// list, and a Done button — plus "Clear History", which only erases
/// this record, never anything it once described.
private struct CleanupHistorySheet: View {
    @ObservedObject var model: CleanupViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if model.log.isEmpty {
                emptyState
            } else {
                list
                    .frame(maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 460, height: 420)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Clean Up History").font(.headline)
                Text(model.log.isEmpty ? "No runs yet." : "\(model.log.count) run(s) recorded.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text("Nothing cleaned yet.")
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(model.log) { entry in
            row(entry)
        }
        .listStyle(.inset)
    }

    private func row(_ entry: CleanupLogEntry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: entry.action == .emptyTrash ? "trash.slash" : "trash")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(title(for: entry)).font(.callout)
                Text(Self.dateFormatter.string(from: entry.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Fmt.bytes(entry.freedBytes)).font(.callout).monospacedDigit()
                if entry.failedCount > 0 {
                    Text("\(entry.failedCount) failed")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else {
                    Text("\(entry.itemCount) item\(entry.itemCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func title(for entry: CleanupLogEntry) -> String {
        switch entry.action {
        case .emptyTrash:
            return "Emptied Trash"
        case .clean:
            guard !entry.categories.isEmpty else { return "Cleaned Items" }
            return entry.categories.map(\.displayName).joined(separator: ", ")
        }
    }

    private var footer: some View {
        HStack {
            Button("Clear History") { model.clearLog() }
                .disabled(model.log.isEmpty)
            Spacer(minLength: 0)
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(14)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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
    /// Every past `clean(_:)`/`emptyTrash()` call, most-recent-first —
    /// `CleanupPage`'s History sheet. Persisted as JSON under one
    /// `UserDefaults` key, the same shape `BenchmarksViewModel.history`
    /// uses for the identical reason: run *data*, not a preference, and
    /// eagerly persisted on every change so it survives a crash or force
    /// quit, not just a clean exit.
    @Published private(set) var log: [CleanupLogEntry] = []

    // MARK: - Project Folders tab

    @Published private(set) var projectFolderPath: String?
    @Published private(set) var isScanningProjectFolder = false
    @Published private(set) var projectScanProgress: ProjectArtifactsScanProgress?
    @Published private(set) var projectScanResult: ProjectArtifactsScanResult?
    @Published private(set) var projectScanUnavailableReason: String?
    @Published private var selectedProjectArtifactIDs: Set<String> = []

    private let projectArtifactsScanner = ProjectArtifactsScanner()
    private var projectScanTask: Task<Void, Never>?

    private let provider = CleanupProvider()
    private let defaults: UserDefaults
    private static let logDefaultsKey = "cleanupLog"
    /// Same cap `BenchmarksViewModel.historyLimit` uses — Clean Up is run
    /// far less often than a benchmark, so this represents years of
    /// normal use, not a rounding-down of real history.
    private static let logLimit = 200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        log = Self.loadLog(from: defaults)
    }

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
        recordLog(action: .clean, categories: Array(Set(items.map(\.category))), outcome: outcome)
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
        recordLog(action: .emptyTrash, categories: [], outcome: outcome)
        isCleaning = false
        scan()
    }

    // MARK: - Project Folders tab

    /// Sets the folder future `scanProjectFolder()` calls scan, and clears
    /// out whatever the previous folder's scan found — an unselected,
    /// unscanned result from a different folder left on screen would be
    /// actively misleading, not just stale.
    func chooseProjectFolder(_ path: String) {
        projectFolderPath = path
        projectScanResult = nil
        projectScanUnavailableReason = nil
        selectedProjectArtifactIDs.removeAll()
    }

    func scanProjectFolder() {
        guard let projectFolderPath, !isScanningProjectFolder else { return }
        isScanningProjectFolder = true
        projectScanUnavailableReason = nil
        projectScanProgress = nil

        let stream = projectArtifactsScanner.scan(rootPath: projectFolderPath)
        projectScanTask = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                switch event {
                case .progress(let progress):
                    self.projectScanProgress = progress
                case .completed(let result):
                    self.projectScanResult = result
                    self.selectedProjectArtifactIDs.removeAll()
                case .failed(let reason):
                    self.projectScanUnavailableReason = reason
                case .cancelled:
                    break
                }
            }
            guard let self else { return }
            self.isScanningProjectFolder = false
            self.projectScanProgress = nil
        }
    }

    /// Takes effect the next time the scanner's walk checks its own
    /// cancellation token — see `ProjectArtifactsScanner.cancelActiveScan`'s
    /// own doc comment.
    func cancelProjectScan() {
        Task { await projectArtifactsScanner.cancelActiveScan() }
    }

    var selectedProjectArtifactItems: [CleanupItem] {
        guard let entries = projectScanResult?.entries else { return [] }
        return entries
            .filter { selectedProjectArtifactIDs.contains($0.id) }
            .map { entry in
                CleanupItem(
                    path: entry.path,
                    name: (entry.path as NSString).lastPathComponent,
                    category: .projectArtifacts,
                    sizeBytes: entry.sizeBytes
                )
            }
    }

    var areAllProjectArtifactsSelected: Bool {
        guard let entries = projectScanResult?.entries, !entries.isEmpty else { return false }
        return entries.allSatisfy { selectedProjectArtifactIDs.contains($0.id) }
    }

    func setAllProjectArtifactsSelected(_ selected: Bool) {
        guard let entries = projectScanResult?.entries else { return }
        for entry in entries {
            if selected {
                selectedProjectArtifactIDs.insert(entry.id)
            } else {
                selectedProjectArtifactIDs.remove(entry.id)
            }
        }
    }

    func projectArtifactSelectionBinding(_ entry: ProjectArtifactEntry) -> Binding<Bool> {
        Binding(
            get: { self.selectedProjectArtifactIDs.contains(entry.id) },
            set: { isOn in
                if isOn {
                    self.selectedProjectArtifactIDs.insert(entry.id)
                } else {
                    self.selectedProjectArtifactIDs.remove(entry.id)
                }
            }
        )
    }

    /// Moves `items` to the Trash, then rescans the same project folder —
    /// mirrors `clean(_:)`'s own "rescan so the list reflects the new,
    /// smaller reality" reasoning, just against `scanProjectFolder()`
    /// instead of the fixed-location `scan()`.
    func cleanProjectArtifacts(_ items: [CleanupItem]) async {
        isCleaning = true
        let outcome = await provider.clean(items)
        if !outcome.failed.isEmpty {
            let names = outcome.failed.map(\.name).joined(separator: ", ")
            lastFailureMessage = "\(outcome.failed.count) item(s) couldn\u{2019}t be moved to the Trash: \(names)"
        }
        recordLog(action: .clean, categories: [.projectArtifacts], outcome: outcome)
        isCleaning = false
        if projectFolderPath != nil {
            scanProjectFolder()
        }
    }

    func clearLog() {
        log = []
        persistLog()
    }

    /// Records a completed run at the front of `log`, then trims to
    /// `logLimit` — mirrors `BenchmarksViewModel.recordHistory(_:)`
    /// exactly. Logged even when `outcome.cleanedCount == 0` (every item
    /// failed): a run that accomplished nothing is still a fact worth
    /// keeping in the record, not silently dropped.
    private func recordLog(action: CleanupLogEntry.Action, categories: [CleanupCategory], outcome: CleanupOutcome) {
        let entry = CleanupLogEntry(
            id: UUID(),
            date: Date(),
            action: action,
            categories: categories,
            freedBytes: outcome.freedBytes,
            itemCount: outcome.cleanedCount,
            failedCount: outcome.failed.count
        )
        log.insert(entry, at: 0)
        if log.count > Self.logLimit {
            log.removeLast(log.count - Self.logLimit)
        }
        persistLog()
    }

    private func persistLog() {
        guard let data = try? JSONEncoder().encode(log) else { return }
        defaults.set(data, forKey: Self.logDefaultsKey)
    }

    private static func loadLog(from defaults: UserDefaults) -> [CleanupLogEntry] {
        guard let data = defaults.data(forKey: logDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([CleanupLogEntry].self, from: data)) ?? []
    }
}

#Preview {
    CleanupPage()
        .frame(width: 900, height: 640)
}
