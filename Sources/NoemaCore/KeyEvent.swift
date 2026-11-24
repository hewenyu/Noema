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

    public init(keyCode: UInt16, characters: String, modifiers: KeyModifiers = [], isKeyDown: Bool = true) {
        self.keyCode = keyCode
        self.characters = characters
        self.modifiers = modifiers
        self.isKeyDown = isKeyDown
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
