import ServiceManagement

/// Wraps `SMAppService.mainApp` — the modern (macOS 13+, exactly this
/// app's minimum target per PLAN.md §2) replacement for the legacy
/// `SMLoginItemSetEnabled`/`LSSharedFileList` APIs — so Settings ▸
/// Window's "Launch at Login" toggle can register or unregister
/// IDOTaskMaster itself as a login item with no separate helper-app
/// target, which the legacy APIs required.
///
/// PLAN.md §1.1 frames this as what makes the global Ctrl+Shift+Esc
/// shortcut (`GlobalShortcutManager`) reliable: "login item to make it
/// always work" — the shortcut can only be caught by a process that's
/// already running, and this is how the app gets itself running again
/// after every login without the user having to remember to launch it.
enum LoginItemManager {
    /// Registers or unregisters the app as a login item, matching
    /// `enabled`. A no-op if the current registration already matches, so
    /// callers can invoke this unconditionally (e.g. once at every launch
    /// to reconcile `SettingsStore.launchAtLogin` with reality) without
    /// worrying about redundant `register()`/`unregister()` calls.
    ///
    /// Failures (the user declining a system prompt, an ad-hoc/unsigned
    /// debug build `SMAppService` refuses, ...) are logged rather than
    /// surfaced as a crash or a thrown error the caller must handle —
    /// matching this app's "Providers must degrade gracefully" rule
    /// (PLAN.md §2) applied to a system service instead of a metric
    /// provider: a login item that didn't register just means the user
    /// has to launch the app manually, not a reason to fail loudly.
    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("LoginItemManager: failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
    }

    /// The live registration state, straight from `SMAppService` rather
    /// than `SettingsStore`'s persisted preference — lets Settings ▸
    /// Window reflect reality if the user removed the login item directly
    /// via System Settings ▸ General ▸ Login Items instead of this app's
    /// own toggle.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
