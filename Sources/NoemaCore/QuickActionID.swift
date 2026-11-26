/// A quick action the input method asks the companion agent to run (`v2`, `v4`, `v6`, `v7`,
/// `v9`). Closed and append-only: the raw values travel in `IMEToAgent.quickActionRequested`.
/// The input method never runs one itself; it only names it.
public enum QuickActionID: String, Codable, Sendable, Hashable, CaseIterable {
    case clipboard
    case voiceInput
    case translate
    case rewrite
    case settings

    /// The name shown in the v-mode menu and in the agent's toast.
    public var title: String {
        switch self {
        case .clipboard: "剪贴板"
        case .voiceInput: "语音输入"
        case .translate: "翻译"
        case .rewrite: "改写"
        case .settings: "设置"
        }
    }

    /// Whether the agent can run the action today (`v2` opens the clipboard history panel,
    /// `v9` Settings); the others answer with a non-activating "coming soon" toast.
    public var isImplemented: Bool { self == .settings || self == .clipboard }

    /// The milestone that ships an action not yet implemented; nil once implemented.
    public var plannedMilestone: String? {
        switch self {
        case .voiceInput: "M3"
        case .translate, .rewrite: "M4"
        case .clipboard, .settings: nil
        }
    }
}
