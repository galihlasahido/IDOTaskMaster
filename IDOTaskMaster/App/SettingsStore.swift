import SwiftUI

/// User-configurable app preferences, persisted across launches.
///
/// M0 scope is just the real-time update-speed preference called out in
/// PLAN.md §1.1 ("General: real-time update speed (e.g. Normal — 2/sec)")
/// and named in the architecture tree in §3
/// (`SettingsStore.swift # @AppStorage-backed preferences`). Later
/// milestones (default start page, appearance, graph history options,
/// update checks, etc. — M8) add more `@Published` properties here; the
/// menu bar's View ▸ Update Frequency ⌘-1/2/3 commands (the remaining
/// M0 scaffold item) and the Settings window's General tab (M8) are both
/// expected to read and write `updateSpeed` through this one store so
/// they stay in sync with each other and with whatever `Sampler` the app
/// is driving.
///
/// Implemented as a `@Published` property persisted to `UserDefaults`
/// rather than a bare `@AppStorage` property wrapper: `@AppStorage` only
/// wires into SwiftUI's invalidation machinery when it is a stored
/// property of a `View`/`App`/`Scene` itself — inside a plain
/// `ObservableObject` it would silently stop notifying observers, since
/// `ObservableObject`'s `objectWillChange` is synthesized from
/// `@Published` properties, not `@AppStorage` ones. This store keeps the
/// exact on-disk representation `@AppStorage` would use (a `String` raw
/// value under one `UserDefaults` key), so a future
/// `@AppStorage("updateSpeed")` read directly in a view would see the
/// same persisted value, while `@Published` here gives correct,
/// testable observation today. The injectable `UserDefaults` suite keeps
/// unit tests from reading or leaving behind the user's real
/// preferences.
@MainActor
final class SettingsStore: ObservableObject {
    /// Real-time update-speed presets shown in Settings ▸ General and
    /// mirrored by the View menu's Update Frequency ⌘-1/2/3 commands
    /// (PLAN.md §2: "Menu bar follows Activity Monitor's menus: **View**
    /// (Update Frequency ⌘-1/2/3, ...)"). Cases and rates match
    /// `Sampler.Interval`'s three named presets exactly; `Sampler`'s
    /// `.custom` case is intentionally not represented here since no UI
    /// exposes an arbitrary rate.
    enum UpdateSpeed: String, CaseIterable, Identifiable, Sendable {
        case fast
        case normal
        case slow

        var id: String { rawValue }

        /// Label for Settings ▸ General and the View menu, using a
        /// "Normal — 2/sec" style phrasing (PLAN.md §1.1).
        var displayName: String {
            switch self {
            case .fast: "Fast — 4/sec"
            case .normal: "Normal — 2/sec"
            case .slow: "Slow — 1/sec"
            }
        }

        /// The `Sampler.Interval` this preference drives (PLAN.md §3
        /// data flow: "`Sampler` ... ticks at the configured rate").
        var samplerInterval: Sampler.Interval {
            switch self {
            case .fast: .fast
            case .normal: .normal
            case .slow: .slow
            }
        }
    }

    /// Settings ▸ Appearance's "App theme" (PLAN.md §1.1: "App theme
    /// (system/light/dark)"). `AppShell`'s window applies this via
    /// `.preferredColorScheme`; Language/Display-font/Popout rows seen
    /// in some other apps' equivalent sections aren't represented here —
    /// this app has no bundled display font or localization to pick
    /// between (PLAN.md §2:
    /// "system font (SF Pro) everywhere ... No bundled display fonts";
    /// §4's Deferred/v2 list: "localization beyond scaffold") and no
    /// desktop-popout overlay feature at all.
    enum AppTheme: String, CaseIterable, Identifiable, Sendable {
        case system
        case light
        case dark

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .system: "System"
            case .light: "Light"
            case .dark: "Dark"
            }
        }

        /// The scheme to force via `.preferredColorScheme`, or `nil` to
        /// leave the OS's own light/dark setting in effect — matching how
        /// this app behaved before this property existed (PLAN.md §2:
        /// "standard light/dark via system appearance").
        var colorScheme: ColorScheme? {
            switch self {
            case .system: nil
            case .light: .light
            case .dark: .dark
            }
        }
    }

    /// View ▸ Dock Icon's five options (`AppCommands`), matching Activity
    /// Monitor's own Dock-icon menu in spirit — PLAN.md §4 M8's fourth
    /// task: "Dock icon live graph (View → Dock Icon: CPU history etc.,
    /// like Activity Monitor)". `DockIconRenderer` reads this and redraws
    /// `NSApp.applicationIconImage` to match. The two "History" cases plot
    /// a scrolling filled-area graph (the task's headline "CPU history");
    /// the two "Usage" cases show one big current reading instead — both
    /// pairs read `MenuBarStatusModel`'s already-live CPU/memory data
    /// rather than needing a new provider for this task's "etc.".
    enum DockIconMode: String, CaseIterable, Identifiable, Sendable {
        case applicationIcon
        case cpuHistory
        case cpuUsage
        case memoryHistory
        case memoryUsage

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .applicationIcon: "Application Icon"
            case .cpuHistory: "CPU History"
            case .cpuUsage: "CPU Usage"
            case .memoryHistory: "Memory History"
            case .memoryUsage: "Memory Usage"
            }
        }
    }

    private enum Keys {
        static let updateSpeed = "updateSpeed"
        static let appTheme = "appTheme"
        static let dockIconMode = "dockIconMode"
        static let highFrequencyVisuals = "highFrequencyVisuals"
        static let defaultStartPage = "defaultStartPage"
        static let colorKeyedGraphs = "colorKeyedGraphs"
        static let compressOlderHistory = "compressOlderHistory"
        static let historyMultiplier = "historyMultiplier"
        static let pixelsPerUpdate = "pixelsPerUpdate"
        static let checkForUpdatesOnLaunch = "checkForUpdatesOnLaunch"
        static let lastUpdateCheckDate = "lastUpdateCheckDate"
        static let globalShortcutEnabled = "globalShortcutEnabled"
        static let launchAtLogin = "launchAtLogin"
        static let alwaysOnTop = "alwaysOnTop"
        static let hideOnClose = "hideOnClose"
    }

    /// The current update-speed preference. Setting this immediately
    /// persists to `UserDefaults`. It does not yet retune any of the
    /// `Sampler` instances now running (`SummaryViewModel`,
    /// `PerformanceViewModel`, `AppShellStatusModel`, each fixed at
    /// `Sampler.Interval.normal`/`.slow` today) — no owner observes this
    /// property yet and calls `Sampler.setInterval(_:)` with
    /// `samplerInterval` when it changes, the same way the View menu's
    /// ⌘-1/2/3 commands and the Settings window are expected to write
    /// through this property rather than to `Sampler` directly. Wiring
    /// that observation up is separate follow-up work, not part of this
    /// property's own contract.
    @Published var updateSpeed: UpdateSpeed {
        didSet {
            guard updateSpeed != oldValue else { return }
            defaults.set(updateSpeed.rawValue, forKey: Keys.updateSpeed)
        }
    }

    /// Settings ▸ Appearance's theme picker. `IDOTaskMasterApp` reads
    /// `colorScheme` off this and applies it via `.preferredColorScheme`
    /// on the main window group, so this is the one property in this file
    /// that's wired all the way through to a visible effect the moment
    /// it's set — unlike most of the rest of this store, which record a
    /// preference for a page or engine that reads it back on its own
    /// schedule rather than reacting live.
    @Published var appTheme: AppTheme {
        didSet {
            guard appTheme != oldValue else { return }
            defaults.set(appTheme.rawValue, forKey: Keys.appTheme)
        }
    }

    /// The current Dock icon mode. Setting this immediately persists to
    /// `UserDefaults`; `DockIconRenderer.start()`'s subscription to
    /// `$dockIconMode` is what actually redraws `NSApp.applicationIconImage`
    /// in response.
    @Published var dockIconMode: DockIconMode {
        didSet {
            guard dockIconMode != oldValue else { return }
            defaults.set(dockIconMode.rawValue, forKey: Keys.dockIconMode)
        }
    }

    /// Settings ▸ Appearance's "High Frequency Visuals" toggle (PLAN.md
    /// §1.1: "smooth interpolated motion vs redraw-on-data"). Per PLAN.md
    /// §3's data flow ("`TimelineView(.animation)` interpolates between
    /// snapshots when 'High Frequency Visuals' is on; otherwise views
    /// redraw only on new data"), `false` (the default) matches every
    /// page's behavior today — plain redraw-on-data, no
    /// `TimelineView(.animation)` anywhere yet. No page reads this
    /// property yet; wiring a `TimelineView` into `HistoryGraph`'s
    /// consumers to honor it is follow-up work for whichever milestone
    /// adds that interpolation, the same "declared here, wired later" arc
    /// `updateSpeed` went through between M0 and this one.
    @Published var highFrequencyVisuals: Bool {
        didSet {
            guard highFrequencyVisuals != oldValue else { return }
            defaults.set(highFrequencyVisuals, forKey: Keys.highFrequencyVisuals)
        }
    }

    /// Settings ▸ General's "default start page" (PLAN.md §1.1: "default
    /// start page"). `AppShell` reads this once, in `onAppear`, to pick
    /// its initial sidebar selection instead of the `.summary` constant it
    /// used before this property existed.
    @Published var defaultStartPage: SidebarPage {
        didSet {
            guard defaultStartPage != oldValue else { return }
            defaults.set(defaultStartPage.rawValue, forKey: Keys.defaultStartPage)
        }
    }

    /// Settings ▸ Graphs' "Color Keyed Graphs" toggle (PLAN.md §1.1) —
    /// there is no separate mono/saturation "Colors" popover in this app
    /// (PLAN.md §2); this toggle is only about whether each series keeps its
    /// per-domain identity color (CPU blue, Memory green, ...) versus a
    /// single neutral trace. `true` (the default) matches every
    /// `HistoryGraph`/`CapacityBar` call site today, which already always
    /// passes `DomainPalette`/`StatusPalette` colors rather than a neutral
    /// one. No call site reads this property yet — same "declared now,
    /// wired later" status as `highFrequencyVisuals` above.
    @Published var colorKeyedGraphs: Bool {
        didSet {
            guard colorKeyedGraphs != oldValue else { return }
            defaults.set(colorKeyedGraphs, forKey: Keys.colorKeyedGraphs)
        }
    }

    /// Settings ▸ Graphs' "Compress Older History" toggle (PLAN.md §1.1:
    /// "Compress Older History (+ history multiplier, e.g. 15× with smooth
    /// time compression)"), paired with `historyMultiplier` below. Drives
    /// `HistoryGraph.HistoryCompression` — see `historyCompression` below
    /// for the computed value a future caller would pass as that view's
    /// `compression:` parameter. `false` (the default) matches every
    /// `HistoryGraph` call site today, all of which currently omit
    /// `compression:` and get its own `nil` default (uniform spacing, no
    /// compression).
    @Published var compressOlderHistory: Bool {
        didSet {
            guard compressOlderHistory != oldValue else { return }
            defaults.set(compressOlderHistory, forKey: Keys.compressOlderHistory)
        }
    }

    /// The multiplier `compressOlderHistory` uses when enabled — how many
    /// older samples' worth of horizontal space one compressed sample
    /// occupies, matching `HistoryGraph.HistoryCompression.multiplier`.
    /// Defaults to `15` (`HistoryCompression.standard`
    /// quotes the same number from PLAN.md §1.1's "e.g. 15×").
    @Published var historyMultiplier: Double {
        didSet {
            guard historyMultiplier != oldValue else { return }
            defaults.set(historyMultiplier, forKey: Keys.historyMultiplier)
        }
    }

    /// Settings ▸ Graphs' "Pixels per update" (PLAN.md §1.1) — how far a
    /// live `HistoryGraph` scrolls per tick. Not yet read by
    /// `HistoryGraph`, which currently lays every sample out across its
    /// full given width rather than scrolling a fixed pixel step per tick;
    /// wiring that scrolling behavior in is follow-up work alongside
    /// `historyCompression` below. Defaults to `2`.
    @Published var pixelsPerUpdate: Double {
        didSet {
            guard pixelsPerUpdate != oldValue else { return }
            defaults.set(pixelsPerUpdate, forKey: Keys.pixelsPerUpdate)
        }
    }

    /// Settings ▸ Updates' "check on start" toggle (PLAN.md §1.1:
    /// "Updates: check on start, auto update (opt-in)"). Recorded as a
    /// preference only — nothing in this app performs a launch-time check
    /// yet, because there is no update source (no Sparkle feed, no
    /// distribution server) for it to check against. Faking a launch-time
    /// check against nothing would violate this app's "honest
    /// degradation" rule (PLAN.md §2) just as much as a provider guessing
    /// a sensor value would; the Settings ▸ Updates tab is honest about
    /// that same absence rather than claiming success — see
    /// `recordUpdateCheck(now:)` below.
    @Published var checkForUpdatesOnLaunch: Bool {
        didSet {
            guard checkForUpdatesOnLaunch != oldValue else { return }
            defaults.set(checkForUpdatesOnLaunch, forKey: Keys.checkForUpdatesOnLaunch)
        }
    }

    /// When the Settings ▸ Updates tab's "Check for Updates Now" button
    /// was last pressed, persisted so the "Last checked" line survives a
    /// relaunch. `nil` until the button is pressed at least once.
    @Published private(set) var lastUpdateCheckDate: Date?

    /// Settings ▸ Window's "Global Shortcut" toggle (PLAN.md §1.1:
    /// "Global shortcut: Ctrl+Shift+Esc opens the app"). `AppDelegate`
    /// observes this and calls `GlobalShortcutManager.register()`/
    /// `unregister()` to match. Defaults to `true` — the shortcut is this
    /// app's headline convenience feature and, unlike `launchAtLogin`,
    /// registering it carries no OS-level side effect or permission
    /// prompt to justify defaulting it off.
    @Published var globalShortcutEnabled: Bool {
        didSet {
            guard globalShortcutEnabled != oldValue else { return }
            defaults.set(globalShortcutEnabled, forKey: Keys.globalShortcutEnabled)
        }
    }

    /// Settings ▸ Window's "Launch at Login" toggle — PLAN.md §1.1's
    /// parenthetical on the shortcut row: "(login item to make it always
    /// work)." `AppDelegate` observes this and calls
    /// `LoginItemManager.setEnabled(_:)` to match. Defaults to `false`:
    /// registering a login item is a real, user-visible OS-level change
    /// (it shows up in System Settings ▸ General ▸ Login Items) that
    /// should only happen when explicitly opted into, unlike the in-process
    /// `globalShortcutEnabled` above.
    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        }
    }

    /// Settings ▸ Window's "Always on Top" toggle (PLAN.md §1.1: "Window
    /// management: Always on top, ..."). `MainWindowController` observes
    /// this and sets the main `NSWindow`'s `level` (`.floating` when on,
    /// `.normal` otherwise) to match.
    @Published var alwaysOnTop: Bool {
        didSet {
            guard alwaysOnTop != oldValue else { return }
            defaults.set(alwaysOnTop, forKey: Keys.alwaysOnTop)
        }
    }

    /// Settings ▸ Window's "Hide on Close" toggle (PLAN.md §1.1: "...
    /// Hide on close (keep collecting in background)."). `MainWindowController`
    /// reads this from its `NSWindowDelegate.windowShouldClose` to decide
    /// whether the close button should really close the window (`false` —
    /// this app's Activity-Monitor-like default, PLAN.md §2) or hide it
    /// instead so the live view underneath — and whatever `Sampler` it
    /// owns — keeps running (`true`).
    @Published var hideOnClose: Bool {
        didSet {
            guard hideOnClose != oldValue else { return }
            defaults.set(hideOnClose, forKey: Keys.hideOnClose)
        }
    }

    /// The `HistoryGraph.HistoryCompression` a caller should pass as that
    /// view's `compression:` parameter to honor `compressOlderHistory` and
    /// `historyMultiplier` — `nil` (uncompressed, `HistoryGraph`'s own
    /// default) when the toggle is off. No call site consumes this yet
    /// (see `compressOlderHistory`'s doc comment); it's exposed here ready
    /// for the milestone that wires it in, so that future call sites don't
    /// each have to re-derive a `HistoryCompression` from the two raw
    /// settings themselves.
    var historyCompression: HistoryGraph.HistoryCompression? {
        guard compressOlderHistory else { return nil }
        return HistoryGraph.HistoryCompression(
            recentWindow: HistoryGraph.HistoryCompression.standard.recentWindow,
            multiplier: historyMultiplier
        )
    }

    private let defaults: UserDefaults

    /// - Parameter defaults: The `UserDefaults` suite to read from and
    ///   persist to. Defaults to `.standard`; tests should pass an
    ///   isolated suite (e.g.
    ///   `UserDefaults(suiteName: UUID().uuidString)!`) so they don't
    ///   read or leave behind real user preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Keys.updateSpeed),
           let speed = UpdateSpeed(rawValue: raw) {
            updateSpeed = speed
        } else {
            updateSpeed = .normal
        }

        if let raw = defaults.string(forKey: Keys.appTheme),
           let theme = AppTheme(rawValue: raw) {
            appTheme = theme
        } else {
            appTheme = .system
        }

        if let raw = defaults.string(forKey: Keys.dockIconMode),
           let mode = DockIconMode(rawValue: raw) {
            dockIconMode = mode
        } else {
            dockIconMode = .applicationIcon
        }

        if defaults.object(forKey: Keys.highFrequencyVisuals) != nil {
            highFrequencyVisuals = defaults.bool(forKey: Keys.highFrequencyVisuals)
        } else {
            highFrequencyVisuals = false
        }

        if let raw = defaults.string(forKey: Keys.defaultStartPage),
           let page = SidebarPage(rawValue: raw) {
            defaultStartPage = page
        } else {
            defaultStartPage = .summary
        }

        if defaults.object(forKey: Keys.colorKeyedGraphs) != nil {
            colorKeyedGraphs = defaults.bool(forKey: Keys.colorKeyedGraphs)
        } else {
            colorKeyedGraphs = true
        }

        if defaults.object(forKey: Keys.compressOlderHistory) != nil {
            compressOlderHistory = defaults.bool(forKey: Keys.compressOlderHistory)
        } else {
            compressOlderHistory = false
        }

        if let stored = defaults.object(forKey: Keys.historyMultiplier) as? Double {
            historyMultiplier = stored
        } else {
            historyMultiplier = HistoryGraph.HistoryCompression.standard.multiplier
        }

        if let stored = defaults.object(forKey: Keys.pixelsPerUpdate) as? Double {
            pixelsPerUpdate = stored
        } else {
            pixelsPerUpdate = 2
        }

        if defaults.object(forKey: Keys.checkForUpdatesOnLaunch) != nil {
            checkForUpdatesOnLaunch = defaults.bool(forKey: Keys.checkForUpdatesOnLaunch)
        } else {
            checkForUpdatesOnLaunch = true
        }

        if let stored = defaults.object(forKey: Keys.lastUpdateCheckDate) as? Double {
            lastUpdateCheckDate = Date(timeIntervalSince1970: stored)
        } else {
            lastUpdateCheckDate = nil
        }

        if defaults.object(forKey: Keys.globalShortcutEnabled) != nil {
            globalShortcutEnabled = defaults.bool(forKey: Keys.globalShortcutEnabled)
        } else {
            globalShortcutEnabled = true
        }

        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        } else {
            launchAtLogin = false
        }

        if defaults.object(forKey: Keys.alwaysOnTop) != nil {
            alwaysOnTop = defaults.bool(forKey: Keys.alwaysOnTop)
        } else {
            alwaysOnTop = false
        }

        if defaults.object(forKey: Keys.hideOnClose) != nil {
            hideOnClose = defaults.bool(forKey: Keys.hideOnClose)
        } else {
            hideOnClose = false
        }
    }

    /// Records that the user pressed Settings ▸ Updates' "Check for
    /// Updates Now" button, for that tab's "Last checked" line. Does not
    /// perform any actual network check — see `checkForUpdatesOnLaunch`'s
    /// doc comment for why there is nothing yet to check against.
    func recordUpdateCheck(now: Date = Date()) {
        lastUpdateCheckDate = now
        defaults.set(now.timeIntervalSince1970, forKey: Keys.lastUpdateCheckDate)
    }
}
