import Foundation
import SwiftUI

/// Users page — PLAN.md §1.1 "Users" ("Per-user grouping (status, process
/// count, total CPU, total Memory) expandable to that user's processes;
/// same rich process detail pane") and §4 M4's final task ("Users page:
/// same data grouped by user with per-user rollups").
///
/// Polls its own `ProcessProvider` instance on the same cadence
/// `ProcessesPage.ProcessesViewModel` does (this file's own
/// `UsersViewModel`, mirroring that view model's own doc comment on why a
/// direct poll rather than a `Sampler`-fed field) and groups each tick's
/// flat `ProcessForest.all` into `UserRollup`s (`Components/
/// UserOutlineView.swift`) keyed by owning uid — a separate `ProcessProvider`
/// instance from `ProcessesPage`'s own rather than a shared one, matching
/// this app's existing "each page owns its own poll" convention (PLAN.md
/// §2's "lowest idle overhead" is about *this app's* aggregate load, not
/// about pages coordinating with each other; no shared process cache exists
/// yet for either page to draw from instead).
///
/// Renders that grouping through `Components/UserOutlineView.swift`'s
/// native `NSOutlineView` tree — the same `NSViewRepresentable` technique
/// `ProcessesPage` uses for its own Applications/Background tree, adapted
/// to per-user groups with real rollup columns (see that file's own doc
/// comment for why its rows aren't `NSOutlineView` group headers). Filtering
/// by name/user/PID and the Identity/Lifetime/Processor/Memory/Disk detail
/// pane are this file's own copies of `ProcessesPage`'s equivalents (its
/// own `Self.filtered(_:query:)`, `detailSections(for:)`, `Fmt`, and
/// `ExecutableArchitecture`) — duplicated rather than shared, per this
/// app's own established convention of each page keeping small file-scoped
/// helpers to itself (see `ProcessesPage.swift`'s own `Fmt` doc comment:
/// "each page keeps a small file-scoped formatter set rather than sharing
/// one across the app").
struct UsersPage: View {
    @StateObject private var model = UsersViewModel()
    @State private var searchText = ""
    /// Starts CPU % descending, matching `ProcessesPage`'s own default —
    /// the most active user's rollup (and, within it, its most active
    /// process) leads the list.
    @State private var sort: DataTableSort? = DataTableSort(columnID: "cpu", ascending: false)
    @State private var selectedPID: pid_t?
    /// See `ProcessesPage.pendingQuitPID`'s doc comment — same
    /// click-time-captured-pid rule for this page's own quit confirmation.
    @State private var pendingQuitPID: pid_t?
    /// Same fixed detail-pane height as `ProcessesPage`, for the same
    /// reason (PLAN.md §1.1's "same rich process detail pane").
    private static let detailPaneHeight: CGFloat = 200

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            detailPane
                .frame(height: Self.detailPaneHeight)
        }
        .pageToolbar(
            searchText: $searchText,
            searchPrompt: "Filter by Name, User, or PID",
            showsProcessActions: true,
            quitAction: selectedPID.map { pid in { pendingQuitPID = pid } }
        )
        .quitConfirmationDialog(pendingPID: $pendingQuitPID, name: pendingQuitProcessName)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    /// See `ProcessesPage.pendingQuitProcessName`'s doc comment — same
    /// "PID"-keyed lookup and same-tick-exit fallback.
    private var pendingQuitProcessName: String? {
        guard let pid = pendingQuitPID else { return nil }
        return readingsByPID[pid]?.name
    }

    @ViewBuilder
    private var content: some View {
        if let forest = model.forest {
            let rollups = Self.filtered(Self.rollups(from: forest.all), query: searchText)
            if isFilterActive, rollups.isEmpty {
                noMatchesState
            } else {
                UserOutlineView(
                    rollups: rollups,
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

    // MARK: - Grouping

    /// Groups `all` (a tick's flat process list) into one `UserRollup` per
    /// distinct owning uid — PLAN.md's "Per-user grouping". See
    /// `UserRollup.displayName`'s doc comment for the "UID n" fallback
    /// when every process for a uid failed the username lookup.
    private static func rollups(from all: [ProcessReading]) -> [UserRollup] {
        var byUID: [uid_t: [ProcessReading]] = [:]
        for reading in all {
            byUID[reading.userID, default: []].append(reading)
        }
        return byUID.map { uid, readings in
            let resolvedName = readings.first(where: { $0.userName != nil })?.userName
            return UserRollup(
                userID: uid,
                displayName: resolvedName ?? "UID \(uid)",
                isNameResolved: resolvedName != nil,
                processes: readings
            )
        }
    }

    // MARK: - Detail pane

    /// Every current reading keyed by pid — mirrors
    /// `ProcessesPage.readingsByPID`'s own doc comment (built from
    /// `model.forest`'s unfiltered `all`, cheap to rebuild on each access
    /// at this page's ~1s poll cadence).
    private var readingsByPID: [pid_t: ProcessReading] {
        guard let forest = model.forest else { return [:] }
        return Dictionary(uniqueKeysWithValues: forest.all.map { ($0.pid, $0) })
    }

    @ViewBuilder
    private var detailPane: some View {
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

    /// See `ProcessesPage.detailSections(for:)`'s doc comment — identical
    /// Identity/Lifetime/Processor/Memory/Disk sections and identical
    /// honest-"Unavailable" fields (per-process GPU/NPU load and private
    /// memory have no public macOS API either page can read).
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
            DetailPaneSection(title: "Lifetime", fields: [
                DetailPaneField(label: "Started", value: Fmt.startedAt(reading.startedAt)),
                DetailPaneField(label: "Uptime", value: Fmt.uptime(uptimeInterval), isMonospaced: true),
                DetailPaneField(label: "Threads", value: reading.threadCount.map { String($0) } ?? "", isUnavailable: reading.threadCount == nil, isMonospaced: true),
                DetailPaneField(label: "Priority", value: priorityLabel(reading.niceValue)),
            ]),
            DetailPaneSection(title: "Processor", fields: [
                DetailPaneField(label: "CPU", value: Fmt.percent(reading.cpuPercent), isUnavailable: reading.cpuPercent == nil, isMonospaced: true),
                DetailPaneField(label: "CPU Time", value: Fmt.cpuTime(reading.cpuTimeSeconds), isUnavailable: reading.cpuTimeSeconds == nil, isMonospaced: true),
                DetailPaneField(label: "GPU", value: "", isUnavailable: true),
                DetailPaneField(label: "NPU", value: "", isUnavailable: true),
            ]),
            DetailPaneSection(title: "Memory", fields: [
                DetailPaneField(label: "Footprint", value: Fmt.bytes(reading.memoryFootprintBytes), isUnavailable: reading.memoryFootprintBytes == nil, isMonospaced: true),
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

    /// See `ProcessesPage.parentLabel(for:)`'s doc comment.
    private func parentLabel(for reading: ProcessReading) -> String {
        guard let parentPID = reading.parentPID else { return "None" }
        guard let parentName = readingsByPID[parentPID]?.name else { return "PID \(parentPID)" }
        return "\(parentName) (\(parentPID))"
    }

    /// See `ProcessesPage.priorityLabel(_:)`'s doc comment.
    private func priorityLabel(_ niceValue: Int) -> String {
        switch niceValue {
        case 0: return "Normal"
        case ..<0: return "High (\(niceValue))"
        default: return "Low (\(niceValue))"
        }
    }

    /// Delegates to `UsersViewModel`'s own cached lookup — see
    /// `ProcessesViewModel.architectureLabel(forExecutablePath:)`'s doc
    /// comment for why this is cached per page rather than re-read every
    /// poll tick.
    private func architecture(for reading: ProcessReading) -> String? {
        guard let path = reading.executablePath else { return nil }
        return model.architectureLabel(forExecutablePath: path)
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

    private var noMatchesState: some View {
        VStack {
            Spacer(minLength: 0)
            Text("No users match \u{201C}\(searchText)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Filtering

    /// Prunes `rollups` to entries matching `query` by username, process
    /// name, or PID (PLAN.md's "filter by name, user, or PID", applied here
    /// per-user rather than per-tree-node). A rollup whose own username
    /// matches is kept whole — all its processes, even non-matching ones —
    /// the same "keep an ancestor for context" rule
    /// `ProcessesPage.filtered(_:query:)` applies to a matching descendant's
    /// parent; a rollup whose username doesn't match is kept only when at
    /// least one of its processes does, narrowed to just those.
    private static func filtered(_ rollups: [UserRollup], query: String) -> [UserRollup] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return rollups }
        let needle = trimmed.lowercased()

        func matches(_ reading: ProcessReading) -> Bool {
            if let name = reading.name, name.lowercased().contains(needle) { return true }
            return String(reading.pid).contains(needle)
        }

        return rollups.compactMap { rollup in
            if rollup.displayName.lowercased().contains(needle) { return rollup }
            let matchingProcesses = rollup.processes.filter(matches)
            guard !matchingProcesses.isEmpty else { return nil }
            return UserRollup(
                userID: rollup.userID,
                displayName: rollup.displayName,
                isNameResolved: rollup.isNameResolved,
                processes: matchingProcesses
            )
        }
    }
}

// MARK: - Quit confirmation dialog

private extension View {
    /// See `ProcessesPage`'s own `quitConfirmationDialog(pendingPID:name:)`
    /// doc comment — identical Quit/Force Quit/Cancel sheet, calling
    /// through to the same shared `ProcessActions` implementation.
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

// MARK: - View model

/// Polls its own `ProcessProvider` instance the same way
/// `ProcessesPage.ProcessesViewModel` polls its own — see that type's own
/// doc comment for why a direct poll rather than a `Sampler`-fed
/// `Snapshot` field, and why a separate `ProcessProvider` instance per page
/// rather than a shared one (no cross-page process cache exists yet).
@MainActor
final class UsersViewModel: ObservableObject {
    @Published private(set) var forest: ProcessForest?
    @Published private(set) var unavailableReason: String?

    private let provider = ProcessProvider()
    private var pollTask: Task<Void, Never>?
    private static let pollInterval = Sampler.Interval.slow.seconds
    private var architectureCache: [String: String] = [:]

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

// MARK: - Formatting

/// See `ProcessesPage.swift`'s own `Fmt` doc comment — this file's own
/// copy of the same byte/duration formatting convention.
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

/// See `ProcessesPage.swift`'s own `ExecutableArchitecture` doc comment —
/// this file's own copy of the same best-effort Mach-O header read.
private enum ExecutableArchitecture {
    static func label(forExecutableAt path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return nil }
        let bytes = [UInt8](header)

        if readUInt32(bytes, at: 0, bigEndian: false) == 0xfeedfacf,
           let cpuType = readUInt32(bytes, at: 4, bigEndian: false) {
            return name(forCPUType: cpuType)
        }

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
    UsersPage()
        .frame(width: 900, height: 640)
}
