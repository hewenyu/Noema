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
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            hanIdeographRanges.contains { $0.contains(scalar.value) }
        }
    }
}
