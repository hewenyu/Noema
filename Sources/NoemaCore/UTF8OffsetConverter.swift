/// Converts the UTF-8 byte offsets librime reports (`cursor_pos`, `sel_start`, `sel_end`)
/// into offsets on a Unicode scalar boundary, in UTF-8 bytes and UTF-16 code units
/// (what `NSRange`-based text clients expect).
///
/// Offsets are untrusted: they are clamped to `0...text.utf8.count`, and an offset that
/// falls inside a multi-byte scalar (a 3-byte Han character, a 4-byte emoji) moves left to
/// the start of that scalar. No conversion traps.
public enum UTF8OffsetConverter {
    /// A position in `text`, in UTF-8 bytes and UTF-16 code units, on a scalar boundary.
    public struct Offset: Sendable, Hashable, Codable {
        public let utf8: Int
        public let utf16: Int

        public init(utf8: Int, utf16: Int) {
            self.utf8 = utf8
            self.utf16 = utf16
        }
    }

    /// Clamps `byteOffset` into `text` and snaps it left to a scalar boundary.
    public static func offset(in text: String, fromUTF8ByteOffset byteOffset: Int) -> Offset {
        let utf8 = text.utf8
        var clamped = min(max(byteOffset, 0), utf8.count)
        // A UTF-8 scalar is at most 4 bytes, so a boundary lies at most 3 bytes to the left.
        var index = utf8.index(utf8.startIndex, offsetBy: clamped)
        var steps = 0
        while index.samePosition(in: text.unicodeScalars) == nil, clamped > 0, steps < 3 {
            index = utf8.index(before: index)
            clamped -= 1
            steps += 1
        }
        if index.samePosition(in: text.unicodeScalars) == nil {
            // Not reachable for valid Swift strings; fall back to the start, never trap.
            return Offset(utf8: 0, utf16: 0)
        }
        let utf16 = text.utf16.distance(from: text.utf16.startIndex, to: index)
        return Offset(utf8: clamped, utf16: utf16)
    }

    /// The UTF-16 offset for a librime UTF-8 byte offset into `text`.
    public static func utf16Offset(in text: String, fromUTF8ByteOffset byteOffset: Int) -> Int {
        offset(in: text, fromUTF8ByteOffset: byteOffset).utf16
    }

    /// Converts a librime byte range (`sel_start`, `sel_end`) into ordered, clamped, scalar
    /// aligned UTF-8 and UTF-16 ranges. Swapped bounds are reordered.
    public static func ranges(
        in text: String, utf8Start: Int, utf8End: Int
    ) -> (utf8: Range<Int>, utf16: Range<Int>) {
        let lower = offset(in: text, fromUTF8ByteOffset: min(utf8Start, utf8End))
        let upper = offset(in: text, fromUTF8ByteOffset: max(utf8Start, utf8End))
        // Snapping keeps order (both move left within one scalar at most), but stay defensive.
        let utf8Range = min(lower.utf8, upper.utf8)..<max(lower.utf8, upper.utf8)
        let utf16Range = min(lower.utf16, upper.utf16)..<max(lower.utf16, upper.utf16)
        return (utf8Range, utf16Range)
    }
}
