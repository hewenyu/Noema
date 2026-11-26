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
        #expect(throws: IPCError.unsupportedVersion(found: raw)) {
            try JSONDecoder().decode(IPCEnvelope<Ping>.self, from: Data(json.utf8))
        }
    }

    /// The version error does not depend on the payload type, so one catch serves
    /// every envelope.
    @Test func unsupportedVersionErrorIsPayloadIndependent() {
        let json = #"{"version":9,"sequence":1,"kind":"test.ping","payload":{"text":"x"}}"#
        let errors: [IPCError?] = [
            decodeError { try JSONDecoder().decode(IPCEnvelope<Ping>.self, from: Data(json.utf8)) },
            decodeError { try JSONDecoder().decode(IPCEnvelope<[String: String]>.self, from: Data(json.utf8)) },
        ]
        #expect(errors == [.unsupportedVersion(found: 9), .unsupportedVersion(found: 9)])
    }

    private func decodeError(_ body: () throws -> some Any) -> IPCError? {
        do {
            _ = try body()
            return nil
        } catch {
            return error as? IPCError
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

    /// First and last code point of every accepted block, plus the gaps around them.
    @Test(arguments: [
        0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xF900, 0xFAFF,
        0x20000, 0x2A6DF, 0x2A700, 0x2B73F, 0x2B740, 0x2B820, 0x2CEB0, 0x2EBEF,
        0x2EBF0, 0x2EE5F, 0x2F800, 0x2FA1F, 0x30000, 0x3134F, 0x31350, 0x323AF,
        0x323B0, 0x3347F,
    ] as [UInt32])
    func hanIdeographBlockBoundaries(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(TextNormalization.isAllHanIdeographs(String(scalar)), "U+\(String(value, radix: 16, uppercase: true))")
    }

    @Test(arguments: [
        0x33FF, 0x4DC0, 0x4DFF, 0xA000, 0xF8FF, 0xFB00,
        0x1FFFF, 0x2A6E0, 0x2A6FF, 0x2EE60, 0x2F7FF, 0x2FA20, 0x2FFFF, 0x33480,
    ] as [UInt32])
    func nonHanNeighboursAreRejected(_ value: UInt32) throws {
        let scalar = try #require(Unicode.Scalar(value))
        #expect(!TextNormalization.isAllHanIdeographs(String(scalar)), "U+\(String(value, radix: 16, uppercase: true))")
    }

    /// The transform's toned readings, NFC as 万象 v18.2.1's dictionaries spell them: `ü`
    /// kept (`nǚ`, `lüè`), `u` after `x`, the neutral tone unmarked.
    @Test func unicodeTonedReadings() {
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "霓昊") == ["ní", "hào"])
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "女孩") == ["nǚ", "hái"])
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "略") == ["lüè"])
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "学的") == ["xué", "de"])
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "你好a") == nil)
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "嗯") == nil)
        #expect(TextNormalization.unicodeTonedMandarinPinyinSyllables(for: "") == nil)
    }

    /// Regular phrases, `ü`, polyphones (the typed reading wins: `hang` for 行, `chong` for
    /// 重), and text that does not align one Han character per syllable. Every result is NFC.
    @Test(arguments: [
        ("ni hao", "霓昊", "ní hào"), ("ni hao", "你好", "nǐ hǎo"), ("shi jie", "世界", "shì jiè"),
        ("nv hai", "女孩", "nǚ hái"), ("lv se", "绿色", "lǜ sè"), ("lve", "略", "lüè"), ("lue", "略", "lüè"),
        ("nve dai", "虐待", "nüè dài"), ("xue", "学", "xué"), ("de", "的", "de"),
        ("yin hang", "银行", "yín hāng"), ("hang ye", "行业", "hāng yè"), ("chong qing", "重庆", "chóng qìng"),
        ("chong hao", "重昊", "chōng hào"), ("zhong yao", "重要", "zhòng yào"), ("ren hao", "人昊", "rén hào"),
        ("lan hao", "蓝昊", "lán hào"), ("ni hao", "你好!", "nǐ hǎo"), ("ni hao", "你", "nī hāo"),
        ("shui", "睡", "shuì"), ("shui", "谁", "shuí"),
    ])
    func unicodeTonedPinyinKey(_ norm: String, _ text: String, _ expected: String) {
        let key = TextNormalization.unicodeTonedPinyinKey(pinyinNorm: norm, text: text)
        #expect(Array(key.unicodeScalars) == Array(expected.precomposedStringWithCanonicalMapping.unicodeScalars), "\(key)")
        #expect(TextNormalization.tonelessPinyinKey(key) == TextNormalization.tonelessPinyinKey(norm == "lue" ? "lve" : norm))
    }

    /// Every standard syllable gets a toned reading that maps back to it, with the standard
    /// mark placement; one with no first-tone reading takes another tone.
    @Test func defaultTonedSyllables() {
        for syllable in TextNormalization.standardMandarinSyllables {
            let toned = TextNormalization.defaultTonedSyllable(syllable)
            #expect(TextNormalization.tonelessPinyinKey(toned) == syllable, "\(syllable) -> \(toned)")
            #expect(toned == toned.precomposedStringWithCanonicalMapping)
        }
        for (syllable, expected) in [
            ("hang", "hāng"), ("lan", "lán"), ("shui", "shuí"), ("lve", "lüè"), ("nv", "nǚ"), ("lv", "lǘ"),
            ("zhei", "zhèi"), ("lo", "lo"), ("gui", "guī"), ("liu", "liū"), ("ou", "ōu"), ("er", "ér"),
        ] {
            #expect(TextNormalization.defaultTonedSyllable(syllable) == expected)
        }
        #expect(TextNormalization.applyToneMark(to: "xiong", tone: 2) == "xióng")
        #expect(TextNormalization.applyToneMark(to: "nve", tone: 5) == "nüe")
    }
}
