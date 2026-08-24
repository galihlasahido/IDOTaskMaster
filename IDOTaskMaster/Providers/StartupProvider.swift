import Darwin
import Foundation

/// Which of the five plist directories `StartupProvider` scans a
/// `StartupItem` came from — PLAN.md §1.1's "Table of launch agents/
/// daemons" spans both LaunchAgents (run in a login session) and
/// LaunchDaemons (run as root, no session), each split further into
/// Apple's own (`/System/Library/...`), machine-wide third-party
/// (`/Library/...`), and — agents only — this one user's own
/// (`~/Library/LaunchAgents`).
///
/// Only `.userAgent` is toggleable from this app (§4 M5's "enable/disable
/// toggle (user domain only)"): it's the one domain this unprivileged,
/// no-sudo-helper app (PLAN.md §3's "Permissions note") can both read and
/// write without elevated privileges — `launchctl enable/disable
/// gui/<uid>/<label>` needs no special entitlement for a job in the
/// caller's own per-user GUI domain, while every other domain either needs
/// root (LaunchDaemons' `system` domain) or affects every user on the
/// machine (`/Library/LaunchAgents`, loaded into *every* logged-in user's
/// `gui/<uid>` domain, not just this one).
enum StartupItemDomain: String, Sendable, CaseIterable {
    case userAgent
    case globalAgent
    case globalDaemon
    case systemAgent
    case systemDaemon

    var displayName: String {
        switch self {
        case .userAgent: return "User Agent"
        case .globalAgent: return "Global Agent"
        case .globalDaemon: return "Global Daemon"
        case .systemAgent: return "System Agent"
        case .systemDaemon: return "System Daemon"
        }
    }

    var systemImage: String {
        switch self {
        case .userAgent: return "person.crop.circle"
        case .globalAgent: return "person.2.circle"
        case .globalDaemon: return "gearshape.2"
        case .systemAgent: return "applelogo"
        case .systemDaemon: return "lock.shield"
        }
    }

    /// Only a user-domain agent — this app's own login-session job — can be
    /// toggled without privileges it doesn't have. See this type's own doc
    /// comment.
    var isUserToggleable: Bool { self == .userAgent }

    /// `launchctl`'s domain-target prefix for `print-disabled`/`enable`/
    /// `disable` (e.g. `"gui/501"`, `"system"`) — every LaunchAgents
    /// directory loads into the per-user GUI domain (`gui/<uid>`); every
    /// LaunchDaemons directory loads into the root `system` domain,
    /// regardless of which of the three agent/daemon directories a given
    /// plist happened to be found in.
    func launchctlDomainTarget(uid: uid_t) -> String {
        usesGUIDomain ? "gui/\(uid)" : "system"
    }

    /// Whether this domain's jobs load into the per-user GUI domain
    /// (`gui/<uid>`, every LaunchAgents directory) rather than the root
    /// `system` domain (every LaunchDaemons directory) — the split
    /// `launchctlDomainTarget(uid:)` and `StartupProvider.startupItem`'s
    /// override lookup both key off.
    var usesGUIDomain: Bool {
        switch self {
        case .userAgent, .globalAgent, .systemAgent: return true
        case .globalDaemon, .systemDaemon: return false
        }
    }
}

/// One parsed `LaunchAgents`/`LaunchDaemons` plist plus its live
/// `launchctl` state — PLAN.md §1.1's "Startup apps" table row and detail
/// pane: "identity, publisher, status, running state, file size/dates,
/// owner, permissions."
struct StartupItem: Sendable, Equatable, Identifiable {
    /// The plist's own filesystem path — stable and unique across every
    /// scanned directory, so it doubles as `id` (two different jobs can
    /// share a `Label`, e.g. a stray duplicate copy, but never a path).
    var id: String { plistPath }

    let plistPath: String
    let domain: StartupItemDomain
    /// The plist's `Label` key — launchd's own stable identity for this
    /// job, and what `launchctl enable/disable`/`print-disabled` key
    /// against. Falls back to the plist's filename (minus `.plist`) on the
    /// rare malformed plist with no `Label` key, so a row still has a
    /// sensible name — but such an item is never toggleable (there's no
    /// real launchd label to target) and its `launchctlLabel` is `nil`.
    let displayName: String
    /// `nil` when the plist had no `Label` string — see `displayName`'s
    /// doc comment.
    let launchctlLabel: String?
    /// `Program`, or the first element of `ProgramArguments` when `Program`
    /// is absent (launchd itself falls back the same way) — `nil` if
    /// neither key was present or readable.
    let programPath: String?
    let programArguments: [String]
    let runAtLoad: Bool?
    /// `true` when the plist's `KeepAlive` key is present at all (a bare
    /// `Bool` or a conditions dictionary both count) — a coarse "launchd
    /// restarts this if it exits" summary rather than parsing every
    /// possible `KeepAlive` condition.
    let keepAlive: Bool?
    /// This job's live enabled/disabled state per `launchctl print-disabled`
    /// — see `StartupProvider.enabledStates(dataTypeTarget:)`'s doc comment
    /// for exactly how this is derived. `true` unless launchd's own
    /// overrides database (or, absent an override, the plist's legacy
    /// top-level `Disabled` key) says otherwise.
    let isEnabled: Bool
    /// Whether this job is currently loaded and running, from `launchctl
    /// list`. `nil` when the job's label doesn't appear in that listing at
    /// all — an unprivileged process only reliably sees its own `gui/<uid>`
    /// domain's jobs, so a `.globalDaemon`/`.systemDaemon` row's running
    /// state is honestly "Unavailable" rather than guessed as not-running.
    let isRunning: Bool?
    let runningPID: Int32?
    let fileSizeBytes: UInt64?
    let modifiedAt: Date?
    let createdAt: Date?
    let ownerAccountName: String?
    let posixPermissions: UInt16?
}

/// One full `sample()`'s worth of startup-item data, mirroring
/// `SystemInfoCatalog`'s "cached, page-driven reload" shape — see
/// `StartupProvider`'s own doc comment for why this domain isn't wired into
/// `Sampler`'s per-tick loop either.
struct StartupCatalog: Sendable, Equatable {
    /// `var`, not `let`: `StartupViewModel.applyOptimisticEnabled(_:forItemID:)`
    /// mutates a single row in place for its optimistic toggle update
    /// rather than rebuilding the whole array.
    var items: [StartupItem]
    let generatedAt: Date
}

/// Failure modes for `StartupProvider.sample()` — PLAN.md's "honest
/// degradation": thrown only when the scan can't produce *any* usable
/// result (every directory unreadable); a single unreadable directory
/// (e.g. `/Library/LaunchDaemons` sandboxed away) or a single unparseable
/// plist is instead dropped silently from an otherwise-successful result,
/// the same per-item grain `SystemInfoProvider.parseCatalog(from:)` uses.
enum StartupProviderError: Error, LocalizedError {
    case noDirectoriesReadable

    var errorDescription: String? {
        switch self {
        case .noDirectoriesReadable:
            return "None of the LaunchAgents/LaunchDaemons directories could be read"
        }
    }
}

/// Scans every `LaunchAgents`/`LaunchDaemons` directory macOS defines and
/// cross-references `launchctl` for each job's live enabled/running state —
/// PLAN.md §3's `Providers/StartupProvider.swift "LaunchAgents/Daemons
/// plist scan + launchctl state"` and §4 M5's second task.
///
/// An `actor`, and driven by its page exactly like `SystemInfoProvider`
/// (load-once-then-Reload, not a `Sampler` tick): a full scan touches five
/// directories and shells out to `launchctl` three times (`print-disabled`
/// ×2, `list` ×1), each an order of magnitude slower than any syscall-backed
/// M2 domain provider — sampling that twice a second would itself be the
/// load PLAN.md §2 warns a monitor must never become.
actor StartupProvider: Provider {
    static let providerID = "startup"

    private(set) var cachedCatalog: StartupCatalog?

    private struct DirectorySpec {
        let path: String
        let domain: StartupItemDomain
    }

    /// Every directory launchd loads agents/daemons from, in the display
    /// order PLAN.md's own table implies (this Mac's own items first, Apple's
    /// last) — `~/Library/LaunchAgents` is resolved fresh on every `sample()`
    /// rather than cached, so a scan always reflects the *current* user even
    /// if that were ever to change within one process lifetime.
    private static func directorySpecs() -> [DirectorySpec] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            DirectorySpec(path: "\(home)/Library/LaunchAgents", domain: .userAgent),
            DirectorySpec(path: "/Library/LaunchAgents", domain: .globalAgent),
            DirectorySpec(path: "/Library/LaunchDaemons", domain: .globalDaemon),
            DirectorySpec(path: "/System/Library/LaunchAgents", domain: .systemAgent),
            DirectorySpec(path: "/System/Library/LaunchDaemons", domain: .systemDaemon),
        ]
    }

    func sample() async throws -> StartupCatalog {
        let catalog = try await Self.scan()
        cachedCatalog = catalog
        return catalog
    }

    // MARK: - Scan

    /// Hops to a background queue the same way
    /// `SystemInfoProvider.runSystemProfiler` does, for the same reason:
    /// this method's filesystem enumeration plus three blocking `launchctl`
    /// invocations have no async variant, and running them directly on this
    /// actor's executor would tie up a cooperative-pool thread for however
    /// long they take.
    private static func scan() async throws -> StartupCatalog {
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
    private static func scanSynchronously() throws -> StartupCatalog {
        let uid = getuid()
        let fileManager = FileManager.default

        var rawItems: [(path: String, domain: StartupItemDomain)] = []
        var anyDirectoryReadable = false
        for spec in directorySpecs() {
            guard let names = try? fileManager.contentsOfDirectory(atPath: spec.path) else { continue }
            anyDirectoryReadable = true
            for name in names where name.hasSuffix(".plist") {
                rawItems.append((path: "\(spec.path)/\(name)", domain: spec.domain))
            }
        }

        // An empty-but-readable scan (e.g. a fresh account with no
        // `~/Library/LaunchAgents` items yet) is a perfectly honest empty
        // result; only "every directory itself was unreadable" — which in
        // practice means something is very wrong (sandboxing, a missing
        // filesystem) — degrades to a thrown error, per this file's own
        // `StartupProviderError` doc comment.
        guard anyDirectoryReadable else {
            throw StartupProviderError.noDirectoriesReadable
        }

        let agentOverrides = enabledOverrides(domainTarget: "gui/\(uid)")
        let daemonOverrides = enabledOverrides(domainTarget: "system")
        let runningByLabel = runningState()

        let items = rawItems.compactMap { raw -> StartupItem? in
            startupItem(
                atPath: raw.path,
                domain: raw.domain,
                fileManager: fileManager,
                agentOverrides: agentOverrides,
                daemonOverrides: daemonOverrides,
                runningByLabel: runningByLabel
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        return StartupCatalog(items: items, generatedAt: Date())
    }

    /// Builds one `StartupItem` from one plist path, or `nil` when the file
    /// can't be read/parsed as a property list at all — dropped from the
    /// result rather than shown as a broken row, matching
    /// `SystemInfoProvider`'s per-item degradation grain.
    private static func startupItem(
        atPath path: String,
        domain: StartupItemDomain,
        fileManager: FileManager,
        agentOverrides: [String: Bool],
        daemonOverrides: [String: Bool],
        runningByLabel: [String: Int32?]
    ) -> StartupItem? {
        guard
            let data = fileManager.contents(atPath: path),
            let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any]
        else {
            return nil
        }

        let filenameStem = (path as NSString).lastPathComponent.replacingOccurrences(of: ".plist", with: "")
        let label = (plist["Label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let launchctlLabel = (label?.isEmpty == false) ? label : nil
        let displayName = launchctlLabel ?? filenameStem

        let programArguments = (plist["ProgramArguments"] as? [String]) ?? []
        let programPath = (plist["Program"] as? String) ?? programArguments.first

        let runAtLoad = plist["RunAtLoad"] as? Bool
        let keepAlive: Bool? = plist["KeepAlive"] != nil ? true : nil

        let overrides = domain.usesGUIDomain ? agentOverrides : daemonOverrides
        let plistDisabled = plist["Disabled"] as? Bool ?? false
        let isEnabled: Bool
        if let launchctlLabel, let override = overrides[launchctlLabel] {
            isEnabled = !override
        } else {
            isEnabled = !plistDisabled
        }

        var isRunning: Bool?
        var runningPID: Int32?
        if let launchctlLabel, let pidEntry = runningByLabel[launchctlLabel] {
            isRunning = pidEntry != nil
            runningPID = pidEntry
        }

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value
        let modifiedAt = attributes?[.modificationDate] as? Date
        let createdAt = attributes?[.creationDate] as? Date
        let owner = attributes?[.ownerAccountName] as? String
        let permissions = (attributes?[.posixPermissions] as? NSNumber)?.uint16Value

        return StartupItem(
            plistPath: path,
            domain: domain,
            displayName: displayName,
            launchctlLabel: launchctlLabel,
            programPath: programPath,
            programArguments: programArguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isEnabled: isEnabled,
            isRunning: isRunning,
            runningPID: runningPID,
            fileSizeBytes: fileSize,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            ownerAccountName: owner,
            posixPermissions: permissions
        )
    }

    // MARK: - launchctl state

    /// Runs `launchctl print-disabled <domainTarget>` and parses its
    /// `"<label>" => true|false` lines into label → *disabled* (not
    /// enabled) flags. Returns an empty dictionary on any failure (no
    /// `launchctl` binary, non-zero exit, unparseable output) — callers
    /// treat a label missing from this map as "no override recorded", which
    /// is exactly what an empty map already means, so a total failure here
    /// degrades to "trust each plist's own `Disabled` key" rather than
    /// blocking the whole scan.
    private static func enabledOverrides(domainTarget: String) -> [String: Bool] {
        guard let output = runLaunchctl(["print-disabled", domainTarget]) else { return [:] }
        var result: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            // Real output looks like: `\t"com.example.foo" => disabled`
            // (or `=> true` on some macOS versions) inside a
            // `disabled services = { ... }` block — parsed leniently by
            // pattern rather than assuming one exact token spelling, since
            // that spelling has changed across macOS releases.
            guard
                let firstQuote = line.firstIndex(of: "\""),
                let lastQuote = line[line.index(after: firstQuote)...].firstIndex(of: "\"")
            else { continue }
            let label = String(line[line.index(after: firstQuote)..<lastQuote])
            guard let arrowRange = line.range(of: "=>") else { continue }
            let token = line[arrowRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if token.contains("disabled") || token == "true" {
                result[label] = true
            } else if token.contains("enabled") || token == "false" {
                result[label] = false
            }
        }
        return result
    }

    /// Runs `launchctl list` and parses its `PID\tStatus\tLabel` rows into
    /// label → PID (`nil` when the row's PID column is `"-"`, meaning
    /// loaded-but-not-running). A label with no entry at all in the result
    /// (as opposed to an entry mapping to `nil`) means this listing didn't
    /// mention it — `StartupItem.isRunning` stays `nil`/"Unavailable" for
    /// those, see that property's own doc comment.
    private static func runningState() -> [String: Int32?] {
        guard let output = runLaunchctl(["list"]) else { return [:] }
        var result: [String: Int32?] = [:]
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: "\t")
            // Skip the header row (`PID\tStatus\tLabel`, no real job is
            // ever literally named "Label").
            guard columns.count >= 3, columns[0] != "PID" else { continue }
            let label = String(columns[2])
            let pid = Int32(columns[0])
            result[label] = pid
        }
        return result
    }

    /// Synchronously runs `/bin/launchctl <arguments>` and returns stdout as
    /// UTF-8 text, or `nil` if the process couldn't launch or exited
    /// non-zero. Must only ever be called from the background queue
    /// `scan()` dispatches onto (see `SystemInfoProvider.launchSynchronously`
    /// for why blocking pipe reads never belong on this actor's own
    /// executor).
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

    // MARK: - Enable/disable toggle

    enum ToggleError: Error, LocalizedError {
        case notUserToggleable
        case missingLabel
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notUserToggleable:
                return "Only items in your own ~/Library/LaunchAgents can be toggled from this app."
            case .missingLabel:
                return "This item has no launchd Label to toggle."
            case .commandFailed(let detail):
                return "launchctl failed: \(detail)"
            }
        }
    }

    /// Enables or disables `item` via `launchctl enable`/`disable` — PLAN.md
    /// §4 M5's "enable/disable toggle (user domain only)". Restricted to
    /// `.userAgent` items both here (the actual guard) and in
    /// `StartupPage`'s UI (the toggle control itself is disabled for every
    /// other domain) — see `StartupItemDomain.isUserToggleable`'s doc
    /// comment for why only that one domain is safe to write without
    /// elevated privileges.
    ///
    /// `launchctl enable`/`disable` only changes launchd's persistent
    /// overrides database — whether the job loads at the *next* login/boot
    /// — so it never lies about starting or stopping a process this app has
    /// no privilege to touch mid-session. After the persistent change
    /// succeeds, this also makes a best-effort `bootstrap`/`bootout` call so
    /// a toggle is visible immediately rather than only after the next
    /// login; that best-effort call's own failure (e.g. `bootout` on a job
    /// that wasn't currently loaded) is swallowed rather than surfaced,
    /// since the persistent state — the part PLAN.md actually asked this
    /// toggle to control — already succeeded.
    func setEnabled(_ enabled: Bool, for item: StartupItem) async throws {
        guard item.domain.isUserToggleable else { throw ToggleError.notUserToggleable }
        guard let label = item.launchctlLabel else { throw ToggleError.missingLabel }
        let domainTarget = item.domain.launchctlDomainTarget(uid: getuid())
        let target = "\(domainTarget)/\(label)"

        try await Self.runLaunchctlThrowing([enabled ? "enable" : "disable", target])

        // Best-effort immediate load/unload — failures here are expected
        // and harmless (e.g. `bootout` when nothing is currently loaded)
        // and intentionally not reported, per this method's own doc
        // comment.
        if enabled {
            _ = try? await Self.runLaunchctlThrowing(["bootstrap", domainTarget, item.plistPath])
        } else {
            _ = try? await Self.runLaunchctlThrowing(["bootout", target])
        }
    }

    /// Same background-queue hop as `scan()`, for the same reason, but
    /// throwing on a non-zero exit rather than silently returning `nil` —
    /// callers here (unlike the read-only helpers above) need to know
    /// whether the write actually took effect.
    private static func runLaunchctlThrowing(_ arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                let stderrPipe = Pipe()
                process.standardError = stderrPipe
                process.standardOutput = Pipe()

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: ToggleError.commandFailed(error.localizedDescription))
                    return
                }
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let text = String(data: stderrData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    continuation.resume(throwing: ToggleError.commandFailed(text.isEmpty ? "exit \(process.terminationStatus)" : text))
                    return
                }
                continuation.resume()
            }
        }
    }
}
