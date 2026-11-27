import AppKit
import NoemaCore

/// A HUD panel that can never become key or main, so showing it never moves focus out of
/// the user's editor.
final class NonActivatingToastPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The agent's answer to a v-mode quick action it cannot run yet (M3/M4): a small
/// non-activating HUD near the top of the screen with the pointer, dismissed after
/// `displayDuration`. One reused panel; a newer toast replaces the text and restarts the
/// timer. Never activates the agent, never takes key focus, ignores the mouse.
@MainActor
public final class QuickActionToastController {
    public static let displayDuration: Duration = .seconds(2)

    public private(set) var isVisible = false
    /// The text of the toast on screen (or last shown).
    public private(set) var message: String?
    /// `false` keeps the panel off screen (headless tests); everything else still runs.
    public var shouldOrderFront = true

    private let panel: NonActivatingToastPanel
    private let label: NSTextField
    private var dismissal: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init() {
        panel = NonActivatingToastPanel(
            contentRect: CGRect(x: 0, y: 0, width: 280, height: 44),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = true

        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true
        label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effect.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: effect.trailingAnchor, constant: -16),
            label.centerYAnchor.constraint(equalTo: effect.centerYAnchor),
        ])
        panel.contentView = effect
    }

    /// The text for `action`: `语音输入将在 M3 推出` for an unimplemented action.
    public static func message(for action: QuickActionID) -> String {
        if let milestone = action.plannedMilestone { return "\(action.title)将在 \(milestone) 推出" }
        return action.title
    }

    /// Shows the "coming soon" toast for `action`.
    public func show(_ action: QuickActionID) {
        show(message: Self.message(for: action))
    }

    public func show(message text: String) {
        generation &+= 1
        let current = generation
        message = text
        label.stringValue = text
        let width = min(max(ceil(label.intrinsicContentSize.width) + 32, 180), 420)
        let size = CGSize(width: width, height: 44)
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrame(CGRect(x: visible.midX - size.width / 2, y: visible.maxY - size.height - 48, width: size.width, height: size.height), display: false)
        } else {
            panel.setContentSize(size)
        }
        if shouldOrderFront { panel.orderFrontRegardless() }
        isVisible = true
        dismissal?.cancel()
        dismissal = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.displayDuration)
            guard !Task.isCancelled, let self, self.generation == current else { return }
            self.dismiss()
        }
    }

    public func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        if isVisible { panel.orderOut(nil) }
        isVisible = false
    }

    /// The panel, for tests: it must never become key or main.
    var panelForTesting: NSPanel { panel }
}
