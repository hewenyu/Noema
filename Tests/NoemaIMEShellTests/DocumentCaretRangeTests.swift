import AppKit
import NoemaIMEShell
import Testing

/// `DocumentCaretRange` turns the panel's inline-relative caret offset into the
/// document-relative range `firstRect(forCharacterRange:actualRange:)` expects.
@MainActor
@Suite struct DocumentCaretRangeTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test func inlineOffsetIsRebasedOnTheMarkedRange() {
        let marked = NSRange(location: 34, length: 2)
        let selected = NSRange(location: 36, length: 0)
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 0, markedRange: marked, selectedRange: selected) == NSRange(location: 34, length: 0))
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 1, markedRange: marked, selectedRange: selected) == NSRange(location: 35, length: 0))
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 99, markedRange: marked, selectedRange: selected) == NSRange(location: 36, length: 0), "clamped to the marked text")
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: -3, markedRange: marked, selectedRange: selected) == NSRange(location: 34, length: 0))
    }

    /// Inline preedit disabled: no marked text, so the caret is the selection.
    @Test func withoutMarkedTextTheSelectionLocationIsUsed() {
        let selected = NSRange(location: 34, length: 0)
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 0, markedRange: none, selectedRange: selected) == NSRange(location: 34, length: 0))
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 5, markedRange: none, selectedRange: selected) == NSRange(location: 34, length: 0))
    }

    @Test func noDocumentLocationIsNilNeverIndexZero() {
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 0, markedRange: none, selectedRange: none) == nil)
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 3, markedRange: none, selectedRange: none) == nil)
    }

    @Test func overflowingLocationIsNil() {
        let marked = NSRange(location: Int.max, length: 10)
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 5, markedRange: marked, selectedRange: none) == nil)
        // NSNotFound is Int.max: a location that lands on it is not a document index either.
        let nearEnd = NSRange(location: Int.max - 2, length: 10)
        #expect(DocumentCaretRange.fallbackRange(inlineOffset: 2, markedRange: nearEnd, selectedRange: none) == nil)
    }

    /// A real multi-line `NSTextView` (an `NSTextInputClient`): the fallback range resolves
    /// to the line holding document offset 34, not to line 1 as `{0, 0}` (the inline
    /// offset passed straight through) would.
    @Test func realTextViewResolvesTheMarkedTextLine() throws {
        let window = NSWindow(
            contentRect: CGRect(x: 200, y: 200, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let textView = NSTextView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        window.contentView = textView
        // 17 UTF-16 units per line: offset 34 starts the third line.
        textView.string = "line one is here\nline two is here\nline three\n"
        textView.setSelectedRange(NSRange(location: 34, length: 0))
        textView.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(textView.markedRange() == NSRange(location: 34, length: 2))

        let range = try #require(DocumentCaretRange.fallbackRange(
            inlineOffset: 0, markedRange: textView.markedRange(), selectedRange: textView.selectedRange()))
        #expect(range == NSRange(location: 34, length: 0))
        let resolved = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let firstLine = textView.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
        let expected = textView.firstRect(forCharacterRange: NSRange(location: 34, length: 0), actualRange: nil)
        #expect(resolved != .zero && resolved == expected)
        // Screen coordinates are bottom-up: the third line sits two lines below the first.
        #expect(resolved.maxY < firstLine.minY, "resolved \(resolved), first line \(firstLine)")
    }
}
