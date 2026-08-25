import AppKit
import SwiftUI

/// Disk Space page — PLAN.md §1.1 "Disk Space" (unlocked here with no
/// paywall, per §2) / §4 M6's fourth task: "async scanner with
/// progress, file-type classification, bubble view + type legend, largest
/// folders/files, scan history."
///
/// Layout follows that task list top to bottom: a status line (plus a live
/// progress banner while `DiskSpaceScanner` is running), an "Overview" band
/// pairing the bubble chart with the type legend, then a segmented control
/// switching a `DataTable` between Largest Folders / Largest Files / Scan
/// History — the same "one table region, a control above it decides what's
/// in it" shape `ConnectionsPage`'s filter row uses, chosen here over three
/// permanently-stacked tables so every list gets the window's full height
/// rather than a cramped third each.
///
/// Unlike every load-once page (`StartupPage`, `InstalledAppsPage`, ...),
/// this page does **not** scan on `onAppear`: walking an arbitrary folder
/// can take a long time and generate real disk I/O, and PLAN.md §3's own
/// "a monitor must not be the load" rationale argues against kicking that
/// off just because a user glanced at this tab. Scanning is always a
/// user-initiated action from the toolbar's Scan button, against whatever
/// folder Choose Folder\u{2026} (default: the user's home folder) picked.
struct DiskSpacePage: View {
    @StateObject private var model = DiskSpaceViewModel()
    @State private var searchText = ""
    @State private var tab: DiskSpaceViewTab = .largestFolders
    @State private var folderSort: DataTableSort? = DataTableSort(columnID: "size", ascending: false)
    @State private var fileSort: DataTableSort? = DataTableSort(columnID: "size", ascending: false)
    @State private var historySort: DataTableSort? = DataTableSort(columnID: "scannedAt", ascending: false)
    @State private var selectedFolderID: String?
    @State private var selectedFileID: String?
    @State private var selectedHistoryID: UUID?

    private static let overviewHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            if model.isScanning, let progress = model.progress {
                progressBanner(progress)
                Divider()
            }
            overviewSection
                .frame(height: Self.overviewHeight)
            Divider()
            tabPicker
            Divider()
            tabContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter by Path")
        .toolbar {
            ToolbarItem(placement: .primaryAction) { chooseFolderButton }
            ToolbarItem(placement: .primaryAction) { scanButton }
            ToolbarItem(placement: .primaryAction) { revealButton }
            ToolbarItem(placement: .primaryAction) { exportMenu }
        }
        .onDisappear { model.cancelScan() }
    }

    // MARK: - Toolbar

    private var chooseFolderButton: some View {
        Button {
            model.chooseFolder()
        } label: {
            Label("Choose Folder\u{2026}", systemImage: "folder")
        }
        .disabled(model.isScanning)
        .help("Choose which folder to scan")
    }

    private var scanButton: some View {
        Button {
            if model.isScanning {
                model.cancelScan()
            } else {
                model.startScan()
            }
        } label: {
            if model.isScanning {
                Label("Cancel", systemImage: "xmark.circle")
            } else {
                Label("Scan", systemImage: "magnifyingglass")
            }
        }
        .help(model.isScanning ? "Cancel the current scan" : "Scan \u{201C}\((model.rootPath as NSString).lastPathComponent)\u{201D}")
    }

    private var revealButton: some View {
        Button {
            guard let path = selectedPathForReveal else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: {
            Label("Reveal in Finder", systemImage: "arrow.up.forward.app")
        }
        .disabled(selectedPathForReveal == nil)
        .help("Reveal the selected item in Finder")
    }

    private var selectedPathForReveal: String? {
        switch tab {
        case .largestFolders: return selectedFolderID
        case .largestFiles: return selectedFileID
        case .history: return nil
        }
    }

    /// Exports whichever of the three tab tables (PLAN.md §4 M10's "any
    /// table \u{2192} CSV/JSON") is currently showing — the same rows/columns
    /// `tabContent` itself renders for that tab, filtered by the toolbar's
    /// search field the same way.
    @ViewBuilder
    private var exportMenu: some View {
        switch tab {
        case .largestFolders:
            ExportMenu(
                columns: Self.folderColumns,
                rows: filteredByPath(model.result?.largestFolders ?? [], path: \.path),
                suggestedName: "Largest Folders"
            )
        case .largestFiles:
            ExportMenu(
                columns: Self.fileColumns,
                rows: filteredByPath(model.result?.largestFiles ?? [], path: \.path),
                suggestedName: "Largest Files"
            )
        case .history:
            ExportMenu(columns: historyColumns, rows: model.history, suggestedName: "Scan History")
        }
    }

    // MARK: - Status line / progress banner

    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(statusIsProblem ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        if model.isScanning {
            return "Scanning \u{201C}\(model.rootPath)\u{201D}\u{2026}"
        }
        if let reason = model.unavailableReason {
            return "Unavailable: \(reason)"
        }
        guard let result = model.result else {
            return "Choose a folder, then click Scan."
        }
        var text = "\(Fmt.bytes(result.totalBytes)) \u{2014} \(Fmt.count(result.totalItemCount)) items in \u{201C}\(result.rootPath)\u{201D} \u{2014} as of \(Self.timeFormatter.string(from: result.generatedAt))"
        if result.unreadableItemCount > 0 {
            text += " \u{2014} \(Fmt.count(result.unreadableItemCount)) unreadable item(s)"
        }
        return text
    }

    private var statusIsProblem: Bool {
        model.unavailableReason != nil || (model.result == nil && !model.isScanning)
    }

    private func progressBanner(_ progress: DiskSpaceScanProgress) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("\(Fmt.count(progress.itemsScanned)) items \u{2014} \(Fmt.bytes(progress.bytesScanned)) so far")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            if let currentPath = progress.currentPath {
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(Color(nsColor: .tertiaryLabelColor))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Overview: bubble chart + type legend

    @ViewBuilder
    private var overviewSection: some View {
        if let result = model.result {
            HStack(spacing: 16) {
                DiskSpaceBubbleChart(totals: result.categoryTotals, colorForCategory: Self.color(for:))
                    .frame(width: Self.overviewHeight - 24, height: Self.overviewHeight - 24)
                Divider()
                legend(for: result.categoryTotals, totalBytes: result.totalBytes)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        } else {
            overviewEmptyState
        }
    }

    private var overviewEmptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "internaldrive")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text(model.isScanning ? "Scanning\u{2026}" : "No scan yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func legend(for totals: [DiskSpaceCategoryTotal], totalBytes: UInt64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(totals) { total in
                legendRow(total, totalBytes: totalBytes)
            }
        }
    }

    private func legendRow(_ total: DiskSpaceCategoryTotal, totalBytes: UInt64) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Self.color(for: total.category))
                .frame(width: 9, height: 9)
            Image(systemName: total.category.systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(total.category.displayName)
                .font(.callout)
                .foregroundStyle(total.sizeBytes > 0 ? .primary : .secondary)
            Spacer(minLength: 8)
            Text(Fmt.percent(total.sizeBytes, of: totalBytes))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Text(total.sizeBytes > 0 ? Fmt.bytes(total.sizeBytes) : "\u{2014}")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(total.sizeBytes > 0 ? .primary : Color(nsColor: .tertiaryLabelColor))
                .frame(width: 78, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    /// Maps a `DiskSpaceFileCategory` to a swatch color — kept here rather
    /// than on the (`Foundation`-only) enum itself, the same split
    /// `ConnectionsPage.exposureColor(_:)` uses for `SocketExposure`.
    /// Chosen from `DomainPalette`'s own `NSColor.system*` token family so
    /// this legend matches the rest of the app's "no custom hex values"
    /// rule, picking colors distinct from the hardware-domain colors
    /// already in heavy use elsewhere (CPU blue/red, Memory/Disk-read
    /// blue, Network blue/red) to avoid implying a connection that isn't
    /// there.
    private static func color(for category: DiskSpaceFileCategory) -> Color {
        switch category {
        case .media: return Color(nsColor: .systemPink)
        case .documents: return Color(nsColor: .systemBlue)
        case .code: return Color(nsColor: .systemIndigo)
        case .archives: return Color(nsColor: .systemOrange)
        case .apps: return Color(nsColor: .systemTeal)
        case .system: return Color(nsColor: .systemGray)
        case .other: return Color(nsColor: .systemBrown)
        }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        Picker("View", selection: $tab) {
            ForEach(DiskSpaceViewTab.allCases) { option in
                Text(option.title).tag(option)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var tabContent: some View {
        switch tab {
        case .largestFolders: largestFoldersTable
        case .largestFiles: largestFilesTable
        case .history: historySection
        }
    }

    // MARK: - Largest Folders

    private var largestFoldersTable: some View {
        DataTable(
            columns: Self.folderColumns,
            rows: filteredByPath(model.result?.largestFolders ?? [], path: \.path),
            sort: $folderSort,
            selection: $selectedFolderID,
            emptyMessage: model.result == nil ? "No scan yet." : "No folders found."
        )
    }

    private static let folderColumns: [DataTableColumn<DiskSpaceFolderEntry>] = [
        DataTableColumn(id: "path", title: "Folder", value: { $0.path }) { entry in
            Text(entry.path).lineLimit(1).truncationMode(.head)
        },
        DataTableColumn(id: "items", title: "Items", width: 80, alignment: .trailing, value: { $0.itemCount }) { entry in
            Text(Fmt.count(entry.itemCount)).monospacedDigit()
        },
        DataTableColumn(id: "size", title: "Size", width: 100, alignment: .trailing, value: { $0.sizeBytes }) { entry in
            Text(Fmt.bytes(entry.sizeBytes)).monospacedDigit()
        },
    ]

    // MARK: - Largest Files

    private var largestFilesTable: some View {
        DataTable(
            columns: Self.fileColumns,
            rows: filteredByPath(model.result?.largestFiles ?? [], path: \.path),
            sort: $fileSort,
            selection: $selectedFileID,
            emptyMessage: model.result == nil ? "No scan yet." : "No files found."
        )
    }

    private static let fileColumns: [DataTableColumn<DiskSpaceFileEntry>] = [
        DataTableColumn(id: "path", title: "File", value: { $0.path }) { entry in
            Text(entry.path).lineLimit(1).truncationMode(.head)
        },
        DataTableColumn(id: "type", title: "Type", width: 108, value: { $0.category.displayName }) { entry in
            HStack(spacing: 4) {
                Circle().fill(color(for: entry.category)).frame(width: 7, height: 7)
                Text(entry.category.displayName).foregroundStyle(.secondary)
            }
        },
        DataTableColumn(id: "size", title: "Size", width: 100, alignment: .trailing, value: { $0.sizeBytes }) { entry in
            Text(Fmt.bytes(entry.sizeBytes)).monospacedDigit()
        },
    ]

    private func filteredByPath<T>(_ items: [T], path: KeyPath<T, String>) -> [T] {
        let needle = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return items }
        return items.filter { $0[keyPath: path].lowercased().contains(needle) }
    }

    // MARK: - Scan History

    /// PLAN.md's "scan history": every completed scan `DiskSpaceViewModel`
    /// has recorded, most recent first, persisted across launches (see
    /// that type's own doc comment). Rescan re-runs the same root path;
    /// Clear History only forgets the list, never touches anything on
    /// disk.
    private var historySection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Every completed scan, most recent first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Clear History") {
                    model.clearHistory()
                }
                .disabled(model.history.isEmpty)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            DataTable(
                columns: historyColumns,
                rows: model.history,
                sort: $historySort,
                selection: $selectedHistoryID,
                emptyMessage: "No scans yet."
            )
        }
    }

    private var historyColumns: [DataTableColumn<DiskSpaceScanHistoryEntry>] {
        [
            DataTableColumn(id: "root", title: "Folder", value: { $0.rootPath }) { entry in
                Text(entry.rootPath).lineLimit(1).truncationMode(.head)
            },
            DataTableColumn(id: "scannedAt", title: "Scanned", width: 150, value: { $0.scannedAt }) { entry in
                Text(Self.historyTimeFormatter.string(from: entry.scannedAt))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            },
            DataTableColumn(id: "items", title: "Items", width: 80, alignment: .trailing, value: { $0.totalItemCount }) { entry in
                Text(Fmt.count(entry.totalItemCount)).monospacedDigit()
            },
            DataTableColumn(id: "size", title: "Size", width: 100, alignment: .trailing, value: { $0.totalBytes }) { entry in
                Text(Fmt.bytes(entry.totalBytes)).monospacedDigit()
            },
            DataTableColumn(id: "rescan", title: "", width: 64, alignment: .center) { entry in
                Button("Rescan") {
                    model.rescan(rootPath: entry.rootPath)
                    tab = .largestFolders
                }
                .buttonStyle(.link)
                .font(.caption)
                .disabled(model.isScanning)
            },
        ]
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    private static let historyTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Tabs

private enum DiskSpaceViewTab: String, CaseIterable, Identifiable {
    case largestFolders
    case largestFiles
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .largestFolders: return "Largest Folders"
        case .largestFiles: return "Largest Files"
        case .history: return "Scan History"
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

    static func percent(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let fraction = Double(part) / Double(total)
        return String(format: "%.0f%%", fraction * 100)
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

// MARK: - Bubble chart

/// PLAN.md's "Balls" bubble-chart visualization, one circle per non-empty
/// `DiskSpaceFileCategory`, area proportional to that category's byte
/// share (not radius-proportional — a radius-proportional bubble chart
/// visually exaggerates small categories and is a well-known way to
/// mislead a reader about relative magnitude). Kept private to this file
/// rather than in `Components/`, matching `PowerFreqPage`'s own precedent
/// for a page-specific visualization only that one page needs (see that
/// type's doc comment).
private struct DiskSpaceBubbleChart: View {
    let totals: [DiskSpaceCategoryTotal]
    let colorForCategory: (DiskSpaceFileCategory) -> Color

    private var nonzeroTotals: [DiskSpaceCategoryTotal] { totals.filter { $0.sizeBytes > 0 } }
    private var totalBytes: UInt64 { totals.reduce(0) { $0 + $1.sizeBytes } }

    var body: some View {
        Group {
            if nonzeroTotals.isEmpty {
                emptyState
            } else {
                GeometryReader { proxy in
                    let bubbles = Self.layout(for: nonzeroTotals, in: proxy.size)
                    ZStack {
                        Canvas { context, _ in
                            for bubble in bubbles {
                                let rect = CGRect(
                                    x: bubble.center.x - bubble.radius,
                                    y: bubble.center.y - bubble.radius,
                                    width: bubble.radius * 2,
                                    height: bubble.radius * 2
                                )
                                let path = Path(ellipseIn: rect)
                                let color = colorForCategory(bubble.category)
                                context.fill(path, with: .color(color.opacity(0.82)))
                                context.stroke(path, with: .color(color), lineWidth: 1)
                            }
                        }
                        ForEach(bubbles) { bubble in
                            if bubble.radius >= 20 {
                                Text(Self.percentLabel(bubble.sizeBytes, of: totalBytes))
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .position(bubble.center)
                            }
                        }
                    }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("File type breakdown by size")
        .accessibilityValue(accessibilityValueText)
    }

    private var accessibilityValueText: String {
        nonzeroTotals
            .map { "\($0.category.displayName) \(Self.percentLabel($0.sizeBytes, of: totalBytes))" }
            .joined(separator: ", ")
    }

    private var emptyState: some View {
        Text("No files found.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static func percentLabel(_ part: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        return String(format: "%.0f%%", Double(part) / Double(total) * 100)
    }

    // MARK: - Layout

    private struct PlacedBubble: Identifiable {
        var id: DiskSpaceFileCategory { category }
        let category: DiskSpaceFileCategory
        let center: CGPoint
        let radius: CGFloat
        let sizeBytes: UInt64
    }

    /// Sizes each bubble by `sqrt(byteShare)` (area-proportional), packs
    /// them with `placeCircle(radius:among:)`, then scales+translates the
    /// whole packed cluster to fit `size`.
    private static func layout(for totals: [DiskSpaceCategoryTotal], in size: CGSize) -> [PlacedBubble] {
        guard !totals.isEmpty else { return [] }
        let maxBytes = totals.map(\.sizeBytes).max() ?? 1
        let baseUnit: CGFloat = 60
        let minRadiusFraction: CGFloat = 0.22

        let sized = totals
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .map { total -> (total: DiskSpaceCategoryTotal, radius: CGFloat) in
                let fraction = maxBytes > 0 ? Double(total.sizeBytes) / Double(maxBytes) : 0
                let radius = max(baseUnit * CGFloat(fraction.squareRoot()), baseUnit * minRadiusFraction)
                return (total, radius)
            }

        var placedCircles: [(center: CGPoint, radius: CGFloat)] = []
        var placements: [(total: DiskSpaceCategoryTotal, center: CGPoint, radius: CGFloat)] = []
        for entry in sized {
            let center = placeCircle(radius: entry.radius, among: placedCircles)
            placedCircles.append((center, entry.radius))
            placements.append((entry.total, center, entry.radius))
        }

        let maxExtent = placedCircles.reduce(CGFloat(1)) { partial, circle in
            max(partial, hypot(circle.center.x, circle.center.y) + circle.radius)
        }
        let availableRadius = max(min(size.width, size.height) / 2 - 6, 1)
        let scale = availableRadius / maxExtent
        let origin = CGPoint(x: size.width / 2, y: size.height / 2)

        return placements.map { placement in
            PlacedBubble(
                category: placement.total.category,
                center: CGPoint(x: origin.x + placement.center.x * scale, y: origin.y + placement.center.y * scale),
                radius: placement.radius * scale,
                sizeBytes: placement.total.sizeBytes
            )
        }
    }

    /// Places one more circle of `radius` with no overlap against
    /// `existing`, by walking outward along an Archimedean-style spiral
    /// from the origin until it finds a free spot. Not a tight/minimal
    /// packing like d3's sibling-pack algorithm, but simple, always
    /// terminating (a step cap guarantees that even in a pathological
    /// case), and more than enough for the handful of category bubbles
    /// this chart ever draws. The very first circle always lands exactly
    /// at the origin.
    private static func placeCircle(radius: CGFloat, among existing: [(center: CGPoint, radius: CGFloat)]) -> CGPoint {
        guard !existing.isEmpty else { return .zero }

        let angleStep: CGFloat = .pi / 18
        let stepsPerRevolution = (2 * CGFloat.pi) / angleStep
        let radiusStep: CGFloat = max(radius, 8) * 0.12
        var angle: CGFloat = 0
        var distance: CGFloat = radiusStep

        for _ in 0..<4000 {
            let candidate = CGPoint(x: distance * cos(angle), y: distance * sin(angle))
            let overlaps = existing.contains { other in
                let dx = other.center.x - candidate.x
                let dy = other.center.y - candidate.y
                let minDistance = other.radius + radius - 0.5
                return (dx * dx + dy * dy) < (minDistance * minDistance)
            }
            if !overlaps {
                return candidate
            }
            angle += angleStep
            distance += radiusStep / stepsPerRevolution
        }
        return CGPoint(x: distance * cos(angle), y: distance * sin(angle))
    }
}

// MARK: - Scan history model

/// One past scan recorded by `DiskSpaceViewModel` — PLAN.md's "scan
/// history." `Codable` so it can round-trip through `UserDefaults` as
/// JSON; see `DiskSpaceViewModel`'s own doc comment for the persistence
/// scheme.
struct DiskSpaceScanHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let rootPath: String
    let scannedAt: Date
    let totalBytes: UInt64
    let totalItemCount: Int
}

// MARK: - View model

/// Drives `DiskSpaceScanner` for `DiskSpacePage`: owns the chosen root
/// path, relays one scan's live `.progress`/terminal events into
/// `@Published` state, and maintains the persisted scan-history list.
///
/// History is stored as JSON under one `UserDefaults` key rather than
/// through `SettingsStore` — it's scan *data*, not a user preference, and
/// nothing else in the app needs to read or observe it, so it doesn't
/// belong in the shared preferences store. Persisted eagerly (on every
/// change, not just on app quit) the same way `SettingsStore.updateSpeed`
/// writes through immediately on `didSet`, so history survives a crash or
/// force-quit, not just a clean exit.
@MainActor
final class DiskSpaceViewModel: ObservableObject {
    @Published var rootPath: String
    @Published private(set) var isScanning = false
    @Published private(set) var progress: DiskSpaceScanProgress?
    @Published private(set) var result: DiskSpaceScanResult?
    /// Set when the most recent scan attempt threw or the chosen path
    /// wasn't a readable folder. Left in place alongside a still-populated
    /// `result` from an earlier successful scan, matching every other
    /// view model's own "one bad attempt doesn't blank an otherwise-good
    /// result" rule.
    @Published private(set) var unavailableReason: String?
    @Published private(set) var history: [DiskSpaceScanHistoryEntry] = []

    private let scanner = DiskSpaceScanner()
    private var scanTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private static let historyDefaultsKey = "diskSpaceScanHistory"
    private static let historyLimit = 20

    /// - Parameter defaults: The `UserDefaults` suite scan history is
    ///   persisted to. Defaults to `.standard`; tests should pass an
    ///   isolated suite, matching `SettingsStore.init(defaults:)`'s own
    ///   reasoning.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        rootPath = FileManager.default.homeDirectoryForCurrentUser.path
        history = Self.loadHistory(from: defaults)
    }

    func startScan() {
        guard !isScanning else { return }
        let path = rootPath
        isScanning = true
        unavailableReason = nil
        progress = nil

        // `scanner` (an `actor`, always `Sendable`) and `path` (`String`,
        // also `Sendable`) are captured into the `Task` below rather than
        // the `AsyncStream` itself, and `scan(rootPath:)` is called fresh
        // inside the `Task`'s own body — the same shape
        // `ConnectionsViewModel.startTrafficSampling()`'s `for await
        // snapshot in sampler.stream()` uses.
        let scanner = scanner
        scanTask = Task { [weak self] in
            for await event in scanner.scan(rootPath: path) {
                guard let self else { return }
                self.handle(event)
            }
            self?.isScanning = false
            self?.scanTask = nil
        }
    }

    /// Cancels whichever scan is running, if any — see
    /// `DiskSpaceScanner.cancelActiveScan()`'s own doc comment for why
    /// this takes effect immediately rather than waiting for this
    /// method's own consuming `Task` to next notice.
    func cancelScan() {
        scanner.cancelActiveScan()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.directoryURL = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        rootPath = url.path
    }

    /// Re-runs a scan against a previously-scanned root path — the Scan
    /// History tab's Rescan action.
    func rescan(rootPath newRootPath: String) {
        rootPath = newRootPath
        startScan()
    }

    func clearHistory() {
        history = []
        persistHistory()
    }

    private func handle(_ event: DiskSpaceScanEvent) {
        switch event {
        case .progress(let progress):
            self.progress = progress
        case .completed(let result):
            self.result = result
            self.progress = nil
            recordHistory(result)
        case .failed(let reason):
            self.unavailableReason = reason
            self.progress = nil
        case .cancelled:
            self.progress = nil
        }
    }

    /// Records a completed scan at the front of `history`, replacing any
    /// earlier entry for the exact same root path (a rescan of the same
    /// folder should move to the top, not pile up a duplicate row), then
    /// trims to `historyLimit`.
    private func recordHistory(_ result: DiskSpaceScanResult) {
        let entry = DiskSpaceScanHistoryEntry(
            id: UUID(),
            rootPath: result.rootPath,
            scannedAt: result.generatedAt,
            totalBytes: result.totalBytes,
            totalItemCount: result.totalItemCount
        )
        history.removeAll { $0.rootPath == entry.rootPath }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        persistHistory()
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.historyDefaultsKey)
    }

    private static func loadHistory(from defaults: UserDefaults) -> [DiskSpaceScanHistoryEntry] {
        guard let data = defaults.data(forKey: historyDefaultsKey) else { return [] }
        return (try? JSONDecoder().decode([DiskSpaceScanHistoryEntry].self, from: data)) ?? []
    }
}

#Preview {
    DiskSpacePage()
        .frame(width: 980, height: 700)
}
