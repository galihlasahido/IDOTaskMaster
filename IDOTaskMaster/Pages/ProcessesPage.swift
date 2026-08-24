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
    ProcessesPage()
        .frame(width: 900, height: 640)
}
