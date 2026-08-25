import AppKit
import Foundation

/// Which well-known per-user location a discovered `RelatedFile` came from
/// — PLAN.md §1.1's "Related Files finder". Kept as its own enum (rather
/// than a free-form string) so `InstalledAppsPage`'s related-files list can
/// group/label rows without re-deriving the location from the raw path.
enum RelatedFileKind: String, Sendable, CaseIterable {
    case preferences
    case applicationSupport
    case caches
    case savedState
    case containers
    case httpStorage
    case webKitData
    case logs

    var displayName: String {
        switch self {
        case .preferences: return "Preferences"
        case .applicationSupport: return "Application Support"
        case .caches: return "Caches"
        case .savedState: return "Saved Application State"
        case .containers: return "Container"
        case .httpStorage: return "HTTP Storage"
        case .webKitData: return "WebKit Data"
        case .logs: return "Logs"
        }
    }
}

/// One leftover file or folder `InstalledAppsProvider.relatedFiles(for:)`
/// found for a given `InstalledApp` — PLAN.md §1.1's "Related Files finder"
/// and the extra items `InstalledAppsProvider.uninstall(_:alsoTrashing:)`
/// can be asked to trash alongside the app bundle itself.
struct RelatedFile: Sendable, Equatable, Identifiable {
    var id: String { path }
    let path: String
    let kind: RelatedFileKind
    /// `nil` when `du` couldn't size this item (unreadable, or it
    /// disappeared between being found and being sized) — an honest gap,
    /// not a zero.
    let sizeBytes: UInt64?
}

/// One `/Applications` bundle's identity, size, and file metadata — PLAN.md
/// §3's `Providers/InstalledAppsProvider.swift "/Applications scan, bundle
/// metadata, sizes"` and §4 M6's third task.
struct InstalledApp: Sendable, Equatable, Identifiable {
    var id: String { bundlePath }

    let bundlePath: String
    /// `CFBundleDisplayName`, falling back to `CFBundleName`, falling back
    /// to the bundle's filename with `.app` stripped — the same
    /// most-specific-first fallback chain `StartupItem.displayName` uses
    /// for a plist's own `Label`.
    let name: String
    let bundleIdentifier: String?
    /// `CFBundleShortVersionString` — the human "Version" a user recognizes
    /// (e.g. "17.2"), as opposed to `buildString`'s internal build number.
    let versionString: String?
    /// `CFBundleVersion` — the build number `versionString` doesn't carry.
    let buildString: String?
    let minimumSystemVersion: String?
    /// Human-readable form of `LSApplicationCategoryType`'s UTI-style
    /// string (e.g. `"public.app-category.developer-tools"` →
    /// "Developer Tools") — `nil` when the bundle declares no category.
    let categoryLabel: String?
    let executablePath: String?
    /// `codesign -dv`'s leaf `Authority=` line — used as a publisher/
    /// editor detail field for the app. `nil` for an unsigned or
    /// ad-hoc-signed bundle.
    let publisher: String?
    /// Recursive on-disk size of the whole bundle via `du -sk`, matching
    /// what Finder's own "Get Info" reports (allocated blocks, not raw
    /// byte lengths). `nil` when `du` failed or the bundle vanished mid-scan.
    let sizeBytes: UInt64?
    /// 64×64 PNG icon rendered from `NSWorkspace`, the same encode-to-`Data`
    /// treatment `ProcessProvider.pngData(from:pixelSize:)` uses so this
    /// `Sendable` value can cross out of this provider's actor without
    /// carrying an `NSImage`. `var`, not `let`: `InstalledAppsProvider
    /// .attachIcons(to:)` fills this in as a second pass over an
    /// already-built `InstalledApp` — see that method's own doc comment.
    var iconPNGData: Data?
    let modifiedAt: Date?
    let createdAt: Date?
    /// `true` when this bundle resolves under `/System` (Apple's own
    /// read-only apps, several of which are only reachable via a symlink
    /// left in `/Applications`) — `InstalledAppsProvider.uninstall` refuses
    /// to touch these regardless of what the caller asks for, matching
    /// PLAN.md §3's "Permissions note" (no privileged helper in v1, so this
    /// app must never attempt what it can't honestly do).
    let isAppleSystemApp: Bool
}

struct InstalledAppsCatalog: Sendable, Equatable {
    let apps: [InstalledApp]
    let generatedAt: Date
}

enum InstalledAppsProviderError: Error, LocalizedError {
    case directoryUnreadable

    var errorDescription: String? {
        switch self {
        case .directoryUnreadable:
            return "/Applications could not be read"
        }
    }
}

/// Failure modes for `InstalledAppsProvider.uninstall(_:alsoTrashing:)`.
/// Failing to trash one *related* file is deliberately not one of these —
/// see that method's own doc comment for why a related-file failure is
/// reported back to the caller instead of thrown.
enum UninstallError: Error, LocalizedError {
    case appleSystemApp
    case trashFailed(String)

    var errorDescription: String? {
        switch self {
        case .appleSystemApp:
            return "This app is part of macOS and can\u{2019}t be uninstalled."
        case .trashFailed(let detail):
            return "Couldn\u{2019}t move it to the Trash: \(detail)"
        }
    }
}

/// Scans `/Applications` (and each of its own subfolders one level deep,
/// e.g. `/Applications/Utilities`) for `.app` bundles, reads each one's
/// `Info.plist`/`codesign`/`du` metadata, and can trash a bundle plus any
/// `relatedFiles(for:)`-discovered leftovers — PLAN.md §3's
/// `InstalledAppsProvider` and §4 M6's third task in full: "/Applications
/// scan, sizes, bundle metadata, related-files finder, Uninstall (move to
/// Trash + related files)."
///
/// An `actor`, driven by its page exactly like `StartupProvider`/
/// `SystemInfoProvider` (load-once-then-Reload, not a `Sampler` tick):
/// sizing every bundle with `du -sk` is easily the slowest scan in this
/// app — a handful of very large apps (Xcode, Final Cut Pro, ...) alone can
/// take several seconds — nowhere near fast enough for a 2×/sec tick.
actor InstalledAppsProvider: Provider {
    static let providerID = "installedApps"

    private(set) var cachedCatalog: InstalledAppsCatalog?

    /// Every top-level directory this provider scans, in display-source
    /// order. Only `/Applications` per PLAN.md's own task title; a Mac's
    /// Apple-provided apps mostly live in `/System/Applications` today and
    /// are out of scope for a page whose whole point is *removable*
    /// software.
    private static let scanRoot = "/Applications"

    func sample() async throws -> InstalledAppsCatalog {
        let catalog = try await Self.scan()
        cachedCatalog = catalog
        return catalog
    }

    // MARK: - Scan

    /// Hops to a background queue for the same reason every other
    /// shell-out-backed provider in this app does (see
    /// `StartupProvider.scan()`'s doc comment), then a second hop onto the
    /// main actor purely to render icons — `NSWorkspace`/`NSImage` aren't
    /// safe to touch off it, matching `ProcessProvider
    /// .readRunningApplications(skippingIconsFor:)`'s own split.
    private static func scan() async throws -> InstalledAppsCatalog {
        let withoutIcons = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[InstalledApp], Error>) in
            DispatchQueue.global(qos: .utility).async {
                do {
                    continuation.resume(returning: try scanBundlesSynchronously())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let apps = await attachIcons(to: withoutIcons)
        return InstalledAppsCatalog(apps: apps, generatedAt: Date())
    }

    /// Must only ever run on the background queue `scan()` dispatches onto.
    /// Every field except `iconPNGData` is filled in here; `scan()` fills
    /// that one in afterward on the main actor.
    private static func scanBundlesSynchronously() throws -> [InstalledApp] {
        let fileManager = FileManager.default
        guard let topLevel = try? fileManager.contentsOfDirectory(atPath: scanRoot) else {
            throw InstalledAppsProviderError.directoryUnreadable
        }

        var bundlePaths: [String] = []
        for name in topLevel {
            let path = "\(scanRoot)/\(name)"
            if name.hasSuffix(".app") {
                bundlePaths.append(path)
                continue
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            // One level into a plain subfolder (e.g. "Utilities") for its
            // own `.app` bundles — deliberately not recursed any deeper,
            // both to bound scan time and because macOS itself never nests
            // installed apps more than one folder below `/Applications`.
            guard let nested = try? fileManager.contentsOfDirectory(atPath: path) else { continue }
            for nestedName in nested where nestedName.hasSuffix(".app") {
                bundlePaths.append("\(path)/\(nestedName)")
            }
        }

        return bundlePaths
            .compactMap { installedApp(atBundlePath: $0, fileManager: fileManager) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Builds one `InstalledApp` (with `iconPNGData: nil` — filled in by
    /// `attachIcons` afterward) from one `.app` path, or `nil` when
    /// `Bundle(path:)` itself couldn't open it — dropped from the result
    /// rather than shown as a broken row, matching
    /// `StartupProvider.startupItem`'s own per-item degradation grain.
    private static func installedApp(atBundlePath path: String, fileManager: FileManager) -> InstalledApp? {
        guard let bundle = Bundle(path: path) else { return nil }
        let info = bundle.infoDictionary ?? [:]

        let filenameStem = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? filenameStem
        let category = (info["LSApplicationCategoryType"] as? String).flatMap(categoryLabel(fromUTI:))

        let attributes = try? fileManager.attributesOfItem(atPath: path)
        let modifiedAt = attributes?[.modificationDate] as? Date
        let createdAt = attributes?[.creationDate] as? Date

        let resolvedPath = URL(fileURLWithPath: path).resolvingSymlinksInPath().path

        return InstalledApp(
            bundlePath: path,
            name: name,
            bundleIdentifier: bundle.bundleIdentifier,
            versionString: info["CFBundleShortVersionString"] as? String,
            buildString: info["CFBundleVersion"] as? String,
            minimumSystemVersion: info["LSMinimumSystemVersion"] as? String,
            categoryLabel: category,
            executablePath: bundle.executablePath,
            publisher: codesignAuthority(atPath: path),
            sizeBytes: directorySizeBytes(atPath: path),
            iconPNGData: nil,
            modifiedAt: modifiedAt,
            createdAt: createdAt,
            isAppleSystemApp: resolvedPath.hasPrefix("/System/")
        )
    }

    /// `"public.app-category.developer-tools"` → `"Developer Tools"` — no
    /// exhaustive lookup table (Apple's own category UTI list changes
    /// occasionally); derived generically from the UTI's own last
    /// hyphen-separated component, which is legible for every category
    /// Apple currently documents.
    private static func categoryLabel(fromUTI uti: String) -> String? {
        guard let suffix = uti.split(separator: ".").last, !suffix.isEmpty else { return nil }
        let words = suffix.split(separator: "-").map { $0.capitalized }
        return words.joined(separator: " ")
    }

    // MARK: - Icons (main actor)

    /// Renders every app's icon via `NSWorkspace` and returns a new array
    /// with `iconPNGData` filled in — see `scan()`'s doc comment for why
    /// this is a separate main-actor pass rather than done inline in
    /// `scanBundlesSynchronously`.
    private static func attachIcons(to apps: [InstalledApp]) async -> [InstalledApp] {
        await MainActor.run {
            apps.map { app in
                var app = app
                let icon = NSWorkspace.shared.icon(forFile: app.bundlePath)
                app.iconPNGData = pngData(from: icon, pixelSize: 64)
                return app
            }
        }
    }

    /// Same fixed-size RGBA-bitmap PNG encode `ProcessProvider
    /// .pngData(from:pixelSize:)` uses, reimplemented here rather than
    /// shared — matching `ConnectionsProvider`'s own "a little duplication
    /// between providers with genuinely different scopes" precedent.
    private static func pngData(from image: NSImage, pixelSize: Int) -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context
        image.draw(
            in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: - Size / publisher (shell-outs)

    /// `du -sk <path>`'s first field, in bytes — Finder "Get Info"'s own
    /// notion of a folder's size (allocated blocks), not a byte-exact sum
    /// of file lengths. `nil` on any failure (missing `du`, unreadable
    /// path, non-zero exit).
    private static func directorySizeBytes(atPath path: String) -> UInt64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }

        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let whitespaceIndex = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) else { return nil }
        guard let kilobytes = UInt64(trimmed[..<whitespaceIndex]) else { return nil }
        return kilobytes * 1024
    }

    /// `codesign -dv --verbose=2 <path>`'s leaf `Authority=` line — the
    /// same technique and same "first `Authority=` line, leaf certificate"
    /// reasoning as `StartupViewModel.codesignPublisherSynchronously
    /// (forExecutablePath:)`, run against the whole `.app` bundle path
    /// (rather than its inner executable) since `codesign` accepts either
    /// and a bundle-level signature is what actually matters for an app.
    private static func codesignAuthority(atPath path: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-dv", "--verbose=2", path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()

        guard (try? process.run()) != nil else { return nil }
        let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.split(separator: "\n") {
            if line.hasPrefix("Authority=") {
                let value = line.dropFirst("Authority=".count).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }

    // MARK: - Related files finder

    /// PLAN.md's "Related Files finder" — best-effort scan of the handful
    /// of well-known per-user locations macOS apps conventionally leave
    /// data in, keyed by `app`'s bundle identifier (falling back to its
    /// display name for the two locations Apple's own conventions key by
    /// name instead of identifier). Only `~/Library/...` locations are
    /// checked — never `/Library/...` — since this unprivileged, no-helper
    /// app (PLAN.md §3's "Permissions note") could find but never actually
    /// trash anything under a system-wide path without elevated rights, and
    /// listing items it then can't offer to remove would be misleading
    /// rather than useful.
    func relatedFiles(for app: InstalledApp) async -> [RelatedFile] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: Self.findRelatedFilesSynchronously(for: app))
            }
        }
    }

    /// Must only ever run on the background queue `relatedFiles(for:)`
    /// dispatches onto.
    private static func findRelatedFilesSynchronously(for app: InstalledApp) -> [RelatedFile] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path

        var candidates: [(path: String, kind: RelatedFileKind)] = []
        if let bundleID = app.bundleIdentifier, !bundleID.isEmpty {
            candidates.append(("\(home)/Library/Preferences/\(bundleID).plist", .preferences))
            candidates.append(("\(home)/Library/Caches/\(bundleID)", .caches))
            candidates.append(("\(home)/Library/Saved Application State/\(bundleID).savedState", .savedState))
            candidates.append(("\(home)/Library/Containers/\(bundleID)", .containers))
            candidates.append(("\(home)/Library/HTTPStorages/\(bundleID)", .httpStorage))
            candidates.append(("\(home)/Library/WebKit/\(bundleID)", .webKitData))
        }
        candidates.append(("\(home)/Library/Application Support/\(app.name)", .applicationSupport))
        candidates.append(("\(home)/Library/Logs/\(app.name)", .logs))

        return candidates
            .filter { fileManager.fileExists(atPath: $0.path) }
            .map { RelatedFile(path: $0.path, kind: $0.kind, sizeBytes: directorySizeBytes(atPath: $0.path)) }
    }

    // MARK: - Uninstall

    /// Moves `app`'s bundle, then each of `relatedFiles`, to the Trash —
    /// PLAN.md's "Uninstall (move to Trash + related files)". Reversible
    /// (the Trash, not `rm`) and never touches anything outside what the
    /// caller explicitly asked for: `InstalledAppsPage` passes only the
    /// related files the user actually checked in its uninstall sheet, not
    /// every candidate `relatedFiles(for:)` found.
    ///
    /// The app bundle itself must trash successfully or this throws
    /// without touching any related file. Once that's done, though, a
    /// failure trashing any *individual* related file (permissions, the
    /// path having already vanished, ...) is folded into the returned
    /// array rather than thrown — the app is already gone at that point,
    /// which is the outcome the caller actually asked for; a leftover
    /// cache folder failing to trash shouldn't read as the whole uninstall
    /// having failed. `InstalledAppsPage` surfaces any such partial
    /// failures in its own follow-up alert.
    /// - Returns: The subset of `relatedFiles` that did **not** trash
    ///   successfully (empty when every one succeeded).
    @discardableResult
    func uninstall(_ app: InstalledApp, alsoTrashing relatedFiles: [RelatedFile]) async throws -> [RelatedFile] {
        guard !app.isAppleSystemApp else { throw UninstallError.appleSystemApp }

        try await Self.trash(path: app.bundlePath)

        var failures: [RelatedFile] = []
        for file in relatedFiles {
            do {
                try await Self.trash(path: file.path)
            } catch {
                failures.append(file)
            }
        }
        return failures
    }

    /// Hops to a background queue since `FileManager.trashItem` blocks
    /// (and can itself prompt for admin authorization via Finder when the
    /// item isn't owned by the current user) — same reasoning as every
    /// other blocking-call hop in this file.
    private static func trash(path: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: UninstallError.trashFailed(error.localizedDescription))
                }
            }
        }
    }
}
