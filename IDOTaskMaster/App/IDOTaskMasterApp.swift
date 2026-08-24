import SwiftUI

/// App entry point. Window sizing and appearance are configured here;
/// sidebar navigation and page routing live in `AppShell` (fleshed out
/// starting M1). Appearance intentionally follows the system light/dark
/// setting — nothing here overrides `NSApp.appearance` or applies a
/// `.preferredColorScheme`, matching Activity Monitor's default behavior.
///
/// Owns the app's single `SettingsStore` instance for the process's
/// lifetime and hands it to two places that must stay in sync through it
/// rather than each keeping their own copy: the View menu's Update
/// Frequency commands (`AppCommands`, this milestone) and, via the
/// environment, whatever page later milestones add that reads preferences
/// (e.g. the Settings window's General tab in M8).
@main
struct IDOTaskMasterApp: App {
    @StateObject private var settings = SettingsStore()

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(settings)
        }
        .defaultSize(width: 1280, height: 860)
        .defaultPosition(.center)
        .commands {
            AppCommands(settings: settings)
        }
    }
}
