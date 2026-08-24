import Foundation

/// One leaf key/value reading inside a `SystemInfoFieldGroup`, e.g.
/// "Chip" → "Apple M4" in the Hardware Overview's key-value detail
/// (PLAN.md §1.1 "System Info ... Key/value detail pane"). `label` is
/// already humanized (see `SystemInfoProvider.humanizeKey(_:)`) — the raw
/// `system_profiler` key never reaches the UI.
struct SystemInfoEntry: Sendable, Equatable, Identifiable {
    let id: String
    let label: String
    let value: String

    init(label: String, value: String) {
        self.id = label
        self.label = label
        self.value = value
    }
}

/// One titled group of `SystemInfoEntry` fields inside a
/// `SystemInfoItem`'s detail — mirrors `DetailPaneSection`'s shape
/// exactly (see that type's doc comment: "Services' and System Info's own
/// key-value detail panes") so `SystemInfoPage` can hand these straight to
/// `DetailPane` with no reshaping. `"Overview"` carries an item's own
/// top-level scalar fields (e.g. a network interface's `interface`/`type`);
/// every other group is one nested `system_profiler` dictionary the item
/// carried (e.g. a network interface's `IPv4`/`IPv6`/`DNS` blocks), titled
/// after that dictionary's own humanized key — see
/// `SystemInfoProvider.systemInfoItem(from:categoryID:index:categorySystemImage:)`.
struct SystemInfoFieldGroup: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let fields: [SystemInfoEntry]
}

/// One row in a category's list — e.g. Hardware's single "Hardware
/// Overview" row, or one row per interface under Network ("Wi-Fi",
/// "Ethernet", "Thunderbolt Bridge", ...). `groups` is this item's whole
/// key-value detail, in display order.
struct SystemInfoItem: Sendable, Equatable, Identifiable {
    let id: String
    let name: String
    let systemImage: String
    let groups: [SystemInfoFieldGroup]
}

/// One of the catalog's three top-level sections — PLAN.md §4 M5's
/// `SystemInfoProvider` scope, "Hardware/Network/Software" (a deliberately
/// narrower set than §1.1's fuller [name removed] research inventory for this page,
/// which additionally splits Hardware into Memory/Audio/Bluetooth/Camera/
/// Graphics/etc. sub-panes and Software into Applications/Extensions/
/// Fonts/etc.; this app's own checklist item names exactly these three,
/// each backed by one `system_profiler` data type, so that's what ships
/// here — nothing about `SystemInfoCatalog`'s shape prevents a later
/// milestone from appending more `SystemInfoCategory` entries for the
/// finer [name removed] sub-panes without touching this provider's plumbing).
struct SystemInfoCategory: Sendable, Equatable, Identifiable {
    let id: String
    let title: String
    let systemImage: String
    let items: [SystemInfoItem]
}

/// One full `sample()`'s worth of catalog data — PLAN.md §3's
/// `SystemInfoProvider.swift # system_profiler -json (cached, Reload)`.
/// `generatedAt` backs the page's "as of HH:MM:SS" caption next to its
/// Reload button, the same role a cache-freshness timestamp plays for any
/// manually-refreshed (rather than ticking) data source in this app.
struct SystemInfoCatalog: Sendable, Equatable {
    let categories: [SystemInfoCategory]
    let generatedAt: Date
}

/// Failure modes for `SystemInfoProvider.sample()` — see `Provider`'s doc
/// comment for when a provider throws versus returning `nil`/empty fields.
/// Every case here is this domain's "entirely unreadable this tick" case
/// (the `system_profiler` process itself never ran or its output couldn't
/// be parsed at all); a single data type coming back empty or missing from
/// an otherwise-successful run is instead the honest "this category has no
/// items" state inside a normally-returned `SystemInfoCatalog` — see
/// `SystemInfoProvider.parseCatalog(from:)`.
enum SystemInfoProviderError: Error, LocalizedError {
    /// `Process.run()` itself threw, e.g. `/usr/sbin/system_profiler`
    /// doesn't exist on this system.
    case launchFailed(underlying: String)
    /// The process ran but exited non-zero.
    case nonZeroExit(status: Int32, stderr: String)
    /// Exit was clean but stdout wasn't a JSON object `system_profiler
    /// -json` is documented to produce — e.g. a future macOS changing the
    /// output format underneath this parser.
    case invalidJSON
    /// Exit was clean but stdout was empty.
    case noDataReturned

    var errorDescription: String? {
        switch self {
        case .launchFailed(let underlying):
            return "system_profiler failed to launch (\(underlying))"
        case .nonZeroExit(let status, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "system_profiler exited with status \(status)"
                : "system_profiler exited with status \(status): \(trimmed)"
        case .invalidJSON:
            return "system_profiler returned output that wasn't valid JSON"
        case .noDataReturned:
            return "system_profiler returned no data"
        }
    }
}

/// Samples the Hardware/Network/Software catalog via `system_profiler
/// -json` — PLAN.md §3 `Providers/SystemInfoProvider.swift "system_profiler
/// -json (cached, Reload)"` and §4 M5's first task.
///
/// Unlike every M2 domain provider (`CPUProvider`, `MemoryProvider`, ...),
/// this one is **not** wired into `Sampler`'s per-tick loop: `system_profiler`
/// takes on the order of one to a few seconds per invocation (it enumerates
/// live hardware/network state, not a cheap syscall), so sampling it twice
/// a second the way `Sampler` ticks would itself be the load PLAN.md §2
/// warns a monitor must never become. That's exactly why the architecture
/// note calls this one out as "cached, Reload" rather than folding it into
/// `Snapshot`: `SystemInfoPage` drives this provider directly (one call on
/// first appearance, another only when the user presses Reload), the same
/// on-demand-poll pattern `ProcessProvider` already established for a
/// still-`Provider`-conforming type `Sampler` never touches (see that
/// type's doc comment and `ProcessesPage.ProcessesViewModel`'s own poll
/// loop) — `providerID` here exists for the same reason theirs does:
/// consistency with every other domain's health-reporting key, even though
/// nothing currently reads `SystemInfoProvider.providerID` out of a
/// `Snapshot.providersHealth` map.
///
/// An `actor` so a page can safely call `sample()`/read `cachedCatalog`
/// from its own `Task` without extra locking, and so a Reload tap that
/// lands while a previous sample is still in flight is naturally
/// serialized rather than launching a second overlapping
/// `system_profiler` process.
actor SystemInfoProvider: Provider {
    static let providerID = "systemInfo"

    /// One `system_profiler -json` data type per catalog category, in the
    /// Hardware/Network/Software order PLAN.md names for this page. A
    /// single `system_profiler -json A B C` invocation fetches all three
    /// in one process launch (each data type's own array lands under its
    /// own top-level JSON key) rather than three separate calls, halving
    /// this already-slow provider's wall time versus calling it once per
    /// category.
    private static let dataTypeSpecs: [DataTypeSpec] = [
        DataTypeSpec(dataType: "SPHardwareDataType", categoryID: "hardware", categoryTitle: "Hardware", systemImage: "desktopcomputer"),
        DataTypeSpec(dataType: "SPNetworkDataType", categoryID: "network", categoryTitle: "Network", systemImage: "wifi"),
        DataTypeSpec(dataType: "SPSoftwareDataType", categoryID: "software", categoryTitle: "Software", systemImage: "macwindow"),
    ]

    private struct DataTypeSpec {
        let dataType: String
        let categoryID: String
        let categoryTitle: String
        let systemImage: String
    }

    /// The most recently successful `sample()`'s result — PLAN.md's
    /// "cached" half of "cached, Reload": a page can show the last-good
    /// catalog (with its own `generatedAt` "as of" timestamp) even while a
    /// fresh Reload is in flight, or after one fails, rather than blanking
    /// the whole page on a transient failure. `nil` only before this
    /// provider's first successful sample.
    private(set) var cachedCatalog: SystemInfoCatalog?

    /// Runs `system_profiler -json` for Hardware/Network/Software, parses
    /// the result into a `SystemInfoCatalog`, and updates `cachedCatalog`
    /// on success. Throws (leaving `cachedCatalog` untouched) when the
    /// process itself couldn't be run or its output couldn't be parsed at
    /// all — see `SystemInfoProviderError`.
    func sample() async throws -> SystemInfoCatalog {
        let data = try await Self.runSystemProfiler(dataTypes: Self.dataTypeSpecs.map(\.dataType))
        let catalog = try Self.parseCatalog(from: data)
        cachedCatalog = catalog
        return catalog
    }

    // MARK: - Process launch

    /// Hops off this actor's own executor to run `system_profiler`
    /// synchronously on a background dispatch queue, bridging the result
    /// back via a checked continuation. `Process`/`Pipe`'s blocking
    /// `readDataToEndOfFile()`/`waitUntilExit()` calls have no async
    /// variant, and calling them directly inside this `async func` would
    /// tie up one of the cooperative thread pool's limited threads for
    /// however long `system_profiler` takes (up to a few seconds) — this
    /// queue hop keeps that block off the pool entirely, the same reason
    /// `ProcessProvider.readRunningApplications` hops to the main actor
    /// rather than blocking wherever it's called from.
    private static func runSystemProfiler(dataTypes: [String]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try launchSynchronously(dataTypes: dataTypes))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Launches `/usr/sbin/system_profiler -json <dataTypes>`, fully reads
    /// stdout and stderr, and waits for exit — must only ever be called
    /// from the background queue `runSystemProfiler` dispatches onto, never
    /// from this actor's own executor (see that function's doc comment).
    private static func launchSynchronously(dataTypes: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json"] + dataTypes

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw SystemInfoProviderError.launchFailed(underlying: error.localizedDescription)
        }

        // Read both pipes to completion before `waitUntilExit()`: a large
        // enough stdout payload (this catalog's JSON can run past 64KB on
        // a Mac with several network interfaces) fills the pipe's kernel
        // buffer and deadlocks the child process against this parent if
        // the parent waits for exit before draining it.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderrText = String(data: stderrData, encoding: .utf8) ?? ""
            throw SystemInfoProviderError.nonZeroExit(status: process.terminationStatus, stderr: stderrText)
        }
        guard !stdoutData.isEmpty else {
            throw SystemInfoProviderError.noDataReturned
        }
        return stdoutData
    }

    // MARK: - JSON -> catalog

    /// Turns `system_profiler -json`'s root object into a
    /// `SystemInfoCatalog`, one `SystemInfoCategory` per `dataTypeSpecs`
    /// entry. A data type key missing from the root (or present but not an
    /// array of objects — e.g. a future macOS renaming a key this parser
    /// doesn't know yet) yields that one category with an honest empty
    /// `items` list rather than failing the whole catalog: PLAN.md's
    /// "honest degradation" rule applies at the per-category grain here,
    /// the same way an individual sensor reading degrades to `nil` inside
    /// an otherwise-successful `ThermalSnapshot`.
    private static func parseCatalog(from data: Data) throws -> SystemInfoCatalog {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SystemInfoProviderError.invalidJSON
        }

        let categories = dataTypeSpecs.map { spec -> SystemInfoCategory in
            let rawItems = (root[spec.dataType] as? [[String: Any]]) ?? []
            let items = rawItems.enumerated().map { index, rawItem in
                systemInfoItem(from: rawItem, categoryID: spec.categoryID, index: index, categorySystemImage: spec.systemImage)
            }
            return SystemInfoCategory(id: spec.categoryID, title: spec.categoryTitle, systemImage: spec.systemImage, items: items)
        }
        return SystemInfoCatalog(categories: categories, generatedAt: Date())
    }

    /// Builds one `SystemInfoItem` from one raw `system_profiler` object
    /// (one array element under a data type key — e.g. one network
    /// interface's dictionary). `_name` becomes the item's display name;
    /// every other key becomes either an `"Overview"` group field (scalar
    /// or array-of-scalar values) or its own nested group (dictionary
    /// values, e.g. a network interface's `IPv4`/`DNS` blocks) — see
    /// `appendField(label:value:overviewFields:nestedGroups:groupTitle:)`.
    private static func systemInfoItem(from rawItem: [String: Any], categoryID: String, index: Int, categorySystemImage: String) -> SystemInfoItem {
        let name = (rawItem["_name"] as? String).map(displayName(forRawName:)) ?? "Item \(index + 1)"

        var overviewFields: [SystemInfoEntry] = []
        var nestedGroups: [SystemInfoFieldGroup] = []
        for key in rawItem.keys.sorted() where key != "_name" {
            // Force-unwrap is safe here: `key` was just read from
            // `rawItem.keys`, so the lookup is guaranteed present — and
            // unwrapping (rather than `as Any`-coercing the `Any?`) avoids
            // boxing a nested `Optional` into `appendField`'s `Any`
            // parameter, which would make its `as?` pattern matches below
            // one Optional layer removed from what they expect.
            appendField(
                label: humanizeKey(key),
                value: rawItem[key]!,
                overviewFields: &overviewFields,
                nestedGroups: &nestedGroups,
                groupTitle: humanizeKey(key)
            )
        }

        var groups: [SystemInfoFieldGroup] = []
        if !overviewFields.isEmpty {
            groups.append(SystemInfoFieldGroup(id: "overview", title: "Overview", fields: overviewFields))
        }
        groups.append(contentsOf: nestedGroups)

        return SystemInfoItem(
            id: "\(categoryID).\(index).\(name)",
            name: name,
            systemImage: categorySystemImage,
            groups: groups
        )
    }

    /// Routes one raw `system_profiler` key/value pair into either
    /// `overviewFields` (a scalar, or an array of scalars joined with
    /// `", "`) or `nestedGroups` (a nested dictionary becomes its own
    /// titled group; an array of dictionaries becomes one group per
    /// element, numbered when there's more than one — e.g. multiple
    /// `Volumes` entries). Values this parser can't represent as text at
    /// all (an array mixing dictionaries and scalars, or an unexpected
    /// JSON type) are simply omitted rather than guessed at — the same
    /// "drop what can't be read honestly, don't fabricate" rule every
    /// other provider in this app follows.
    private static func appendField(
        label: String,
        value: Any,
        overviewFields: inout [SystemInfoEntry],
        nestedGroups: inout [SystemInfoFieldGroup],
        groupTitle: String
    ) {
        switch value {
        case let dict as [String: Any]:
            let entries = flatEntries(from: dict)
            if !entries.isEmpty {
                nestedGroups.append(SystemInfoFieldGroup(id: groupTitle, title: groupTitle, fields: entries))
            }
        case let array as [[String: Any]]:
            for (index, element) in array.enumerated() {
                let title = array.count > 1 ? "\(groupTitle) \(index + 1)" : groupTitle
                let entries = flatEntries(from: element)
                if !entries.isEmpty {
                    nestedGroups.append(SystemInfoFieldGroup(id: "\(groupTitle).\(index)", title: title, fields: entries))
                }
            }
        default:
            if let scalar = stringValue(value) {
                overviewFields.append(SystemInfoEntry(label: label, value: scalar))
            }
        }
    }

    /// One flat dictionary's own key/value pairs, each stringified via
    /// `stringValue(_:)` and sorted by (humanized) key for stable, scannable
    /// detail-pane ordering — shared by both branches of
    /// `appendField(label:value:overviewFields:nestedGroups:groupTitle:)`
    /// that flatten a nested dictionary.
    private static func flatEntries(from dict: [String: Any]) -> [SystemInfoEntry] {
        dict.keys.sorted().compactMap { key in
            guard let scalar = stringValue(dict[key]) else { return nil }
            return SystemInfoEntry(label: humanizeKey(key), value: scalar)
        }
    }

    /// Stringifies one JSON leaf value for display: a non-blank `String`
    /// as-is (trimmed); an `NSNumber` as "Yes"/"No" when it's really a JSON
    /// boolean (`system_profiler` mixes both conventions across data
    /// types) or its plain numeric description otherwise; an array of
    /// scalars joined with `", "` (e.g. `dns_nameserver_addresses`'s list
    /// of IPs). `nil` for a blank string, an empty array, or any value
    /// shape this parser doesn't know how to render as text (dictionaries
    /// and arrays-of-dictionaries are handled one level up in
    /// `appendField`, never reach here).
    private static func stringValue(_ raw: Any?) -> String? {
        switch raw {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue ? "Yes" : "No"
            }
            return number.stringValue
        case let array as [Any]:
            let parts = array.compactMap { stringValue($0) }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        default:
            return nil
        }
    }

    // MARK: - Key/name humanizing

    /// Common acronyms `system_profiler`'s snake_case keys spell out in
    /// lowercase (`os_version`, `ip_address`) that should render
    /// upper-case in the detail pane, matched case-insensitively against
    /// each underscore-delimited token in `humanizeKey(_:)`.
    private static let acronymOverrides: [String: String] = [
        "os": "OS", "id": "ID", "uuid": "UUID", "udid": "UDID", "cpu": "CPU",
        "gpu": "GPU", "ram": "RAM", "mac": "MAC", "ip": "IP", "dns": "DNS",
        "url": "URL", "smc": "SMC", "ane": "ANE", "ssid": "SSID",
        "bssid": "BSSID", "mtu": "MTU", "nat": "NAT", "vpn": "VPN",
        "wins": "WINS", "rom": "ROM", "ecid": "ECID",
    ]

    /// Best-effort raw `system_profiler` key → display label, e.g.
    /// `"chip_type"` → `"Chip Type"`, `"os_version"` → `"OS Version"`.
    /// Not guaranteed pretty for every key across every macOS version —
    /// worst case is a slightly awkward but still legible label sitting
    /// next to real data, never a wrong or fabricated value, which is the
    /// bar PLAN.md's "honest degradation" rule actually sets.
    static func humanizeKey(_ rawKey: String) -> String {
        var cleaned = rawKey
        while cleaned.hasPrefix("_") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else { return rawKey }

        let tokens = cleaned.split(separator: "_").map(String.init)
        let words = tokens.map { token -> String in
            if let override = acronymOverrides[token.lowercased()] {
                return override
            }
            // A token that already carries an uppercase letter (e.g.
            // "IPv4", or a raw key that was already readable) is left
            // alone rather than risk mangling something that already
            // reads fine.
            if token.contains(where: { $0.isUppercase }) {
                return token
            }
            return token.prefix(1).uppercased() + token.dropFirst()
        }
        return words.joined(separator: " ")
    }

    /// An item's `_name` value as shown in the master list: humanized only
    /// when it looks like a raw snake_case key (e.g. Hardware's
    /// `"hardware_overview"` → "Hardware Overview") — network interfaces'
    /// `_name` values (`"Wi-Fi"`, `"Thunderbolt Bridge"`) already read as
    /// proper display names straight from `system_profiler` and are passed
    /// through unchanged.
    static func displayName(forRawName rawName: String) -> String {
        guard rawName.contains("_") else { return rawName }
        return humanizeKey(rawName)
    }
}
