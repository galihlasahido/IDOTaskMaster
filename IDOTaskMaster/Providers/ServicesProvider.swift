import Darwin
import Foundation

/// Which `launchctl print` domain a `ServiceItem` was listed under — PLAN.md
/// §3's `Providers/ServicesProvider.swift "launchctl print system/user"`.
/// Unlike `StartupItemDomain`'s five on-disk directories (`StartupProvider`
/// scans plists at rest), this only has the two live domains `launchctl
/// print` can list without root privileges this unprivileged, no-sudo-helper
/// app doesn't have (PLAN.md §3's "Permissions note"): the machine-wide
/// `system` domain (every LaunchDaemon, regardless of which of the two
/// LaunchDaemons directories defined it) and this user's own `gui/<uid>`
/// session domain (every LaunchAgent loaded into it, regardless of which of
/// the three LaunchAgents directories defined it, or whether it has an
/// on-disk plist at all — e.g. XPC services launchd creates ad hoc).
enum ServiceRuntimeDomain: String, Sendable {
    case system
    case userAgent

    var displayName: String {
        switch self {
        case .system: return "System"
        case .userAgent: return "User"
        }
    }

    /// `launchctl print`'s own domain-target spelling for this case.
    func launchctlTarget(uid: uid_t) -> String {
        switch self {
        case .system: return "system"
        case .userAgent: return "gui/\(uid)"
        }
    }
}

/// One `launchctl print`-listed job plus, when a matching on-disk plist
/// could be found, its program path — PLAN.md §1.1's "Services" table row:
/// "Running checkbox, Name, Description/path, Group" and this app's own
/// detail-pane inspector.
struct ServiceItem: Sendable, Equatable, Identifiable {
    /// `launchctl` job labels are only guaranteed unique *within* one
    /// domain, not across both `system` and `gui/<uid>` — this app has
    /// never observed a real collision, but the id still folds in
    /// `runtimeDomain` rather than assume one never happens.
    var id: String { "\(runtimeDomain.rawValue):\(label)" }

    let label: String
    let runtimeDomain: ServiceRuntimeDomain
    /// From `launchctl print`'s services block: `true` when this job has a
    /// live PID right now, `false` when it's a known-but-currently-stopped
    /// job (its row still appears in the listing with a `-` PID column) —
    /// this is a live read every `sample()`, never `nil`/"Unavailable",
    /// since `launchctl print` reported this job at all.
    let isRunning: Bool
    let pid: Int32?
    /// The job's last exit status as `launchctl print` reports it, or `nil`
    /// when that column couldn't be parsed for this row.
    let lastExitStatus: Int32?
    /// Best-effort cross-reference against a LaunchAgents/LaunchDaemons
    /// plist whose `Label` matches — `nil` for jobs `launchctl print` knows
    /// about but that have no on-disk plist (mach services, XPC services,
    /// jobs `launchctl bootstrap`ed ad hoc), which is a perfectly normal,
    /// honest outcome, not a failure.
    let plistPath: String?
    let programPath: String?
    /// `true` when the plist location is under `/System/Library/...`, or
    /// (absent a located plist) the label itself looks like one of Apple's
    /// own (`com.apple.*`) — a best-effort "Group" classification, per
    /// this type's own doc comment; never authoritative, so the detail
    /// pane never claims otherwise.
    let isAppleService: Bool

    /// The table's "Group" column and the detail pane's own grouping
    /// summary: which domain this job runs in, crossed with the
    /// Apple/third-party split — e.g. "System · Apple",
    /// "User · Third-Party".
    var group: String {
        "\(runtimeDomain.displayName) \u{00B7} \(isAppleService ? "Apple" : "Third-Party")"
    }
}

/// One full `sample()`'s worth of service data — mirrors `StartupCatalog`'s
/// "cached, page-driven reload" shape; see `ServicesProvider`'s own doc
/// comment for why this domain isn't wired into `Sampler`'s per-tick loop
/// either.
struct ServicesCatalog: Sendable, Equatable {
    let items: [ServiceItem]
    let generatedAt: Date
}

/// Failure mode for `ServicesProvider.sample()` — PLAN.md's "honest
/// degradation": thrown only when `launchctl print` produced nothing usable
/// for *either* domain; a single domain failing (e.g. `system` refused for
/// some sandboxing reason while `gui/<uid>` still answers) instead degrades
/// to "just that domain's jobs are missing from an otherwise-successful
/// result," the same per-source grain `StartupProvider`'s own directory scan
/// uses for an unreadable directory.
enum ServicesProviderError: Error, LocalizedError {
    case launchctlUnavailable

    var errorDescription: String? {
        switch self {
        case .launchctlUnavailable:
            return "launchctl print returned no data for the system or user domain"
        }
    }
}

/// Lists every job `launchctl print` currently knows about in the system
/// and user domains, cross-referenced against on-disk LaunchAgents/
/// LaunchDaemons plists for a program path — PLAN.md §3's `Providers/
/// ServicesProvider.swift "launchctl print system/user"` and §4 M5's third
/// task: "Services page: `launchctl print` listing, running state, filter,
/// detail pane."
///
/// An `actor`, and driven by its page exactly like `StartupProvider` and
/// `SystemInfoProvider` (load-once-then-Reload, not a `Sampler` tick): two
/// `launchctl print` shell-outs plus a five-directory plist scan are, like
/// those two siblings' own I/O, an order of magnitude slower than any
/// syscall-backed M2 domain provider — sampling that twice a second would
/// itself be the load PLAN.md §2 warns a monitor must never become.
///
/// Deliberately independent of `StartupProvider` rather than built on top
/// of its `StartupCatalog`: `launchctl print`'s services block is the
/// authoritative *live* job listing (it includes jobs with no on-disk plist
/// at all), where `StartupProvider`'s directory scan is the authoritative
/// *configured* listing (it includes disabled jobs `launchctl print` may
/// omit) — the two pages answer different questions per PLAN.md §1.1's own
/// separate "Startup apps" and "Services" sections, so this provider does
/// its own minimal plist scan (label → program path only, none of
/// `StartupProvider`'s enabled-override/toggle plumbing) purely for the
/// "Description/path" column rather than reusing that provider's richer,
/// differently-scoped result.
actor ServicesProvider: Provider {
    static let providerID = "services"

    private(set) var cachedCatalog: ServicesCatalog?

    func sample() async throws -> ServicesCatalog {
        let catalog = try await Self.scan()
        cachedCatalog = catalog
        return catalog
    }

    // MARK: - Scan

    /// Hops to a background queue the same way `StartupProvider.scan()`
    /// does, for the same reason: two blocking `launchctl` invocations plus
    /// filesystem enumeration have no async variant, and running them
    /// directly on this actor's executor would tie up a cooperative-pool
    /// thread for however long they take.
    private static func scan() async throws -> ServicesCatalog {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try scanSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Must only ever run on the background queue `scan()` dispatches onto.
    private static func scanSynchronously() throws -> ServicesCatalog {
        let uid = getuid()
        let systemOutput = runLaunchctl(["print", ServiceRuntimeDomain.system.launchctlTarget(uid: uid)])
        let userOutput = runLaunchctl(["print", ServiceRuntimeDomain.userAgent.launchctlTarget(uid: uid)])

        // Only "neither domain answered at all" degrades to a thrown
        // error, per this file's own `ServicesProviderError` doc comment.
        guard systemOutput != nil || userOutput != nil else {
            throw ServicesProviderError.launchctlUnavailable
        }

        let index = plistIndex()

        var items: [ServiceItem] = []
        if let systemOutput {
            items += parseServicesBlock(from: systemOutput).map { entry in
                makeItem(from: entry, domain: .system, index: index)
            }
        }
        if let userOutput {
            items += parseServicesBlock(from: userOutput).map { entry in
                makeItem(from: entry, domain: .userAgent, index: index)
            }
        }
        items.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }

        return ServicesCatalog(items: items, generatedAt: Date())
    }

    private static func makeItem(
        from entry: ParsedServiceEntry,
        domain: ServiceRuntimeDomain,
        index: [String: PlistIndexEntry]
    ) -> ServiceItem {
        let plist = index[entry.label]
        let isApple = plist?.isAppleLocation ?? entry.label.hasPrefix("com.apple.")
        return ServiceItem(
            label: entry.label,
            runtimeDomain: domain,
            isRunning: entry.pid != nil,
            pid: entry.pid,
            lastExitStatus: entry.lastExitStatus,
            plistPath: plist?.path,
            programPath: plist?.programPath,
            isAppleService: isApple
        )
    }

    // MARK: - `launchctl print` parsing

    private struct ParsedServiceEntry {
        let pid: Int32?
        let lastExitStatus: Int32?
        let label: String
    }

    /// Parses the `services = { ... }` block out of one `launchctl print`
    /// invocation's stdout — each line inside reads `<pid-or-dash>
    /// <last-exit-status> <label>` (the same three columns `launchctl
    /// list` prints, just indented inside this block rather than given a
    /// header row). Lenient about the exact whitespace between columns
    /// (observed as both tabs and runs of spaces across macOS releases,
    /// the same lesson `StartupProvider.enabledOverrides(domainTarget:)`
    /// already draws from `print-disabled`'s own equally-informal format)
    /// and stops at the block's closing brace rather than reading past it
    /// into unrelated `print` output that follows.
    private static func parseServicesBlock(from output: String) -> [ParsedServiceEntry] {
        guard let marker = output.range(of: "services = {") else { return [] }
        var entries: [ParsedServiceEntry] = []
        for rawLine in output[marker.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed == "}" { break }
            guard !trimmed.isEmpty else { continue }
            let fields = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3 else { continue }
            let label = fields[2...].joined(separator: " ")
            guard !label.isEmpty else { continue }
            entries.append(ParsedServiceEntry(
                pid: Int32(fields[0]),
                lastExitStatus: Int32(fields[1]),
                label: label
            ))
        }
        return entries
    }

    /// Synchronously runs `/bin/launchctl <arguments>` and returns stdout as
    /// UTF-8 text, or `nil` if the process couldn't launch or exited
    /// non-zero — matching `StartupProvider.runLaunchctl(_:)`. Must only
    /// ever be called from the background queue `scan()` dispatches onto.
    private static func runLaunchctl(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Plist cross-reference

    private struct PlistIndexEntry {
        let path: String
        let programPath: String?
        let isAppleLocation: Bool
    }

    /// Scans every LaunchAgents/LaunchDaemons directory macOS defines —
    /// the same five directories `StartupProvider.directorySpecs()` scans —
    /// but reads only `Label` and `Program`/`ProgramArguments`, since this
    /// provider's plist scan exists purely to fill in "Description/path"
    /// for a job `launchctl print` already told us about, not to duplicate
    /// `StartupProvider`'s own richer configured-item catalog (see this
    /// type's own doc comment). An unreadable directory (permissions,
    /// sandboxing) or unparseable plist is silently skipped, the same
    /// per-item degradation grain `StartupProvider.startupItem` uses —
    /// this index is best-effort by nature, and a label missing from it
    /// just means `ServiceItem.plistPath`/`programPath` stay `nil`.
    private static func plistIndex() -> [String: PlistIndexEntry] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let directories: [(path: String, isApple: Bool)] = [
            ("\(home)/Library/LaunchAgents", false),
            ("/Library/LaunchAgents", false),
            ("/Library/LaunchDaemons", false),
            ("/System/Library/LaunchAgents", true),
            ("/System/Library/LaunchDaemons", true),
        ]

        let fileManager = FileManager.default
        var index: [String: PlistIndexEntry] = [:]
        for directory in directories {
            guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names where name.hasSuffix(".plist") {
                let path = "\(directory.path)/\(name)"
                guard
                    let data = fileManager.contents(atPath: path),
                    let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                    let label = (plist["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !label.isEmpty
                else { continue }
                let programArguments = (plist["ProgramArguments"] as? [String]) ?? []
                let programPath = (plist["Program"] as? String) ?? programArguments.first
                index[label] = PlistIndexEntry(path: path, programPath: programPath, isAppleLocation: directory.isApple)
            }
        }
        return index
    }
}
