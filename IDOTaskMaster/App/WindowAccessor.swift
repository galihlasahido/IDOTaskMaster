import AppKit
import SwiftUI

/// Bridges the `WindowGroup` scene's underlying `NSWindow` out to AppKit
/// so `MainWindowController` can install itself as that window's delegate
/// (for hide-on-close) and adjust `window.level` (for always-on-top) —
/// PLAN.md §4 M8's "always-on-top, hide-on-close with background
/// collection." SwiftUI's `Window`/`WindowGroup` API exposes neither hook
/// on this app's macOS 13.0 minimum target, so an invisible
/// `NSViewRepresentable` reading `nsView.window` is the standard, minimal
/// way to reach the hosting `NSWindow` without reimplementing the scene as
/// raw AppKit.
///
/// Zero-sized and hit-test-transparent by construction (a bare `NSView`,
/// never given a frame or added to the layout) — it exists purely to ride
/// along in the view hierarchy long enough for `updateNSView`/
/// `makeNSView` to see a non-nil `window`.
struct WindowAccessor: NSViewRepresentable {
    /// Called (possibly more than once, as SwiftUI re-evaluates the view
    /// tree) once the underlying `NSWindow` is available. `onResolve`
    /// itself is responsible for de-duplicating repeat calls for the same
    /// window if it matters — `MainWindowController.attach(_:)` already
    /// does.
    let onResolve: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        resolve(from: view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        resolve(from: nsView)
    }

    /// `nsView.window` is `nil` at the moment `makeNSView` first runs (the
    /// view isn't attached to a window yet) — deferring to the next run
    /// loop turn is the standard trick to observe it once SwiftUI has
    /// finished inserting the view into its hosting window.
    private func resolve(from view: NSView) {
        DispatchQueue.main.async {
            if let window = view.window {
                onResolve(window)
            }
        }
    }
}
