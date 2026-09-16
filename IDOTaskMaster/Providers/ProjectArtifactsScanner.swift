import Foundation

/// One detected rebuildable project-artifact directory (a `node_modules`,
/// a Rust `target`, a Python `.venv`, ...) — positively identified via a
/// marker file alongside or inside it, per `ProjectArtifactsScanner
/// .markers`, never a guess based on the directory's name alone. A bare
/// folder named `build` with nothing to tie it to a known build tool is
/// never reported: PLAN.md's "honest degradation" rule applied to
/// classification, not just readings — a wrong "this is safe to delete"
/// guess is worse than not finding it at all.
struct ProjectArtifactEntry: Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    /// e.g. `"Node.js Dependencies (node_modules)"` — the matched
    /// marker's own label, not a generic "Folder".
    let kind: String
    let sizeBytes: UInt64
}

struct ProjectArtifactsScanProgress: Sendable, Equatable {
    let foldersScanned: Int
    let artifactsFound: Int
    let bytesFound: UInt64
}

struct ProjectArtifactsScanResult: Sendable, Equatable {
    let rootPath: String
    /// Largest-first, matching every other "what's taking up space" list
    /// in this app.
    let entries: [ProjectArtifactEntry]
    var totalBytes: UInt64 { entries.reduce(0) { $0 + $1.sizeBytes } }
}

enum ProjectArtifactsScanEvent: Sendable {
    case progress(ProjectArtifactsScanProgress)
    case completed(ProjectArtifactsScanResult)
    case failed(String)
    case cancelled
}

/// Finds rebuildable dependency/build-output directories under a
/// user-chosen root — `node_modules`, Rust's `target`, a Python `.venv`,
/// CocoaPods' `Pods`, a Gradle `build`, SwiftPM's `.build` — the
/// "mo purge"-shaped half of Clean Up: unlike every `CleanupCategory`,
/// these live at arbitrary, unpredictable paths inside a user's own
/// project folders rather than one well-known system location, so this
/// needs its own user-chosen-root scanner, the same shape
/// `DiskSpaceScanner` already establishes (`AsyncStream` of progress
/// ticks then one terminal event, a `CancellationToken`/`TokenBox` pair,
/// the real walk on `DispatchQueue.global` rather than this actor's own
/// executor) rather than `CleanupProvider`'s fixed-location model.
///
/// Never descends into a directory once it's matched — a `node_modules`
/// can contain thousands of files several directories deep, all
/// irrelevant to "how big is this artifact and where does it live," and
/// walking them anyway would make a scan of a real project folder
/// pathologically slow for no benefit. Also never descends into version-
/// control internals (`.git`/`.hg`/`.svn`): large but not a build
/// artifact, and not this feature's concern (`.git`'s own housekeeping,
/// e.g. `git gc`, is the right tool for that, not a delete).
actor ProjectArtifactsScanner {
    static let providerID = "projectArtifacts"

    /// Holds whichever scan's `CancellationToken` is currently active —
    /// see `DiskSpaceScanner`'s own `activeTokenBox` for why this lives
    /// behind a lock rather than actor isolation: `cancelActiveScan()`
    /// must take effect immediately, without waiting for this actor's own
    /// queue (which the long-running scan itself never occupies, but a
    /// caller shouldn't have to know that).
    private let activeTokenBox = TokenBox()

    /// Starts an async recursive scan of `rootPath`. Returns an
    /// `AsyncStream` of zero or more `.progress` ticks followed by exactly
    /// one terminal event, then finishes — identical contract to
    /// `DiskSpaceScanner.scan(rootPath:)`.
    nonisolated func scan(rootPath: String) -> AsyncStream<ProjectArtifactsScanEvent> {
        let token = CancellationToken()
        activeTokenBox.set(token)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .utility).async {
                Self.performScan(rootPath: rootPath, token: token, continuation: continuation)
            }
        }
    }

    /// Takes effect the next time the walk checks `token.isCancelled` (at
    /// most one directory's worth of latency later) — mirrors
    /// `DiskSpaceScanner.cancelActiveScan()`.
    func cancelActiveScan() {
        activeTokenBox.current?.cancel()
    }

    // MARK: - Markers

    /// One rule tying a directory name to the tool that owns it. Exactly
    /// one of `siblingMarkerFiles`/`innerMarkerFile` is used per rule:
    /// a dependency folder is confirmed by a manifest file *next to* it
    /// (`node_modules` needs a sibling `package.json` — the folder itself
    /// never contains one), while a virtual environment is confirmed by a
    /// file *inside* it (`pyvenv.cfg`, which every `python -m venv`
    /// creates) since there's no meaningful "sibling" for a venv that
    /// could live anywhere. Two rules can share a `directoryName` (Rust's
    /// and Maven's build output are both called `target`) — `matchMarker`
    /// tries every rule for a name and uses whichever sibling actually
    /// exists.
    private struct Marker {
        let directoryName: String
        let siblingMarkerFiles: [String]
        let innerMarkerFile: String?
        let displayName: String
    }

    private static let markers: [Marker] = [
        Marker(directoryName: "node_modules", siblingMarkerFiles: ["package.json"], innerMarkerFile: nil, displayName: "Node.js Dependencies (node_modules)"),
        Marker(directoryName: "target", siblingMarkerFiles: ["Cargo.toml"], innerMarkerFile: nil, displayName: "Rust Build Output (target)"),
        Marker(directoryName: "target", siblingMarkerFiles: ["pom.xml"], innerMarkerFile: nil, displayName: "Maven Build Output (target)"),
        Marker(directoryName: "build", siblingMarkerFiles: ["build.gradle", "build.gradle.kts"], innerMarkerFile: nil, displayName: "Gradle Build Output (build)"),
        Marker(directoryName: ".venv", siblingMarkerFiles: [], innerMarkerFile: "pyvenv.cfg", displayName: "Python Virtual Environment (.venv)"),
        Marker(directoryName: "venv", siblingMarkerFiles: [], innerMarkerFile: "pyvenv.cfg", displayName: "Python Virtual Environment (venv)"),
        Marker(directoryName: "Pods", siblingMarkerFiles: ["Podfile.lock", "Podfile"], innerMarkerFile: nil, displayName: "CocoaPods Dependencies (Pods)"),
        Marker(directoryName: ".build", siblingMarkerFiles: ["Package.swift"], innerMarkerFile: nil, displayName: "Swift Package Manager Build Output (.build)"),
    ]

    /// Every directory name any marker cares about — checked once per
    /// child on the fast path (a plain `Set` lookup) before the fuller
    /// `matchMarker` check runs, since most directories in a real project
    /// tree (`src`, `Sources`, `.git`, ...) match no marker at all.
    private static let directoryNamesOfInterest: Set<String> = Set(markers.map(\.directoryName))

    private static let neverDescend: Set<String> = [".git", ".hg", ".svn"]

    // MARK: - Scan

    private static func performScan(
        rootPath: String,
        token: CancellationToken,
        continuation: AsyncStream<ProjectArtifactsScanEvent>.Continuation
    ) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            continuation.yield(.failed("\u{201C}\((rootPath as NSString).lastPathComponent)\u{201D} isn\u{2019}t a folder, or can\u{2019}t be read."))
            continuation.finish()
            return
        }

        var entries: [ProjectArtifactEntry] = []
        var foldersScanned = 0
        var lastProgressEmit = Date.distantPast

        func emitProgressIfDue() {
            let now = Date()
            guard now.timeIntervalSince(lastProgressEmit) > 0.2 else { return }
            lastProgressEmit = now
            continuation.yield(.progress(ProjectArtifactsScanProgress(
                foldersScanned: foldersScanned,
                artifactsFound: entries.count,
                bytesFound: entries.reduce(0) { $0 + $1.sizeBytes }
            )))
        }

        // Plain recursive descent (not `FileManager.enumerator`, which
        // has no way to skip descending into a subtree it's already
        // handed you) — returns `false` the moment cancellation is
        // noticed, unwinding the whole walk immediately rather than only
        // at the current directory's level.
        func walk(_ path: String) -> Bool {
            guard !token.isCancelled else { return false }
            foldersScanned += 1
            emitProgressIfDue()

            guard let childNames = try? FileManager.default.contentsOfDirectory(atPath: path) else { return true }
            let childNameSet = Set(childNames)

            for name in childNames {
                guard !token.isCancelled else { return false }
                let childPath = "\(path)/\(name)"
                guard let entry = statEntry(atPath: childPath), entry.isDirectory, !entry.isSymbolicLink else { continue }
                if neverDescend.contains(name) { continue }

                if directoryNamesOfInterest.contains(name),
                   let matched = matchMarker(directoryName: name, candidatePath: childPath, siblingNames: childNameSet) {
                    let size = recursiveRealSizeBytes(atPath: childPath, fileManager: FileManager())
                    if size > 0 {
                        entries.append(ProjectArtifactEntry(path: childPath, kind: matched.displayName, sizeBytes: size))
                        emitProgressIfDue()
                    }
                    continue // matched — never descend into it
                }

                if !walk(childPath) { return false }
            }
            return true
        }

        guard walk(rootPath) else {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        }

        let result = ProjectArtifactsScanResult(rootPath: rootPath, entries: entries.sorted { $0.sizeBytes > $1.sizeBytes })
        continuation.yield(.completed(result))
        continuation.finish()
    }

    private static func matchMarker(directoryName: String, candidatePath: String, siblingNames: Set<String>) -> Marker? {
        for marker in markers where marker.directoryName == directoryName {
            if let inner = marker.innerMarkerFile {
                if FileManager.default.fileExists(atPath: "\(candidatePath)/\(inner)") {
                    return marker
                }
            } else if marker.siblingMarkerFiles.contains(where: siblingNames.contains) {
                return marker
            }
        }
        return nil
    }
}

// MARK: - Cancellation (private copy — see `DiskSpaceScanner`'s own pair
// for why every scanner in this codebase keeps its own rather than
// sharing one utility type)

private final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class TokenBox: @unchecked Sendable {
    private let lock = NSLock()
    private var token: CancellationToken?

    var current: CancellationToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func set(_ newToken: CancellationToken) {
        lock.lock()
        token = newToken
        lock.unlock()
    }
}
