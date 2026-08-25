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

    private static let mediaExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "heic", "heif", "bmp", "tiff", "tif", "svg", "webp", "raw", "psd", "ico",
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
    /// been read yet.
    let currentPath: String?
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

    private struct ScanCancelled: Error {}

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
            continuation.yield(.progress(DiskSpaceScanProgress(
                itemsScanned: accumulator.itemsScanned,
                bytesScanned: accumulator.totalBytes,
                currentPath: currentPath
            )))
        }
        reportProgress(currentPath: rootPath)

        do {
            _ = try scanDirectory(
                atPath: rootPath,
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
            // `scanDirectory` only ever throws `ScanCancelled` — this
            // branch exists solely because Swift can't express "throws
            // exactly one error type" in a function signature.
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
            largestFolders: accumulator.folderCollector.finalize(),
            largestFiles: accumulator.fileCollector.finalize(),
            unreadableItemCount: accumulator.unreadableCount
        )
        continuation.yield(.completed(result))
        continuation.finish()
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
            accumulator.unreadableCount += 1
            return (0, 0)
        }

        var directorySize: UInt64 = 0
        var directoryItemCount = 0

        for name in entries {
            guard !token.isCancelled else { throw ScanCancelled() }
            let entryPath = "\(path)/\(name)"

            guard let attributes = try? fileManager.attributesOfItem(atPath: entryPath) else {
                accumulator.unreadableCount += 1
                continue
            }
            let fileType = attributes[.type] as? FileAttributeType

            if fileType == .typeSymbolicLink {
                continue
            }

            if fileType == .typeDirectory {
                let ext = (name as NSString).pathExtension.lowercased()
                if let bundleCategory = DiskSpaceFileCategory.bundleCategory(forExtension: ext) {
                    let size = bundleSizeIgnoringErrors(atPath: entryPath, fileManager: fileManager, token: token)
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
            } else {
                let sizeBytes = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
                let category = DiskSpaceFileCategory.classify(fileName: name)
                accumulator.addFile(path: entryPath, sizeBytes: sizeBytes, category: category)
                directorySize += sizeBytes
                directoryItemCount += 1
            }

            if accumulator.itemsScanned % progressStride == 0 {
                reportProgress(entryPath)
            }
        }

        return (directorySize, directoryItemCount)
    }

    /// Sums a bundle directory's (`.app`, `.framework`, ...) total size
    /// without touching `accumulator` — nothing inside a bundle should
    /// show up in the category breakdown or largest-files/folders lists
    /// as its own entry (see `scanDirectory`'s bundle branch above). Still
    /// checks `token` between directories so cancelling mid-scan doesn't
    /// have to wait out one giant bundle (Xcode.app, ...) first.
    private static func bundleSizeIgnoringErrors(atPath path: String, fileManager: FileManager, token: CancellationToken) -> UInt64 {
        guard !token.isCancelled else { return 0 }
        guard let entries = try? fileManager.contentsOfDirectory(atPath: path) else { return 0 }
        var total: UInt64 = 0
        for name in entries {
            guard !token.isCancelled else { break }
            let entryPath = "\(path)/\(name)"
            guard let attributes = try? fileManager.attributesOfItem(atPath: entryPath) else { continue }
            let fileType = attributes[.type] as? FileAttributeType
            if fileType == .typeSymbolicLink { continue }
            if fileType == .typeDirectory {
                total += bundleSizeIgnoringErrors(atPath: entryPath, fileManager: fileManager, token: token)
            } else {
                total += (attributes[.size] as? NSNumber)?.uint64Value ?? 0
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
private final class DiskSpaceAccumulator {
    private(set) var totalBytes: UInt64 = 0
    private(set) var itemsScanned = 0
    var unreadableCount = 0
    // `var`, not `let`: `TopSizeCollector.insert`/`finalize` are `mutating`
    // methods, which need a mutable property even though `self` here is a
    // class (mutating `self`'s own stored properties never requires the
    // property itself, only the *method*, to be non-`let`).
    var folderCollector: TopSizeCollector<DiskSpaceFolderEntry>
    var fileCollector: TopSizeCollector<DiskSpaceFileEntry>

    private var categoryBytes: [DiskSpaceFileCategory: UInt64] = [:]
    private var categoryCounts: [DiskSpaceFileCategory: Int] = [:]

    init(topListLimit: Int) {
        folderCollector = TopSizeCollector(limit: topListLimit)
        fileCollector = TopSizeCollector(limit: topListLimit)
    }

    func addFile(path: String, sizeBytes: UInt64, category: DiskSpaceFileCategory) {
        totalBytes += sizeBytes
        itemsScanned += 1
        categoryBytes[category, default: 0] += sizeBytes
        categoryCounts[category, default: 0] += 1
        fileCollector.insert(size: sizeBytes, value: DiskSpaceFileEntry(path: path, sizeBytes: sizeBytes, category: category))
    }

    func addFolder(path: String, sizeBytes: UInt64, itemCount: Int) {
        folderCollector.insert(size: sizeBytes, value: DiskSpaceFolderEntry(path: path, sizeBytes: sizeBytes, itemCount: itemCount))
    }

    /// Every `DiskSpaceFileCategory` in its own `allCases` (legend) order,
    /// zero-sized entries included — see `DiskSpaceScanResult
    /// .categoryTotals`'s own doc comment.
    func categoryTotals() -> [DiskSpaceCategoryTotal] {
        DiskSpaceFileCategory.allCases.map { category in
            DiskSpaceCategoryTotal(
                category: category,
                sizeBytes: categoryBytes[category] ?? 0,
                itemCount: categoryCounts[category] ?? 0
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
