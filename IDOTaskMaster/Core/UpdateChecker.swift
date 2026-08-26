import AppKit
import Foundation

/// Checks GitHub Releases for a version newer than the one currently
/// running — the real implementation behind Settings ▸ Updates' "Check for
/// Updates Now" button and "Check for Updates on Launch" toggle
/// (`SettingsStore.checkForUpdatesOnLaunch`). No Sparkle/appcast
/// dependency: this reads the repo's public `/releases/latest` endpoint,
/// which needs no auth token for a public repo and already excludes
/// drafts/pre-releases (this app's own release process — PLAN.md §6 —
/// never publishes either).
///
/// "Download & Install…" downloads the release's universal `.dmg` asset
/// straight from GitHub and hands it to `NSWorkspace.shared.open` — the
/// same thing macOS does when you double-click a file you downloaded in
/// Safari, which mounts the disk image and shows its Finder window with
/// the app + Applications-alias drag target. This app never runs the
/// installer, moves anything into `/Applications`, or replaces its own
/// bundle — the drag-and-drop step (and Gatekeeper's "unidentified
/// developer" right-click-Open, same as every release so far) stays
/// exactly as manual as it's always been, matching the "explicit user
/// action for anything that changes local state" pattern Clean Up and
/// Installed Apps' uninstall already follow. It does quit the app itself
/// a moment after opening the DMG, though — see `downloadAndOpenInstaller`
/// — since a running app can't have its own bundle overwritten by the
/// drag-and-drop that's about to happen.
///
/// Owned by `AppDelegate` alongside `alertsEngine`/`networkMonitor` so a
/// launch-time check (when `checkForUpdatesOnLaunch` is on) has already
/// populated `lastResult` by the time the user opens Settings, rather than
/// `SettingsPage` needing its own separate instance that starts from
/// scratch every time the window opens.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Result: Equatable {
        case upToDate(current: String)
        case updateAvailable(latest: String, releaseURL: URL, dmgURL: URL?)
        case failed(String)
    }

    enum DownloadState: Equatable {
        case idle
        case downloading
        case failed(String)
    }

    /// The outcome of the most recently completed check — `nil` until the
    /// first one finishes. `UpdatesSettingsTab` reads this directly rather
    /// than polling, since it's `@Published`.
    @Published private(set) var lastResult: Result?
    @Published private(set) var isChecking = false
    /// State of the "Download & Install…" button's own action, kept
    /// separate from `lastResult` — a download failure shouldn't erase the
    /// fact that a newer version was found.
    @Published private(set) var downloadState: DownloadState = .idle

    private static let repoSlug = "galihlasahido/IDOTaskMaster"
    private static let releasesURL = URL(string: "https://api.github.com/repos/\(repoSlug)/releases/latest")!

    /// Runs one check and updates `lastResult`. Safe to call while a
    /// previous check is still in flight — it just runs concurrently
    /// rather than being coalesced/cancelled, since a user pressing the
    /// button twice in a row (or the launch-time check overlapping a
    /// manual press) is rare and harmless here.
    func check() async {
        isChecking = true
        defer { isChecking = false }

        guard let current = Self.currentVersion() else {
            lastResult = .failed("This build has no CFBundleShortVersionString to compare against.")
            return
        }

        do {
            var request = URLRequest(url: Self.releasesURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("IDOTaskMaster-UpdateChecker", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                lastResult = .failed("GitHub returned status \(code).")
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName

            guard let releaseURL = URL(string: release.htmlURL) else {
                lastResult = .failed("GitHub's release page URL was malformed.")
                return
            }

            if Self.isNewer(latest, than: current) {
                let dmgURL = Self.universalDMGAsset(in: release)
                lastResult = .updateAvailable(latest: latest, releaseURL: releaseURL, dmgURL: dmgURL)
            } else {
                lastResult = .upToDate(current: current)
            }
        } catch {
            lastResult = .failed(error.localizedDescription)
        }
    }

    /// Downloads `url` (the universal `.dmg` asset from `lastResult`) to
    /// the user's Downloads folder and opens it — see this type's own doc
    /// comment for why that, not a silent in-place replace, is as far as
    /// this goes. Quits the app shortly after the DMG opens, so it isn't
    /// still running (and holding its own bundle in place) by the time the
    /// user drags the new one over it in the Finder window that just
    /// appeared — the same reason Finder can't overwrite an app while it's
    /// open.
    func downloadAndOpenInstaller(from url: URL) async {
        downloadState = .downloading

        do {
            var request = URLRequest(url: url)
            request.setValue("IDOTaskMaster-UpdateChecker", forHTTPHeaderField: "User-Agent")

            let (tempURL, response) = try await URLSession.shared.download(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                downloadState = .failed("Download failed (status \(code)).")
                return
            }

            let downloadsDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            let destination = downloadsDir.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)

            downloadState = .idle
            NSWorkspace.shared.open(destination)

            // Give the Finder/DiskImages round trip a moment to actually
            // start mounting before this process disappears out from under
            // it.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            NSApp.terminate(nil)
        } catch {
            downloadState = .failed(error.localizedDescription)
        }
    }

    static func currentVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// Plain dotted-integer comparison (`"0.10.0" > "0.3.0"`, unlike a
    /// naive string compare) — this app's tags are always `MAJOR.MINOR.PATCH`
    /// (`scripts/release.sh`), so nothing more elaborate (pre-release
    /// suffixes, build metadata) is needed.
    private static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0) ?? 0 } }
        let l = parts(latest), c = parts(current)
        for i in 0..<max(l.count, c.count) {
            let lv = i < l.count ? l[i] : 0
            let cv = i < c.count ? c[i] : 0
            if lv != cv { return lv > cv }
        }
        return false
    }

    /// `scripts/dmg.sh`/`dmg-intel.sh` publish two `.dmg` assets per
    /// release (universal + Intel-only, per README's download table) —
    /// this always prefers the universal one so "Download & Install…"
    /// works regardless of which Mac it's clicked on, rather than needing
    /// to detect the running architecture.
    private static func universalDMGAsset(in release: GitHubRelease) -> URL? {
        let asset = release.assets.first { $0.name.hasSuffix(".dmg") && !$0.name.localizedCaseInsensitiveContains("intel") }
        return asset.flatMap { URL(string: $0.browserDownloadURL) }
    }

    private struct GitHubRelease: Decodable {
        let tagName: String
        let htmlURL: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case assets
        }

        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name
                case browserDownloadURL = "browser_download_url"
            }
        }
    }
}
