import Foundation
import NoemaCore

/// Exports the learning store to `noema_learned.tsv`, the file `noema_learned.lua` reads:
/// one `<pinyin_compact>\t<text>\t<frequency>\n` line per phrase, most frequent first, then
/// most recent. Entries whose spellings differ only by syllable breaks (`xi an`, `xian`)
/// share one compact key and are merged, frequencies summed.
///
/// Written atomically: a `0600` temporary file in the same directory, `fsync`, `rename(2)`.
public enum LearnedSnapshotExporter {
    /// Phrases beyond this many are left out; the translator only needs the frequent ones.
    public static let defaultMaximumEntries = 100_000

    public struct Line: Sendable, Hashable {
        public var pinyinCompact: String
        public var text: String
        public var frequency: Int64
    }

    /// The lines `export` writes, in order.
    public static func lines(for entries: [LearnedEntry], maximumEntries: Int = defaultMaximumEntries) -> [Line] {
        var lines: [Line] = []
        var index: [String: Int] = [:]
        for entry in entries {
            let key = "\(entry.pinyinCompact)\t\(entry.text)"
            if let existing = index[key] {
                lines[existing].frequency += entry.frequency
            } else {
                guard lines.count < maximumEntries else { continue }
                index[key] = lines.count
                lines.append(Line(pinyinCompact: entry.pinyinCompact, text: entry.text, frequency: entry.frequency))
            }
        }
        // Merging can raise a later line above an earlier one; the sort is stable otherwise.
        return lines.enumerated().sorted { lhs, rhs in
            lhs.element.frequency != rhs.element.frequency ? lhs.element.frequency > rhs.element.frequency : lhs.offset < rhs.offset
        }.map(\.element)
    }

    public static func render(_ lines: [Line]) -> Data {
        var text = ""
        for line in lines { text += "\(line.pinyinCompact)\t\(line.text)\t\(line.frequency)\n" }
        return Data(text.utf8)
    }

    /// Writes every entry of `store` to `url`; returns the number of lines written.
    @discardableResult
    public static func export(
        from store: LearningStore, to url: URL, maximumEntries: Int = defaultMaximumEntries
    ) throws -> Int {
        let lines = lines(for: try store.allEntries(), maximumEntries: maximumEntries)
        try FileSafety.writeAtomically(render(lines), to: url, mode: 0o600)
        return lines.count
    }
}
