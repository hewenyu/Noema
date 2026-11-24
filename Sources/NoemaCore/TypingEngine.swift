/// One candidate on the current menu page.
public struct CandidateItem: Sendable, Hashable, Codable {
    public let text: String
    public let comment: String?
    /// Selection label shown beside the candidate (e.g. "1"), if the engine provides one.
    public let label: String?

    public init(text: String, comment: String? = nil, label: String? = nil) {
        self.text = text
        self.comment = comment
        self.label = label
    }
}

/// Why an engine started in Safe Mode: it then handles no key and every key passes through.
public enum SafeModeReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The previous launches failed while loading the engine (crash loop).
    case bootCrashLoop
    /// The user data directory cannot be written (read-only, permissions, disk full).
    case userDataDirUnwritable
    /// The boot-guard sentinel is unreadable, malformed, or not a regular file.
    case bootGuardCorrupted
    /// Another process holds the single-writer lock on the user data directory.
    case userDataDirLocked
    /// The engine failed to deploy, initialize, or open a session.
    case engineInitFailed
}

/// Why a key was not handled by the engine even though it might have been.
public enum KeyDegradation: String, Sendable, Hashable, Codable {
    case safeMode
    case timeout
    case engineUnavailable
}

/// A snapshot of the composition after an engine call. Offsets are on Unicode scalar
/// boundaries of `preedit`, in UTF-8 bytes and UTF-16 code units.
public struct CompositionState: Sendable, Hashable, Codable {
    public let preedit: String
    public let caretUTF8Offset: Int
    public let caretUTF16Offset: Int
    public let selectionUTF8Range: Range<Int>
    public let selectionUTF16Range: Range<Int>
    /// Text that committing now would insert, if the engine provides it.
    public let commitTextPreview: String?
    /// Candidates on the current page.
    public let candidates: [CandidateItem]
    /// Highlighted candidate on the current page; nil exactly when `candidates` is empty.
    public let highlightedIndex: Int?
    public let pageIndex: Int
    public let pageSize: Int
    public let isLastPage: Bool
    public let isComposing: Bool
    public let isASCIIMode: Bool
    public let schemaID: String?
    /// Strictly increases with every state the engine produces; stale snapshots compare lower.
    public let generationID: UInt64
    public let isSafeMode: Bool
    public let safeModeReason: SafeModeReason?

    /// Builds a state, normalizing inconsistent inputs instead of trapping: offsets are
    /// clamped into `preedit`, ranges are clamped, `highlightedIndex` is nil for an empty
    /// menu and clamped into `0..<candidates.count` otherwise, and page fields are non-negative.
    public init(
        preedit: String = "",
        caretUTF8Offset: Int = 0,
        caretUTF16Offset: Int = 0,
        selectionUTF8Range: Range<Int> = 0..<0,
        selectionUTF16Range: Range<Int> = 0..<0,
        commitTextPreview: String? = nil,
        candidates: [CandidateItem] = [],
        highlightedIndex: Int? = nil,
        pageIndex: Int = 0,
        pageSize: Int = 0,
        isLastPage: Bool = true,
        isComposing: Bool = false,
        isASCIIMode: Bool = false,
        schemaID: String? = nil,
        generationID: UInt64 = 0,
        isSafeMode: Bool = false,
        safeModeReason: SafeModeReason? = nil
    ) {
        let utf8Count = preedit.utf8.count
        let utf16Count = preedit.utf16.count
        func clamp(_ value: Int, _ upper: Int) -> Int { min(max(value, 0), upper) }
        func clamp(_ range: Range<Int>, _ upper: Int) -> Range<Int> {
            clamp(range.lowerBound, upper)..<clamp(range.upperBound, upper)
        }
        self.preedit = preedit
        self.caretUTF8Offset = clamp(caretUTF8Offset, utf8Count)
        self.caretUTF16Offset = clamp(caretUTF16Offset, utf16Count)
        self.selectionUTF8Range = clamp(selectionUTF8Range, utf8Count)
        self.selectionUTF16Range = clamp(selectionUTF16Range, utf16Count)
        self.commitTextPreview = commitTextPreview
        self.candidates = candidates
        if candidates.isEmpty {
            self.highlightedIndex = nil
        } else {
            self.highlightedIndex = clamp(highlightedIndex ?? 0, candidates.count - 1)
        }
        self.pageIndex = max(pageIndex, 0)
        self.pageSize = max(pageSize, 0)
        self.isLastPage = isLastPage
        self.isComposing = isComposing
        self.isASCIIMode = isASCIIMode
        self.schemaID = schemaID
        self.generationID = generationID
        self.isSafeMode = isSafeMode || safeModeReason != nil
        self.safeModeReason = safeModeReason
    }

    private enum CodingKeys: String, CodingKey {
        case preedit, caretUTF8Offset, caretUTF16Offset, selectionUTF8Range, selectionUTF16Range
        case commitTextPreview, candidates, highlightedIndex, pageIndex, pageSize, isLastPage
        case isComposing, isASCIIMode, schemaID, generationID, isSafeMode, safeModeReason
    }

    /// Decodes through the normalizing initializer, so a decoded state holds the same
    /// invariants as a constructed one, whatever the JSON says.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            preedit: try container.decode(String.self, forKey: .preedit),
            caretUTF8Offset: try container.decode(Int.self, forKey: .caretUTF8Offset),
            caretUTF16Offset: try container.decode(Int.self, forKey: .caretUTF16Offset),
            selectionUTF8Range: try container.decode(Range<Int>.self, forKey: .selectionUTF8Range),
            selectionUTF16Range: try container.decode(Range<Int>.self, forKey: .selectionUTF16Range),
            commitTextPreview: try container.decodeIfPresent(String.self, forKey: .commitTextPreview),
            candidates: try container.decode([CandidateItem].self, forKey: .candidates),
            highlightedIndex: try container.decodeIfPresent(Int.self, forKey: .highlightedIndex),
            pageIndex: try container.decode(Int.self, forKey: .pageIndex),
            pageSize: try container.decode(Int.self, forKey: .pageSize),
            isLastPage: try container.decode(Bool.self, forKey: .isLastPage),
            isComposing: try container.decode(Bool.self, forKey: .isComposing),
            isASCIIMode: try container.decode(Bool.self, forKey: .isASCIIMode),
            schemaID: try container.decodeIfPresent(String.self, forKey: .schemaID),
            generationID: try container.decode(UInt64.self, forKey: .generationID),
            isSafeMode: try container.decode(Bool.self, forKey: .isSafeMode),
            safeModeReason: try container.decodeIfPresent(SafeModeReason.self, forKey: .safeModeReason)
        )
    }

    /// No composition, no candidates.
    public static func empty(
        generationID: UInt64 = 0,
        isASCIIMode: Bool = false,
        schemaID: String? = nil,
        safeModeReason: SafeModeReason? = nil
    ) -> CompositionState {
        CompositionState(
            isASCIIMode: isASCIIMode, schemaID: schemaID, generationID: generationID,
            isSafeMode: safeModeReason != nil, safeModeReason: safeModeReason
        )
    }
}

/// The outcome of handing one key (or a selection/commit request) to the engine.
public struct KeyHandlingResult: Sendable, Hashable, Codable {
    /// False means the shell must pass the key through to the client unchanged.
    public let handled: Bool
    /// Text to insert into the client, if the engine committed any.
    public let committedText: String?
    public let state: CompositionState
    /// Set when the key was passed through because the engine is degraded.
    public let degradation: KeyDegradation?

    public init(handled: Bool, committedText: String? = nil, state: CompositionState, degradation: KeyDegradation? = nil) {
        self.handled = handled
        self.committedText = committedText
        self.state = state
        self.degradation = degradation
    }
}

/// The key-handling boundary between the IMKit shell and an input engine. Calls are
/// synchronous and main-actor bound: a hot-path key must be answered before the next one.
/// Implementations never swallow a key they cannot process: they return `handled: false`.
@MainActor
public protocol TypingEngine: AnyObject {
    var currentState: CompositionState { get }

    func processKey(_ event: KeyEvent) -> KeyHandlingResult
    /// Selects (and usually commits) candidate `index` of the current page (0-based).
    /// An index off the page returns `handled: false` and changes nothing.
    func selectCandidate(at index: Int) -> KeyHandlingResult
    /// Highlights candidate `index` of the current page without committing.
    @discardableResult func highlightCandidate(at index: Int) -> CompositionState
    @discardableResult func changePage(backward: Bool) -> CompositionState
    @discardableResult func setASCIIMode(_ enabled: Bool) -> CompositionState
    /// Commits the current composition as the engine would on Return.
    func commitComposition() -> KeyHandlingResult
    @discardableResult func clearComposition() -> CompositionState
    /// Drops the composition and starts a fresh session (e.g. on client switch).
    func resetSession()
}
