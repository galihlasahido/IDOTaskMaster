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

        /// Label for Settings ▸ General and the View menu, matching
        /// [name removed]'s "Normal — 2/sec" phrasing (PLAN.md §1.1).
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

    private enum Keys {
        static let updateSpeed = "updateSpeed"
    }

    /// The current update-speed preference. Setting this immediately
    /// persists to `UserDefaults`. It does not by itself retune a
    /// running `Sampler` — no milestone has wired a live `Sampler`
    /// instance into the app yet (M0's `Sampler` is a standalone
    /// skeleton); once one exists, its owner is expected to observe this
    /// property and call `Sampler.setInterval(_:)` with
    /// `samplerInterval` whenever it changes, the same way the View
    /// menu's ⌘-1/2/3 commands and the Settings window are expected to
    /// write through this property rather than to `Sampler` directly.
    @Published var updateSpeed: UpdateSpeed {
        didSet {
            guard updateSpeed != oldValue else { return }
            defaults.set(updateSpeed.rawValue, forKey: Keys.updateSpeed)
        }
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
    }
}
