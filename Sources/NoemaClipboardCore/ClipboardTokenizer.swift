import Foundation

/// Turns text into what the in-memory FTS5 index stores, and a user's search into a safe
/// FTS5 query. FTS5's `unicode61` tokenizer keeps a run of CJK characters as one token, so
/// `你好世界` would only match a search for exactly `你好世界`. `indexForm` puts each CJK
/// character in its own token; `compileFTSQuery` searches CJK runs as phrases (adjacent
/// characters in order), so `你好` matches `你好世界` and `世你` does not.
public enum ClipboardTokenizer {
    /// Han (URO, Extension A, Extensions B–F), Hiragana, Katakana, and Hangul syllables.
    public static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2EBEF, 0x3040...0x30FF, 0xAC00...0xD7AF: true
        default: false
        }
    }

    /// `text` with a space on each side of every CJK scalar; other runs stay contiguous.
    public static func indexForm(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count * 2)
        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                out.append(" ")
                out.append(scalar)
                out.append(" ")
            } else {
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// Whether `unicode61` keeps `scalar` inside a token (letters, numbers, private use).
    static func isTokenCharacter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse, .nonspacingMark, .spacingMark, .enclosingMark:
            true
        default:
            false
        }
    }

    /// An FTS5 MATCH expression for `rawQuery`, or nil when it holds no searchable term.
    /// Each CJK run becomes a quoted phrase (`"你 好"`), each other word a quoted prefix
    /// term (`"swift"*`); terms are joined with `AND`. Punctuation separates words, and
    /// every term is quoted with `"` doubled, so `OR`, `NOT`, `NEAR/5`, `*`, `:`, `(`, `)`,
    /// and `"` in a search are plain text, never FTS5 syntax.
    public static func compileFTSQuery(_ rawQuery: String) -> String? {
        var terms: [String] = []
        var cjk = String.UnicodeScalarView()
        var word = String.UnicodeScalarView()
        func quoted(_ text: String) -> String { "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        func flushCJK() {
            guard !cjk.isEmpty else { return }
            terms.append(quoted(cjk.map { String($0) }.joined(separator: " ")))
            cjk.removeAll()
        }
        func flushWord() {
            guard !word.isEmpty else { return }
            terms.append(quoted(String(word)) + "*")
            word.removeAll()
        }
        for scalar in rawQuery.unicodeScalars {
            if isCJK(scalar) {
                flushWord()
                cjk.append(scalar)
            } else if isTokenCharacter(scalar) {
                flushCJK()
                word.append(scalar)
            } else {
                flushCJK()
                flushWord()
            }
        }
        flushCJK()
        flushWord()
        guard !terms.isEmpty else { return nil }
        return terms.joined(separator: " AND ")
    }
}
