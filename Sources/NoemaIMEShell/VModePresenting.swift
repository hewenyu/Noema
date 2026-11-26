import Foundation
import NoemaCore

/// One cell of the v-mode menu grid.
public struct VModeMenuCell: Sendable, Hashable {
    /// The shortcut digit (`1`…`9`).
    public let number: Int
    public let title: String
    /// The cell asks the companion agent instead of running an offline tool.
    public let isAgentAction: Bool
    /// False for an agent action that ships in a later milestone.
    public let isAvailable: Bool

    public init(number: Int, title: String, isAgentAction: Bool, isAvailable: Bool) {
        self.number = number
        self.title = title
        self.isAgentAction = isAgentAction
        self.isAvailable = isAvailable
    }

    /// The nine cells of `VMenuItem`, in order.
    public static let all: [VModeMenuCell] = VMenuItem.allCases.map { item in
        VModeMenuCell(
            number: item.rawValue, title: item.title, isAgentAction: item.quickAction != nil,
            isAvailable: item.quickAction?.isImplemented ?? true)
    }
}

/// One row of a v-mode sub-mode list.
public struct VModeSubRow: Sendable, Hashable {
    /// The selection label (`1`…`9`, or a word such as 结果).
    public let label: String
    public let text: String

    public init(label: String, text: String) {
        self.label = label
        self.text = text
    }
}

/// What the v-mode panel shows. Pure values; `generationID` strictly increases with every
/// state the shell presents, and a click carries it back so a click on a stale panel is
/// ignored (`InputSessionCoordinator.selectVModeItem(at:expectedGenerationID:)`).
public enum VModePanelState: Sendable, Hashable {
    case menu(items: [VModeMenuCell], highlightedIndex: Int, preedit: String, generationID: UInt64)
    case subMode(
        title: String, preedit: String, queryHint: String?, rows: [VModeSubRow], highlightedIndex: Int, pageInfo: String?,
        generationID: UInt64)

    public var generationID: UInt64 {
        switch self {
        case .menu(_, _, _, let generation), .subMode(_, _, _, _, _, _, let generation): generation
        }
    }

    public var preedit: String {
        switch self {
        case .menu(_, _, let preedit, _), .subMode(_, let preedit, _, _, _, _, _): preedit
        }
    }
}

/// Shows the v-mode menu and its sub-modes. `NoemaUI.CandidatePanelController` implements it
/// on the same panel as `CandidatePresenting`, so the two never overlap.
@MainActor
public protocol VModePresenting: AnyObject {
    /// Shows or refreshes `state` next to `client`'s caret.
    func updateVMode(_ state: VModePanelState, client: any TextInputClient, options: CandidatePresentationOptions)
    /// Hides the v-mode panel. Idempotent.
    func hideVMode()
}

/// Presents nothing: for hosts without a window server and for tests of other parts.
@MainActor
public final class NoOpVModePresenter: VModePresenting {
    public init() {}
    public func updateVMode(_ state: VModePanelState, client: any TextInputClient, options: CandidatePresentationOptions) {}
    public func hideVMode() {}
}
