import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// PLAN.md §4 M10's fifth task: "Export: any table → CSV/JSON; one-click
/// system snapshot report." Two independent pieces live in this file:
///
/// - `TableExporter` + `ExportMenu<Value>`: turns any `DataTable`'s
///   `[DataTableColumn<Value>]`/`[Value]` pair — the same two things a
///   page already hands its `DataTable` — into CSV or JSON text and saves
///   it through a native `NSSavePanel`. Pure and generic, like `DataTable`
///   itself: it only knows how to serialize whatever columns/rows it's
///   given via each column's `exportValue` (see `DataTableColumn`'s own
///   doc comment), never anything about a specific page's data.
/// - `SnapshotReport` + `SnapshotReportButton`: a one-click, single-file
///   diagnostic report folding every domain in a `Snapshot` plus the top
///   CPU processes into one human-readable text file — this app's own
///   take on "About This Mac" / a support diagnostic dump. Lives here
///   rather than in `SummaryPage.swift` itself since, like the export
///   pieces above, none of its formatting logic is specific to how
///   `SummaryPage` lays itself out — `SummaryPage` only supplies the data.
///
/// Both pieces write straight to disk with no async work: PLAN.md's other
/// `NSSavePanel`/`NSOpenPanel` call sites (`DiskSpacePage.chooseFolder()`,
/// `BenchmarksPage`'s own folder picker) already run `panel.runModal()`
/// synchronously on the main actor the same way, and a CSV/JSON/text
/// string this size is negligible I/O next to that modal dialog itself.

// MARK: - Table → CSV/JSON

/// Serializes a `DataTable`'s exportable columns (`DataTableColumn.exportValue
/// != nil`) into CSV or JSON text. Free functions rather than anything
/// stateful — the same "pure data transform" shape `HistoryGraph`'s own
/// series-to-path math takes.
enum TableExporter {
    /// RFC 4180 field escaping: wrap in quotes and double any embedded
    /// quote whenever the field contains a comma, quote, or newline that
    /// would otherwise be misread as a field/row boundary.
    static func csvField(_ raw: String) -> String {
        guard raw.contains(",") || raw.contains("\"") || raw.contains("\n") else { return raw }
        return "\"" + raw.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Columns with no `exportValue` (icon-only, checkbox columns — see
    /// `DataTableColumn`'s doc comment) are silently dropped from the
    /// output rather than exported as blank fields.
    private static func exportableColumns<Value: Identifiable>(
        _ columns: [DataTableColumn<Value>]
    ) -> [(id: String, title: String, value: (Value) -> String)] {
        columns.compactMap { column in
            guard let exportValue = column.exportValue else { return nil }
            let title = column.title.isEmpty ? column.id : column.title
            return (column.id, title, exportValue)
        }
    }

    /// One header row of column titles, then one row per element of
    /// `rows`, each field escaped per `csvField(_:)`. Lines are joined
    /// with `\r\n` — the line ending RFC 4180 itself specifies, and what
    /// keeps a mixed-platform CSV reader from misparsing a field that
    /// happens to contain a bare `\n`.
    static func csv<Value: Identifiable>(columns: [DataTableColumn<Value>], rows: [Value]) -> String {
        let exportable = exportableColumns(columns)
        var lines = [exportable.map { csvField($0.title) }.joined(separator: ",")]
        lines.append(contentsOf: rows.map { row in
            exportable.map { csvField($0.value(row)) }.joined(separator: ",")
        })
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// One JSON object per row, keyed by each exportable column's stable
    /// `id` (not its display `title`, which can be empty or change with
    /// localization) — an array of flat `{"pid": "1421", "name": "Safari", ...}`
    /// objects, the shape most downstream tools (`jq`, a spreadsheet
    /// import, a quick script) expect from a table dump.
    static func json<Value: Identifiable>(columns: [DataTableColumn<Value>], rows: [Value]) -> String {
        let exportable = exportableColumns(columns)
        let objects: [[String: String]] = rows.map { row in
            var object: [String: String] = [:]
            for column in exportable {
                object[column.id] = column.value(row)
            }
            return object
        }
        guard
            let data = try? JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]),
            let text = String(data: data, encoding: .utf8)
        else {
            return "[]"
        }
        return text
    }

    /// Whether at least one column in `columns` actually has an
    /// `exportValue` — `ExportMenu` disables itself when this is `false`
    /// rather than offering a save dialog that would only ever write an
    /// empty file.
    static func hasExportableColumns<Value: Identifiable>(_ columns: [DataTableColumn<Value>]) -> Bool {
        columns.contains { $0.exportValue != nil }
    }
}

/// Toolbar control for exporting one `DataTable`'s current `columns`/`rows`
/// — a `Menu` offering "Export as CSV…" / "Export as JSON…", each opening
/// a native save panel and writing the chosen format. Drop straight into a
/// page's `.toolbar { ToolbarItem(placement: .primaryAction) { ExportMenu(...) } }`
/// alongside that page's `DataTable` call, passing the same `columns`/`rows`
/// already handed to it — exports exactly what's currently on screen
/// (post-filter, post-search), not some separate unfiltered copy.
struct ExportMenu<Value: Identifiable>: View {
    let columns: [DataTableColumn<Value>]
    let rows: [Value]
    /// Base file name offered in the save panel (no extension) — e.g.
    /// "Startup Items", "Top CPU Processes". Also becomes this control's
    /// help text and save-panel title.
    var suggestedName: String

    @State private var saveErrorMessage: String?

    var body: some View {
        Menu {
            Button("Export as CSV\u{2026}") { save(format: .csv) }
            Button("Export as JSON\u{2026}") { save(format: .json) }
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .disabled(rows.isEmpty || !TableExporter.hasExportableColumns(columns))
        .help(rows.isEmpty ? "No rows to export." : "Export \(suggestedName) to CSV or JSON.")
        .alert(
            "Couldn\u{2019}t Save Export",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } }
            ),
            presenting: saveErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private enum Format: Equatable {
        case csv, json

        var fileExtension: String { self == .csv ? "csv" : "json" }
        var contentType: UTType { self == .csv ? .commaSeparatedText : .json }
    }

    private func save(format: Format) {
        let panel = NSSavePanel()
        panel.title = "Export \(suggestedName)"
        panel.nameFieldStringValue = "\(sanitizedFileName) Export.\(format.fileExtension)"
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = format == .csv
            ? TableExporter.csv(columns: columns, rows: rows)
            : TableExporter.json(columns: columns, rows: rows)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    /// `suggestedName` with path-hostile characters stripped, so a caller
    /// can pass a title straight off its page ("Scan History", "Top CPU
    /// Processes") without separately worrying about `NSSavePanel`'s
    /// default file name.
    private var sanitizedFileName: String {
        let disallowed = CharacterSet(charactersIn: "/:\\")
        return suggestedName.components(separatedBy: disallowed).joined(separator: "-")
    }
}

// MARK: - One-click system snapshot report

/// Builds a single human-readable text report from a `Snapshot` — every
/// domain PLAN.md §3 lists (`cpu`/`memory`/`gpu`/`disk`/`network`/`energy`/
/// `thermal`/`npu`) plus the live top-CPU process list — the "About This
/// Mac"-style diagnostic dump PLAN.md §4 M10's "one-click system snapshot
/// report" calls for. A missing domain (a `nil` field, or the whole
/// `Snapshot` payload for a provider that hasn't sampled successfully) is
/// always written as "Unavailable", never guessed or silently omitted —
/// the same honest-degradation rule every provider itself already follows
/// (PLAN.md §2/§3).
enum SnapshotReport {
    static func text(
        snapshot: Snapshot?,
        topProcesses: [TopProcessReading],
        liveProcessCount: Int
    ) -> String {
        var lines = [
            "IDOTaskMaster \u{2014} System Snapshot Report",
            "Generated \(dateFormatter.string(from: Date()))",
            String(repeating: "=", count: 64),
        ]

        guard let snapshot else {
            lines.append("")
            lines.append("No data has been sampled yet \u{2014} give the Summary page a moment to collect a reading, then try again.")
            return lines.joined(separator: "\n")
        }

        lines.append("")
        lines.append("Snapshot generation #\(snapshot.generation) \u{2014} sampled \(dateFormatter.string(from: snapshot.timestamp))")
        lines.append("Live process count: \(liveProcessCount > 0 ? "\(liveProcessCount)" : "Unavailable")")
        lines.append("Providers reporting: \(snapshot.providersHealth.count) total, \(snapshot.degradedProviderCount) degraded")
        for (providerID, health) in snapshot.providersHealth.sorted(by: { $0.key < $1.key }) {
            if case .degraded(let reason) = health {
                lines.append("  \u{2022} \(providerID): \(reason)")
            }
        }

        appendSection(&lines, "CPU", cpuLines(snapshot.cpu))
        appendSection(&lines, "Memory", memoryLines(snapshot.memory))
        appendSection(&lines, "GPU", gpuLines(snapshot.gpu))
        appendSection(&lines, "Disk", diskLines(snapshot.disk))
        appendSection(&lines, "Network", networkLines(snapshot.network))
        appendSection(&lines, "Energy", energyLines(snapshot.energy))
        appendSection(&lines, "Thermal", thermalLines(snapshot.thermal))
        appendSection(&lines, "NPU (Neural Engine)", npuLines(snapshot.npu))
        appendSection(&lines, "Top Processes by CPU %", topProcessLines(topProcesses))

        return lines.joined(separator: "\n")
    }

    private static func appendSection(_ lines: inout [String], _ title: String, _ body: [String]) {
        lines.append("")
        lines.append(title)
        lines.append(String(repeating: "-", count: title.count))
        lines.append(contentsOf: body)
    }

    private static func cpuLines(_ cpu: CPUSnapshot?) -> [String] {
        guard let cpu else { return ["Unavailable"] }
        var lines = [
            "Total utilization: \(Fmt.percent(cpu.totalUtilization))",
            "User / System / Idle: \(Fmt.percent(cpu.userUtilization)) / \(Fmt.percent(cpu.systemUtilization)) / \(Fmt.percent(cpu.idleUtilization))",
            "Logical cores reporting: \(cpu.perCoreUtilization.count)",
            "Uptime: \(Fmt.duration(cpu.uptime))",
            "Processor: \(Fmt.string(cpu.topology.brandString))",
            "Logical / Physical cores: \(Fmt.int(cpu.topology.logicalCoreCount)) / \(Fmt.int(cpu.topology.physicalCoreCount))",
        ]
        if cpu.topology.performanceCoreCount != nil || cpu.topology.efficiencyCoreCount != nil {
            lines.append("Performance / Efficiency cores: \(Fmt.int(cpu.topology.performanceCoreCount)) / \(Fmt.int(cpu.topology.efficiencyCoreCount))")
        }
        lines.append("Packages: \(Fmt.int(cpu.topology.packageCount))")
        return lines
    }

    private static func memoryLines(_ memory: MemorySnapshot?) -> [String] {
        guard let memory else { return ["Unavailable"] }
        var lines = [
            "Total: \(Fmt.bytesOptional(memory.totalBytes))",
            "Used: \(Fmt.bytesOptional(memory.usedBytes))",
            "Available: \(Fmt.bytes(memory.availableBytes))",
            "Free / Cached: \(Fmt.bytes(memory.freeBytes)) / \(Fmt.bytes(memory.cachedBytes))",
            "Active / Inactive / Wired: \(Fmt.bytes(memory.activeBytes)) / \(Fmt.bytes(memory.inactiveBytes)) / \(Fmt.bytes(memory.wiredBytes))",
            "Compressed / Purgeable: \(Fmt.bytes(memory.compressedBytes)) / \(Fmt.bytes(memory.purgeableBytes))",
        ]
        if memory.swapTotalBytes != nil || memory.swapUsedBytes != nil {
            lines.append("Swap used / total: \(Fmt.bytesOptional(memory.swapUsedBytes)) / \(Fmt.bytesOptional(memory.swapTotalBytes))")
        }
        lines.append("Pressure: \(memoryPressureLabel(memory.pressureLevel))")
        return lines
    }

    private static func memoryPressureLabel(_ level: MemoryPressureLevel?) -> String {
        switch level {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        case nil: return "Unavailable"
        }
    }

    private static func gpuLines(_ gpu: GPUSnapshot?) -> [String] {
        guard let gpu else { return ["Unavailable"] }
        return [
            "Device: \(gpu.deviceClassName)",
            "Utilization: \(Fmt.percent(gpu.utilizationPercent))",
            "Renderer / Tiler: \(Fmt.percent(gpu.rendererUtilizationPercent)) / \(Fmt.percent(gpu.tilerUtilizationPercent))",
            "Memory in use / allocated: \(Fmt.bytesOptional(gpu.vramUsedBytes)) / \(Fmt.bytesOptional(gpu.vramAllocatedBytes))",
            "Dedicated VRAM total: \(Fmt.bytesOptional(gpu.vramTotalBytes))",
            "Temperature: \(Fmt.celsius(gpu.temperatureCelsius))",
        ]
    }

    private static func diskLines(_ disk: DiskSnapshot?) -> [String] {
        guard let disk else { return ["Unavailable"] }
        var lines = [
            "Active: \(Fmt.percent(disk.activePercent))",
            "Read / Write rate: \(Fmt.bytesPerSecond(disk.readBytesPerSecond)) / \(Fmt.bytesPerSecond(disk.writeBytesPerSecond))",
            "Total read / written since boot: \(Fmt.bytes(disk.totalBytesRead)) / \(Fmt.bytes(disk.totalBytesWritten))",
            "Devices detected: \(disk.units.count)",
        ]
        for volume in disk.volumes {
            let name = volume.volumeName ?? volume.id
            let flag = volume.isSystemVolume ? " (System)" : ""
            lines.append("  \u{2022} \(name)\(flag): \(Fmt.bytesOptional(volume.availableBytes)) free of \(Fmt.bytesOptional(volume.totalBytes))")
        }
        return lines
    }

    private static func networkLines(_ network: NetworkSnapshot?) -> [String] {
        guard let network else { return ["Unavailable"] }
        var lines = [
            "Send / Receive rate: \(Fmt.bytesPerSecond(network.sendBytesPerSecond)) / \(Fmt.bytesPerSecond(network.receiveBytesPerSecond))",
            "Total sent / received since boot: \(Fmt.bytes(network.totalBytesSent)) / \(Fmt.bytes(network.totalBytesReceived))",
        ]
        for interface in network.interfaces where interface.isUp && !interface.isLoopback {
            lines.append("  \u{2022} \(interface.id): \(Fmt.bytesPerSecond(interface.sendBytesPerSecond)) up / \(Fmt.bytesPerSecond(interface.receiveBytesPerSecond)) down")
        }
        return lines
    }

    private static func energyLines(_ energy: EnergySnapshot?) -> [String] {
        guard let energy else { return ["Unavailable"] }
        var lines = [
            "System power draw: \(Fmt.watts(energy.systemPowerWatts))",
            "Adapter / Battery power: \(Fmt.watts(energy.adapterPowerWatts)) / \(Fmt.watts(energy.batteryPowerWatts))",
            "Power source: \(powerSourceLabel(energy.powerSource))",
            "Low Power Mode: \(energy.isLowPowerModeEnabled ? "On" : "Off")",
        ]
        if let battery = energy.battery {
            lines.append("Battery: \(Fmt.percent(battery.percent)), \(Fmt.bool(battery.isCharging)) charging, \(Fmt.bool(battery.isCharged)) charged")
            lines.append("Cycle count: \(Fmt.int(battery.cycleCount)) \u{2014} condition: \(Fmt.string(battery.condition))")
        } else {
            lines.append("Battery: none (this Mac has no battery)")
        }
        return lines
    }

    private static func powerSourceLabel(_ source: EnergyPowerSource) -> String {
        switch source {
        case .acPower: return "AC Power"
        case .batteryPower: return "Battery"
        case .unknown: return "Unknown"
        }
    }

    private static func thermalLines(_ thermal: ThermalSnapshot?) -> [String] {
        guard let thermal else { return ["Unavailable"] }
        return [
            "Hotspot: \(Fmt.celsius(thermal.hotspotCelsius))",
            "Thermal pressure: \(thermal.thermalPressure.rawValue.capitalized)",
            "Sensors reporting: \(thermal.dieSensors.count)",
        ]
    }

    private static func npuLines(_ npu: NPUSnapshot?) -> [String] {
        guard let npu else { return ["Unavailable"] }
        guard npu.devicePresent else { return ["Not present on this Mac"] }
        var lines = [
            "Device: \(Fmt.string(npu.deviceName))",
            "Active since last sample: \(Fmt.bool(npu.isActive))",
        ]
        if let reason = npu.unavailableReason {
            lines.append("Note: \(reason)")
        }
        return lines
    }

    private static func topProcessLines(_ processes: [TopProcessReading]) -> [String] {
        guard !processes.isEmpty else { return ["Unavailable"] }
        return processes.map { process in
            let cpu = process.cpuPercent.map { String(format: "%5.1f%%", $0) } ?? "  n/a"
            let name = process.name ?? "Unavailable"
            return "  \(cpu)  \(Fmt.bytesOptional(process.memoryBytes))  \(name) (pid \(process.pid))"
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}

/// One-click toolbar button: click, choose a save location in the panel
/// that opens, and the full `SnapshotReport.text(...)` for whatever
/// `Snapshot` is passed in is written there — no intermediate format
/// picker or configuration step, matching PLAN.md's own "one-click"
/// phrasing for this feature. Lives on `SummaryPage`'s toolbar (PLAN.md
/// §1.1 "Summary (dashboard)"): that's the one page whose view model
/// already keeps a full cross-domain `Snapshot` plus the top-processes
/// list this report also folds in, rather than one single domain.
struct SnapshotReportButton: View {
    let snapshot: Snapshot?
    let topProcesses: [TopProcessReading]
    let liveProcessCount: Int

    @State private var saveErrorMessage: String?

    var body: some View {
        Button {
            save()
        } label: {
            Label("Snapshot Report\u{2026}", systemImage: "doc.text")
        }
        .help("Save a one-click system snapshot report — every metric domain\u{2019}s latest reading, in one text file.")
        .alert(
            "Couldn\u{2019}t Save Snapshot Report",
            isPresented: Binding(
                get: { saveErrorMessage != nil },
                set: { isPresented in if !isPresented { saveErrorMessage = nil } }
            ),
            presenting: saveErrorMessage
        ) { _ in
            Button("OK") {}
        } message: { message in
            Text(message)
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.title = "Save System Snapshot Report"
        panel.nameFieldStringValue = "IDOTaskMaster Snapshot \(Self.fileNameDateFormatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = SnapshotReport.text(snapshot: snapshot, topProcesses: topProcesses, liveProcessCount: liveProcessCount)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }

    private static let fileNameDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return formatter
    }()
}

// MARK: - Shared "Unavailable"-honest formatting

/// `SnapshotReport`'s own formatting helpers — deliberately separate from
/// every page's own file-private `Fmt` enum (`SummaryPage.swift`,
/// `PerformancePage.swift`, ...): those read for a specific card's cell
/// (some prefer a bare "\u{2014}" for "no value"), while a standalone
/// report file reads better spelling "Unavailable" out in full, matching
/// `DetailPane`'s own convention for the same reason.
private enum Fmt {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f%%", value)
    }

    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f\u{00B0}C", value)
    }

    static func watts(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "Unavailable" }
        return String(format: "%.1f W", value)
    }

    static func bytes(_ value: UInt64) -> String {
        bytesFormatter.string(fromByteCount: Int64(clamping: value))
    }

    static func bytesOptional(_ value: UInt64?) -> String {
        guard let value else { return "Unavailable" }
        return bytes(value)
    }

    static func bytesPerSecond(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "Unavailable" }
        let clamped = min(value, Double(Int64.max))
        return bytesFormatter.string(fromByteCount: Int64(clamped.rounded())) + "/s"
    }

    static func int(_ value: Int?) -> String {
        value.map { "\($0)" } ?? "Unavailable"
    }

    static func string(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "Unavailable" }
        return value
    }

    static func bool(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? "Unavailable"
    }

    static func duration(_ value: TimeInterval) -> String {
        guard value.isFinite, value >= 0 else { return "Unavailable" }
        let totalSeconds = Int(value)
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let bytesFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()
}
