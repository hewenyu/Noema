import CryptoKit
import Foundation

/// Line-level edits of a Rime `<schema>.custom.yaml` that `noema-rime-deployer` makes in
/// its staging directory. Never parses YAML in general: it only recognizes a top-level
/// block `patch:` line and, directly under it, an `engine/translators/+` key, and refuses
/// anything else rather than guess.
public enum SchemaPatch {
    /// The patch key whose sequence librime appends to the schema's translator list. Unlike
    /// `@after last`, a user's patch may hold its own copy of that key without one of the two
    /// being dropped: librime applies `engine/translators/+` and `engine/translators/@after
    /// last` both.
    public static let appendTranslatorKey = "engine/translators/+"

    /// `existing` (nil: no file) with `"<component>"` added to the `"engine/translators/+"`
    /// sequence of its patch, so no patch key is ever duplicated. Returns the text unchanged
    /// when a line other than a comment already names `"<component>"`; a new file when
    /// `existing` is nil or holds no top-level `patch:` key (one is appended). Under a
    /// top-level block `patch:` line, an existing block `engine/translators/+` key (quoted or
    /// not) gets the item as its first entry, indented like its first item; otherwise the key
    /// and item are inserted right under `patch:`, indented like that mapping's first key
    /// (two spaces when it is empty). Nil when `patch:` is in flow style (`patch: {...}`),
    /// the `engine/translators/+` key has an inline value (`[...]`, a scalar) or a mapping,
    /// or a tab-indented line is under `patch:`. CRLF files are edited line by line and keep
    /// their CRLF endings. `noema-rime-deployer` still checks the compiled translator list.
    public static func appendingTranslator(_ component: String, to existing: String?) -> String? {
        let item = "- \"\(component)\""
        let key = "\"\(appendTranslatorKey)\":"
        guard let original = existing, !original.isEmpty else { return "patch:\n  \(key)\n    \(item)\n" }
        let quoted = "\"\(component)\""
        let named = original.split(whereSeparator: \.isNewline).contains { line in
            !line.drop { $0 == " " }.hasPrefix("#") && line.contains(quoted)
        }
        if named { return original }
        // `"\r\n"` is one Character, so it never matches a `"\n"` split; edit LF lines.
        let usesCRLF = original.contains("\r\n")
        guard let patched = appendingItem(item, key: key, to: usesCRLF ? original.replacingOccurrences(of: "\r\n", with: "\n") : original)
        else { return nil }
        return usesCRLF ? patched.replacingOccurrences(of: "\n", with: "\r\n") : patched
    }

    private static func appendingItem(_ item: String, key: String, to existing: String) -> String? {
        var text = existing
        if !text.hasSuffix("\n") { text += "\n" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let patchIndex = lines.firstIndex(where: isTopLevelPatchKey) else {
            if lines.contains(where: { $0.hasPrefix("patch:") }) { return nil }
            return text + "patch:\n  \(key)\n    \(item)\n"
        }
        // The patch mapping: every line after `patch:` up to the next column-0 content.
        var end = patchIndex + 1
        while end < lines.count {
            let line = lines[end]
            let trimmed = line.drop { $0 == " " }
            if !trimmed.isEmpty, !trimmed.hasPrefix("#"), line.first != " ", line.first != "\t" { break }
            if line.first == "\t" { return nil }
            end += 1
        }
        let body = (patchIndex + 1)..<end
        let indent = body.lazy.map { lines[$0] }
            .first { !$0.drop { $0 == " " }.isEmpty && !$0.drop { $0 == " " }.hasPrefix("#") }
            .map { String($0.prefix { $0 == " " }) } ?? "  "
        for index in body where lines[index].hasPrefix(indent) && lines[index].dropFirst(indent.count).first != " " {
            guard let value = appendKeyValue(lines[index].dropFirst(indent.count)) else { continue }
            guard value.isEmpty else { return nil }
            // A block sequence: items more indented than the key, or `- ` at its indent.
            // Nothing (null) gets a fresh sequence; anything else (a nested mapping) is refused.
            var itemIndent = indent + "  "
            if let first = lines[(index + 1)..<end].first(where: {
                let trimmed = $0.drop { $0 == " " }
                return !trimmed.isEmpty && !trimmed.hasPrefix("#")
            }) {
                let depth = first.prefix { $0 == " " }
                if first.dropFirst(depth.count).hasPrefix("- ") || first.dropFirst(depth.count) == "-" {
                    guard depth.count >= indent.count else { return nil }
                    itemIndent = String(depth)
                } else if depth.count > indent.count {
                    return nil
                }
            }
            lines.insert(itemIndent + item, at: index + 1)
            return lines.joined(separator: "\n") + "\n"
        }
        lines.insert(contentsOf: [indent + key, indent + "  " + item], at: patchIndex + 1)
        return lines.joined(separator: "\n") + "\n"
    }

    /// For a patch-mapping line whose key is `engine/translators/+` (plain, `"..."`, or
    /// `'...'`), what follows the colon and its spaces (empty for nothing or only a
    /// comment); nil for any other line.
    static func appendKeyValue(_ line: Substring) -> Substring? {
        for spelling in [appendTranslatorKey, "\"\(appendTranslatorKey)\"", "'\(appendTranslatorKey)'"] {
            guard line.hasPrefix(spelling) else { continue }
            var rest = line.dropFirst(spelling.count).drop { $0 == " " }
            guard rest.first == ":" else { return nil }
            rest = rest.dropFirst()
            guard rest.isEmpty || rest.first == " " || rest.first == "\r" else { return nil }
            let value = rest.drop { $0 == " " || $0 == "\r" }
            return value.hasPrefix("#") ? "" : value
        }
        return nil
    }

    /// `patch:` at column 0 with nothing after it but spaces, a stray `\r`, or a comment.
    static func isTopLevelPatchKey(_ line: String) -> Bool {
        guard line.hasPrefix("patch:") else { return false }
        let rest = line.dropFirst("patch:".count).drop { $0 == " " || $0 == "\t" || $0 == "\r" }
        return rest.isEmpty || rest.hasPrefix("#")
    }
}

extension DeployManifest {
    /// Lowercase hex SHA-256 of `data`, or nil for nil.
    public static func sha256(of data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}
