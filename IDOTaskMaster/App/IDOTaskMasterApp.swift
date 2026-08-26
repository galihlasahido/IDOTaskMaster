import SwiftUI

/// App entry point. Window sizing and appearance are configured here;
/// sidebar navigation and page routing live in `AppShell` (fleshed out
/// starting M1). Appearance follows the system light/dark setting by
/// default — `.preferredColorScheme(settings.appTheme.colorScheme)` only
/// forces a scheme when Settings ▸ Appearance's theme picker (M8) is set
/// away from "System"; `.colorScheme` is `nil` for that case, which is a
/// no-op identical to this app's pre-M8 behavior (matching Activity
/// Monitor's own default).
///
/// The single `SettingsStore` instance for the process's lifetime lives on
/// `appDelegate` (see `AppDelegate`'s doc comment for why it — not a
/// `@StateObject` here — is the one place that constructs it), read back
/// out via `appDelegate.settings` and handed to every place that must stay
/// in sync through it: the View menu's Update Frequency commands
/// (`AppCommands`), the main window (via the environment, for `AppShell`'s
/// default-start-page read and any page that reads preferences), and the
/// `Settings` scene below — the native ⌘, / App-menu "Settings…" window,
/// standard on every macOS app.
///
/// `@NSApplicationDelegateAdaptor` is what M8's second task needs an
/// `NSApplicationDelegate` for at all: the global Ctrl+Shift+Esc shortcut,
/// login-item registration, and `applicationShouldTerminateAfterLastWindowClosed`/
/// `applicationShouldHandleReopen` for hide-on-close have no SwiftUI
/// `App`/`Scene`-level API on this app's macOS 13.0 minimum target.
/// `WindowAccessor` hands the same delegate's `windowController` the
/// `WindowGroup`'s underlying `NSWindow` for always-on-top and
/// hide-on-close's `NSWindowDelegate` hook.
@main
struct IDOTaskMasterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.alertsEngine)
                // M10's ⌘K command palette (`App/CommandPalette.swift`):
                // `AppShell` reads this to drive its `.sheet`, and
                // `AppCommands` below drives the same instance's
                // `isPresented` from its "Command Palette…" menu item.
                .environmentObject(appDelegate.commandPalette)
                .environmentObject(appDelegate.networkTraffic)
                .environmentObject(appDelegate.networkMonitor)
                // `HistoryStore` is an `actor`, not an `ObservableObject`,
                // so it rides the plain environment (see
                // `EnvironmentValues.historyStore` in `Pages/HistoryPage.swift`)
                // rather than `.environmentObject` like `settings`/
                // `alertsEngine` above.
                .environment(\.historyStore, appDelegate.historyStore)
                .preferredColorScheme(appDelegate.settings.appTheme.colorScheme)
                .background(
                    WindowAccessor { window in
                        appDelegate.windowController.attach(window)
                    }
                )
        }
        .defaultSize(width: 1280, height: 860)
        .defaultPosition(.center)
        .commands {
            AppCommands(settings: appDelegate.settings, commandPalette: appDelegate.commandPalette)
        }

        Settings {
            SettingsPage()
                .environmentObject(appDelegate.settings)
                .environmentObject(appDelegate.updateChecker)
        }

        // M8's third task (PLAN.md §4, §3's `MenuBarExtraView.swift`):
        // compact live readout + popover mini-dashboard. `appDelegate.
        // menuBarStatus` is the one `MenuBarStatusModel` instance both the
        // label and the popover below share — see that type's doc comment
        // for why it's started once, at launch, on `AppDelegate` rather
        // than owned by either view. `.window` style (not the default
        // `.menu`) is what lets the popover host real SwiftUI content —
        // `HistoryGraph`'s `Canvas` sparklines, live `StatTile`s — instead
        // of a plain `NSMenuItem` list.
        MenuBarExtra {
            MenuBarPopoverView(
                model: appDelegate.menuBarStatus,
                onOpenMainWindow: { appDelegate.windowController.show() }
            )
        } label: {
            MenuBarExtraLabel(model: appDelegate.menuBarStatus)
        }
        .menuBarExtraStyle(.window)
    }
}
