import AppKit
import Combine
import UserNotifications

/// `NSApplicationDelegate` hosting the AppKit-level app-lifecycle behavior
/// PLAN.md §4 M8 asks for that has no SwiftUI `App`/`Scene` API on this
/// app's macOS 13.0 minimum target: the global Ctrl+Shift+Esc shortcut,
/// the launch-at-login toggle, and keeping the app itself alive after its
/// window closes or hides (paired with `MainWindowController`, which does
/// the actual per-window hide-vs-close decision).
///
/// Owns the single `SettingsStore` instance for the process's lifetime —
/// `IDOTaskMasterApp` reads it back out via `appDelegate.settings` rather
/// than each independently constructing (and thus each independently
/// persisting/observing) its own, which is what makes this delegate's own
/// `Combine` subscriptions below actually see the same live changes
/// Settings ▸ Window's toggles make. Constructing it here, in this
/// class's own `init()`, sidesteps the property-wrapper initialization
/// ordering pitfall of trying to hand a `@StateObject` from
/// `IDOTaskMasterApp` into a separately-constructed
/// `@NSApplicationDelegateAdaptor` instance (the adaptor's instance is
/// built before `IDOTaskMasterApp`'s own initializer body would run).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let settings = SettingsStore()
    let windowController: MainWindowController
    /// Backs the menu bar extra's compact readout and popover
    /// mini-dashboard (M8's third task, `App/MenuBarExtraView.swift`).
    /// Owned here, alongside `settings`, for the same reason: a single
    /// instance that starts once at launch and lives for the process's
    /// whole lifetime, independent of any window's own show/hide state —
    /// see `MenuBarStatusModel`'s doc comment.
    let menuBarStatus = MenuBarStatusModel()
    /// Redraws the Dock icon per `settings.dockIconMode` (M8's fourth task,
    /// `App/DockIconRenderer.swift`). Owned here alongside `menuBarStatus`
    /// for the same reason: it must track the live setting and the live
    /// sample data for the whole process lifetime, not just while a window
    /// happens to be open — see that type's own doc comment.
    let dockIconRenderer: DockIconRenderer
    /// Evaluates the user's alert rules against live snapshots and posts
    /// `UserNotifications` (M9's first task, `Core/AlertsEngine.swift`).
    /// Owned here, alongside `menuBarStatus`/`dockIconRenderer`, for the
    /// same reason: a watchdog is only useful if it keeps evaluating rules
    /// for the whole process lifetime, not just while `AlertsPage` happens
    /// to be the visible page — see that type's own doc comment.
    let alertsEngine = AlertsEngine()
    /// Downsampled, pruned SQLite persistence of every domain's history
    /// (M9's second task, `Core/HistoryStore.swift`). Owned here, alongside
    /// `alertsEngine`, for the same reason: history is only useful if it
    /// keeps recording for the whole process lifetime, not just while the
    /// future `HistoryPage` happens to be the visible page — see that
    /// type's own doc comment. An `actor` rather than a plain stored
    /// property read directly by views: every access goes through `await`,
    /// matching how the rest of this app already reaches provider data.
    let historyStore = HistoryStore()
    /// Shared open/closed state for the ⌘K command palette (M10's fourth
    /// task, `App/CommandPalette.swift`). Owned here, alongside
    /// `alertsEngine`/`historyStore`, for the same cross-scene reason:
    /// `AppCommands`' menu item and `AppShell`'s `.sheet` both need to
    /// read and write the *same* instance — see that type's own doc
    /// comment.
    let commandPalette = CommandPaletteController()
    /// Per-process network send/receive rates (`NetworkUsagePage`). Owned
    /// here, alongside `alertsEngine`/`historyStore`, so it survives page
    /// navigation once started — but unlike those, **not** auto-started
    /// in `applicationDidFinishLaunching` below; see this type's own doc
    /// comment for why it waits for the user's explicit "Start
    /// Collecting" instead.
    let networkTraffic = NetworkTrafficMonitor()
    /// Which apps have talked to which remote hosts (`NetworkMonitorPage`).
    /// Owned here, alongside `networkTraffic`, for the exact same reason:
    /// once the user turns on its "Watch" button, both the polling and
    /// everything it's accumulated must survive navigating away from that
    /// page and back — not auto-started here, same "waits for explicit
    /// opt-in" rule. See that type's own doc comment.
    let networkMonitor = NetworkMonitorViewModel()
    /// Backs Settings ▸ Updates' "Check for Updates Now" button and "Check
    /// for Updates on Launch" toggle (`Core/UpdateChecker.swift`). Owned
    /// here, alongside `networkMonitor`, so a launch-time check has
    /// already populated its result by the time the user opens Settings —
    /// unlike that type, this one *is* auto-started below, gated on the
    /// user's own `checkForUpdatesOnLaunch` preference rather than an
    /// always-on-by-default sampler, so it doesn't need the "waits for
    /// explicit opt-in" treatment those other two document.
    let updateChecker = UpdateChecker()

    private var shortcut: GlobalShortcutManager?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        windowController = MainWindowController(settings: settings)
        dockIconRenderer = DockIconRenderer(settings: settings, status: menuBarStatus)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        shortcut = GlobalShortcutManager { [weak self] in
            self?.windowController.show()
        }
        applyGlobalShortcut(enabled: settings.globalShortcutEnabled)
        LoginItemManager.setEnabled(settings.launchAtLogin)
        // Starts sampling immediately, before any window exists — the
        // menu bar readout must be live "while main window is closed"
        // (PLAN.md §4 M8), not merely once one has been shown.
        menuBarStatus.start()
        // Applies the persisted `dockIconMode` immediately (including the
        // "Application Icon" default, a no-op) and keeps redrawing it as
        // `menuBarStatus`'s live data ticks in — see `DockIconRenderer`'s
        // doc comment for why this, like `menuBarStatus.start()` above, is
        // called once here rather than from any view's `onAppear`.
        dockIconRenderer.start()
        // Starts the alert watchdog immediately too, for the same reason
        // as `menuBarStatus`/`dockIconRenderer` above — rules must keep
        // evaluating (and notifications keep firing) whether or not the
        // Alerts page, or any window at all, is currently open.
        alertsEngine.start()
        // Registers this delegate before any rule could possibly fire —
        // without one, `UNUserNotificationCenter` has nothing to call
        // when the user clicks a posted notification, which is why
        // clicking one used to do nothing at all. See this class's
        // `UNUserNotificationCenterDelegate` conformance below.
        UNUserNotificationCenter.current().delegate = self
        // Starts the history recorder immediately too, for the same reason
        // as `alertsEngine` above — it must keep recording (and, later,
        // rolling up/pruning) whether or not a `HistoryPage` window is
        // currently open. Wrapped in `Task` since `HistoryStore.start()` is
        // an actor method.
        Task { await historyStore.start() }
        // `networkTraffic` is deliberately NOT started here — see its own
        // doc comment. It only starts once the user clicks "Start
        // Collecting" on `NetworkUsagePage`.

        // Unlike `networkTraffic`/`networkMonitor` above, this one *is*
        // triggered from launch — but only when the user's own
        // "Check for Updates on Launch" preference is on (defaults to
        // true), so it's still gated on an explicit, visible setting
        // rather than being an unconditional hidden network request.
        if settings.checkForUpdatesOnLaunch {
            Task {
                await updateChecker.check()
                settings.recordUpdateCheck()
            }
        }

        settings.$globalShortcutEnabled
            .dropFirst() // current value already applied just above
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in self?.applyGlobalShortcut(enabled: enabled) }
            .store(in: &cancellables)

        settings.$launchAtLogin
            .dropFirst() // current value already applied just above
            .receive(on: DispatchQueue.main)
            .sink { enabled in LoginItemManager.setEnabled(enabled) }
            .store(in: &cancellables)
    }

    /// Before M8's menu bar extra existed, this mirrored
    /// `settings.hideOnClose` — with `hideOnClose == false` (this app's
    /// original Activity-Monitor-style default), closing the one real
    /// window quit the whole app. That default now directly contradicts
    /// M8's third task, "menu bar extra ... works while main window is
    /// closed" (PLAN.md §4): a menu bar item that dies the moment its
    /// host app quits isn't a persistent readout at all. So this always
    /// returns `false` now — closing (or `hideOnClose`-hiding) the main
    /// window never quits the app on its own; the menu bar item's Quit
    /// button (`MenuBarPopoverView.actionRow`) and the standard ⌘Q are the
    /// explicit ways out. `hideOnClose` keeps its own, narrower meaning
    /// unchanged: whether the close button really destroys the `NSWindow`
    /// (recreated fresh on next reopen) or just orders it out
    /// (`MainWindowController.windowShouldClose` keeps the same instance,
    /// and whatever `Sampler` the SwiftUI view underneath it owns, alive
    /// and hidden) — not whether the process itself survives, which is now
    /// this menu bar item's job alone.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Handles a Dock-icon click with no visible windows. If the main
    /// window still exists (hidden via hide-on-close, or minimized),
    /// `windowController.show()` brings it back and this method reports
    /// "handled." Otherwise — no window was ever attached yet, an
    /// exceedingly brief window right at launch — this defers to AppKit's
    /// own default `WindowGroup` reopen handling by returning `false`.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard windowController.hasWindow else { return false }
        windowController.show()
        return true
    }

    private func applyGlobalShortcut(enabled: Bool) {
        if enabled {
            shortcut?.register()
        } else {
            shortcut?.unregister()
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Without this, macOS doesn't reliably show a banner for a
    /// notification posted while this app is the active/frontmost app —
    /// `alertsEngine`'s watchdog can fire at any time, including while
    /// someone's looking right at the window, so this always asks for the
    /// full presentation.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }

    /// The other half of the fix `UNUserNotificationCenter.current()
    /// .delegate = self` above sets up: with no delegate at all, clicking
    /// a posted notification had nothing to call and silently did
    /// nothing. The default click (the notification's own body, not a
    /// custom action button — this app doesn't define any) brings the
    /// window forward and tells `AlertsEngine` a click happened, which
    /// `AppShell` observes to switch to the Alerts page.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor in
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                NSApp.activate(ignoringOtherApps: true)
                windowController.show()
                alertsEngine.handleNotificationClicked()
            }
            completionHandler()
        }
    }
}
