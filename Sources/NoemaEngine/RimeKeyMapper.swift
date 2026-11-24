import NoemaCore

/// Maps a platform-neutral `KeyEvent` to an X11 keysym and modifier mask for
/// `RimeApi.process_key`, or decides the key must pass through to the client untouched.
///
/// Pure and stateless: the engine supplies whether a composition is open and whether
/// ASCII mode is on. Pass-through rules, in order:
/// 1. key-up events;
/// 2. any modifier other than Shift, Caps Lock, or `⌃` (so every `⌘` or `⌥` chord), after
///    dropping the `fn` bit, which arrow, paging, Home/End and forward-delete keys carry on
///    Mac keyboards;
/// 3. `⌃` chords, except a bare `⌃` plus one of the Emacs editing letters
///    (a e b f n p h g) while composing, which become Home/End/arrows/BackSpace/Escape;
/// 4. everything while idle in ASCII mode;
/// 5. editing, navigation, and whitespace keys while idle (they belong to the client);
/// 6. keys that type no single printable ASCII character.
public enum RimeKeyMapper {
    public enum MappedKey: Sendable, Hashable {
        /// Hand the key back to the client (the shell returns `false`).
        case passthrough
        /// Send this X11 keysym and mask to librime.
        case rime(keycode: Int32, mask: Int32)
    }

    /// X11 / librime modifier mask bits.
    public enum Mask {
        public static let shift: Int32 = 1 << 0
        public static let lock: Int32 = 1 << 1
        public static let control: Int32 = 1 << 2
        public static let alt: Int32 = 1 << 3
    }

    /// X11 keysyms used by the mapper.
    public enum Keysym {
        public static let backSpace: Int32 = 0xFF08
        public static let tab: Int32 = 0xFF09
        public static let `return`: Int32 = 0xFF0D
        public static let escape: Int32 = 0xFF1B
        public static let home: Int32 = 0xFF50
        public static let left: Int32 = 0xFF51
        public static let up: Int32 = 0xFF52
        public static let right: Int32 = 0xFF53
        public static let down: Int32 = 0xFF54
        public static let pageUp: Int32 = 0xFF55
        public static let pageDown: Int32 = 0xFF56
        public static let end: Int32 = 0xFF57
        public static let delete: Int32 = 0xFFFF
        public static let space: Int32 = 0x20
        public static let f1: Int32 = 0xFFBE
    }

    /// Editing and navigation keys by virtual key code. They pass through while idle.
    static let editingKeys: [UInt16: Int32] = [
        VirtualKeyCode.return: Keysym.return,
        VirtualKeyCode.keypadEnter: Keysym.return,
        VirtualKeyCode.tab: Keysym.tab,
        VirtualKeyCode.space: Keysym.space,
        VirtualKeyCode.delete: Keysym.backSpace,
        VirtualKeyCode.forwardDelete: Keysym.delete,
        VirtualKeyCode.escape: Keysym.escape,
        VirtualKeyCode.leftArrow: Keysym.left,
        VirtualKeyCode.rightArrow: Keysym.right,
        VirtualKeyCode.upArrow: Keysym.up,
        VirtualKeyCode.downArrow: Keysym.down,
        VirtualKeyCode.pageUp: Keysym.pageUp,
        VirtualKeyCode.pageDown: Keysym.pageDown,
        VirtualKeyCode.home: Keysym.home,
        VirtualKeyCode.end: Keysym.end,
    ]

    /// `⌃`-letter editing shortcuts honoured while composing (Emacs bindings).
    static let controlEditing: [Character: Int32] = [
        "a": Keysym.home,
        "e": Keysym.end,
        "b": Keysym.left,
        "f": Keysym.right,
        "n": Keysym.down,
        "p": Keysym.up,
        "h": Keysym.backSpace,
        "g": Keysym.escape,
    ]

    static let functionKeyOrder: [UInt16] = [
        VirtualKeyCode.f1, VirtualKeyCode.f2, VirtualKeyCode.f3, VirtualKeyCode.f4,
        VirtualKeyCode.f5, VirtualKeyCode.f6, VirtualKeyCode.f7, VirtualKeyCode.f8,
        VirtualKeyCode.f9, VirtualKeyCode.f10, VirtualKeyCode.f11, VirtualKeyCode.f12,
    ]

    public static func map(_ event: KeyEvent, isComposing: Bool, isASCIIMode: Bool) -> MappedKey {
        guard event.isKeyDown else { return .passthrough }
        // fn rides along with arrows, paging, Home/End, and forward delete; it is not a chord.
        let modifiers = event.modifiers.subtracting(.function)
        // Allow-list: only Shift and Caps Lock reach librime with a key. ⌘, ⌥, and any bit
        // this mapper does not know make the key a shortcut; bare ⌃ is checked below.
        let chord = modifiers.subtracting([.shift, .capsLock])
        if !chord.isEmpty && chord != .control { return .passthrough }

        if chord == .control {
            guard isComposing, modifiers == .control,
                  let letter = controlLetter(of: event),
                  let keysym = controlEditing[letter]
            else { return .passthrough }
            return .rime(keycode: keysym, mask: 0)
        }

        if !isComposing && isASCIIMode { return .passthrough }

        let mask = mask(for: modifiers)
        if let keysym = editingKeys[event.keyCode] {
            guard isComposing else { return .passthrough }
            return .rime(keycode: keysym, mask: mask)
        }
        if let index = functionKeyOrder.firstIndex(of: event.keyCode) {
            guard isComposing else { return .passthrough }
            return .rime(keycode: Keysym.f1 + Int32(index), mask: mask)
        }

        // Printable ASCII: letters start or extend a composition, punctuation goes to the
        // punctuator even while idle, digits select candidates. librime declines what it
        // does not use, and the engine then passes the key through.
        guard event.characters.unicodeScalars.count == 1,
              let scalar = event.characters.unicodeScalars.first,
              (0x21..<0x7F).contains(scalar.value)
        else { return .passthrough }
        return .rime(keycode: Int32(scalar.value), mask: mask)
    }

    /// Shift and Caps Lock are the only modifiers that reach librime with a typed key.
    static func mask(for modifiers: KeyModifiers) -> Int32 {
        var mask: Int32 = 0
        if modifiers.contains(.shift) { mask |= Mask.shift }
        if modifiers.contains(.capsLock) { mask |= Mask.lock }
        return mask
    }

    /// The letter of a `⌃` chord: from `charactersIgnoringModifiers` when present, else
    /// from `characters`, decoding a C0 control code (`⌃A` = U+0001) back to its letter.
    static func controlLetter(of event: KeyEvent) -> Character? {
        for text in [event.charactersIgnoringModifiers, event.characters].compactMap({ $0 }) {
            guard text.unicodeScalars.count == 1, let scalar = text.unicodeScalars.first else { continue }
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A:
                return Character(String(scalar).lowercased())
            case 0x01...0x1A:
                guard let letter = Unicode.Scalar(scalar.value + 0x60) else { continue }
                return Character(letter)
            default:
                continue
            }
        }
        return nil
    }
}
