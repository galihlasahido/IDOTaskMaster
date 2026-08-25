import SwiftUI

/// Power & Freq page — PLAN.md §1.1 "Power & Freq" (a former [name removed] Pro page,
/// unlocked here per §2) / §4 M6's first task: "sensor tree with Value/Min/
/// Max from SMC + provider stats" — an HWiNFO-style live sensor panel.
///
/// A native hierarchical `List` (SwiftUI's `List(_:children:)` initializer,
/// the same mechanism Finder's own outline view is built on) rather than
/// `Components/DataTable.swift`: unlike every other list page in this app,
/// this one's rows are genuinely nested (this Mac → CPU → Temperatures →
/// one row per sensor), and the whole point of an HWiNFO-style panel is
/// being able to collapse a category you don't care about — something a
/// flat `DataTable` (see its own doc comment: "only knows how to lay out a
/// flat row list") has no way to express. `PowerFreqNode`/
/// `PowerFreqTreeBuilder` below are this page's own small tree type, kept
/// self-contained in this file matching this app's one-file-per-page
/// convention rather than growing `DataTable` a hierarchy mode only this
/// page would ever use.
///
/// Every leaf reading comes straight off `Snapshot.cpu`/`.gpu`/`.disk`/
/// `.energy`/`.thermal` — this page adds no new `Provider`; it is a
/// different *view* of the same live data `PerformancePage` already
/// samples, per this task's "from SMC + provider stats" (the SMC half is
/// `ThermalProvider`'s discovered temperature sensors and `EnergyProvider`'s
/// wattage keys; the "provider stats" half is `CPUProvider`/`GPUProvider`/
/// `DiskProvider`'s ordinary utilization/throughput readings). What is new
/// here is the running **Min/Max**: unlike `PerformanceViewModel`'s
/// ring-buffer history (a fixed recent window for a scrolling graph),
/// `PowerFreqViewModel` keeps one running `(min, max)` pair per sensor for
/// as long as this page stays open — the toolbar's Reset Min/Max button
/// (or simply leaving and revisiting the page, which recreates the
/// `@StateObject`) starts a fresh window, the same behavior HWiNFO's own
/// Min/Max columns have across its own restarts.
struct PowerFreqPage: View {
    @StateObject private var model = PowerFreqViewModel()
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            statusLine
            Divider()
            columnHeader
            Divider()
            treeOrEmptyState
        }
        .pageToolbar(searchText: $searchText, searchPrompt: "Filter Sensors")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                resetButton
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Toolbar

    private var resetButton: some View {
        Button {
            model.resetTracking()
        } label: {
            Label("Reset Min/Max", systemImage: "arrow.counterclockwise")
        }
        .disabled(model.latest == nil)
        .help("Reset every sensor's Min/Max back to its current reading")
    }

    // MARK: - Status line

    /// Mirrors `SystemInfoPage.statusLine`/`StartupPage.statusLine`'s "as
    /// of" caption, but for a live-polled page rather than a load-once
    /// catalog: names when the tree was last refreshed and since when the
    /// visible Min/Max window has been accumulating.
    private var statusLine: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(model.latest == nil ? Color(nsColor: .tertiaryLabelColor) : .secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var statusText: String {
        guard let timestamp = model.latest?.timestamp else { return "Waiting for the first sample…" }
        let updated = Self.timeFormatter.string(from: timestamp)
        let since = Self.timeFormatter.string(from: model.trackingStartedAt ?? timestamp)
        return "Live — updated \(updated) — Min/Max since \(since)"
    }

    // MARK: - Column header

    private var columnHeader: some View {
        HStack(spacing: 0) {
            Text("Sensor")
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Value").frame(width: Self.valueColumnWidth, alignment: .trailing)
            Text("Min").frame(width: Self.minMaxColumnWidth, alignment: .trailing)
            Text("Max").frame(width: Self.minMaxColumnWidth, alignment: .trailing)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Tree

    @ViewBuilder
    private var treeOrEmptyState: some View {
        let roots = filteredRoots
        if roots.isEmpty {
            emptyState
        } else {
            List(roots, children: \.children) { node in
                row(node)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer(minLength: 0)
            Text(searchText.isEmpty ? "No sensors available." : "No sensors match \u{201C}\(searchText)\u{201D}.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func row(_ node: PowerFreqNode) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                if let systemImage = node.systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(node.tint ?? Color.secondary)
                        .frame(width: 16)
                }
                Text(node.title)
                    .fontWeight(node.children == nil ? .regular : .medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            valueCell(node.value, isUnavailable: node.isUnavailable, width: Self.valueColumnWidth, dimmed: false)
            valueCell(node.minValue, isUnavailable: false, width: Self.minMaxColumnWidth, dimmed: true)
            valueCell(node.maxValue, isUnavailable: false, width: Self.minMaxColumnWidth, dimmed: true)
        }
        .padding(.trailing, 12)
        .padding(.vertical, 1)
        // This row's Sensor/Value/Min/Max columns are four separate `Text`
        // views with no column-header association for VoiceOver to read
        // back (unlike `DataTable`'s AppKit-backed siblings, this is a
        // plain SwiftUI `List` row — see this file's own doc comment on
        // why). Collapsing it into one element with an explicit
        // label/value pairing (matching `DetailPane.fieldValue`'s own
        // "say what the number means" convention) reads as e.g. "Hotspot,
        // 42.3°C, min 38.0°C, max 61.4°C" instead of four bare, unlabeled
        // numbers in a row.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(node.title)
        .accessibilityValue(rowAccessibilityValue(node))
    }

    /// See `row(_:)`'s own doc comment. A group row (`node.children != nil`)
    /// has no reading of its own — `node.title` alone, read by
    /// `accessibilityLabel` above, is already a complete description (List's
    /// own disclosure-triangle semantics cover expanded/collapsed state), so
    /// this returns an empty value rather than an empty "Value , min —, max
    /// —" that would just repeat "unavailable" three times for nothing.
    private func rowAccessibilityValue(_ node: PowerFreqNode) -> String {
        guard node.children == nil else { return "" }
        var parts: [String] = [node.isUnavailable ? "Unavailable" : (node.value ?? "Unavailable")]
        if let minValue = node.minValue, minValue != "\u{2014}" {
            parts.append("min \(minValue)")
        }
        if let maxValue = node.maxValue, maxValue != "\u{2014}" {
            parts.append("max \(maxValue)")
        }
        return parts.joined(separator: ", ")
    }

    private func valueCell(_ text: String?, isUnavailable: Bool, width: CGFloat, dimmed: Bool) -> some View {
        let color: Color = isUnavailable
            ? Color(nsColor: .tertiaryLabelColor)
            : (dimmed ? Color.secondary : Color.primary)
        return Text(text ?? "")
            .monospacedDigit()
            .foregroundStyle(color)
            .lineLimit(1)
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - Filtering

    private var filteredRoots: [PowerFreqNode] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return model.roots }
        return Self.filter(model.roots, matching: trimmed)
    }

    /// Keeps a node whose own title matches as-is (with its full, unfiltered
    /// subtree); otherwise drops it in favor of just its matching
    /// descendants — the same "prune, don't hide the whole branch" rule
    /// `SystemInfoPage.filteredCategories` applies to its own two-level
    /// catalog, generalized here to this tree's arbitrary depth.
    private static func filter(_ nodes: [PowerFreqNode], matching needle: String) -> [PowerFreqNode] {
        nodes.compactMap { node -> PowerFreqNode? in
            if node.title.localizedCaseInsensitiveContains(needle) {
                return node
            }
            guard let children = node.children else { return nil }
            let matchingChildren = filter(children, matching: needle)
            guard !matchingChildren.isEmpty else { return nil }
            var copy = node
            copy.children = matchingChildren
            return copy
        }
    }

    // MARK: - Layout constants

    private static let valueColumnWidth: CGFloat = 100
    private static let minMaxColumnWidth: CGFloat = 84

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}

// MARK: - Tree model

/// One row of the Power & Freq sensor tree — either a pure group heading
/// (`children` non-`nil`; `value`/`minValue`/`maxValue` all `nil` so those
/// columns render blank, matching HWiNFO's own group rows having no
/// reading of their own) or a leaf sensor reading (`children` nil; `value`
/// is always non-`nil` once built — the literal string `"Unavailable"`
/// counts as a value per PLAN.md's honest-degradation convention, styled
/// via `isUnavailable` rather than omitted). `minValue`/`maxValue` are
/// `"—"` for the handful of leaves whose reading is a fixed capacity/state
/// rather than a genuinely time-varying sensor (GPU total dedicated VRAM,
/// power source, thermal pressure, the "no live clock reading" leaf) —
/// tracking a running Min/Max for those would be either meaningless (a
/// constant) or misleading (an enum state has no ordering).
struct PowerFreqNode: Identifiable {
    let id: String
    let title: String
    var systemImage: String? = nil
    var tint: Color? = nil
    var value: String? = nil
    var minValue: String? = nil
    var maxValue: String? = nil
    var isUnavailable: Bool = false
    var children: [PowerFreqNode]? = nil
}

// MARK: - View model

/// Drives `PowerFreqPage`'s live sensor tree: subscribes to `Sampler.shared`
/// (started in `onAppear`/unsubscribed in `onDisappear` — the same shared-
/// instance pattern `PerformanceViewModel`'s doc comment establishes, so
/// this page's tick doesn't duplicate the CPU/memory/GPU/.../NPU sampling
/// round the info bar or Performance page may already be driving) and, on
/// every tick, folds each finite reading into a running per-sensor
/// `SensorTrack` alongside the plain latest `Snapshot` — `PowerFreqPage`
/// builds this tick's tree from both via `PowerFreqTreeBuilder`.
///
/// Subscribes to `Sampler.shared` rather than a private `Sampler` for the
/// same reason `PerformanceViewModel` does (see its doc comment): a
/// private instance here would duplicate the whole CPU/memory/GPU/disk/
/// network/energy/thermal/NPU sampling round — every one of which this
/// page's sensor tree reads — on top of whatever the info bar (and
/// possibly the Performance or Summary page) is already driving via the
/// shared instance, for the same wall-clock tick.
@MainActor
final class PowerFreqViewModel: ObservableObject {
    @Published private(set) var latest: Snapshot?
    /// Running Min/Max per sensor id, keyed by the dotted ids `SensorID`
    /// assigns below — cleared only by `resetTracking()`, never pruned on a
    /// gap tick (a sensor that goes briefly unreadable keeps its
    /// previously-tracked range rather than losing history over one missed
    /// reading).
    @Published private(set) var tracks: [String: SensorTrack] = [:]
    /// When the current Min/Max window started — the first tick after
    /// `start()`, or the most recent `resetTracking()`, whichever is later.
    /// `nil` before the first tick.
    @Published private(set) var trackingStartedAt: Date?

    private let sampler = Sampler.shared
    private var streamTask: Task<Void, Never>?

    /// This tick's tree, built fresh from `latest`/`tracks`. Pure of any
    /// filtering, which `PowerFreqPage.filteredRoots` applies on top.
    var roots: [PowerFreqNode] {
        PowerFreqTreeBuilder.build(snapshot: latest, tracks: tracks)
    }

    /// Starts the live snapshot stream if it isn't already running. Safe to
    /// call repeatedly (`SwiftUI.onAppear` can fire more than once for the
    /// same view instance).
    func start() {
        guard streamTask == nil else { return }
        let sampler = sampler
        streamTask = Task { [weak self] in
            await sampler.start()
            for await snapshot in sampler.stream() {
                guard let self else { return }
                self.ingest(snapshot)
            }
        }
    }

    /// Ends this view model's own subscription — called from `onDisappear`
    /// so this page stops reading (and computing sensor tracks for) live
    /// data while another page is showing. Deliberately does *not* call
    /// `sampler.stop()`: `sampler` is the shared instance, and stopping it
    /// outright would cut off every other still-active subscriber (the
    /// info bar, and whichever other page might also be subscribed) —
    /// cancelling just this task ends only this subscription, and
    /// `Sampler.shared` itself goes idle on its own once the last one (of
    /// any kind) does the same, per `removeContinuation`'s doc comment.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Clears every tracked Min/Max so the next tick's reading becomes each
    /// sensor's new starting point — HWiNFO's own "Reset Min/Max" action,
    /// reproduced here as the toolbar button `PowerFreqPage` wires to this.
    func resetTracking() {
        tracks = [:]
        trackingStartedAt = latest?.timestamp
    }

    // MARK: - Ingest

    private func ingest(_ snapshot: Snapshot) {
        latest = snapshot
        if trackingStartedAt == nil { trackingStartedAt = snapshot.timestamp }

        // Mutated locally and assigned back once at the end so one tick's
        // worth of sensor updates becomes a single `@Published` change
        // notification, matching `PerformanceViewModel.ingest`'s own
        // "build a local copy, publish once" shape.
        var updated = tracks
        func record(_ id: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            if var track = updated[id] {
                track.current = value
                track.min = min(track.min, value)
                track.max = max(track.max, value)
                updated[id] = track
            } else {
                updated[id] = SensorTrack(current: value, min: value, max: value)
            }
        }

        record(SensorID.systemPower, snapshot.energy?.systemPowerWatts)
        record(SensorID.adapterPower, snapshot.energy?.adapterPowerWatts)
        record(SensorID.batteryPower, snapshot.energy?.batteryPowerWatts)

        record(SensorID.cpuHotspot, snapshot.thermal?.hotspotCelsius)
        for sensor in snapshot.thermal?.dieSensors ?? [] {
            record(SensorID.cpuTempSensor(sensor.key), sensor.celsius)
        }

        record(SensorID.cpuUtilTotal, snapshot.cpu?.totalUtilization)
        record(SensorID.cpuUtilUser, snapshot.cpu?.userUtilization)
        record(SensorID.cpuUtilSystem, snapshot.cpu?.systemUtilization)
        record(SensorID.cpuUtilIdle, snapshot.cpu?.idleUtilization)
        for core in snapshot.cpu?.perCoreUtilization ?? [] {
            record(SensorID.cpuCore(core.id), core.totalUtilization)
        }

        record(SensorID.gpuUtilOverall, snapshot.gpu?.utilizationPercent)
        record(SensorID.gpuUtilRenderer, snapshot.gpu?.rendererUtilizationPercent)
        record(SensorID.gpuUtilTiler, snapshot.gpu?.tilerUtilizationPercent)
        record(SensorID.gpuTemperature, snapshot.gpu?.temperatureCelsius)
        if let used = snapshot.gpu?.vramUsedBytes { record(SensorID.gpuMemUsed, Double(used)) }
        if let allocated = snapshot.gpu?.vramAllocatedBytes { record(SensorID.gpuMemAllocated, Double(allocated)) }

        for unit in snapshot.disk?.units ?? [] {
            record(SensorID.diskActive(unit.id), unit.activePercent)
            record(SensorID.diskRead(unit.id), unit.readBytesPerSecond)
            record(SensorID.diskWrite(unit.id), unit.writeBytesPerSecond)
        }

        tracks = updated
    }
}

/// One sensor's running reading — the latest value plus the lowest/highest
/// seen since tracking started (`PowerFreqViewModel.resetTracking()`).
/// Every field holds the *raw* reading; `PowerFreqTreeBuilder` applies a
/// `SensorUnit`'s formatting only when turning a track into display text.
struct SensorTrack: Equatable {
    var current: Double
    var min: Double
    var max: Double
}

/// Stable dotted ids for every tracked sensor, shared between
/// `PowerFreqViewModel.ingest(_:)` (which writes `tracks` under these keys)
/// and `PowerFreqTreeBuilder` (which reads them back) so the two never
/// drift out of sync via a typo'd literal.
private enum SensorID {
    static let systemPower = "power.system"
    static let adapterPower = "power.adapter"
    static let batteryPower = "power.battery"
    static let cpuHotspot = "cpu.temp.hotspot"
    static func cpuTempSensor(_ smcKey: String) -> String { "cpu.temp.sensor.\(smcKey)" }
    static let cpuUtilTotal = "cpu.util.total"
    static let cpuUtilUser = "cpu.util.user"
    static let cpuUtilSystem = "cpu.util.system"
    static let cpuUtilIdle = "cpu.util.idle"
    static func cpuCore(_ coreID: Int) -> String { "cpu.util.core.\(coreID)" }
    static let gpuUtilOverall = "gpu.util.overall"
    static let gpuUtilRenderer = "gpu.util.renderer"
    static let gpuUtilTiler = "gpu.util.tiler"
    static let gpuTemperature = "gpu.temperature"
    static let gpuMemUsed = "gpu.mem.used"
    static let gpuMemAllocated = "gpu.mem.allocated"
    static func diskActive(_ unitID: String) -> String { "disk.\(unitID).active" }
    static func diskRead(_ unitID: String) -> String { "disk.\(unitID).read" }
    static func diskWrite(_ unitID: String) -> String { "disk.\(unitID).write" }
}

// MARK: - Tree builder

/// Builds `PowerFreqPage`'s tree from a `Snapshot` plus the running
/// `SensorTrack`s `PowerFreqViewModel` maintains — pure and stateless, so
/// it can be re-run every tick with no bookkeeping of its own. Shape
/// follows PLAN.md §1.1's "machine → CPU → Temperatures/Powers/
/// Utilization/Clocks; GPU; SSD → temps/throughput" literally: one root
/// node for this Mac, with CPU / GPU / SSD as its three children.
private enum PowerFreqTreeBuilder {
    static func build(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> [PowerFreqNode] {
        [machineNode(snapshot: snapshot, tracks: tracks)]
    }

    // MARK: Root

    private static func machineNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        group(id: "machine", title: machineTitle(snapshot), systemImage: "laptopcomputer", children: [
            cpuNode(snapshot: snapshot, tracks: tracks),
            gpuNode(snapshot: snapshot, tracks: tracks),
            ssdNode(snapshot: snapshot, tracks: tracks),
        ])
    }

    /// `CPUTopology.brandString` is this app's best-effort machine label
    /// even outside a CPU-specific context: Intel Macs get a real CPU brand
    /// string, Apple silicon Macs fall back to `hw.model` (e.g.
    /// `"Mac15,6"`) — see `CPUProvider.readTopology`'s own doc comment.
    /// `"This Mac"` only when the whole `cpu` domain is degraded this tick.
    private static func machineTitle(_ snapshot: Snapshot?) -> String {
        snapshot?.cpu?.topology.brandString ?? "This Mac"
    }

    // MARK: CPU

    private static func cpuNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        group(id: "cpu", title: "CPU", systemImage: "cpu", tint: DomainPalette.cpuUser, children: [
            cpuTemperaturesNode(snapshot: snapshot, tracks: tracks),
            cpuPowersNode(snapshot: snapshot, tracks: tracks),
            cpuUtilizationNode(snapshot: snapshot, tracks: tracks),
            cpuClocksNode(),
        ])
    }

    /// `ThermalProvider.dieSensors` are undocumented AppleSMC keys with no
    /// published component attribution (see that type's own doc comment on
    /// why it can't call any one of them "the CPU sensor"); shown here by
    /// raw SMC key (`"Sensor TPD3"`) rather than a numbered "Die N" label
    /// so this page never implies a stability across ticks the underlying
    /// discovered key set doesn't actually promise.
    private static func cpuTemperaturesNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        var children = [
            leaf(id: SensorID.cpuHotspot, title: "Hotspot", unit: .celsius, tracks: tracks),
            staticLeaf(id: "cpu.temp.pressure", title: "Thermal Pressure", value: thermalPressureText(snapshot), isUnavailable: snapshot?.thermal == nil),
        ]
        for sensor in snapshot?.thermal?.dieSensors ?? [] {
            children.append(leaf(id: SensorID.cpuTempSensor(sensor.key), title: "Sensor \(sensor.key)", unit: .celsius, tracks: tracks))
        }
        return group(id: "cpu.temperatures", title: "Temperatures", systemImage: "thermometer", children: children)
    }

    /// `EnergyProvider`'s three SMC wattage keys are system-wide (there is
    /// no CPU-package-specific power key this app reads), not a true "CPU
    /// package power" the way some vendor tools report — shown here anyway,
    /// under PLAN.md's literal "CPU → Powers" branch, as the closest and
    /// most honest reading available; nothing about the labels below claims
    /// CPU-only attribution.
    private static func cpuPowersNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        group(id: "cpu.powers", title: "Powers", systemImage: "bolt", children: [
            leaf(id: SensorID.systemPower, title: "System Total", unit: .watts, tracks: tracks),
            leaf(id: SensorID.adapterPower, title: "Adapter (DC-In)", unit: .watts, tracks: tracks),
            leaf(id: SensorID.batteryPower, title: "Battery", unit: .watts, tracks: tracks),
            staticLeaf(id: "cpu.powers.source", title: "Power Source", value: powerSourceText(snapshot), isUnavailable: snapshot?.energy == nil),
        ])
    }

    private static func cpuUtilizationNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        var children = [
            leaf(id: SensorID.cpuUtilTotal, title: "Total", unit: .percent, tracks: tracks),
            leaf(id: SensorID.cpuUtilUser, title: "User", unit: .percent, tracks: tracks),
            leaf(id: SensorID.cpuUtilSystem, title: "System", unit: .percent, tracks: tracks),
            leaf(id: SensorID.cpuUtilIdle, title: "Idle", unit: .percent, tracks: tracks),
        ]
        for core in snapshot?.cpu?.perCoreUtilization ?? [] {
            children.append(leaf(id: SensorID.cpuCore(core.id), title: "Core \(core.id)", unit: .percent, tracks: tracks))
        }
        return group(id: "cpu.utilization", title: "Utilization", systemImage: "gauge", children: children)
    }

    /// No provider in this app exposes a live CPU clock-speed reading —
    /// the same honest gap `SummaryPage.speedCaption` and
    /// `PerformancePage`'s own "Frequency Governor"/"Clock" cards already
    /// document (Apple silicon manages clock speed with no public readout;
    /// Intel's driver/governor sysctls aren't read either). One explicit
    /// "Unavailable" leaf rather than an empty — and therefore
    /// misleadingly-collapsed-looking — group.
    private static func cpuClocksNode() -> PowerFreqNode {
        group(id: "cpu.clocks", title: "Clocks", systemImage: "timer", children: [
            staticLeaf(id: "cpu.clocks.core", title: "Core Clock", value: nil, isUnavailable: true),
        ])
    }

    // MARK: GPU

    private static func gpuNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        group(id: "gpu", title: snapshot?.gpu?.deviceClassName ?? "GPU", systemImage: "square.stack.3d.up.fill", tint: DomainPalette.gpu, children: [
            group(id: "gpu.utilization", title: "Utilization", systemImage: "gauge", children: [
                leaf(id: SensorID.gpuUtilOverall, title: "Overall", unit: .percent, tracks: tracks),
                leaf(id: SensorID.gpuUtilRenderer, title: "Renderer", unit: .percent, tracks: tracks),
                leaf(id: SensorID.gpuUtilTiler, title: "Tiler", unit: .percent, tracks: tracks),
            ]),
            group(id: "gpu.memory", title: "Memory", systemImage: "memorychip", children: [
                leaf(id: SensorID.gpuMemUsed, title: "In Use", unit: .bytes, tracks: tracks),
                leaf(id: SensorID.gpuMemAllocated, title: "Allocated", unit: .bytes, tracks: tracks),
                staticLeaf(id: "gpu.mem.total", title: "Total (Dedicated)", value: snapshot?.gpu?.vramTotalBytes.map(Fmt.bytes), isUnavailable: snapshot?.gpu?.vramTotalBytes == nil),
            ]),
            leaf(id: SensorID.gpuTemperature, title: "Temperature", unit: .celsius, tracks: tracks),
        ])
    }

    // MARK: SSD

    private static func ssdNode(snapshot: Snapshot?, tracks: [String: SensorTrack]) -> PowerFreqNode {
        guard let units = snapshot?.disk?.units, !units.isEmpty else {
            return group(id: "ssd", title: "SSD", systemImage: "internaldrive", children: [
                staticLeaf(id: "ssd.none", title: "No Storage Devices", value: nil, isUnavailable: true),
            ])
        }
        let children = units.map { unit -> PowerFreqNode in
            group(id: "ssd.\(unit.id)", title: unit.mediaName ?? unit.id, children: [
                leaf(id: SensorID.diskActive(unit.id), title: "Activity", unit: .percent, tracks: tracks),
                group(id: "ssd.\(unit.id).throughput", title: "Throughput", systemImage: "arrow.up.arrow.down", children: [
                    leaf(id: SensorID.diskRead(unit.id), title: "Read", unit: .bytesPerSecond, tracks: tracks),
                    leaf(id: SensorID.diskWrite(unit.id), title: "Write", unit: .bytesPerSecond, tracks: tracks),
                ]),
                // No provider reads a per-disk temperature: `ThermalProvider`'s
                // discovered SMC sensors have no component attribution (see
                // `cpuTemperaturesNode`'s doc comment) so none can be
                // honestly claimed as "this SSD's" reading rather than a
                // guess.
                staticLeaf(id: "ssd.\(unit.id).temp", title: "Temperature", value: nil, isUnavailable: true),
            ])
        }
        return group(id: "ssd", title: "SSD", systemImage: "internaldrive", children: children)
    }

    // MARK: - Text-only leaves

    private static func powerSourceText(_ snapshot: Snapshot?) -> String? {
        switch snapshot?.energy?.powerSource {
        case .acPower: return "AC Power"
        case .batteryPower: return "Battery Power"
        case .unknown: return "Unknown"
        case nil: return nil
        }
    }

    private static func thermalPressureText(_ snapshot: Snapshot?) -> String? {
        guard let pressure = snapshot?.thermal?.thermalPressure else { return nil }
        switch pressure {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        case .unknown: return "Unknown"
        }
    }

    // MARK: - Node builders

    private static func group(id: String, title: String, systemImage: String? = nil, tint: Color? = nil, children: [PowerFreqNode]) -> PowerFreqNode {
        PowerFreqNode(id: id, title: title, systemImage: systemImage, tint: tint, children: children)
    }

    /// A tracked numeric sensor: `"Unavailable"` (dashed Min/Max) when
    /// nothing has been recorded under `id` yet — the domain's provider
    /// hasn't sampled a value for this sensor even once since tracking
    /// started, e.g. a `gpu.temperature` reading Apple's AGX driver simply
    /// never publishes — otherwise the current/min/max reading formatted
    /// per `unit`.
    private static func leaf(id: String, title: String, unit: SensorUnit, tracks: [String: SensorTrack]) -> PowerFreqNode {
        guard let track = tracks[id] else {
            return PowerFreqNode(id: id, title: title, value: "Unavailable", minValue: "—", maxValue: "—", isUnavailable: true)
        }
        return PowerFreqNode(
            id: id,
            title: title,
            value: unit.format(track.current),
            minValue: unit.format(track.min),
            maxValue: unit.format(track.max)
        )
    }

    /// A leaf with no running Min/Max — a fixed capacity/state reading
    /// (see `PowerFreqNode`'s own doc comment for why those get dashes
    /// instead of a tracked range). `value: nil` and `isUnavailable: true`
    /// are independent so a caller can either supply a genuine value or
    /// mark the row unavailable without also having a string on hand.
    private static func staticLeaf(id: String, title: String, value: String?, isUnavailable: Bool) -> PowerFreqNode {
        PowerFreqNode(id: id, title: title, value: value ?? "Unavailable", minValue: "—", maxValue: "—", isUnavailable: isUnavailable || value == nil)
    }
}

// MARK: - Formatting

/// Which physical unit a tracked sensor's raw `Double` is in, and how to
/// render one reading of it — this page's counterpart to
/// `PerformancePage`'s own private `Fmt` enum, scoped to only the units
/// this tree actually uses.
private enum SensorUnit {
    case percent
    case celsius
    case watts
    case bytesPerSecond
    case bytes

    func format(_ value: Double) -> String {
        switch self {
        case .percent: return String(format: "%.1f%%", value)
        case .celsius: return String(format: "%.1f°C", value)
        case .watts: return String(format: "%.2f W", value)
        case .bytesPerSecond: return Fmt.bytesPerSecond(value)
        case .bytes:
            let clamped = min(max(0, value), Double(UInt64.max))
            return Fmt.bytes(UInt64(clamped.rounded()))
        }
    }
}

private enum Fmt {
    static func bytesPerSecond(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func bytes(_ value: UInt64) -> String {
        let clamped = min(value, UInt64(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped))
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}

// MARK: - Preview

#Preview {
    PowerFreqPage()
        .frame(width: 760, height: 560)
}
