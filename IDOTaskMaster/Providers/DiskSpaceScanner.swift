import Foundation

/// Which of PLAN.md §1.1's Disk Space legend buckets ("File Type legend
/// breakdown (Media/Documents/Code/Archives/Apps/System/Other)") a scanned
/// file falls into. Case order matches that legend's own left-to-right
/// listing, which `DiskSpacePage`'s legend and `DiskSpaceAccumulator
/// .categoryTotals()` both rely on via `allCases` rather than re-stating
/// the order themselves.
enum DiskSpaceFileCategory: String, CaseIterable, Identifiable, Sendable {
    case media
    case documents
    case code
    case archives
    case apps
    case system
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .media: return "Media"
        case .documents: return "Documents"
        case .code: return "Code"
        case .archives: return "Archives"
        case .apps: return "Apps"
        case .system: return "System"
        case .other: return "Other"
        }
    }

    /// SF Symbol for this category's legend swatch/icon. Colors are a
    /// `View`-layer concern (this type stays `Foundation`-only, matching
    /// every other classification enum in `Providers/` — e.g.
    /// `ConnectionsProvider.SocketExposure`); `DiskSpacePage` maps each
    /// case to a `Color` the same way that page maps `SocketExposure`.
    var systemImage: String {
        switch self {
        case .media: return "photo.on.rectangle"
        case .documents: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .archives: return "archivebox"
        case .apps: return "app.badge"
        case .system: return "gearshape"
        case .other: return "questionmark.folder"
        }
    }

    /// Classifies an ordinary file (not a recognized bundle directory —
    /// see `bundleCategory(forExtension:)`) purely by its extension. No
    /// extension, or one this app doesn't recognize, falls through to
    /// `.other` — an honest "didn't recognize it" bucket rather than a
    /// guess.
    static func classify(fileName: String) -> DiskSpaceFileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard !ext.isEmpty else { return .other }
        if mediaExtensions.contains(ext) { return .media }
        if documentExtensions.contains(ext) { return .documents }
        if codeExtensions.contains(ext) { return .code }
        if archiveExtensions.contains(ext) { return .archives }
        if systemExtensions.contains(ext) { return .system }
        return .other
    }

    /// Classifies a directory whose own extension marks it as an opaque
    /// bundle `DiskSpaceScanner` sizes as one unit rather than recursing
    /// into (an app, framework, plugin, ...) — `nil` for a plain folder,
    /// which the scanner recurses into normally. See
    /// `DiskSpaceScanner.scanDirectory` for why bundles are never opened
    /// up: an app's hundreds of internal frameworks shouldn't flood either
    /// "largest files" or "largest folders."
    static func bundleCategory(forExtension ext: String) -> DiskSpaceFileCategory? {
        switch ext {
        case "app", "ipa":
            return .apps
        case "framework", "kext", "bundle", "plugin", "prefpane", "component", "qlgenerator", "saver", "xpc", "appex", "systemextension":
            return .system
        default:
            return nil
        }
    }

    // "raw" is deliberately not a media extension despite being a common
    // camera-RAW suffix: it collides with the generic ".raw" sparse virtual
    // disk images VM/container tools (Docker Desktop, QEMU, ...) use, which
    // tend to be enormous — better to leave those as an honest "Other" than
    // fold multi-hundred-GB VM disks into "Media."
    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "tif", "svg", "webp", "psd", "ico",
        "mp3", "wav", "aac", "flac", "m4a", "aiff", "alac", "ogg",
        "mp4", "mov", "avi", "mkv", "m4v", "wmv", "webm", "mpg", "mpeg",
    ]
    private static let documentExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "txt", "rtf", "rtfd",
        "pages", "numbers", "key", "md", "csv", "epub", "odt", "ods", "odp",
    ]
    private static let codeExtensions: Set<String> = [
        "swift", "m", "mm", "h", "hpp", "c", "cpp", "cc", "py", "js", "ts", "tsx", "jsx",
        "java", "kt", "go", "rs", "rb", "php", "html", "htm", "css", "scss", "json", "xml",
        "yaml", "yml", "sh", "zsh", "bash", "sql", "pl", "lua", "toml", "ini", "gradle",
    ]
    private static let archiveExtensions: Set<String> = [
        "zip", "gz", "tgz", "tar", "bz2", "7z", "rar", "xz", "dmg", "pkg", "iso", "cpio", "z",
    ]
    private static let systemExtensions: Set<String> = [
        "plist", "log", "cache", "db", "sqlite", "sqlite3", "so", "dylib", "o", "pyc", "swiftmodule",
    ]
}

/// A live tick from an in-progress `DiskSpaceScanner.scan(rootPath:)` —
/// PLAN.md §4 M6's "async scanner with progress." Deliberately carries no
/// notion of a total (there is no cheap way to know a folder's total item
/// count before walking it), so `DiskSpacePage` shows this alongside an
/// indeterminate spinner rather than a determinate percentage — the same
/// "don't fabricate a number you don't have" rule as everywhere else in
/// this app's "honest degradation" convention.
struct DiskSpaceScanProgress: Sendable, Equatable {
    let itemsScanned: Int
    let bytesScanned: UInt64
    /// The path most recently finished, shown as a live "scanning ⁠…"
    /// caption. `nil` only for the very first tick, before anything has
    /// been read yet. Once the scan is parallelized (see
    /// `DiskSpaceScanner.scanTopLevelInParallel`), this is whichever of
    /// several concurrently-running subtrees happened to trip this tick —
    /// still a real, just-finished path, just not necessarily "the" one
    /// most recently touched globally.
    let currentPath: String?
    /// A live snapshot of category totals as scanned so far — always
    /// exactly `DiskSpaceFileCategory.allCases.count` entries, same as
    /// `DiskSpaceScanResult.categoryTotals`. Lets `DiskSpacePage` show a
    /// growing overview bar/legend while the scan is still running instead
    /// of only once it completes.
    let categoryTotals: [DiskSpaceCategoryTotal]
}

/// One category's aggregate size/count within a finished scan — a row in
/// `DiskSpacePage`'s type legend and a bubble in its bubble chart.
struct DiskSpaceCategoryTotal: Sendable, Equatable, Identifiable {
    var id: DiskSpaceFileCategory { category }
    let category: DiskSpaceFileCategory
    let sizeBytes: UInt64
    let itemCount: Int
}

/// One entry in a finished scan's "Largest Files" list.
struct DiskSpaceFileEntry: Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let sizeBytes: UInt64
    let category: DiskSpaceFileCategory
}

/// One entry in a finished scan's "Largest Folders" list. `itemCount` is
/// the recursive count of files (and bundle-directories, each counted as
/// one item — see `DiskSpaceScanResult.totalItemCount`) anywhere under
/// this folder, not just its immediate children.
struct DiskSpaceFolderEntry: Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let sizeBytes: UInt64
    let itemCount: Int
}

/// A completed `DiskSpaceScanner.scan(rootPath:)` — PLAN.md §4 M6's
/// "file-type classification, ... largest folders/files."
struct DiskSpaceScanResult: Sendable, Equatable {
    let rootPath: String
    let generatedAt: Date
    let totalBytes: UInt64
    /// Every scanned file, plus every bundle directory (each counted once,
    /// not opened up into its contents) — see
    /// `DiskSpaceFileCategory.bundleCategory(forExtension:)`. Plain
    /// folders are not themselves counted as items.
    let totalItemCount: Int
    /// Always exactly `DiskSpaceFileCategory.allCases.count` entries, one
    /// per category in that enum's legend order, zero-sized entries
    /// included — `DiskSpacePage`'s legend always shows all seven rows
    /// rather than only the categories this particular scan happened to
    /// contain.
    let categoryTotals: [DiskSpaceCategoryTotal]
    /// Largest-first, capped at `DiskSpaceAccumulator.topListLimit`.
    let largestFolders: [DiskSpaceFolderEntry]
    /// Largest-first, capped at `DiskSpaceAccumulator.topListLimit`.
    let largestFiles: [DiskSpaceFileEntry]
    /// Directories/items the scan couldn't read (permissions, or a race
    /// with something deleting a file mid-scan) — surfaced as an honest
    /// count on `DiskSpacePage`'s status line rather than silently
    /// under-reporting `totalBytes`.
    let unreadableItemCount: Int
}

/// One event from `DiskSpaceScanner.scan(rootPath:)`'s stream: any number
/// of `.progress` ticks, followed by exactly one terminal event, after
/// which the stream finishes.
enum DiskSpaceScanEvent: Sendable {
    case progress(DiskSpaceScanProgress)
    case completed(DiskSpaceScanResult)
    case failed(String)
    case cancelled
}

/// Async recursive folder scanner with file-type classification — PLAN.md
/// §3's `Providers/DiskSpaceScanner.swift "async recursive scan +
/// file-type classification"` and §4 M6's fourth task's "async scanner
/// with progress, file-type classification" half (the bubble view, type
/// legend, largest folders/files, and scan history are `DiskSpacePage`'s
/// own concerns, built over this type's output).
///
/// Not a `Provider` conformer: `Provider.sample()` is shaped for "one
/// snapshot per call," but a folder scan's whole point is reporting live
/// progress over what can be a long walk — `ConnectionsProvider`/
/// `InstalledAppsProvider`'s own precedent of adding extra methods beyond
/// `sample()` when a domain needs more than that one shape applies here
/// too, just with nothing left over that fits `sample()` at all.
///
/// An `actor` for the same "one instance, consistent with every other
/// `Providers/*.swift` type" reason `InstalledAppsProvider`/
/// `StartupProvider` are, even though — see `scan(rootPath:)`'s doc
/// comment — the actual work always runs on a plain `DispatchQueue.global`
/// thread rather than as actor-isolated code.
actor DiskSpaceScanner {
    /// Not used by `Sampler` (this type isn't `Provider`-conforming — see
    /// this type's own doc comment) but kept for the same reason
    /// `SystemInfoProvider.providerID` is: a stable per-domain key ready
    /// for `PageInfoBar`/`AlertsEngine` if a later milestone wants one,
    /// without every load-once/streaming provider inventing its own naming
    /// scheme.
    static let providerID = "diskSpace"

    /// Holds whichever scan's `CancellationToken` is currently active,
    /// behind its own lock rather than actor isolation — see
    /// `cancelActiveScan()`'s doc comment for why.
    private let activeTokenBox = TokenBox()

    /// Starts an async recursive scan of `rootPath`, classifying every
    /// file by `DiskSpaceFileCategory` as it goes. Returns an
    /// `AsyncStream` of zero or more `.progress` ticks followed by exactly
    /// one terminal event (`.completed`, `.failed`, or `.cancelled`), then
    /// finishes.
    ///
    /// The actual filesystem walk runs on a dedicated `DispatchQueue
    /// .global` thread rather than inside this `async` function's own
    /// Task — the same reasoning `InstalledAppsProvider.scan()`'s own doc
    /// comment gives for its `du`/`codesign` shell-outs: this is
    /// genuinely slow, blocking I/O (a scan of a large folder can touch
    /// hundreds of thousands of files), and must never tie up a thread
    /// from Swift's cooperative pool that `Sampler`'s own ticks and every
    /// other provider share.
    ///
    /// Cancel an in-flight scan with `cancelActiveScan()`. Letting the
    /// stream's consumer stop iterating (its `AsyncStream.Iterator` being
    /// deallocated) also cancels it via `onTermination` below, as a
    /// second line of defense — e.g. if a view disappears without an
    /// explicit cancel — but `cancelActiveScan()` is the one path that
    /// takes effect immediately rather than only once the consumer next
    /// notices.
    nonisolated func scan(rootPath: String) -> AsyncStream<DiskSpaceScanEvent> {
        let token = CancellationToken()
        activeTokenBox.set(token)
        return AsyncStream { continuation in
            continuation.onTermination = { _ in token.cancel() }
            DispatchQueue.global(qos: .utility).async {
                Self.performScan(rootPath: rootPath, token: token, continuation: continuation)
            }
        }
    }

    /// Cancels whichever scan is currently running (a no-op if none is,
    /// or if the most recent one already finished). `nonisolated` and
    /// synchronous — see `TokenBox`'s own doc comment for why this doesn't
    /// need an `await` to take effect immediately.
    nonisolated func cancelActiveScan() {
        activeTokenBox.current?.cancel()
    }

    // MARK: - Background scan (never touches actor-isolated state)

    private static let progressStride = 150
    private static let topListLimit = 60
    /// Upper bound on how many of `rootPath`'s immediate children
    /// `scanTopLevelInParallel` scans at once. Filesystem walks are
    /// I/O-bound (dominated by `stat`-style syscalls, not CPU work), so
    /// concurrency past a modest number of threads has diminishing
    /// returns and risks thrashing the I/O layer on Macs with very high
    /// core counts — `activeProcessorCount` is still respected as a
    /// ceiling below this.
    private static let maxWorkerCount = 8

    private struct ScanCancelled: Error {}

    /// Whether `entry` describes a file this scan has already counted once
    /// under a different name pointing at the same (volume, inode) — i.e.
    /// a hard link. Summing real size once per directory *entry* rather
    /// than once per physical file can still over-report when hard links
    /// are involved (Photos Library, Mail, and Xcode.app's toolchain all
    /// use them heavily) — `du` avoids this by tracking inodes it's
    /// already counted, which this mirrors. Only files with more than one
    /// link ever touch `accumulator`'s tracking set, so the common case
    /// (an ordinary file with exactly one name) pays nothing beyond a
    /// property read already sitting in `entry`.
    private static func isDuplicateHardLink(_ entry: FileEntryStat, accumulator: DiskSpaceAccumulator) -> Bool {
        guard entry.linkCount > 1 else { return false }
        return !accumulator.isFirstSighting(device: entry.device, inode: entry.inode)
    }

    private static func performScan(
        rootPath: String,
        token: CancellationToken,
        continuation: AsyncStream<DiskSpaceScanEvent>.Continuation
    ) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            continuation.yield(.failed("\u{201C}\(rootPath)\u{201D} isn\u{2019}t a folder, or can\u{2019}t be read."))
            continuation.finish()
            return
        }

        let accumulator = DiskSpaceAccumulator(topListLimit: topListLimit)

        func reportProgress(currentPath: String?) {
            let snapshot = accumulator.progressSnapshot()
            continuation.yield(.progress(DiskSpaceScanProgress(
                itemsScanned: snapshot.items,
                bytesScanned: snapshot.bytes,
                currentPath: currentPath,
                categoryTotals: snapshot.categoryTotals
            )))
        }
        reportProgress(currentPath: rootPath)

        do {
            try scanTopLevelInParallel(
                rootPath: rootPath,
                fileManager: fileManager,
                token: token,
                accumulator: accumulator,
                reportProgress: reportProgress
            )
        } catch is ScanCancelled {
            continuation.yield(.cancelled)
            continuation.finish()
            return
        } catch {
            // Neither `scanTopLevelInParallel` nor `scanDirectory` throws
            // anything but `ScanCancelled` — this branch exists solely
            // because Swift can't express "throws exactly one error type"
            // in a function signature.
            continuation.yield(.failed(error.localizedDescription))
            continuation.finish()
            return
        }

        let result = DiskSpaceScanResult(
            rootPath: rootPath,
            generatedAt: Date(),
            totalBytes: accumulator.totalBytes,
            totalItemCount: accumulator.itemsScanned,
            categoryTotals: accumulator.categoryTotals(),
            largestFolders: accumulator.finalizeFolders(),
            largestFiles: accumulator.finalizeFiles(),
            unreadableItemCount: accumulator.unreadableCount
        )
        continuation.yield(.completed(result))
        continuation.finish()
    }

    /// Fans `rootPath`'s immediate children out across up to
    /// `maxWorkerCount` concurrent `OperationQueue` threads — each worker
    /// takes full, exclusive ownership of one top-level child's entire
    /// subtree and walks it with the same `scanDirectory` recursion used
    /// before this type supported any concurrency at all, completely
    /// unchanged. Only `DiskSpaceAccumulator` (now lock-protected — see
    /// its own doc comment) and `CancellationToken` (already lock-protected
    /// and already checked at every item, from the original single-threaded
    /// design) are shared across those workers; nothing about the
    /// cancellation mechanism itself is new, which is deliberate — a
    /// second, worker-pool-specific cancel flag would risk exactly the
    /// kind of "two flags, one of them not wired up" bug that made an
    /// earlier parallel attempt at this fail to cancel reliably.
    ///
    /// Fanning out only at the top level (rather than at every directory
    /// depth) means a scan root dominated by one giant top-level folder
    /// sees less speedup than one with several similarly-sized siblings —
    /// an accepted v1 tradeoff. The alternative (recursing into deeper
    /// levels across workers too) would need each directory's bottom-up
    /// `(sizeBytes, itemCount)` to be reassembled from children finishing
    /// asynchronously on other threads, which is real complexity this
    /// design avoids by keeping `scanDirectory`'s own recursion fully
    /// synchronous and single-threaded within each worker.
    private static func scanTopLevelInParallel(
        rootPath: String,
        fileManager: FileManager,
        token: CancellationToken,
        accumulator: DiskSpaceAccumulator,
        reportProgress: @escaping (String?) -> Void
    ) throws {
        guard !token.isCancelled else { throw ScanCancelled() }

        guard let entries = try? fileManager.contentsOfDirectory(atPath: rootPath) else {
            accumulator.recordUnreadable()
            return
        }

        let workerCount = max(1, min(ProcessInfo.processInfo.activeProcessorCount, maxWorkerCount))
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = workerCount
        queue.qualityOfService = .utility

        for name in entries {
            guard !token.isCancelled else { break }
            let entryPath = "\(rootPath)/\(name)"

            guard let entry = statEntry(atPath: entryPath) else {
                accumulator.recordUnreadable()
                continue
            }

            if entry.isSymbolicLink {
                continue
            }

            if entry.isDirectory {
                let ext = (name as NSString).pathExtension.lowercased()
                if let bundleCategory = DiskSpaceFileCategory.bundleCategory(forExtension: ext) {
                    queue.addOperation {
                        guard !token.isCancelled else { return }
                        // A fresh `FileManager` per operation — see the
                        // matching comment on the plain-directory branch
                        // below for why.
                        let size = bundleSizeIgnoringErrors(atPath: entryPath, fileManager: FileManager(), token: token, accumulator: accumulator)
                        accumulator.addFile(path: entryPath, sizeBytes: size, category: bundleCategory)
                        reportProgress(entryPath)
                    }
                } else {
                    queue.addOperation {
                        guard !token.isCancelled else { return }
                        do {
                            // A fresh `FileManager` per operation rather
                            // than sharing the one passed into this
                            // function — simplest way to sidestep any
                            // doubt about `FileManager`'s concurrent-use
                            // guarantees (still needed here for
                            // `contentsOfDirectory`) when several of these
                            // run on different threads at once.
                            let (size, count) = try scanDirectory(
                                atPath: entryPath,
                                fileManager: FileManager(),
                                token: token,
                                accumulator: accumulator,
                                reportProgress: reportProgress
                            )
                            accumulator.addFolder(path: entryPath, sizeBytes: size, itemCount: count)
                        } catch {
                            // `scanDirectory` only ever throws
                            // `ScanCancelled`, which just means this
                            // subtree stopped early — `token.isCancelled`
                            // is checked once after every worker finishes,
                            // below, as the single source of truth for
                            // whether the whole scan was cancelled.
                        }
                    }
                }
            } else if !isDuplicateHardLink(entry, accumulator: accumulator) {
                let category = DiskSpaceFileCategory.classify(fileName: name)
                accumulator.addFile(path: entryPath, sizeBytes: entry.realSizeBytes, category: category)
            }
        }

        // Safe to block this thread: `performScan` already runs on its own
        // dedicated `DispatchQueue.global` thread, off the cooperative
        // pool, specifically so slow synchronous I/O like this is fine —
        // see `scan(rootPath:)`'s own doc comment.
        queue.waitUntilAllOperationsAreFinished()

        if token.isCancelled {
            throw ScanCancelled()
        }
    }

    /// Recurses `path`'s children, folding every plain file (and every
    /// bundle directory, sized as one opaque unit — see
    /// `DiskSpaceFileCategory.bundleCategory(forExtension:)`) into
    /// `accumulator`, and reports a `.progress` tick roughly every
    /// `progressStride` items. Symbolic links are never followed (`du`'s
    /// own default behavior) — this both avoids symlink cycles and
    /// matches what a person expects "how big is this folder" to mean.
    /// Throws `ScanCancelled` the moment `token` is cancelled, unwinding
    /// the whole recursion at once rather than threading a cancelled flag
    /// through every return.
    /// - Returns: This directory's own recursive `(sizeBytes, itemCount)`,
    ///   for its caller to fold into its own total and, if this directory
    ///   isn't the scan root, record as one `DiskSpaceFolderEntry`
    ///   candidate.
    private static func scanDirectory(
        atPath path: String,
        fileManager: FileManager,
        token: CancellationToken,
        accumulator: DiskSpaceAccumulator,
        reportProgress: (String?) -> Void
    ) throws -> (sizeBytes: UInt64, itemCount: Int) {
        guard !token.isCancelled else { throw ScanCancelled() }

        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else {
            accumulator.recordUnreadable()
            return (0, 0)
        }

        var directorySize: UInt64 = 0
        var directoryItemCount = 0

        for name in entries {
            guard !token.isCancelled else { throw ScanCancelled() }
            let entryPath = "\(path)/\(name)"

            guard let entry = statEntry(atPath: entryPath) else {
                accumulator.recordUnreadable()
                continue
            }

            if entry.isSymbolicLink {
                continue
            }

            if entry.isDirectory {
                let ext = (name as NSString).pathExtension.lowercased()
                if let bundleCategory = DiskSpaceFileCategory.bundleCategory(forExtension: ext) {
                    let size = bundleSizeIgnoringErrors(atPath: entryPath, fileManager: fileManager, token: token, accumulator: accumulator)
                    accumulator.addFile(path: entryPath, sizeBytes: size, category: bundleCategory)
                    directorySize += size
                    directoryItemCount += 1
                } else {
                    let (childSize, childCount) = try scanDirectory(
                        atPath: entryPath,
                        fileManager: fileManager,
                        token: token,
                        accumulator: accumulator,
                        reportProgress: reportProgress
                    )
                    accumulator.addFolder(path: entryPath, sizeBytes: childSize, itemCount: childCount)
                    directorySize += childSize
                    directoryItemCount += childCount
                }
            } else if !isDuplicateHardLink(entry, accumulator: accumulator) {
                let category = DiskSpaceFileCategory.classify(fileName: name)
                accumulator.addFile(path: entryPath, sizeBytes: entry.realSizeBytes, category: category)
                directorySize += entry.realSizeBytes
                directoryItemCount += 1
            }

            if accumulator.itemsScanned % progressStride == 0 {
                reportProgress(entryPath)
            }
        }

        return (directorySize, directoryItemCount)
    }

    /// Sums a bundle directory's (`.app`, `.framework`, ...) total size.
    /// Doesn't add anything to `accumulator`'s category breakdown or
    /// largest-files/folders lists — nothing inside a bundle should show
    /// up as its own entry there (see `scanDirectory`'s bundle branch
    /// above) — but does still consult `accumulator`'s hard-link tracking,
    /// since a bundle's own internal toolchain (Xcode.app's platform SDKs
    /// are the extreme case) can hard-link the same file under many
    /// internal names, and without dedup a single bundle can already
    /// report a wildly inflated size on its own. Still checks `token`
    /// between directories so cancelling mid-scan doesn't have to wait out
    /// one giant bundle first.
    private static func bundleSizeIgnoringErrors(
        atPath path: String,
        fileManager: FileManager,
        token: CancellationToken,
        accumulator: DiskSpaceAccumulator
    ) -> UInt64 {
        guard !token.isCancelled else { return 0 }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return 0 }
        var total: UInt64 = 0
        for name in entries {
            guard !token.isCancelled else { break }
            let entryPath = "\(path)/\(name)"
            guard let entry = statEntry(atPath: entryPath) else { continue }
            if entry.isSymbolicLink { continue }
            if entry.isDirectory {
                total += bundleSizeIgnoringErrors(atPath: entryPath, fileManager: fileManager, token: token, accumulator: accumulator)
            } else if !isDuplicateHardLink(entry, accumulator: accumulator) {
                total += entry.realSizeBytes
            }
        }
        return total
    }
}

// MARK: - Accumulator

/// Mutable running totals for one `DiskSpaceScanner.performScan` call — a
/// plain reference type (not `inout` parameters threaded through the
/// recursion) so `scanDirectory`'s nested `reportProgress` closure and
/// every recursive call it makes always see the same, live, up-to-date
/// counts rather than risking a stale copy from Swift's normal
/// copy-in/copy-out `inout` semantics.
///
/// One instance is now shared across every `scanTopLevelInParallel`
/// worker thread at once (each owns a disjoint subtree, but all of them
/// fold their results into this same accumulator), so every mutation and
/// every read goes through `lock` — `@unchecked Sendable` for the same
/// reason `CancellationToken`/`TokenBox` below are: the compiler can't
/// verify a hand-rolled lock, but every stored property actually is only
/// ever touched while holding it.
private final class DiskSpaceAccumulator: @unchecked Sendable {
    private let lock = NSLock()

    private var _totalBytes: UInt64 = 0
    private var _itemsScanned = 0
    private var _unreadableCount = 0
    private var folderCollector: TopSizeCollector<DiskSpaceFolderEntry>
    private var fileCollector: TopSizeCollector<DiskSpaceFileEntry>
    private var categoryBytes: [DiskSpaceFileCategory: UInt64] = [:]
    private var categoryCounts: [DiskSpaceFileCategory: Int] = [:]
    /// (device, inode) pairs already counted for a multiply-linked file —
    /// see `DiskSpaceScanner.isDuplicateHardLink`. Only files with more
    /// than one hard link are ever inserted, so this stays far smaller
    /// than the total item count on an ordinary volume.
    private var seenHardLinks: Set<HardLinkID> = []

    private struct HardLinkID: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    init(topListLimit: Int) {
        folderCollector = TopSizeCollector(limit: topListLimit)
        fileCollector = TopSizeCollector(limit: topListLimit)
    }

    var totalBytes: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _totalBytes
    }

    var itemsScanned: Int {
        lock.lock(); defer { lock.unlock() }
        return _itemsScanned
    }

    var unreadableCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _unreadableCount
    }

    func recordUnreadable() {
        lock.lock()
        _unreadableCount += 1
        lock.unlock()
    }

    /// Records this (device, inode) pair as counted, returning `true` the
    /// first time it's seen (caller should count the file) and `false` on
    /// every later call for the same pair (caller should skip it — it's a
    /// hard link to a file already counted under a different name).
    func isFirstSighting(device: UInt64, inode: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return seenHardLinks.insert(HardLinkID(device: device, inode: inode)).inserted
    }

    func addFile(path: String, sizeBytes: UInt64, category: DiskSpaceFileCategory) {
        lock.lock()
        _totalBytes += sizeBytes
        _itemsScanned += 1
        categoryBytes[category, default: 0] += sizeBytes
        categoryCounts[category, default: 0] += 1
        fileCollector.insert(size: sizeBytes, value: DiskSpaceFileEntry(path: path, sizeBytes: sizeBytes, category: category))
        lock.unlock()
    }

    func addFolder(path: String, sizeBytes: UInt64, itemCount: Int) {
        lock.lock()
        folderCollector.insert(size: sizeBytes, value: DiskSpaceFolderEntry(path: path, sizeBytes: sizeBytes, itemCount: itemCount))
        lock.unlock()
    }

    /// Every `DiskSpaceFileCategory` in its own `allCases` (legend) order,
    /// zero-sized entries included — see `DiskSpaceScanResult
    /// .categoryTotals`'s own doc comment.
    func categoryTotals() -> [DiskSpaceCategoryTotal] {
        lock.lock(); defer { lock.unlock() }
        return Self.categoryTotalsLocked(bytes: categoryBytes, counts: categoryCounts)
    }

    /// One locked read of everything a `.progress` tick needs, so a
    /// concurrent writer's file can never be observed split across two
    /// separate lock acquisitions (its bytes counted but its category not
    /// yet, or vice versa).
    func progressSnapshot() -> (items: Int, bytes: UInt64, categoryTotals: [DiskSpaceCategoryTotal]) {
        lock.lock(); defer { lock.unlock() }
        return (_itemsScanned, _totalBytes, Self.categoryTotalsLocked(bytes: categoryBytes, counts: categoryCounts))
    }

    func finalizeFolders() -> [DiskSpaceFolderEntry] {
        lock.lock(); defer { lock.unlock() }
        return folderCollector.finalize()
    }

    func finalizeFiles() -> [DiskSpaceFileEntry] {
        lock.lock(); defer { lock.unlock() }
        return fileCollector.finalize()
    }

    private static func categoryTotalsLocked(
        bytes: [DiskSpaceFileCategory: UInt64],
        counts: [DiskSpaceFileCategory: Int]
    ) -> [DiskSpaceCategoryTotal] {
        DiskSpaceFileCategory.allCases.map { category in
            DiskSpaceCategoryTotal(
                category: category,
                sizeBytes: bytes[category] ?? 0,
                itemCount: counts[category] ?? 0
            )
        }
    }
}

/// Exact (not approximate) bounded top-K collector. Batches inserts and
/// only sorts+trims once the buffer grows to `limit * 4`, rather than
/// re-sorting after every single insert — safe because trimming down to
/// the top `limit` items by size can never discard something that would
/// have survived to the final top `limit`: a discarded item was never
/// among the top `limit` at that point, and no later insert of a
/// *smaller* item could ever push it back in.
private struct TopSizeCollector<Value> {
    let limit: Int
    private var items: [(size: UInt64, value: Value)] = []

    init(limit: Int) {
        self.limit = limit
    }

    mutating func insert(size: UInt64, value: Value) {
        guard size > 0 else { return }
        items.append((size, value))
        if items.count >= limit * 4 {
            trim()
        }
    }

    /// Final sorted (largest-first), trimmed result. Safe to call more
    /// than once.
    mutating func finalize() -> [Value] {
        trim()
        return items.map(\.value)
    }

    private mutating func trim() {
        items.sort { $0.size > $1.size }
        if items.count > limit {
            items.removeLast(items.count - limit)
        }
    }
}

// MARK: - Cancellation

/// Thread-safe cancel flag shared between whatever calls
/// `cancelActiveScan()`/lets the stream's consumer stop, and the
/// `DispatchQueue.global` thread actually walking the filesystem.
/// Deliberately a plain lock rather than actor-isolated state: checking an
/// actor-isolated property from inside the scan's tight per-item loop
/// would mean an `await` — and a hop off the background thread — for
/// every single file, which would slow the scan down far more than a lock
/// ever does.
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

/// Holds the `CancellationToken` for whichever scan is currently active,
/// behind its own lock rather than actor isolation. `DiskSpaceScanner`
/// stores this in a `let` property: Swift permits `nonisolated` access to
/// an actor's immutable, `Sendable`-typed stored properties without an
/// `await`, which is what lets both `scan(rootPath:)` and
/// `cancelActiveScan()` stay synchronous and take effect immediately
/// rather than needing to hop onto the actor first.
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
