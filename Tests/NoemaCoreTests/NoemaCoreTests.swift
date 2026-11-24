import Foundation
import NoemaCore
import NoemaIPC
import NoemaText
import Testing

@Suite struct KeyEventTests {
    @Test func printableASCIIForPlainLetter() {
        let event = KeyEvent(keyCode: 0x00, characters: "a")
        #expect(event.printableASCII == "a")
    }

    @Test(arguments: [
        KeyEvent(keyCode: 0x00, characters: "a", modifiers: .command),
        KeyEvent(keyCode: 0x00, characters: "a", modifiers: [.control, .shift]),
        KeyEvent(keyCode: 0x00, characters: "a", isKeyDown: false),
        KeyEvent(keyCode: 0x24, characters: "\r"),
        KeyEvent(keyCode: 0x33, characters: "\u{7F}"),
        KeyEvent(keyCode: 0x00, characters: "ab"),
        KeyEvent(keyCode: 0x00, characters: "é"),
        KeyEvent(keyCode: 0x7B, characters: ""),
    ])
    func printableASCIIRejectsNonText(_ event: KeyEvent) {
        #expect(event.printableASCII == nil)
    }

    @Test func shiftAndSpaceBoundariesStayPrintable() {
        #expect(KeyEvent(keyCode: 0x00, characters: "A", modifiers: [.shift, .capsLock]).printableASCII == "A")
        #expect(KeyEvent(keyCode: 0x31, characters: " ").printableASCII == " ")
        #expect(KeyEvent(keyCode: 0x2C, characters: "~").printableASCII == "~")
    }

    @Test func modifiersShortcutClassification() {
        #expect(!KeyModifiers([]).isShortcut)
        #expect(!KeyModifiers([.shift, .capsLock, .function]).isShortcut)
        #expect(KeyModifiers.option.isShortcut)
        #expect(KeyModifiers([.shift, .command]).isShortcut)
    }

    @Test func keyEventCodableRoundTrip() throws {
        let event = KeyEvent(keyCode: 0x31, characters: " ", modifiers: [.shift, .option], isKeyDown: false)
        let decoded = try JSONDecoder().decode(KeyEvent.self, from: JSONEncoder().encode(event))
        #expect(decoded == event)
    }

    @Test func modifiersEncodeAsRawBits() throws {
        let data = try JSONEncoder().encode(KeyModifiers([.shift, .command]))
        #expect(String(decoding: data, as: UTF8.self) == "17")
    }
}

@Suite struct NoemaVersionTests {
    @Test func parsesAndOrders() throws {
        let version = try #require(NoemaVersion("1.10.0"))
        #expect(version == NoemaVersion(major: 1, minor: 10, patch: 0))
        #expect(NoemaVersion(major: 1, minor: 9, patch: 9) < version)
        #expect(version.description == "1.10.0")
    }

    @Test(arguments: ["", "1", "1.2", "1.2.3.4", "1..3", "a.b.c", "-1.0.0", "1.2.3 ", "١.٢.٣"])
    func rejectsMalformed(_ text: String) {
        #expect(NoemaVersion(text) == nil)
    }
}

@Suite struct NoemaErrorTests {
    @Test func codableRoundTripPreservesAssociatedValues() throws {
        let errors: [NoemaError] = [
            .engineUnavailable(reason: "missing"),
            .engineCallFailed(function: "deploy"),
            .unsupportedVersion(found: 9, supported: 1...2),
            .invalidArgument(""),
        ]
        let decoded = try JSONDecoder().decode([NoemaError].self, from: JSONEncoder().encode(errors))
        #expect(decoded == errors)
    }
}

@Suite struct IPCEnvelopeTests {
    struct Ping: Codable, Sendable, Equatable {
        var text: String
    }

    @Test func roundTripsCurrentVersion() throws {
        let envelope = IPCEnvelope(sequence: .max, kind: "test.ping", payload: Ping(text: "你好"))
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(IPCEnvelope<Ping>.self, from: data)
        #expect(decoded == envelope)
        #expect(decoded.version == .current)
    }

    @Test(arguments: [0, 2, -1])
    func rejectsUnsupportedVersion(_ raw: Int) throws {
        let json = #"{"version":\#(raw),"sequence":1,"kind":"test.ping","payload":{"text":"x"}}"#
        #expect(throws: IPCEnvelope<Ping>.UnsupportedVersion(found: raw)) {
            try JSONDecoder().decode(IPCEnvelope<Ping>.self, from: Data(json.utf8))
        }
    }

    @Test func rejectsMissingPayload() {
        let json = #"{"version":1,"sequence":1,"kind":"test.ping"}"#
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(IPCEnvelope<Ping>.self, from: Data(json.utf8))
        }
    }
}

@Suite struct TextNormalizationTests {
    @Test func collapsesWhitespace() {
        #expect(TextNormalization.collapsingWhitespace("  你好\t\n 世界\u{3000} ") == "你好 世界")
        #expect(TextNormalization.collapsingWhitespace(" \n\t") == "")
        #expect(TextNormalization.collapsingWhitespace("") == "")
    }

    @Test func asciiSpellingKey() {
        #expect(TextNormalization.asciiSpellingKey("Ni Hao!") == "nihao")
        #expect(TextNormalization.asciiSpellingKey("你好123") == "")
        #expect(TextNormalization.asciiSpellingKey("[Za]") == "za")
    }

    @Test func hanIdeographDetection() {
        #expect(TextNormalization.isAllHanIdeographs("你好"))
        #expect(TextNormalization.isAllHanIdeographs("𠀀"))
        #expect(!TextNormalization.isAllHanIdeographs("你好!"))
        #expect(!TextNormalization.isAllHanIdeographs("かな"))
        #expect(!TextNormalization.isAllHanIdeographs(""))
    }
}
