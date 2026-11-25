/// The text client of one input session, as the shell sees it. `NoemaIME` adapts IMKit's
/// `IMKTextInput` sender to it; tests use a recording client. Offsets are UTF-16 code
/// units into `preedit`, what `NSRange`-based clients expect.
@MainActor
public protocol TextInputClient: AnyObject {
    /// The client application's bundle identifier, if known.
    var clientBundleIdentifier: String? { get }
    /// Inserts committed text, replacing any marked text.
    func insertText(_ text: String)
    /// Shows `preedit` as marked text with the caret at `caretUTF16Offset`;
    /// `selectionUTF16Range` is the segment being converted.
    func setMarkedText(preedit: String, caretUTF16Offset: Int, selectionUTF16Range: Range<Int>)
    /// Removes the marked text without inserting anything.
    func clearMarkedText()
}
