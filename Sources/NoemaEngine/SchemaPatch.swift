import CryptoKit
import Foundation

/// Line-level edits of a Rime `<schema>.custom.yaml` that `noema-rime-deployer` makes in
/// its staging directory. Never parses YAML in general: it only recognizes a top-level
/// block `patch:` line, and refuses anything else rather than guess.
public enum SchemaPatch {
    /// The patch key that appends to the schema's translator list.
    public static let appendTranslatorKey = "engine/translators/@after last"

    /// `existing` (nil: no file) with `"engine/translators/@after last": "<component>"`
    /// added to its patch. Returns the text unchanged when it already names `component`;
    /// a new file when `existing` is nil or holds no top-level `patch:` key (one is
    /// appended); the line inserted right under a top-level block `patch:` line, indented
    /// like that mapping's first key (two spaces when it is empty); nil when `patch:` is in
    /// flow style (`patch: {...}`) or the text holds a tab-indented line under it.
    public static func appendingTranslator(_ component: String, to existing: String?) -> String? {
        let line = "\"\(appendTranslatorKey)\": \"\(component)\""
        guard var text = existing, !text.isEmpty else { return "patch:\n  \(line)\n" }
        if text.contains("\"\(component)\"") { return text }
        if !text.hasSuffix("\n") { text += "\n" }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        guard let patchIndex = lines.firstIndex(where: isTopLevelPatchKey) else {
            if lines.contains(where: { $0.hasPrefix("patch:") }) { return nil }
            return text + "patch:\n  \(line)\n"
        }
        var indent = "  "
        for candidate in lines[(patchIndex + 1)...] {
            let trimmed = candidate.drop { $0 == " " }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if candidate.first == "\t" { return nil }
            guard candidate.first == " " else { break }
            indent = String(candidate.prefix { $0 == " " })
            break
        }
        lines.insert(indent + line, at: patchIndex + 1)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `patch:` at column 0 with nothing after it but spaces or a comment.
    static func isTopLevelPatchKey(_ line: String) -> Bool {
        guard line.hasPrefix("patch:") else { return false }
        let rest = line.dropFirst("patch:".count).drop { $0 == " " || $0 == "\t" }
        return rest.isEmpty || rest.hasPrefix("#")
    }
}

extension DeployManifest {
    /// Lowercase hex SHA-256 of `data`, or nil for nil.
    public static func sha256(of data: Data?) -> String? {
        data.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
    }
}
