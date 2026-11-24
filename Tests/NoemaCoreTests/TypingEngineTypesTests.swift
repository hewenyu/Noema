import Foundation
import NoemaCore
import Testing

@Suite struct UTF8OffsetConverterTests {
    typealias Offset = UTF8OffsetConverter.Offset

    @Test func asciiOffsetsAreIdentical() {
        for byte in 0...5 {
            #expect(UTF8OffsetConverter.offset(in: "nihao", fromUTF8ByteOffset: byte) == Offset(utf8: byte, utf16: byte))
        }
    }

    @Test func clampsNegativeAndOverlongOffsets() {
        #expect(UTF8OffsetConverter.offset(in: "nihao", fromUTF8ByteOffset: -1) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: "nihao", fromUTF8ByteOffset: .min) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: "nihao", fromUTF8ByteOffset: 99) == Offset(utf8: 5, utf16: 5))
        #expect(UTF8OffsetConverter.offset(in: "nihao", fromUTF8ByteOffset: .max) == Offset(utf8: 5, utf16: 5))
        #expect(UTF8OffsetConverter.offset(in: "", fromUTF8ByteOffset: 0) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: "", fromUTF8ByteOffset: 3) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: "", fromUTF8ByteOffset: -3) == Offset(utf8: 0, utf16: 0))
    }

    /// 你 and 好 are 3 UTF-8 bytes and 1 UTF-16 unit each.
    @Test func hanCharactersSnapLeftInsideAScalar() {
        let text = "你好hao"
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 0) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 1) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 2) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 3) == Offset(utf8: 3, utf16: 1))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 5) == Offset(utf8: 3, utf16: 1))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 6) == Offset(utf8: 6, utf16: 2))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 7) == Offset(utf8: 7, utf16: 3))
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 9) == Offset(utf8: 9, utf16: 5))
        #expect(UTF8OffsetConverter.utf16Offset(in: text, fromUTF8ByteOffset: 4) == 1)
    }

    /// 😀 is 4 UTF-8 bytes and a UTF-16 surrogate pair.
    @Test func emojiSnapsLeftAndCountsSurrogatePair() {
        let text = "a😀"
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 1) == Offset(utf8: 1, utf16: 1))
        for inside in 2...4 {
            #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: inside) == Offset(utf8: 1, utf16: 1))
        }
        #expect(UTF8OffsetConverter.offset(in: text, fromUTF8ByteOffset: 5) == Offset(utf8: 5, utf16: 3))
        #expect(UTF8OffsetConverter.offset(in: "😀", fromUTF8ByteOffset: 3) == Offset(utf8: 0, utf16: 0))
        #expect(UTF8OffsetConverter.offset(in: "😀", fromUTF8ByteOffset: 4) == Offset(utf8: 4, utf16: 2))
    }

    @Test func rangesAreOrderedClampedAndAligned() {
        let text = "你好hao"
        let ordered = UTF8OffsetConverter.ranges(in: text, utf8Start: 3, utf8End: 9)
        #expect(ordered.utf8 == 3..<9 && ordered.utf16 == 1..<5)
        let swapped = UTF8OffsetConverter.ranges(in: text, utf8Start: 9, utf8End: 3)
        #expect(swapped.utf8 == 3..<9 && swapped.utf16 == 1..<5)
        let wild = UTF8OffsetConverter.ranges(in: text, utf8Start: -4, utf8End: 400)
        #expect(wild.utf8 == 0..<9 && wild.utf16 == 0..<5)
        let inside = UTF8OffsetConverter.ranges(in: text, utf8Start: 1, utf8End: 4)
        #expect(inside.utf8 == 0..<3 && inside.utf16 == 0..<1)
        let empty = UTF8OffsetConverter.ranges(in: "", utf8Start: 2, utf8End: 1)
        #expect(empty.utf8 == 0..<0 && empty.utf16 == 0..<0)
    }
}

@Suite struct CompositionStateTests {
    @Test func emptyStateHasNoHighlight() {
        let state = CompositionState.empty(generationID: 7, isASCIIMode: true, schemaID: "noema_pinyin")
        #expect(state.highlightedIndex == nil)
        #expect(state.candidates.isEmpty && !state.isComposing && state.isASCIIMode)
        #expect(state.generationID == 7 && !state.isSafeMode && state.safeModeReason == nil)
    }

    @Test func highlightIsNilForEmptyMenuAndClampedOtherwise() {
        let items = [CandidateItem(text: "你"), CandidateItem(text: "泥")]
        #expect(CompositionState(candidates: [], highlightedIndex: 3).highlightedIndex == nil)
        #expect(CompositionState(candidates: items, highlightedIndex: nil).highlightedIndex == 0)
        #expect(CompositionState(candidates: items, highlightedIndex: 5).highlightedIndex == 1)
        #expect(CompositionState(candidates: items, highlightedIndex: -2).highlightedIndex == 0)
        #expect(CompositionState(candidates: items, highlightedIndex: 1).highlightedIndex == 1)
    }

    @Test func offsetsAndPagesAreClampedIntoThePreedit() {
        let state = CompositionState(
            preedit: "你hao", caretUTF8Offset: 40, caretUTF16Offset: -1,
            selectionUTF8Range: 2..<90, selectionUTF16Range: 0..<9, pageIndex: -1, pageSize: -5
        )
        #expect(state.caretUTF8Offset == 6 && state.caretUTF16Offset == 0)
        #expect(state.selectionUTF8Range == 2..<6 && state.selectionUTF16Range == 0..<4)
        #expect(state.pageIndex == 0 && state.pageSize == 0)
    }

    @Test func safeModeReasonImpliesSafeMode() {
        for reason in SafeModeReason.allCases {
            let state = CompositionState.empty(safeModeReason: reason)
            #expect(state.isSafeMode && state.safeModeReason == reason)
        }
    }

    @Test func codableRoundTrip() throws {
        let state = CompositionState(
            preedit: "ni hao", caretUTF8Offset: 6, caretUTF16Offset: 6,
            selectionUTF8Range: 0..<6, selectionUTF16Range: 0..<6, commitTextPreview: "你好",
            candidates: [CandidateItem(text: "你好", comment: nil, label: "1"), CandidateItem(text: "拟好", comment: "~", label: "2")],
            highlightedIndex: 1, pageIndex: 2, pageSize: 5, isLastPage: false, isComposing: true,
            isASCIIMode: false, schemaID: "noema_pinyin", generationID: .max, isSafeMode: false, safeModeReason: nil
        )
        let decoded = try JSONDecoder().decode(CompositionState.self, from: JSONEncoder().encode(state))
        #expect(decoded == state)
        let result = KeyHandlingResult(handled: false, committedText: "，", state: .empty(safeModeReason: .bootCrashLoop), degradation: .safeMode)
        #expect(try JSONDecoder().decode(KeyHandlingResult.self, from: JSONEncoder().encode(result)) == result)
        let reasons = try JSONEncoder().encode(SafeModeReason.allCases)
        #expect(String(decoding: reasons, as: UTF8.self)
            == #"["bootCrashLoop","userDataDirUnwritable","bootGuardCorrupted","userDataDirLocked","engineInitFailed"]"#)
    }

    @Test func keyEventKeepsBackwardCompatibleShape() throws {
        let legacy = #"{"keyCode":0,"characters":"a","modifiers":0,"isKeyDown":true}"#
        let decoded = try JSONDecoder().decode(KeyEvent.self, from: Data(legacy.utf8))
        #expect(decoded == KeyEvent(keyCode: 0, characters: "a"))
        #expect(decoded.charactersIgnoringModifiers == nil)
        let control = KeyEvent(keyCode: 0, characters: "\u{1}", modifiers: .control, charactersIgnoringModifiers: "a")
        #expect(try JSONDecoder().decode(KeyEvent.self, from: JSONEncoder().encode(control)) == control)
    }
}
