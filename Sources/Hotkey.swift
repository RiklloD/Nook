import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut through Carbon's hot key API: no Accessibility or Input Monitoring
/// permission, no event tap, nothing running between presses. The window server delivers the
/// press on the main run loop.
@MainActor
final class Hotkey {
    /// ⌃⌥N, for Nook.
    static let label = "⌃⌥N"
    private static let keyCode = UInt32(kVK_ANSI_N)
    private static let modifiers = UInt32(controlKey | optionKey)

    private let action: () -> Void
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return noErr }
            let hotkey = Unmanaged<Hotkey>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { hotkey.action() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    var isEnabled: Bool {
        get { ref != nil }
        set {
            guard newValue != isEnabled else { return }
            if newValue {
                // "Nook" as the signature; fails quietly if another app already owns the combination.
                let id = EventHotKeyID(signature: 0x4E6F_6F6B, id: 1)
                if RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &ref) != noErr { ref = nil }
            } else if let ref {
                UnregisterEventHotKey(ref)
                self.ref = nil
            }
        }
    }
}
