import AppKit
import NoemaCore
import NoemaIMEShell
import Testing

/// `NSEventKeyBridge` on real AppKit `NSEvent`s, built the way the window server delivers them.
@MainActor
@Suite struct NSEventKeyBridgeTests {
    private func key(
        _ characters: String,
        ignoring: String? = nil,
        flags: NSEvent.ModifierFlags = [],
        keyCode: UInt16,
        type: NSEvent.EventType = .keyDown
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: characters, charactersIgnoringModifiers: ignoring ?? characters,
            isARepeat: false, keyCode: keyCode))
    }

    @Test func letterKeyDown() throws {
        let event = try #require(NSEventKeyBridge.keyEvent(from: try key("n", keyCode: 0x2D)))
        #expect(event == KeyEvent(keyCode: 0x2D, characters: "n", modifiers: [], isKeyDown: true, charactersIgnoringModifiers: "n"))
        #expect(event.printableASCII == "n")
    }

    @Test func modifiersMapOneToOne() throws {
        let cases: [(NSEvent.ModifierFlags, KeyModifiers)] = [
            (.shift, .shift), (.capsLock, .capsLock), (.control, .control),
            (.option, .option), (.command, .command), (.function, .function),
            ([.command, .shift, .function], [.command, .shift, .function]),
        ]
        for (flags, expected) in cases {
            let event = try #require(NSEventKeyBridge.keyEvent(from: try key("a", flags: flags, keyCode: 0x00)))
            #expect(event.modifiers == expected)
        }
        // Device-dependent bits (left/right side) never leak into KeyModifiers.
        let raw = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        #expect(NSEventKeyBridge.modifiers(from: raw) == .command)
    }

    @Test func controlChordKeepsCharactersIgnoringModifiers() throws {
        let event = try #require(NSEventKeyBridge.keyEvent(from: try key("\u{1}", ignoring: "a", flags: .control, keyCode: 0x00)))
        #expect(event.characters == "\u{1}" && event.charactersIgnoringModifiers == "a")
        #expect(event.modifiers == .control && event.printableASCII == nil)
    }

    @Test func arrowKeyCarriesFunctionFlag() throws {
        let event = try #require(NSEventKeyBridge.keyEvent(
            from: try key("\u{F702}", flags: [.function, .numericPad], keyCode: VirtualKeyCode.leftArrow)))
        #expect(event.keyCode == VirtualKeyCode.leftArrow && event.modifiers == KeyModifiers.function)
    }

    /// Only key-down events convert. Reading `characters` or `keyCode` of a mouse,
    /// application-defined, or flags-changed event raises an Objective-C exception, so the
    /// bridge must reject them by type first; reaching the `#expect` proves it did.
    @Test func nonKeyDownEventsAreRejectedBeforeAnyKeyAccessor() throws {
        let keyUp = try key("n", keyCode: 0x2D, type: .keyUp)
        #expect(NSEventKeyBridge.keyEvent(from: keyUp) == nil)

        let mouse = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(NSEventKeyBridge.keyEvent(from: mouse) == nil)

        let other = try #require(NSEvent.otherEvent(
            with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, subtype: 0, data1: 0, data2: 0))
        #expect(NSEventKeyBridge.keyEvent(from: other) == nil)

        let flags = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: .shift, timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 0x38))
        #expect(NSEventKeyBridge.keyEvent(from: flags) == nil)
    }
}
