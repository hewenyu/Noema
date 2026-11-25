import CoreGraphics

/// The text client of one input session, as the shell sees it. `NoemaIME` adapts IMKit's
/// `IMKTextInput` sender to it; tests use a recording client. Offsets are UTF-16 code
/// units into `preedit`, what `NSRange`-based clients expect.
@MainActor
public protocol TextInputClient: AnyObject {
    /// The client application's bundle identifier, if known.
    var clientBundleIdentifier: String? { get }
    /// An identifier unique to this client document or window, if the client provides one.
    /// Two windows of one application have different identifiers.
    var uniqueClientIdentifier: String? { get }
    /// The window level of the client's window (`CGWindowLevel`), if known.
    var windowLevel: Int? { get }
    /// Inserts committed text, replacing any marked text.
    func insertText(_ text: String)
    /// Shows `preedit` as marked text with the caret at `caretUTF16Offset`;
    /// `selectionUTF16Range` is the segment being converted.
    func setMarkedText(preedit: String, caretUTF16Offset: Int, selectionUTF16Range: Range<Int>)
    /// Removes the marked text without inserting anything.
    func clearMarkedText()
    /// The screen rectangle (Cocoa global coordinates, bottom-left origin) of the line at
    /// `offset`, or nil when the client reports none. Callers validate the value: clients
    /// return `.zero`, stale, and off-screen rectangles.
    func caretScreenRect(atUTF16Offset offset: Int) -> CGRect?
}

extension TextInputClient {
    public var uniqueClientIdentifier: String? { nil }
    public var windowLevel: Int? { nil }
    public func caretScreenRect(atUTF16Offset offset: Int) -> CGRect? { nil }
}
