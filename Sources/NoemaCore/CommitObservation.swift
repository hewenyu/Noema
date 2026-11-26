/// What an engine committed, with the input that produced it, captured before the key,
/// selection, or commit call changed the engine's state. The learning recorder turns it
/// into a learned phrase; it never leaves the input method process.
public struct CommitObservation: Sendable, Hashable {
    /// The engine's raw input before the call (e.g. `nihao`).
    public let rawInput: String
    /// The preedit shown before the call (e.g. `ni hao`).
    public let preedit: String
    /// The committed text the call drained.
    public let committedText: String
    public let schemaID: String?
    /// Whether `schemaID` spells Mandarin pinyin (full, double, or jianpin; its preedit and
    /// userdb are keyed by full pinyin). False for a shape or non-Mandarin schema (Wubi,
    /// Cangjie, Zhuyin, Jyutping): its codes (`wo` for 伙 in Wubi 98) are never readings, so
    /// the commit is never learned. `RimeEngine` always passes the live schema's answer.
    public let isMandarinPinyinSchema: Bool

    public init(
        rawInput: String, preedit: String, committedText: String, schemaID: String?, isMandarinPinyinSchema: Bool = true
    ) {
        self.rawInput = rawInput
        self.preedit = preedit
        self.committedText = committedText
        self.schemaID = schemaID
        self.isMandarinPinyinSchema = isMandarinPinyinSchema
    }
}
