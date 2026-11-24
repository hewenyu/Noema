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

    /// True when every scalar is in a CJK Unified Ideographs block (basic or extensions A–H).
    public static func isAllHanIdeographs(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2A6DF, 0x2A700...0x2EBEF, 0x2EBF0...0x2EE5F,
                 0x30000...0x3134F, 0x31350...0x323AF:
                true
            default:
                false
            }
        }
    }
}
