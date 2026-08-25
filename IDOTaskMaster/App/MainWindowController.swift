import AppKit
import Combine

/// Owns the main window's AppKit-level behavior that PLAN.md §4 M8 asks
/// for and SwiftUI's `WindowGroup` has no API for on this app's macOS
/// 13.0 minimum target: always-on-top (`window.level`) and hide-on-close.
///
/// Reached from `AppShell` via `WindowAccessor` (the only way to obtain
/// the `NSWindow` a `WindowGroup` scene creates), and owned by
/// `AppDelegate` for the app's lifetime so `GlobalShortcutManager` and
/// `applicationShouldHandleReopen` can both call `show()` on the same
/// instance.
///
/// **Hide-on-close semantics** (PLAN.md §1.1: "Hide on close (keep
/// collecting in background)"): this app is modeled on Activity Monitor
/// (PLAN.md §2), which quits when its window closes — that is this app's
/// own default too (`AppDelegate.applicationShouldTerminateAfterLastWindowClosed`
/// mirrors it). "Hide on Close" is what opts *out* of that default: when
/// on, `windowShouldClose` intercepts the red close button and orders the
/// window out instead of letting it actually close, so the SwiftUI view
/// hierarchy underneath it — and whatever `Sampler` it owns — stays alive
/// and ticking while the window is merely invisible. That's also why this
/// design never needs to *recreate* a closed window: with the setting on,
/// the window is never truly destroyed to begin with, so `show()` only
/// ever has to un-hide the same instance; with the setting off, a real
/// close is a real quit (Activity Monitor's own behavior), so there's
/// nothing left running to reopen a window on top of.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    private weak var window: NSWindow?
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// Whether a window has ever been attached — `AppDelegate` uses this
    /// to decide whether `applicationShouldHandleReopen` can handle a Dock
    /// re-click itself (`show()`) or must defer to AppKit's own default
    /// `WindowGroup` reopen handling.
    var hasWindow: Bool { window != nil }

    /// Called from `WindowAccessor` once the SwiftUI window exists. Safe
    /// to call repeatedly with the same window — SwiftUI re-evaluates the
    /// view tree far more often than the window identity actually changes.
    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        window.delegate = self
        applyAlwaysOnTop()

        cancellables.removeAll()
        settings.$alwaysOnTop
            .dropFirst() // current value already applied just above
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.applyAlwaysOnTop() }
            .store(in: &cancellables)
    }

    /// Un-hides and brings the window to front. Used by
    /// `GlobalShortcutManager`'s Ctrl+Shift+Esc action and
    /// `AppDelegate.applicationShouldHandleReopen` (Dock icon click).
    func show() {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.setIsVisible(true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func applyAlwaysOnTop() {
        window?.level = settings.alwaysOnTop ? .floating : .normal
    }

    // MARK: - NSWindowDelegate

    /// See this type's doc comment for the full hide-vs-quit rationale.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard settings.hideOnClose else { return true }
        sender.orderOut(nil)
        return false
    }
}
