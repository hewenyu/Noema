import AppKit
import NoemaCore

/// Converts AppKit key events into platform-neutral `KeyEvent`s. Pure: no state, no I/O.
public enum NSEventKeyBridge {
    /// The `KeyEvent` for a key-down `event`; nil for every other event type. The type is
    /// checked before anything else: `characters` and `keyCode` raise an Objective-C
    /// exception on non-key events.
    public static func keyEvent(from event: NSEvent) -> KeyEvent? {
        guard event.type == .keyDown else { return nil }
        return KeyEvent(
            keyCode: event.keyCode,
            characters: event.characters ?? "",
            modifiers: modifiers(from: event.modifierFlags),
            isKeyDown: true,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers
        )
    }

    /// Maps AppKit modifier flags onto `KeyModifiers`; device-dependent bits are dropped.
    public static func modifiers(from flags: NSEvent.ModifierFlags) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.capsLock) { modifiers.insert(.capsLock) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }
}
