import AppKit
import Carbon.HIToolbox
import InputMethodKit
import NoemaCore
import NoemaIMEShell

/// The IMKit controller named by `InputMethodServerControllerClass`. IMKit creates one per
/// client session. It only adapts IMKit calls onto the shared `InputSessionCoordinator`;
/// every decision lives there.
///
/// `IMKInputController` carries no actor annotation, so this class is nonisolated. IMKit
/// calls it on the main thread; any other thread is logged and answered with a pass-through
/// fallback instead of trapping, so a key is never swallowed.
@objc(NoemaInputController)
final class NoemaInputController: IMKInputController {
    private let sessionToken = UUID()

    // Key-down only: mouse and flags-changed events stay with IMKit, which then keeps
    // committing the composition on a click outside the marked text.
    override func recognizedEvents(_ sender: Any!) -> Int {
        Int(NSEvent.EventTypeMask.keyDown.rawValue)
    }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }
        let key = MainThreadBound(event)
        return withClient(sender, fallback: false) { coordinator, token, client in
            coordinator.handleNSEvent(key.value, token: token, client: client)
        }
    }

    override func activateServer(_ sender: Any!) {
        super.activateServer(sender)
        withClient(sender, fallback: ()) { coordinator, token, client in
            coordinator.activate(token: token, client: client)
        }
    }

    // No client lookup: a detached client must not skip releasing the composition.
    override func deactivateServer(_ sender: Any!) {
        let token = sessionToken
        onMainActor(fallback: ()) { EngineHost.shared.coordinator.deactivate(token: token) }
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        withClient(sender, fallback: ()) { coordinator, token, client in
            coordinator.commitComposition(token: token, client: client)
        }
    }

    override func hidePalettes() {
        let token = sessionToken
        onMainActor(fallback: ()) { EngineHost.shared.coordinator.hidePalettes(token: token) }
        super.hidePalettes()
    }

    override func inputControllerWillClose() {
        let token = sessionToken
        onMainActor(fallback: ()) { EngineHost.shared.coordinator.controllerWillClose(token: token) }
        super.inputControllerWillClose()
    }

    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        super.setValue(value, forTag: tag, client: sender)
        guard tag == kTextServiceInputModePropertyTag, let modeID = value as? String else { return }
        withClient(sender, fallback: ()) { coordinator, token, client in
            coordinator.setInputMode(modeID, token: token, client: client)
        }
    }

    // MARK: - Main-thread hop

    /// Runs `body` on the main actor with this session's token and client adapter; returns
    /// `fallback` off the main thread or without an `IMKTextInput` client.
    @discardableResult
    private func withClient<T: Sendable>(
        _ sender: Any!,
        fallback: T,
        _ body: @MainActor (InputSessionCoordinator, UUID, any TextInputClient) -> T
    ) -> T {
        let call = MainThreadBound((self, sender as Any?))
        return onMainActor(fallback: fallback) {
            let (controller, sender) = call.value
            let input = (sender as? any IMKTextInput) ?? (controller.client() as (any IMKTextInput)?)
            guard let input else { return fallback }
            let client = IMKTextInputClientAdapter(client: input, controller: controller)
            return body(EngineHost.shared.coordinator, controller.sessionToken, client)
        }
    }

    @discardableResult
    private func onMainActor<T: Sendable>(fallback: T, _ body: @MainActor () -> T) -> T {
        guard Thread.isMainThread else {
            NoemaLog.ime("input").fault("IMKit called NoemaInputController off the main thread; passing through")
            return fallback
        }
        return MainActor.assumeIsolated(body)
    }
}

/// Carries IMKit's non-Sendable arguments into `MainActor.assumeIsolated`. Sound only
/// because the value is used on the thread it came from: `onMainActor` runs the body
/// synchronously and only when already on the main thread.
private struct MainThreadBound<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// `TextInputClient` over IMKit's client proxy. Marked text is styled with the
/// controller's IMKit marks: converted prefix, selected segment, raw suffix.
@MainActor
private final class IMKTextInputClientAdapter: TextInputClient {
    private let client: any IMKTextInput
    private weak var controller: NoemaInputController?
    /// Replace the client's current selection or marked text.
    private let replacementRange = NSRange(location: NSNotFound, length: NSNotFound)

    init(client: any IMKTextInput, controller: NoemaInputController) {
        self.client = client
        self.controller = controller
    }

    var clientBundleIdentifier: String? { client.bundleIdentifier() }

    var uniqueClientIdentifier: String? { client.uniqueClientIdentifierString() }

    var windowLevel: Int? { Int(client.windowLevel()) }

    /// `attributes(forCharacterIndex:lineHeightRectangle:)` first, with the inline-relative
    /// index IMKit expects; then `firstRect(forCharacterRange:actualRange:)`, which takes a
    /// document index, so the offset is rebased on the marked range (or the selection) by
    /// `DocumentCaretRange`. `.zero` from both, or no document location, is nil.
    /// `CaretPositionResolver` validates whatever comes back.
    func caretScreenRect(atUTF16Offset offset: Int) -> CGRect? {
        let index = max(offset, 0)
        var rect = NSRect.zero
        _ = client.attributes(forCharacterIndex: index, lineHeightRectangle: &rect)
        if rect != .zero { return rect }
        guard let range = DocumentCaretRange.fallbackRange(
            inlineOffset: index, markedRange: client.markedRange(), selectedRange: client.selectedRange())
        else { return nil }
        let fallback = client.firstRect(forCharacterRange: range, actualRange: nil)
        return fallback == .zero ? nil : fallback
    }

    func insertText(_ text: String) {
        client.insertText(text, replacementRange: replacementRange)
    }

    func setMarkedText(preedit: String, caretUTF16Offset: Int, selectionUTF16Range: Range<Int>) {
        let marked = NSMutableAttributedString(string: preedit)
        let length = (preedit as NSString).length
        let selection = selectionUTF16Range.clamped(to: 0..<length)
        let active = selection.isEmpty ? 0..<length : selection
        mark(marked, 0..<active.lowerBound, style: kTSMHiliteConvertedText)
        mark(marked, active, style: kTSMHiliteSelectedRawText)
        mark(marked, active.upperBound..<length, style: kTSMHiliteRawText)
        let caret = min(max(caretUTF16Offset, 0), length)
        client.setMarkedText(
            marked, selectionRange: NSRange(location: caret, length: 0), replacementRange: replacementRange)
    }

    func clearMarkedText() {
        client.setMarkedText(
            "", selectionRange: NSRange(location: 0, length: 0), replacementRange: replacementRange)
    }

    private func mark(_ text: NSMutableAttributedString, _ range: Range<Int>, style: Int) {
        guard !range.isEmpty, let controller else { return }
        let nsRange = NSRange(location: range.lowerBound, length: range.count)
        guard let attributes = controller.mark(forStyle: style, at: nsRange) else { return }
        var keyed: [NSAttributedString.Key: Any] = [:]
        for (key, value) in attributes {
            if let name = key as? String { keyed[NSAttributedString.Key(name)] = value }
            else if let name = key as? NSAttributedString.Key { keyed[name] = value }
        }
        text.addAttributes(keyed, range: nsRange)
    }
}
