import Foundation

/// A well-known, safe-to-clear location this app knows how to find and
/// size — same "honest degradation" rule as `DiskSpaceFileCategory`: only
/// locations this app can positively identify as regenerable caches/logs/
/// build output are ever offered, never a guess at what's "junk." Nothing
/// resembling a user's actual documents, an app's real saved data
/// (`Application Support`), or another app's bundle is in scope here — that
/// overlaps with `InstalledAppsProvider`'s own related-files finder/
/// Uninstall flow, which already handles "remove this specific app and its
/// data" deliberately, one app at a time, with its own confirmation.
enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case appCaches
    case logs
    case xcodeDerivedData
    case developerToolCaches
    case commandLineToolCaches
    case trash

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .appCaches: return "App Caches"
        case .logs: return "Logs & Diagnostic Reports"
        case .xcodeDerivedData: return "Xcode Derived Data"
        case .developerToolCaches: return "Simulator & Device Support"
        case .commandLineToolCaches: return "Command-Line Tool Caches"
        case .trash: return "Trash"
        }
    }

    var systemImage: String {
        switch self {
        case .appCaches: return "archivebox"
        case .logs: return "doc.text.magnifyingglass"
        case .xcodeDerivedData: return "hammer"
        case .developerToolCaches: return "cpu"
        case .commandLineToolCaches: return "terminal"
        case .trash: return "trash"
        }
    }

    /// One sentence on *why* this category is safe to clear, shown right
    /// next to it — this app never asks for a destructive action without
    /// explaining it.
    var explanation: String {
        switch self {
        case .appCaches:
            return "Regenerated automatically by each app the next time it needs them."
        case .logs:
            return "Historical log files and crash reports \u{2014} not used by running apps."
        case .xcodeDerivedData:
            return "Xcode\u{2019}s build intermediates \u{2014} rebuilt automatically on your next build."
        case .developerToolCaches:
            return "Simulator caches and device-support files \u{2014} recreated the next time you use them."
        case .commandLineToolCaches:
            return "Downloaded package caches (npm, Gradle, Cargo, and similar tools) \u{2014} re-downloaded on demand."
        case .trash:
            return "Items already in the Trash \u{2014} emptying is permanent."
        }
    }
}

/// One selectable item within a `CleanupCategorySummary` — one app's cache
/// folder, one project's Derived Data, one tool's download cache. Sized via
/// `recursiveRealSizeBytes` (actual on-disk usage, not apparent size — see
/// `FileEntryStat`'s own doc comment).
struct CleanupItem: Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let name: String
    let category: CleanupCategory
    let sizeBytes: UInt64
}

/// One category's items from a finished `CleanupProvider.scan()` — a
/// section in `CleanupPage`'s list. `.trash` never appears here; its size
/// is reported separately by `CleanupScanResult.trashBytes` since emptying
/// it is a distinct, irreversible action from the reversible "move to
/// Trash" every other category uses.
struct CleanupCategorySummary: Sendable, Equatable, Identifiable {
    var id: CleanupCategory { category }
    let category: CleanupCategory
    /// Largest-first, matching every other "what's taking up space" list
    /// in this app.
    let items: [CleanupItem]
    var totalBytes: UInt64 { items.reduce(0) { $0 + $1.sizeBytes } }
}

struct CleanupScanResult: Sendable, Equatable {
    let generatedAt: Date
    let categories: [CleanupCategorySummary]
    let trashBytes: UInt64
    let trashItemCount: Int
}

enum CleanupError: Error, LocalizedError {
    case trashFailed(String)
    case emptyTrashFailed(String)

    var errorDescription: String? {
        switch self {
        case .trashFailed(let detail):
            return "Couldn\u{2019}t move it to the Trash: \(detail)"
        case .emptyTrashFailed(let detail):
            return "Couldn\u{2019}t remove it: \(detail)"
        }
    }
}

/// The result of one `CleanupProvider.clean(_:)` or `emptyTrash()` call.
/// `failed` is never silently dropped — `CleanupPage` surfaces it, the same
/// "a leftover item failing shouldn't read as the whole operation having
/// failed, but it must still be reported" reasoning
/// `InstalledAppsProvider.uninstall`'s own doc comment gives.
struct CleanupOutcome: Sendable, Equatable {
    let freedBytes: UInt64
    let cleanedCount: Int
    let failed: [CleanupItem]
}

/// Finds and clears well-known regenerable caches/logs/build output —
/// this app's "Clean Up" tool. An `actor`, driven by its page exactly like
/// `InstalledAppsProvider` (load-once-then-Reload, not a `Sampler` tick):
/// sizing dozens of cache folders is too slow for a 2\u{d7}/sec tick.
///
/// Every path this type will ever touch comes from `CleanupCategory`'s own
/// fixed, hard-coded list of roots — there is no user-supplied arbitrary
/// path here (unlike `DiskSpaceScanner`'s Choose Folder\u{2026}), and a
/// category root itself is never deleted, only its *children* — so an app
/// or tool that expects its own cache directory to still exist (even
/// empty) after a clean isn't broken by the folder disappearing outright.
/// `clean(_:)` always moves to the Trash (reversible); only the separate,
/// explicitly-irreversible `emptyTrash()` permanently deletes anything.
actor CleanupProvider {
    static let providerID = "cleanup"

    /// Upper bound on concurrent sizing workers — same reasoning as
    /// `DiskSpaceScanner.maxWorkerCount`: this is I/O-bound, not CPU-bound,
    /// so more than a modest number of threads has diminishing returns.
    private static let maxWorkerCount = 8

    func scan() async -> CleanupScanResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.scanSynchronously())
            }
        }
    }

    // MARK: - Scan

    private static func scanSynchronously() -> CleanupScanResult {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        let categories = CleanupCategory.allCases
            .filter { $0 != .trash }
            .map { category in
                CleanupCategorySummary(category: category, items: items(for: category, home: home, fileManager: fileManager))
            }

        let (trashBytes, trashCount) = trashTotals(home: home, fileManager: fileManager)

        return CleanupScanResult(generatedAt: Date(), categories: categories, trashBytes: trashBytes, trashItemCount: trashCount)
    }

    private static func items(for category: CleanupCategory, home: String, fileManager: FileManager) -> [CleanupItem] {
        switch category {
        case .appCaches:
            return containerChildren(root: "\(home)/Library/Caches", category: category, fileManager: fileManager)
        case .logs:
            return containerChildren(root: "\(home)/Library/Logs", category: category, fileManager: fileManager)
        case .xcodeDerivedData:
            return containerChildren(root: "\(home)/Library/Developer/Xcode/DerivedData", category: category, fileManager: fileManager)
        case .developerToolCaches:
            return namedItems(category: category, fileManager: fileManager, candidates: [
                ("Simulator Caches", "\(home)/Library/Developer/CoreSimulator/Caches"),
                ("iOS/iPadOS Device Support", "\(home)/Library/Developer/Xcode/iOS DeviceSupport"),
            ])
        case .commandLineToolCaches:
            return namedItems(category: category, fileManager: fileManager, candidates: [
                ("npm Cache", "\(home)/.npm/_cacache"),
                ("Gradle Cache", "\(home)/.gradle/caches"),
                ("Cargo Registry Cache", "\(home)/.cargo/registry/cache"),
                ("Generic Cache (~/.cache)", "\(home)/.cache"),
            ])
        case .trash:
            return []
        }
    }

    /// Lists `root`'s immediate children as individually selectable items
    /// — used for categories whose whole point is "one subfolder per app/
    /// project," so a user can clear one bloated app's cache without
    /// clearing every other app's. Sizes children in parallel (`root`
    /// itself, e.g. `~/Library/Caches`, can hold dozens of entries with
    /// deep trees) via a bounded `OperationQueue`, the same pattern
    /// `DiskSpaceScanner.scanTopLevelInParallel` uses for the same reason.
    private static func containerChildren(root: String, category: CleanupCategory, fileManager: FileManager) -> [CleanupItem] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }

        let workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, maxWorkerCount))
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = workerCount
        let lock = NSLock()
        var items: [CleanupItem] = []

        for name in names {
            queue.addOperation {
                let path = "\(root)/\(name)"
                guard let entry = statEntry(atPath: path), !entry.isSymbolicLink else { return }
                let size = entry.isDirectory ? recursiveRealSizeBytes(atPath: path, fileManager: FileManager()) : entry.realSizeBytes
                guard size > 0 else { return }
                let item = CleanupItem(path: path, name: name, category: category, sizeBytes: size)
                lock.lock(); items.append(item); lock.unlock()
            }
        }
        queue.waitUntilAllOperationsAreFinished()

        return items.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    /// A fixed, named list of whole directories — for categories where
    /// each entry is one specific known tool's cache/support directory
    /// rather than "every child of some container." Silently omits any
    /// candidate that doesn't exist on this Mac (e.g. no Gradle cache if
    /// Gradle was never used) rather than showing a misleading zero-size
    /// row — the same "honest gap, not a zero" rule `RelatedFile.sizeBytes`
    /// documents.
    private static func namedItems(
        category: CleanupCategory,
        fileManager: FileManager,
        candidates: [(name: String, path: String)]
    ) -> [CleanupItem] {
        candidates.compactMap { candidate in
            guard fileManager.fileExists(atPath: candidate.path) else { return nil }
            let size = recursiveRealSizeBytes(atPath: candidate.path, fileManager: fileManager)
            guard size > 0 else { return nil }
            return CleanupItem(path: candidate.path, name: candidate.name, category: category, sizeBytes: size)
        }.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    private static func trashTotals(home: String, fileManager: FileManager) -> (bytes: UInt64, count: Int) {
        let trashPath = "\(home)/.Trash"
        guard let names = try? fileManager.contentsOfDirectory(atPath: trashPath) else { return (0, 0) }
        var total: UInt64 = 0
        for name in names {
            let path = "\(trashPath)/\(name)"
            guard let entry = statEntry(atPath: path), !entry.isSymbolicLink else { continue }
            total += entry.isDirectory ? recursiveRealSizeBytes(atPath: path, fileManager: fileManager) : entry.realSizeBytes
        }
        return (total, names.count)
    }

    // MARK: - Clean

    /// Moves every item in `items` to the Trash — reversible, exactly
    /// `InstalledAppsProvider.uninstall`'s own `trash(path:)` pattern. An
    /// item that fails (already gone, permission denied, in use) is
    /// collected into `CleanupOutcome.failed` rather than aborting the rest
    /// of the batch.
    func clean(_ items: [CleanupItem]) async -> CleanupOutcome {
        var freedBytes: UInt64 = 0
        var cleanedCount = 0
        var failed: [CleanupItem] = []
        for item in items {
            do {
                try await Self.trash(path: item.path)
                freedBytes += item.sizeBytes
                cleanedCount += 1
            } catch {
                failed.append(item)
            }
        }
        return CleanupOutcome(freedBytes: freedBytes, cleanedCount: cleanedCount, failed: failed)
    }

    /// Hops to a background queue since `FileManager.trashItem` blocks
    /// (and can itself prompt for admin authorization via Finder when the
    /// item isn't owned by the current user) — same reasoning as
    /// `InstalledAppsProvider.trash(path:)`.
    private static func trash(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CleanupError.trashFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Permanently deletes everything currently in the Trash — irreversible,
    /// unlike `clean(_:)`. Removes each top-level item directly rather than
    /// scripting Finder's own "Empty Trash" command, avoiding an
    /// Apple-Events automation permission prompt for something this simple.
    @discardableResult
    func emptyTrash() async -> CleanupOutcome {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let trashPath = "\(home)/.Trash"
        guard let names = try? fileManager.contentsOfDirectory(atPath: trashPath) else {
            return CleanupOutcome(freedBytes: 0, cleanedCount: 0, failed: [])
        }

        var freedBytes: UInt64 = 0
        var cleanedCount = 0
        var failed: [CleanupItem] = []
        for name in names {
            let path = "\(trashPath)/\(name)"
            let size = statEntry(atPath: path).map {
                $0.isDirectory ? recursiveRealSizeBytes(atPath: path, fileManager: fileManager) : $0.realSizeBytes
            } ?? 0
            do {
                try await Self.permanentlyRemove(path: path)
                freedBytes += size
                cleanedCount += 1
            } catch {
                failed.append(CleanupItem(path: path, name: name, category: .trash, sizeBytes: size))
            }
        }
        return CleanupOutcome(freedBytes: freedBytes, cleanedCount: cleanedCount, failed: failed)
    }

    private static func permanentlyRemove(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.removeItem(atPath: path)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: CleanupError.emptyTrashFailed(error.localizedDescription))
                }
            }
        }
    }
}
