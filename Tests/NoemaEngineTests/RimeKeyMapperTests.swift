import NoemaCore
import NoemaEngine
import Testing

/// Pure mapping rules; no librime involved, so these run concurrently.
@Suite struct RimeKeyMapperTests {
    typealias K = RimeKeyMapper.Keysym
    typealias M = RimeKeyMapper.Mask

    static func key(_ code: UInt16, _ characters: String = "", _ modifiers: KeyModifiers = [],
                    down: Bool = true, ignoring: String? = nil) -> KeyEvent {
        KeyEvent(keyCode: code, characters: characters, modifiers: modifiers, isKeyDown: down,
                 charactersIgnoringModifiers: ignoring)
    }

    static func map(_ event: KeyEvent, composing: Bool = true, ascii: Bool = false) -> RimeKeyMapper.MappedKey {
        RimeKeyMapper.map(event, isComposing: composing, isASCIIMode: ascii)
    }

    @Test func lettersAndPunctuationReachRimeWhileIdle() {
        #expect(Self.map(Self.key(0x2D, "n"), composing: false) == .rime(keycode: 0x6E, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.comma, ","), composing: false) == .rime(keycode: 0x2C, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.period, "."), composing: false) == .rime(keycode: 0x2E, mask: 0))
        #expect(Self.map(Self.key(0x2C, "?", .shift), composing: false) == .rime(keycode: 0x3F, mask: M.shift))
        #expect(Self.map(Self.key(0x00, "A", [.capsLock]), composing: false) == .rime(keycode: 0x41, mask: M.lock))
    }

    @Test func keyUpAlwaysPassesThrough() {
        #expect(Self.map(Self.key(0x00, "a", down: false)) == .passthrough)
        #expect(Self.map(Self.key(VirtualKeyCode.return, "\r", down: false)) == .passthrough)
    }

    /// Arrow, paging, Home/End, and forward-delete keys carry fn on Mac keyboards; the
    /// mapper must strip it, not treat it as a chord.
    @Test(arguments: [
        (VirtualKeyCode.leftArrow, K.left), (VirtualKeyCode.rightArrow, K.right),
        (VirtualKeyCode.upArrow, K.up), (VirtualKeyCode.downArrow, K.down),
        (VirtualKeyCode.pageUp, K.pageUp), (VirtualKeyCode.pageDown, K.pageDown),
        (VirtualKeyCode.home, K.home), (VirtualKeyCode.end, K.end),
        (VirtualKeyCode.forwardDelete, K.delete),
    ])
    func functionBitIsStrippedFromNavigationKeys(_ code: UInt16, _ keysym: Int32) {
        #expect(Self.map(Self.key(code, "", .function)) == .rime(keycode: keysym, mask: 0))
        #expect(Self.map(Self.key(code, "", [.function, .shift])) == .rime(keycode: keysym, mask: M.shift))
        #expect(Self.map(Self.key(code, "", .function), composing: false) == .passthrough)
    }

    @Test(arguments: [
        VirtualKeyCode.return, VirtualKeyCode.keypadEnter, VirtualKeyCode.delete, VirtualKeyCode.forwardDelete,
        VirtualKeyCode.escape, VirtualKeyCode.tab, VirtualKeyCode.space, VirtualKeyCode.leftArrow,
        VirtualKeyCode.rightArrow, VirtualKeyCode.upArrow, VirtualKeyCode.downArrow, VirtualKeyCode.pageUp,
        VirtualKeyCode.pageDown, VirtualKeyCode.home, VirtualKeyCode.end, VirtualKeyCode.f4,
    ])
    func idleEditingKeysPassThrough(_ code: UInt16) {
        #expect(Self.map(Self.key(code, code == VirtualKeyCode.space ? " " : ""), composing: false) == .passthrough)
    }

    @Test func composingEditingKeysMapToKeysyms() {
        #expect(Self.map(Self.key(VirtualKeyCode.return, "\r")) == .rime(keycode: K.return, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.keypadEnter, "\u{3}")) == .rime(keycode: K.return, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.delete, "\u{7F}")) == .rime(keycode: K.backSpace, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.escape, "\u{1B}")) == .rime(keycode: K.escape, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.space, " ")) == .rime(keycode: K.space, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.tab, "\t")) == .rime(keycode: K.tab, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.tab, "\u{19}", .shift)) == .rime(keycode: K.tab, mask: M.shift))
        #expect(Self.map(Self.key(VirtualKeyCode.f1, "")) == .rime(keycode: K.f1, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.f12, "")) == .rime(keycode: K.f1 + 11, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.ansi1, "1")) == .rime(keycode: 0x31, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.keypad3, "3")) == .rime(keycode: 0x33, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.minus, "-")) == .rime(keycode: 0x2D, mask: 0))
        #expect(Self.map(Self.key(VirtualKeyCode.equal, "=")) == .rime(keycode: 0x3D, mask: 0))
    }

    @Test(arguments: [true, false])
    func commandAndOptionChordsAlwaysPassThrough(_ composing: Bool) {
        #expect(Self.map(Self.key(0x00, "a", .command), composing: composing) == .passthrough)
        #expect(Self.map(Self.key(0x08, "c", [.command, .function]), composing: composing) == .passthrough)
        #expect(Self.map(Self.key(0x00, "å", .option), composing: composing) == .passthrough)
        #expect(Self.map(Self.key(VirtualKeyCode.leftArrow, "", [.option, .function]), composing: composing) == .passthrough)
        #expect(Self.map(Self.key(VirtualKeyCode.return, "\r", .command), composing: composing) == .passthrough)
    }

    @Test(arguments: [
        ("a", K.home), ("e", K.end), ("b", K.left), ("f", K.right),
        ("n", K.down), ("p", K.up), ("h", K.backSpace), ("g", K.escape),
    ])
    func controlEditingWhitelistWhileComposing(_ letter: String, _ keysym: Int32) throws {
        let scalar = try #require(letter.unicodeScalars.first)
        let control = String(try #require(Unicode.Scalar(scalar.value - 0x60)))
        // Recognized from charactersIgnoringModifiers, and from the C0 code alone.
        #expect(Self.map(Self.key(0x00, control, .control, ignoring: letter)) == .rime(keycode: keysym, mask: 0))
        #expect(Self.map(Self.key(0x00, control, .control)) == .rime(keycode: keysym, mask: 0))
        #expect(Self.map(Self.key(0x00, control, [.control, .function], ignoring: letter)) == .rime(keycode: keysym, mask: 0))
        // Idle, extra modifiers, or ⌘ never reach librime.
        #expect(Self.map(Self.key(0x00, control, .control, ignoring: letter), composing: false) == .passthrough)
        #expect(Self.map(Self.key(0x00, control, [.control, .shift], ignoring: letter)) == .passthrough)
        #expect(Self.map(Self.key(0x00, control, [.control, .command], ignoring: letter)) == .passthrough)
    }

    @Test(arguments: [("c", "\u{3}"), ("d", "\u{4}"), ("z", "\u{1A}"), ("k", "\u{B}"), (" ", "\0")])
    func controlShortcutsOutsideWhitelistPassThrough(_ letter: String, _ control: String) {
        let code = letter == " " ? VirtualKeyCode.space : 0x08
        #expect(Self.map(Self.key(code, control, .control, ignoring: letter)) == .passthrough)
        #expect(Self.map(Self.key(code, control, .control, ignoring: letter), composing: false) == .passthrough)
    }

    @Test func unknownModifierBitsPassThrough() {
        let unknown = KeyModifiers(rawValue: 1 << 9)
        #expect(Self.map(Self.key(0x00, "a", unknown)) == .passthrough)
        #expect(Self.map(Self.key(VirtualKeyCode.leftArrow, "", [unknown, .function])) == .passthrough)
    }

    @Test func asciiModePassesEverythingThroughWhileIdle() {
        #expect(Self.map(Self.key(0x00, "a"), composing: false, ascii: true) == .passthrough)
        #expect(Self.map(Self.key(VirtualKeyCode.comma, ","), composing: false, ascii: true) == .passthrough)
        // A composition still open when ASCII mode turns on keeps receiving keys.
        #expect(Self.map(Self.key(0x00, "a"), composing: true, ascii: true) == .rime(keycode: 0x61, mask: 0))
    }

    @Test func nonASCIIOrMultiCharacterInputPassesThrough() {
        #expect(Self.map(Self.key(0x00, "é")) == .passthrough)
        #expect(Self.map(Self.key(0x00, "ab")) == .passthrough)
        #expect(Self.map(Self.key(0x00, "")) == .passthrough)
        #expect(Self.map(Self.key(0x00, "\u{7F}")) == .passthrough)
        #expect(Self.map(Self.key(0x38, ""), composing: false) == .passthrough)
    }

    @Test func virtualKeyCodesMatchCarbonValues() {
        #expect(VirtualKeyCode.return == 0x24 && VirtualKeyCode.keypadEnter == 0x4C)
        #expect(VirtualKeyCode.tab == 0x30 && VirtualKeyCode.space == 0x31 && VirtualKeyCode.delete == 0x33)
        #expect(VirtualKeyCode.forwardDelete == 0x75 && VirtualKeyCode.escape == 0x35)
        #expect(VirtualKeyCode.leftArrow == 0x7B && VirtualKeyCode.rightArrow == 0x7C)
        #expect(VirtualKeyCode.downArrow == 0x7D && VirtualKeyCode.upArrow == 0x7E)
        #expect(VirtualKeyCode.pageUp == 0x74 && VirtualKeyCode.pageDown == 0x79)
        #expect(VirtualKeyCode.home == 0x73 && VirtualKeyCode.end == 0x77)
        #expect(VirtualKeyCode.ansi0 == 0x1D && VirtualKeyCode.ansi9 == 0x19)
        #expect(VirtualKeyCode.keypad0 == 0x52 && VirtualKeyCode.keypad9 == 0x5C)
        #expect(VirtualKeyCode.functionKeys.count == 12)
    }
}
