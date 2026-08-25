import SwiftUI

/// Menu bar skeleton for the app, modeled on Activity Monitor's menus
/// (PLAN.md §2: "Menu bar follows Activity Monitor's menus: **View**
/// (Update Frequency ⌘-1/2/3, column toggles, filter scope), **Window**,
/// page-appropriate **File/Edit** ..."). PLAN.md §4's M0 checklist scopes
/// this down to exactly two things: "View (Update Frequency ⌘-1/2/3,
/// Columns), Window, standard File/Edit" — everything else in that quote
/// (filter scope, per-page File/Edit customization) is later milestones'
/// work, once the pages it depends on exist.
///
/// Two different things are true of the menus this struct is responsible
/// for:
/// - **View ▸ Update Frequency** is fully wired, because `SettingsStore`
///   already exists (this milestone's previous task). Picking a rate here
///   writes straight through `settings.updateSpeed` — the same property
///   the Settings window's General tab (M8) will read and write — so menu
///   and Settings stay in sync automatically; neither one owns the value,
///   the store does. `Toggle` (rather than `Button`) is what gets SwiftUI
///   to draw a native checkmark next to the active rate, matching Activity
///   Monitor's radio-style menu; routing all three toggles through the
///   same `settings.updateSpeed` property keeps them mutually exclusive.
/// - **View ▸ Columns** is an honest placeholder, not a real feature yet.
///   Column toggles are inherently per-page (Processes' columns aren't
///   Services' columns), and no page has any columns to toggle yet —
///   `DataTable` doesn't exist until M1, and the pages that actually need
///   this (Processes, Services) don't land until M4. So it's a single
///   disabled item rather than fabricated column names, kept here so the
///   menu's shape already matches Activity Monitor's; a later milestone
///   replaces the body of this submenu with the real per-page list (most
///   likely surfaced from the active page via a focused value) without
///   touching where it lives in the menu bar.
///
/// **Window** and **File**/**Edit** aren't touched at all: SwiftUI already
/// synthesizes Activity-Monitor-standard versions of those three for any
/// `WindowGroup` scene (New/Close Window; Undo/Redo/Cut/Copy/Paste/Select
/// All; Minimize/Zoom/Bring All to Front/window list; ...) the moment the
/// app declares `.commands`, with no code required to keep them. This
/// struct only ever inserts into the View menu — there's nothing to add or
/// override there until a page needs a custom File/Edit item of its own
/// (e.g. Processes' File ▸ menu growing a "Quit Process ⌘⌫" entry once
/// `ProcessProvider` exists in M4).
struct AppCommands: Commands {
    @ObservedObject var settings: SettingsStore
    /// Drives M10's fourth task (PLAN.md §4: "⌘K command palette: jump to
    /// any page or process by name/PID") — this menu item is the
    /// discoverable, Edit-menu-adjacent counterpart to the shortcut
    /// itself; both just call `commandPalette.present()`, the same "one
    /// shared instance, several triggers" pattern `settings.updateSpeed`
    /// already uses for its own menu item + Settings-window pair.
    @ObservedObject var commandPalette: CommandPaletteController

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            Button("Command Palette\u{2026}") {
                commandPalette.present()
            }
            .keyboardShortcut("k", modifiers: .command)

            Divider()

            Menu("Update Frequency") {
                frequencyToggle(.fast, shortcut: "1")
                frequencyToggle(.normal, shortcut: "2")
                frequencyToggle(.slow, shortcut: "3")
            }

            Menu("Columns") {
                // Replaced with real per-page column toggles once a page
                // has columns to toggle (M1 `DataTable`, M4 Processes /
                // Services). Disabled rather than omitted so the menu's
                // shape already matches Activity Monitor's.
                Button("No Columns Available") {}
                    .disabled(true)
            }

            // M8's fourth task (PLAN.md §4: "Dock icon live graph (View →
            // Dock Icon: CPU history etc., like Activity Monitor)").
            // Checkmarked, mutually-exclusive `Toggle`s over
            // `settings.dockIconMode` — same radio-style pattern as Update
            // Frequency above, so picking one here and picking one in a
            // future Settings tab (if ever added) stay in sync through the
            // one store, just like `updateSpeed`. `DockIconRenderer`
            // observes `settings.$dockIconMode` and redraws the actual
            // Dock icon; this menu only ever writes the preference.
            Menu("Dock Icon") {
                dockIconToggle(.applicationIcon)
                Divider()
                dockIconToggle(.cpuUsage)
                dockIconToggle(.cpuHistory)
                Divider()
                dockIconToggle(.memoryUsage)
                dockIconToggle(.memoryHistory)
            }

            Divider()
        }
    }

    /// One "Dock Icon" row — a checkmarked, mutually-exclusive `Toggle` for
    /// one `SettingsStore.DockIconMode` case. Mirrors `frequencyToggle(_:
    /// shortcut:)` above, minus the keyboard shortcut: Activity Monitor
    /// doesn't assign one to its own Dock Icon submenu either.
    private func dockIconToggle(_ mode: SettingsStore.DockIconMode) -> some View {
        Toggle(isOn: dockIconBinding(for: mode)) {
            Text(mode.displayName)
        }
    }

    /// Same "set to `true` writes through, set to `false` is a no-op"
    /// shape as `binding(for:)` below, over `settings.dockIconMode` instead
    /// of `settings.updateSpeed`.
    private func dockIconBinding(for mode: SettingsStore.DockIconMode) -> Binding<Bool> {
        Binding(
            get: { settings.dockIconMode == mode },
            set: { isOn in
                guard isOn else { return }
                settings.dockIconMode = mode
            }
        )
    }

    /// One "Update Frequency" row: a checkmarked, mutually-exclusive
    /// `Toggle` for one `SettingsStore.UpdateSpeed` case, carrying its
    /// ⌘-digit shortcut per PLAN.md's "Update Frequency ⌘-1/2/3".
    private func frequencyToggle(
        _ speed: SettingsStore.UpdateSpeed,
        shortcut: KeyEquivalent
    ) -> some View {
        Toggle(isOn: binding(for: speed)) {
            Text(speed.displayName)
        }
        .keyboardShortcut(shortcut, modifiers: .command)
    }

    /// A two-way binding that reads as "is `speed` the current update
    /// speed" and, on being set to `true`, writes `speed` through to
    /// `settings.updateSpeed`. Setting it to `false` is a no-op rather than
    /// clearing the preference — `updateSpeed` always has exactly one
    /// value, so "turn this one off" only makes sense as "turn another one
    /// on", which the sibling toggle's own binding already does.
    private func binding(for speed: SettingsStore.UpdateSpeed) -> Binding<Bool> {
        Binding(
            get: { settings.updateSpeed == speed },
            set: { isOn in
                guard isOn else { return }
                settings.updateSpeed = speed
            }
        )
    }
}
