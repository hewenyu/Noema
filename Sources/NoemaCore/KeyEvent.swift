/// Modifier keys held during a key event, independent of AppKit's `NSEvent.ModifierFlags`.
public struct KeyModifiers: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let shift = KeyModifiers(rawValue: 1 << 0)
    public static let capsLock = KeyModifiers(rawValue: 1 << 1)
    public static let control = KeyModifiers(rawValue: 1 << 2)
    public static let option = KeyModifiers(rawValue: 1 << 3)
    public static let command = KeyModifiers(rawValue: 1 << 4)
    public static let function = KeyModifiers(rawValue: 1 << 5)

    /// Modifiers that turn a key into a shortcut rather than text input.
    public static let shortcutModifiers: KeyModifiers = [.control, .option, .command]

    /// True when the event is a shortcut chord the input method should pass through.
    public var isShortcut: Bool { !isDisjoint(with: .shortcutModifiers) }
}

/// A platform-neutral key press handed from the IMKit shell to the typing engine.
public struct KeyEvent: Sendable, Hashable, Codable {
    /// Hardware virtual key code (`kVK_*`).
    public let keyCode: UInt16
    /// Characters produced by the key with modifiers applied; empty for non-text keys.
    public let characters: String
    public let modifiers: KeyModifiers
    public let isKeyDown: Bool
    /// Characters the key produces with no modifier but Shift applied (AppKit's
    /// `charactersIgnoringModifiers`); nil when the shell does not provide them.
    /// Lets the engine recognize `Ctrl+A` when `characters` holds the control code.
    public let charactersIgnoringModifiers: String?

    public init(
        keyCode: UInt16,
        characters: String,
        modifiers: KeyModifiers = [],
        isKeyDown: Bool = true,
        charactersIgnoringModifiers: String? = nil
    ) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isKeyDown = isKeyDown
        self.charactersIgnoringModifiers = charactersIgnoringModifiers
    }

    /// The single printable ASCII scalar this event types, if any and if it is not a shortcut.
    public var printableASCII: Unicode.Scalar? {
        guard isKeyDown, !modifiers.isShortcut,
              characters.unicodeScalars.count == 1,
              let scalar = characters.unicodeScalars.first,
              scalar.isASCII, (0x20..<0x7F).contains(scalar.value)
        else { return nil }
        return scalar
    }
}

/// Hardware virtual key codes (`kVK_*` from Carbon's `Events.h`), kept here so the engine
/// needs no Carbon import. These are positions on an ANSI keyboard, not characters.
public enum VirtualKeyCode {
    public static let `return`: UInt16 = 0x24
    public static let keypadEnter: UInt16 = 0x4C
    public static let tab: UInt16 = 0x30
    public static let space: UInt16 = 0x31
    /// Backspace.
    public static let delete: UInt16 = 0x33
    public static let forwardDelete: UInt16 = 0x75
    public static let escape: UInt16 = 0x35
    public static let leftArrow: UInt16 = 0x7B
    public static let rightArrow: UInt16 = 0x7C
    public static let downArrow: UInt16 = 0x7D
    public static let upArrow: UInt16 = 0x7E
    public static let pageUp: UInt16 = 0x74
    public static let pageDown: UInt16 = 0x79
    public static let home: UInt16 = 0x73
    public static let end: UInt16 = 0x77

    public static let ansi0: UInt16 = 0x1D
    public static let ansi1: UInt16 = 0x12
    public static let ansi2: UInt16 = 0x13
    public static let ansi3: UInt16 = 0x14
    public static let ansi4: UInt16 = 0x15
    public static let ansi5: UInt16 = 0x17
    public static let ansi6: UInt16 = 0x16
    public static let ansi7: UInt16 = 0x1A
    public static let ansi8: UInt16 = 0x1C
    public static let ansi9: UInt16 = 0x19

    public static let keypad0: UInt16 = 0x52
    public static let keypad1: UInt16 = 0x53
    public static let keypad2: UInt16 = 0x54
    public static let keypad3: UInt16 = 0x55
    public static let keypad4: UInt16 = 0x56
    public static let keypad5: UInt16 = 0x57
    public static let keypad6: UInt16 = 0x58
    public static let keypad7: UInt16 = 0x59
    public static let keypad8: UInt16 = 0x5B
    public static let keypad9: UInt16 = 0x5C

    public static let minus: UInt16 = 0x1B
    public static let equal: UInt16 = 0x18
    public static let comma: UInt16 = 0x2B
    public static let period: UInt16 = 0x2F
    public static let leftBracket: UInt16 = 0x21
    public static let rightBracket: UInt16 = 0x1E
    public static let grave: UInt16 = 0x32

    public static let f1: UInt16 = 0x7A
    public static let f2: UInt16 = 0x78
    public static let f3: UInt16 = 0x63
    public static let f4: UInt16 = 0x76
    public static let f5: UInt16 = 0x60
    public static let f6: UInt16 = 0x61
    public static let f7: UInt16 = 0x62
    public static let f8: UInt16 = 0x64
    public static let f9: UInt16 = 0x65
    public static let f10: UInt16 = 0x6D
    public static let f11: UInt16 = 0x67
    public static let f12: UInt16 = 0x6F

    /// Function keys F1–F12.
    public static let functionKeys: Set<UInt16> = [f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12]
}
