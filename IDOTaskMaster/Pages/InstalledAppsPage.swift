import AppKit
import SwiftUI

/// Installed Apps page — PLAN.md §1.1 "Installed Apps" (a former [name removed] Pro
/// page, unlocked here per §2) / §4 M6's third task: "/Applications scan,
/// sizes, bundle metadata, related-files finder, Uninstall (move to Trash +
/// related files)." A `DataTable` (icon / Name / Version / Size / Category
/// columns) over a `DetailPane` below the fold, the same table-over-detail
/// layout `StartupPage`/`ProcessesPage` use.
///
/// Like `StartupPage`, this is a load-once-then-Reload page rather than a
/// polled one: `InstalledAppsProvider`'s own doc comment explains why
/// sizing every bundle with `du -sk` is too slow for `Sampler`'s tick
/// cadence.
///
/// The Uninstall flow is two steps: the toolbar's trash-can button opens
/// `UninstallSheet` for the current selection, which — PLAN.md's "Related
/// Files finder" — lazily looks up that app's leftover `~/Library/...`
/// files via `InstalledAppsViewModel.relatedFiles(for:)` and lets the user
/// choose which of them to also move to the Trash alongside the app bundle
/// itself.
struct InstalledAppsPage: View {
    @StateObject private var model = InstalledAppsViewModel()
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "name", ascending: true)
    @State private var selectedAppID: String?
    @State private var pendingUninstallApp: InstalledApp?
    /// Matches `StartupPage.detailPaneHeight` in spirit — enough room for
    /// this domain's own detail sections without scrolling on the app's
    /// minimum window height.
    private static let detailPaneHeight: CGFloat = 240

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
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Installed Apps")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                uninstallButton
            }
            ToolbarItem(placement: .primaryAction) {
                reloadButton
            }
            ToolbarItem(placement: .primaryAction) {
                ExportMenu(columns: Self.columns, rows: filteredApps, suggestedName: "Installed Apps")
            }
        }
        .sheet(item: $pendingUninstallApp) { app in
            UninstallSheet(app: app, model: model)
        }
        .alert(
            "Couldn\u{2019}t Uninstall",
            isPresented: model.uninstallErrorBinding,
            presenting: model.uninstallErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
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
        .help("Rescan /Applications")
    }

    private var uninstallButton: some View {
        Button {
            if let selectedApp {
                pendingUninstallApp = selectedApp
            }
        } label: {
            Label("Uninstall\u{2026}", systemImage: "trash")
        }
        .disabled(selectedApp == nil || selectedApp?.isAppleSystemApp == true)
        .help(uninstallButtonHelp)
    }

    private var uninstallButtonHelp: String {
        guard let selectedApp else { return "Select an app to uninstall" }
        if selectedApp.isAppleSystemApp { return "This app is part of macOS and can\u{2019}t be uninstalled" }
        return "Move \u{201C}\(selectedApp.name)\u{201D} to the Trash\u{2026}"
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
            return model.isLoading ? "Scanning /Applications\u{2026}" : "Not loaded"
        }
        let count = catalog.apps.count
        let itemsText = count == 1 ? "1 app" : "\(count) apps"
        if let reason = model.unavailableReason {
            return "\(itemsText) \u{2014} reload failed: \(reason)"
        }
        return "\(itemsText) \u{2014} as of \(Self.timeFormatter.string(from: catalog.generatedAt))"
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || model.catalog == nil
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns,
            rows: filteredApps,
            sort: $sort,
            selection: $selectedAppID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        guard model.catalog != nil else { return "No apps available." }
        return searchText.isEmpty ? "No apps found in /Applications." : "No apps match \u{201C}\(searchText)\u{201D}."
    }

    private var filteredApps: [InstalledApp] {
        guard let catalog = model.catalog else { return [] }
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return catalog.apps }
        return catalog.apps.filter { app in
            app.name.lowercased().contains(needle)
                || (app.bundleIdentifier?.lowercased().contains(needle) ?? false)
                || (app.publisher?.lowercased().contains(needle) ?? false)
        }
    }

    private static let columns: [DataTableColumn<InstalledApp>] = [
        DataTableColumn(id: "icon", title: "", width: 28, alignment: .center, comparator: nil) { app in
            Self.appIcon(app, pointSize: 16)
        },
        DataTableColumn(id: "name", title: "Name", value: { $0.name }) { app in
            Text(app.name).lineLimit(1)
        },
        DataTableColumn(id: "version", title: "Version", width: 80, value: { $0.versionString ?? "" }) { app in
            Text(app.versionString ?? "Unavailable")
                .foregroundStyle(app.versionString == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
        },
        DataTableColumn(id: "size", title: "Size", width: 90, alignment: .trailing, value: { $0.sizeBytes ?? 0 }) { app in
            Text(app.sizeBytes.map(Fmt.bytes) ?? "Unavailable")
                .monospacedDigit()
                .foregroundStyle(app.sizeBytes == nil ? Color(nsColor: .tertiaryLabelColor) : .primary)
        },
        DataTableColumn(id: "category", title: "Category", width: 150, value: { $0.categoryLabel ?? "" }) { app in
            Text(app.categoryLabel ?? "\u{2014}")
                .foregroundStyle(.secondary)
                .lineLimit(1)
        },
    ]

    @ViewBuilder
    private static func appIcon(_ app: InstalledApp, pointSize: CGFloat) -> some View {
        if let data = app.iconPNGData, let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .frame(width: pointSize, height: pointSize)
        } else {
            Image(systemName: "app.dashed")
                .foregroundStyle(.secondary)
                .frame(width: pointSize, height: pointSize)
        }
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let app = selectedApp {
            DetailPane(
                title: app.name,
                subtitle: app.bundlePath,
                systemImage: "app.fill",
                sections: detailSections(for: app)
            )
        } else {
            DetailPane(emptyMessage: "Select an app to view its details.")
        }
    }

    private var selectedApp: InstalledApp? {
        guard let selectedAppID, let catalog = model.catalog else { return nil }
        return catalog.apps.first(where: { $0.id == selectedAppID })
    }

    /// Identity / Location / File / Related Files sections — PLAN.md
    /// §1.1's detail-pane inventory ("editor, opened/modified dates")
    /// folded into groups matching this app's own bundle metadata, plus
    /// PLAN.md's "Related Files finder" surfaced read-only here (the
    /// interactive, checkbox-driven version lives in `UninstallSheet`).
    private func detailSections(for app: InstalledApp) -> [DetailPaneSection] {
        [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Bundle ID", value: app.bundleIdentifier ?? "", isUnavailable: app.bundleIdentifier == nil, isMonospaced: true),
                DetailPaneField(label: "Version", value: app.versionString ?? "", isUnavailable: app.versionString == nil),
                DetailPaneField(label: "Build", value: app.buildString ?? "", isUnavailable: app.buildString == nil),
                DetailPaneField(label: "Category", value: app.categoryLabel ?? "", isUnavailable: app.categoryLabel == nil),
                DetailPaneField(label: "Minimum macOS", value: app.minimumSystemVersion ?? "", isUnavailable: app.minimumSystemVersion == nil),
                DetailPaneField(label: "Editor", value: app.publisher ?? "", isUnavailable: app.publisher == nil),
            ]),
            DetailPaneSection(title: "Location", fields: [
                DetailPaneField(label: "Bundle", value: app.bundlePath, isMonospaced: true),
                DetailPaneField(label: "Executable", value: app.executablePath ?? "", isUnavailable: app.executablePath == nil, isMonospaced: true),
            ]),
            DetailPaneSection(title: "File", fields: [
                DetailPaneField(label: "Size", value: app.sizeBytes.map(Fmt.bytes) ?? "", isUnavailable: app.sizeBytes == nil, isMonospaced: true),
                DetailPaneField(label: "Modified", value: app.modifiedAt.map(Fmt.dateTime) ?? "", isUnavailable: app.modifiedAt == nil),
                DetailPaneField(label: "Created", value: app.createdAt.map(Fmt.dateTime) ?? "", isUnavailable: app.createdAt == nil),
            ]),
            DetailPaneSection(title: "Related Files", fields: relatedFilesFields(for: app)),
        ]
    }

    private func relatedFilesFields(for app: InstalledApp) -> [DetailPaneField] {
        guard let files = model.relatedFiles(for: app) else {
            return [DetailPaneField(label: "Searching\u{2026}", value: "", isUnavailable: true)]
        }
        guard !files.isEmpty else {
            return [DetailPaneField(label: "Found", value: "None")]
        }
        return files.map { file in
            let sizeText = file.sizeBytes.map(Fmt.bytes) ?? "Unavailable"
            return DetailPaneField(id: file.id, label: file.kind.displayName, value: "\(file.path) (\(sizeText))", isMonospaced: false)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Formatting

private enum Fmt {
    static func bytes(_ value: UInt64) -> String {
        let clamped = min(value, UInt64(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped))
    }

    static func dateTime(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Uninstall sheet

/// The trash-can toolbar button's destination — PLAN.md's "Related Files
/// finder" plus the actual "Uninstall (move to Trash + related files)"
/// action in one place: a warning, the app's own headline info, and a
/// checklist of everything `InstalledAppsViewModel.relatedFiles(for:)`
/// found for it (defaulted to all-checked, matching the "clean uninstall"
/// expectation a page that specifically advertises a related-files finder
/// implies — a user who didn't want the extras unchecks them here rather
/// than this sheet defaulting to leaving them behind).
private struct UninstallSheet: View {
    let app: InstalledApp
    @ObservedObject var model: InstalledAppsViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedFileIDs: Set<String> = []
    @State private var hasInitializedSelection = false
    @State private var isUninstalling = false

    private var relatedFiles: [RelatedFile] { model.relatedFiles(for: app) ?? [] }
    private var isRelatedFilesLoaded: Bool { model.relatedFiles(for: app) != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            relatedFilesList
                .frame(maxHeight: .infinity)
            Divider()
            footer
        }
        .frame(width: 440, height: 380)
        .onChange(of: isRelatedFilesLoaded) { loaded in
            guard loaded, !hasInitializedSelection else { return }
            selectedFileIDs = Set(relatedFiles.map(\.id))
            hasInitializedSelection = true
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let data = app.iconPNGData, let nsImage = NSImage(data: data) {
                    Image(nsImage: nsImage).resizable().frame(width: 32, height: 32)
                } else {
                    Image(systemName: "app.dashed").font(.system(size: 28)).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall \u{201C}\(app.name)\u{201D}?").font(.headline)
                    Text(app.bundlePath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Text("The app will be moved to the Trash. Choose which related files to remove along with it.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
    }

    @ViewBuilder
    private var relatedFilesList: some View {
        if !isRelatedFilesLoaded {
            centered { ProgressView("Searching for related files\u{2026}") }
        } else if relatedFiles.isEmpty {
            centered { Text("No related files found.").foregroundStyle(.secondary) }
        } else {
            List(relatedFiles) { file in
                Toggle(isOn: toggleBinding(for: file)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(file.kind.displayName).font(.callout)
                        Text(file.path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .toggleStyle(.checkbox)
            }
            .listStyle(.inset)
        }
    }

    private func centered<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack {
            Spacer(minLength: 0)
            content()
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func toggleBinding(for file: RelatedFile) -> Binding<Bool> {
        Binding(
            get: { selectedFileIDs.contains(file.id) },
            set: { isOn in
                if isOn { selectedFileIDs.insert(file.id) } else { selectedFileIDs.remove(file.id) }
            }
        )
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(role: .destructive) {
                confirmUninstall()
            } label: {
                if isUninstalling {
                    ProgressView().controlSize(.small).frame(width: 40)
                } else {
                    Text("Uninstall")
                }
            }
            .keyboardShortcut(.defaultAction)
            .disabled(isUninstalling)
        }
        .padding(14)
    }

    private func confirmUninstall() {
        isUninstalling = true
        let filesToTrash = relatedFiles.filter { selectedFileIDs.contains($0.id) }
        Task {
            await model.uninstall(app, relatedFiles: filesToTrash)
            isUninstalling = false
            dismiss()
        }
    }
}

// MARK: - View model

/// Drives `InstalledAppsProvider` for `InstalledAppsPage` — load-once-then-
/// Reload, the same pattern `StartupViewModel` establishes, plus a
/// per-app related-files cache computed lazily only for the selected/
/// uninstall-pending app, mirroring `StartupViewModel.publisher(for:)`'s
/// own lazy, cached, on-demand lookup.
@MainActor
final class InstalledAppsViewModel: ObservableObject {
    @Published private(set) var catalog: InstalledAppsCatalog?
    @Published private(set) var isLoading = false
    /// Set when the most recent `sample()` threw. Left in place alongside a
    /// still-populated `catalog` after a failed Reload, matching
    /// `StartupViewModel.unavailableReason`'s honest-degradation behavior.
    @Published private(set) var unavailableReason: String?
    /// Set when `uninstall(_:relatedFiles:)` itself failed, or succeeded
    /// but left one or more related files behind — shown as an alert,
    /// matching `StartupViewModel.toggleErrorMessage`'s "never silently
    /// swallow a failed write" rule.
    @Published var uninstallErrorMessage: String?

    private let provider = InstalledAppsProvider()
    private var hasLoadedOnce = false
    /// `nil` for "not looked up yet", an empty array for "looked up, found
    /// nothing" — see `relatedFiles(for:)`'s own doc comment.
    @Published private var relatedFilesCache: [String: [RelatedFile]] = [:]
    private var relatedFilesLookupsInFlight: Set<String> = []

    var uninstallErrorBinding: Binding<Bool> {
        Binding(
            get: { self.uninstallErrorMessage != nil },
            set: { isPresented in if !isPresented { self.uninstallErrorMessage = nil } }
        )
    }

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

    /// Returns the cached related-files list for `app`, kicking off a
    /// background lookup the first time it's asked about — the same
    /// "return what you have now, update asynchronously once it resolves"
    /// shape `StartupViewModel.publisher(for:)` uses, safe to call
    /// repeatedly from a view's `body` (SwiftUI re-renders on its own once
    /// `relatedFilesCache` — `@Published` — is filled in).
    func relatedFiles(for app: InstalledApp) -> [RelatedFile]? {
        if let cached = relatedFilesCache[app.id] { return cached }
        loadRelatedFilesIfNeeded(for: app)
        return nil
    }

    private func loadRelatedFilesIfNeeded(for app: InstalledApp) {
        guard relatedFilesCache[app.id] == nil, !relatedFilesLookupsInFlight.contains(app.id) else { return }
        relatedFilesLookupsInFlight.insert(app.id)
        let provider = provider
        let id = app.id
        Task {
            let files = await provider.relatedFiles(for: app)
            relatedFilesCache[id] = files
            relatedFilesLookupsInFlight.remove(id)
        }
    }

    /// Uninstalls `app`, trashing exactly `relatedFiles` alongside it (the
    /// subset `UninstallSheet`'s checkboxes actually selected — not every
    /// candidate `relatedFiles(for:)` found). Removes `app` from `catalog`
    /// on success so the table reflects the trash immediately, without a
    /// full Reload.
    func uninstall(_ app: InstalledApp, relatedFiles: [RelatedFile]) async {
        do {
            let failures = try await provider.uninstall(app, alsoTrashing: relatedFiles)
            if let catalog {
                self.catalog = InstalledAppsCatalog(apps: catalog.apps.filter { $0.id != app.id }, generatedAt: catalog.generatedAt)
            }
            relatedFilesCache[app.id] = nil
            if !failures.isEmpty {
                let names = failures.map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
                uninstallErrorMessage = "\u{201C}\(app.name)\u{201D} was moved to the Trash, but these related files couldn\u{2019}t be: \(names)"
            }
        } catch {
            uninstallErrorMessage = error.localizedDescription
        }
    }
}

#Preview {
    InstalledAppsPage()
        .frame(width: 820, height: 640)
}
