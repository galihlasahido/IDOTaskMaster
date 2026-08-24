import Foundation
import SwiftUI

/// Startup apps page — PLAN.md §1.1 "Startup apps" / §4 M5's second task:
/// "LaunchAgent/Daemon plist scan, enabled state via `launchctl`,
/// enable/disable toggle (user domain only), detail pane." A `DataTable`
/// (Enabled toggle / Name / Command columns, matching §1.1's "Enabled
/// checkbox, Name, Command/plist path; filter box") over `Components/
/// DetailPane.swift` below the fold, the same table-over-detail layout
/// `ProcessesPage` uses.
///
/// Like `SystemInfoPage`, this is a load-once-then-Reload page rather than
/// a polled one: `StartupProvider`'s own doc comment explains why a
/// five-directory scan plus three `launchctl` shell-outs is too slow for
/// `Sampler`'s tick cadence.
struct StartupPage: View {
    @StateObject private var model = StartupViewModel()
    @State private var searchText = ""
    @State private var sort: DataTableSort? = DataTableSort(columnID: "name", ascending: true)
    @State private var selectedItemID: String?
    /// Matches `ProcessesPage.detailPaneHeight` — enough room for this
    /// domain's own detail sections without scrolling on the app's minimum
    /// window height.
    private static let detailPaneHeight: CGFloat = 220

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
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Startup Items")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                reloadButton
            }
        }
        .alert(
            "Couldn\u{2019}t Change Startup Item",
            isPresented: model.toggleErrorBinding,
            presenting: model.toggleErrorMessage
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
        .help("Reload from LaunchAgents/LaunchDaemons and launchctl")
    }

    // MARK: - Status line

    /// Mirrors `SystemInfoPage.statusLine`: an "as of / Unavailable"
    /// caption above the table rather than `PageInfoBar` (which reports
    /// `Sampler`-driven generation/health this page has neither of, per
    /// `StartupProvider`'s own doc comment on why it isn't ticked).
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
            return model.isLoading ? "Loading…" : "Not loaded"
        }
        let count = catalog.items.count
        let itemsText = count == 1 ? "1 item" : "\(count) items"
        if let reason = model.unavailableReason {
            return "\(itemsText) — reload failed: \(reason)"
        }
        return "\(itemsText) — as of \(Self.timeFormatter.string(from: catalog.generatedAt))"
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || model.catalog == nil
    }

    // MARK: - Table

    private var table: some View {
        DataTable(
            columns: Self.columns(toggle: { [weak model] item, enabled in
                model?.setEnabled(enabled, for: item)
            }),
            rows: filteredItems,
            sort: $sort,
            selection: $selectedItemID,
            emptyMessage: emptyMessage
        )
    }

    private var emptyMessage: String {
        searchText.isEmpty ? "No startup items found." : "No startup items match \u{201C}\(searchText)\u{201D}."
    }

    private var filteredItems: [StartupItem] {
        guard let catalog = model.catalog else { return [] }
        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return catalog.items }
        let needle = searchText.lowercased()
        return catalog.items.filter { item in
            item.displayName.lowercased().contains(needle)
                || (item.programPath?.lowercased().contains(needle) ?? false)
                || item.plistPath.lowercased().contains(needle)
        }
    }

    private static func columns(toggle: @escaping (StartupItem, Bool) -> Void) -> [DataTableColumn<StartupItem>] {
        [
            // `Bool` isn't `Comparable`, so this column uses the general
            // initializer with an explicit `comparator: nil` (unsortable —
            // the checkbox column is filtered/scanned visually, not sorted)
            // rather than `DataTableColumn`'s `value:`-based convenience
            // initializer every other column below uses.
            DataTableColumn(id: "enabled", title: "Enabled", width: 60, alignment: .center, comparator: nil) { item in
                Toggle("", isOn: Binding(
                    get: { item.isEnabled },
                    set: { newValue in toggle(item, newValue) }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!item.domain.isUserToggleable)
                .help(item.domain.isUserToggleable
                    ? (item.isEnabled ? "Disable at login" : "Enable at login")
                    : "Only items in your own ~/Library/LaunchAgents can be toggled")
            },
            DataTableColumn(id: "name", title: "Name", value: { $0.displayName }) { item in
                Label {
                    Text(item.displayName)
                        .lineLimit(1)
                } icon: {
                    Image(systemName: item.domain.systemImage)
                        .foregroundStyle(.secondary)
                }
            },
            DataTableColumn(id: "command", title: "Command / Plist Path", value: { $0.programPath ?? $0.plistPath }) { item in
                Text(item.programPath ?? item.plistPath)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            },
        ]
    }

    // MARK: - Detail pane

    @ViewBuilder
    private var detailPane: some View {
        if let item = selectedItem {
            DetailPane(
                title: item.displayName,
                subtitle: item.plistPath,
                systemImage: item.domain.systemImage,
                sections: detailSections(for: item)
            )
        } else {
            DetailPane(emptyMessage: "Select a startup item to view its details.")
        }
    }

    private var selectedItem: StartupItem? {
        guard let selectedItemID, let catalog = model.catalog else { return nil }
        return catalog.items.first(where: { $0.id == selectedItemID })
    }

    /// Identity / Publisher / Status / File sections — PLAN.md §1.1's
    /// "identity, publisher, status, running state, file size/dates,
    /// owner, permissions" folded into four titled groups rather than one
    /// per listed noun, matching how `ProcessesPage.detailSections(for:)`
    /// groups its own longer field list.
    private func detailSections(for item: StartupItem) -> [DetailPaneSection] {
        [
            DetailPaneSection(title: "Identity", fields: [
                DetailPaneField(label: "Label", value: item.launchctlLabel ?? "", isUnavailable: item.launchctlLabel == nil),
                DetailPaneField(label: "Location", value: item.domain.displayName),
                DetailPaneField(label: "Command", value: commandText(for: item), isUnavailable: item.programPath == nil),
                DetailPaneField(label: "Publisher", value: model.publisher(for: item) ?? "", isUnavailable: model.publisher(for: item) == nil),
            ]),
            DetailPaneSection(title: "Status", fields: [
                DetailPaneField(label: "Enabled", value: item.isEnabled ? "Yes" : "No"),
                DetailPaneField(label: "Running", value: runningText(for: item), isUnavailable: item.isRunning == nil),
                DetailPaneField(label: "Run at Load", value: item.runAtLoad.map { $0 ? "Yes" : "No" } ?? "", isUnavailable: item.runAtLoad == nil),
                DetailPaneField(label: "Keeps Alive", value: item.keepAlive.map { $0 ? "Yes" : "No" } ?? "No"),
            ]),
            DetailPaneSection(title: "File", fields: [
                DetailPaneField(label: "Size", value: item.fileSizeBytes.map(Fmt.bytes) ?? "", isUnavailable: item.fileSizeBytes == nil),
                DetailPaneField(label: "Modified", value: item.modifiedAt.map(Fmt.dateTime) ?? "", isUnavailable: item.modifiedAt == nil),
                DetailPaneField(label: "Created", value: item.createdAt.map(Fmt.dateTime) ?? "", isUnavailable: item.createdAt == nil),
            ]),
            DetailPaneSection(title: "Ownership", fields: [
                DetailPaneField(label: "Owner", value: item.ownerAccountName ?? "", isUnavailable: item.ownerAccountName == nil),
                DetailPaneField(label: "Permissions", value: item.posixPermissions.map(Fmt.permissions) ?? "", isUnavailable: item.posixPermissions == nil),
            ]),
        ]
    }

    private func commandText(for item: StartupItem) -> String {
        guard let programPath = item.programPath else { return "" }
        let extraArguments = item.programArguments.dropFirst()
        guard !extraArguments.isEmpty, item.programArguments.first == programPath else { return programPath }
        return ([programPath] + extraArguments).joined(separator: " ")
    }

    private func runningText(for item: StartupItem) -> String {
        guard let isRunning = item.isRunning else { return "" }
        guard isRunning else { return "Not Running" }
        return item.runningPID.map { "Running (PID \($0))" } ?? "Running"
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

    /// `rwxr-xr-x`-style permissions string from a POSIX mode, matching
    /// `ls -l`'s own rendering — the "permissions" field PLAN.md's detail
    /// pane inventory calls for.
    static func permissions(_ mode: UInt16) -> String {
        let bits: [(UInt16, String)] = [
            (0o400, "r"), (0o200, "w"), (0o100, "x"),
            (0o040, "r"), (0o020, "w"), (0o010, "x"),
            (0o004, "r"), (0o002, "w"), (0o001, "x"),
        ]
        let symbolic = bits.map { mask, symbol in (mode & mask) != 0 ? symbol : "-" }.joined()
        return "\(symbolic) (\(String(format: "%03o", UInt32(mode))))"
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

// MARK: - View model

/// Drives `StartupProvider` for `StartupPage` — load-once-then-Reload, the
/// same pattern `SystemInfoViewModel` establishes, plus the toggle plumbing
/// and a small per-item code-signing "Publisher" cache (PLAN.md §1.1's
/// detail-pane "publisher" field) computed lazily for only the selected row,
/// mirroring `ProcessesViewModel.architectureLabel(forExecutablePath:)`'s
/// own lazy, cached, selection-only lookup.
@MainActor
final class StartupViewModel: ObservableObject {
    @Published private(set) var catalog: StartupCatalog?
    @Published private(set) var isLoading = false
    /// Set when the most recent `sample()` threw. Left in place alongside a
    /// still-populated `catalog` after a failed Reload, matching
    /// `SystemInfoViewModel.unavailableReason`'s honest-degradation
    /// behavior.
    @Published private(set) var unavailableReason: String?
    /// Set when a toggle's `launchctl enable`/`disable` call itself failed
    /// (e.g. permission denied, `launchctl` missing) — shown as an alert
    /// rather than silently reverting the checkbox, so a failed write is
    /// never mistaken for a successful one.
    @Published var toggleErrorMessage: String?

    private let provider = StartupProvider()
    private var hasLoadedOnce = false
    /// `@Published` (not just a plain stored dictionary) so a background
    /// `codesign` lookup landing after `publisher(for:)` already returned
    /// `nil` for this render still triggers a re-render once it resolves —
    /// see `publisher(for:)`'s own doc comment.
    @Published private var publisherCache: [String: String?] = [:]
    private var publisherLookupsInFlight: Set<String> = []

    var toggleErrorBinding: Binding<Bool> {
        Binding(
            get: { self.toggleErrorMessage != nil },
            set: { isPresented in if !isPresented { self.toggleErrorMessage = nil } }
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

    /// Optimistically flips `item`'s checkbox in `catalog` so the UI
    /// responds immediately, then asks `StartupProvider` to make it real;
    /// on failure the optimistic flip is reverted and `toggleErrorMessage`
    /// is set — never left showing a state that isn't what `launchctl`
    /// actually has.
    func setEnabled(_ enabled: Bool, for item: StartupItem) {
        applyOptimisticEnabled(enabled, forItemID: item.id)
        Task {
            do {
                try await provider.setEnabled(enabled, for: item)
            } catch {
                applyOptimisticEnabled(!enabled, forItemID: item.id)
                toggleErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyOptimisticEnabled(_ enabled: Bool, forItemID id: String) {
        guard var catalog = self.catalog, let index = catalog.items.firstIndex(where: { $0.id == id }) else { return }
        var item = catalog.items[index]
        item = StartupItem(
            plistPath: item.plistPath,
            domain: item.domain,
            displayName: item.displayName,
            launchctlLabel: item.launchctlLabel,
            programPath: item.programPath,
            programArguments: item.programArguments,
            runAtLoad: item.runAtLoad,
            keepAlive: item.keepAlive,
            isEnabled: enabled,
            isRunning: item.isRunning,
            runningPID: item.runningPID,
            fileSizeBytes: item.fileSizeBytes,
            modifiedAt: item.modifiedAt,
            createdAt: item.createdAt,
            ownerAccountName: item.ownerAccountName,
            posixPermissions: item.posixPermissions
        )
        catalog.items[index] = item
        self.catalog = catalog
    }

    /// Best-effort code-signing "Authority" lookup for `item`'s executable
    /// — PLAN.md §1.1's detail-pane "publisher" field — cached by item id
    /// so re-rendering the detail pane doesn't re-spawn `codesign` on every
    /// SwiftUI redraw. Returns the current cached value immediately
    /// (`nil`/"Unavailable" the first time a row is selected) and, when
    /// nothing is cached yet, kicks off a background lookup via
    /// `loadPublisherIfNeeded(for:)`; `publisherCache` being `@Published`
    /// means the view re-renders on its own once that lookup resolves, the
    /// same "return what you have now, update asynchronously" shape
    /// `AsyncImage` uses — never a synchronous `Process` spawn on the
    /// caller's thread (SwiftUI's own main thread, since this is called
    /// from `StartupPage.detailSections(for:)`).
    func publisher(for item: StartupItem) -> String? {
        if let cached = publisherCache[item.id] { return cached }
        loadPublisherIfNeeded(for: item)
        return nil
    }

    private func loadPublisherIfNeeded(for item: StartupItem) {
        guard publisherCache[item.id] == nil, !publisherLookupsInFlight.contains(item.id) else { return }
        publisherLookupsInFlight.insert(item.id)
        let id = item.id
        let path = item.programPath
        Task {
            let value = await Self.codesignPublisher(forExecutablePath: path)
            publisherCache[id] = value
            publisherLookupsInFlight.remove(id)
        }
    }

    /// Hops to a background queue the same way
    /// `SystemInfoProvider.runSystemProfiler`/`StartupProvider.scan` do —
    /// `Process.run()`/`readDataToEndOfFile()`/`waitUntilExit()` are
    /// blocking calls with no async variant, and this runs from a `Task`
    /// launched on `@MainActor StartupViewModel`, so without this hop the
    /// blocking wait would tie up the main thread for however long
    /// `codesign` takes. `nonisolated` so these two static helpers (like
    /// their called-on-a-background-queue callee below) genuinely run off
    /// the main actor rather than implicitly inheriting `StartupViewModel`'s
    /// `@MainActor` isolation the way every other `static` member of this
    /// type does by default.
    private nonisolated static func codesignPublisher(forExecutablePath path: String?) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: codesignPublisherSynchronously(forExecutablePath: path))
            }
        }
    }

    /// Must only ever run on the background queue `codesignPublisher(
    /// forExecutablePath:)` dispatches onto. `nil` when the item has no
    /// resolvable program path, the executable doesn't exist, or it isn't
    /// signed — never a guess.
    private nonisolated static func codesignPublisherSynchronously(forExecutablePath path: String?) -> String? {
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }

        // `codesign -dv` writes one `Authority=<name>` line per certificate
        // in the signing chain to stderr, leaf certificate first — e.g.
        // `Authority=Apple Mac OS Application Signing` or
        // `Authority=Developer ID Application: Example Inc (TEAMID)`. The
        // first line is the most specific identity, which is what a
        // publisher field should show.
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Authority=") {
                let value = line.dropFirst("Authority=".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

#Preview {
    StartupPage()
        .frame(width: 820, height: 620)
}
