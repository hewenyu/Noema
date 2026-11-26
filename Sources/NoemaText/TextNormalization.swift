/// Text helpers shared by lexicon import and learning (pure Swift, no Foundation).
public enum TextNormalization {
    /// Collapses each run of Unicode whitespace to one ASCII space and trims both ends.
    public static func collapsingWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// Lowercased ASCII letters only, as typed into a Rime spelling (e.g. "Ni Hao!" -> "nihao").
    public static func asciiSpellingKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 0x61...0x7A: scalar
            case 0x41...0x5A: Unicode.Scalar(scalar.value + 0x20)
            default: nil
            }
        }))
    }

    /// Han ideograph blocks: CJK Unified Ideographs (basic and Extensions A–J) and
    /// CJK Compatibility Ideographs (and their Supplement).
    static let hanIdeographRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,   // Extension A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0x20000...0x2A6DF, // Extension B
        0x2A700...0x2EBEF, // Extensions C, D, E, F
        0x2EBF0...0x2EE5F, // Extension I
        0x2F800...0x2FA1F, // CJK Compatibility Ideographs Supplement
        0x30000...0x3134F, // Extension G
        0x31350...0x323AF, // Extension H
        0x323B0...0x3347F, // Extension J
    ]

    /// True when every scalar lies in one of `hanIdeographRanges`.
    public static func isAllHanIdeographs(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isHanIdeograph)
    }

    /// True when at least one scalar lies in one of `hanIdeographRanges`.
    public static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanIdeograph)
    }

    static func isHanIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        hanIdeographRanges.contains { $0.contains(scalar.value) }
    }

    /// Precomposed pinyin letters and the base letter each decomposes to (NFD), lowercase;
    /// `v` stands for `ü` in every tone. Combining marks (U+0300–U+036F) after a plain
    /// letter are dropped separately, so decomposed input reads the same.
    static let pinyinDecompositions: [UInt32: Unicode.Scalar] = {
        var table: [UInt32: Unicode.Scalar] = [:]
        let groups: [(Unicode.Scalar, [UInt32])] = [
            ("a", [0x101, 0xE1, 0x1CE, 0xE0, 0x100, 0xC1, 0x1CD, 0xC0]),
            ("e", [0x113, 0xE9, 0x11B, 0xE8, 0x112, 0xC9, 0x11A, 0xC8, 0xEA, 0xCA]),
            ("i", [0x12B, 0xED, 0x1D0, 0xEC, 0x12A, 0xCD, 0x1CF, 0xCC]),
            ("o", [0x14D, 0xF3, 0x1D2, 0xF2, 0x14C, 0xD3, 0x1D1, 0xD2]),
            ("u", [0x16B, 0xFA, 0x1D4, 0xF9, 0x16A, 0xDA, 0x1D3, 0xD9]),
            ("v", [0x1D6, 0x1D8, 0x1DA, 0x1DC, 0x1D5, 0x1D7, 0x1D9, 0x1DB, 0xFC, 0xDC]),
            ("n", [0x144, 0x148, 0x1F9, 0x143, 0x147, 0x1F8]),
            ("m", [0x1E3F, 0x1E3E]),
        ]
        for (base, scalars) in groups {
            for scalar in scalars { table[scalar] = base }
        }
        return table
    }()

    /// The canonical learning key of a pinyin spelling: tone marks and other diacritics
    /// dropped, ASCII letters lowercased, `ü` (also `u` + U+0308 and a typed `u:`) written
    /// `v`, syllables separated by exactly one space. Whitespace, `'`, `-`, tone digits, and
    /// every other non-letter separate syllables and are dropped. "Nǐ hǎo" -> "ni hao",
    /// "xi'an" -> "xi an", "ni3hao3" -> "ni hao", "lü4" -> "lv", "你好" -> "".
    public static func tonelessPinyinKey(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var previousWasU = false
        func append(_ letter: Unicode.Scalar) {
            if pendingSpace, !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(letter)
            previousWasU = letter == "u"
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A:
                append(scalar)
            case 0x41...0x5A:
                append(Unicode.Scalar(scalar.value + 0x20)!)
            case 0x0308 where previousWasU, 0x3A where previousWasU:
                // u + combining diaeresis, or a typed `u:`, is ü.
                result.removeLast()
                result.append("v")
                previousWasU = false
            case 0x0300...0x036F:
                continue
            case 0x30...0x39:
                pendingSpace = true
                previousWasU = false
            default:
                if let base = pinyinDecompositions[scalar.value] {
                    append(base)
                } else {
                    pendingSpace = true
                    previousWasU = false
                }
            }
        }
        return String(result)
    }

    /// `tonelessPinyinKey` without its separators ("ni hao" -> "nihao"): the key
    /// `noema_learned.tsv` and its Lua translator look typed input up by.
    public static func compactPinyinKey(_ text: String) -> String {
        String(String.UnicodeScalarView(tonelessPinyinKey(text).unicodeScalars.filter { $0 != " " }))
    }

    /// The number of syllables of a `tonelessPinyinKey` result.
    public static func syllableCount(ofPinyinKey key: String) -> Int {
        key.isEmpty ? 0 : key.unicodeScalars.reduce(1) { $0 + ($1 == " " ? 1 : 0) }
    }
}
