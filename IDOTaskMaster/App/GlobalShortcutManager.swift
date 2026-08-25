import AppKit
import Carbon.HIToolbox

/// Claims the system-wide Ctrl+Shift+Esc shortcut described in PLAN.md
/// §1.1 ("Global shortcut: Ctrl+Shift+Esc opens the app") and §4 M8
/// ("Global shortcut Ctrl+Shift+Esc (login item), ..."). "Global" means it
/// must fire even when IDOTaskMaster isn't the frontmost app — the whole
/// point of the feature — which is why this wraps the (deprecated but
/// still fully functional, and still the only API with this property)
/// Carbon Event Manager hot key calls (`RegisterEventHotKey`/
/// `InstallEventHandler`) rather than `NSEvent.addGlobalMonitorForEvents`.
///
/// `NSEvent`'s global monitor only delivers keyDown/keyUp/flagsChanged
/// events once the process is trusted for Accessibility
/// (`AXIsProcessTrusted`) — shipping that would mean either a first-run
/// permission-request flow or the shortcut silently doing nothing until
/// the user finds System Settings ▸ Privacy & Security ▸ Accessibility on
/// their own. `RegisterEventHotKey` needs no such trust; it is how
/// Carbon-era global-hotkey utilities have always worked system-wide, and
/// needs nothing beyond the Carbon framework AppKit already links.
///
/// This app's login-item support (`LoginItemManager`, wired alongside this
/// type in `AppDelegate`) is what PLAN.md's parenthetical "(login item to
/// make it always work)" is about: the shortcut can only be caught by a
/// process that's already running, so a user who wants Ctrl+Shift+Esc to
/// reliably work needs IDOTaskMaster launched at login — this manager
/// itself has no dependency on that setting one way or the other.
@MainActor
final class GlobalShortcutManager {
    /// Posted (always on the main thread — Carbon's event dispatcher runs
    /// on the main run loop) when the hotkey fires. A plain
    /// `NotificationCenter` round-trip, rather than reaching back into
    /// `self` directly from the C callback, sidesteps having to smuggle an
    /// `Unmanaged<GlobalShortcutManager>` context pointer through Carbon's
    /// `void *inUserData` and cross back out of a non-actor-isolated
    /// `@convention(c)` function into this `@MainActor` type.
    private static let hotKeyPressedNotification = Notification.Name("IDOTaskMaster.GlobalShortcutManager.hotKeyPressed")
    private static let hotKeySignature: OSType = 0x49444f54 // 'IDOT', this app's own registration namespace
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var notificationObserver: NSObjectProtocol?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    deinit {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
    }

    /// Registers Ctrl+Shift+Esc. Safe to call repeatedly — it tears down
    /// any prior registration first — so Settings ▸ Window's "Global
    /// Shortcut" toggle can call this on and `unregister()` off at
    /// runtime without leaking handlers.
    func register() {
        unregister()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: Self.hotKeyPressedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.action()
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // Deliberately non-capturing (only static members and its own
        // parameters are referenced) so Swift converts it directly to the
        // `@convention(c)` function pointer `InstallEventHandler` expects.
        InstallEventHandler(GetEventDispatcherTarget(), { _, eventRef, _ in
            guard let eventRef else { return noErr }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(
                eventRef,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &pressedID
            )
            if status == noErr,
               pressedID.signature == GlobalShortcutManager.hotKeySignature,
               pressedID.id == GlobalShortcutManager.hotKeyID {
                NotificationCenter.default.post(name: GlobalShortcutManager.hotKeyPressedNotification, object: nil)
            }
            return noErr
        }, 1, &eventType, nil, &eventHandlerRef)

        var registeredRef: EventHotKeyRef?
        let eventHotKeyID = EventHotKeyID(signature: Self.hotKeySignature, id: Self.hotKeyID)
        // controlKey + shiftKey (Carbon's classic modifier masks) + Escape.
        let status = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(controlKey | shiftKey),
            eventHotKeyID,
            GetEventDispatcherTarget(),
            0,
            &registeredRef
        )
        if status == noErr {
            hotKeyRef = registeredRef
        } else {
            // Another app (or the system) already owns Ctrl+Shift+Esc, or
            // registration otherwise failed. Degrade gracefully — no
            // global shortcut rather than a crash — matching this app's
            // "Providers must degrade gracefully" rule (PLAN.md §2)
            // applied to a system service instead of a metric provider.
            print("GlobalShortcutManager: failed to register Ctrl+Shift+Esc (OSStatus \(status))")
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
                self.eventHandlerRef = nil
            }
            if let notificationObserver {
                NotificationCenter.default.removeObserver(notificationObserver)
                self.notificationObserver = nil
            }
        }
    }

    /// Releases the hotkey registration and event handler. Called by
    /// `register()` itself (so re-registering never double-installs) and
    /// by Settings ▸ Window's toggle when the user turns the shortcut off.
    func unregister() {
        if let notificationObserver {
            NotificationCenter.default.removeObserver(notificationObserver)
            self.notificationObserver = nil
        }
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
    }
}
