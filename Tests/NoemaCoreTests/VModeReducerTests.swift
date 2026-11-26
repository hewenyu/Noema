import Foundation
import NoemaCore
import NoemaText
import Testing

/// `VModeReducer`: every edge of the v-mode state machine, driven with the real offline
/// tools of `NoemaText` (calculator, symbols, snippets, a fixed date).
@Suite struct VModeReducerTests {
    static let fixedDate = Date(timeIntervalSince1970: 1_795_656_600)  // 2026-11-26 09:30:00 +08:00
    static let environment = VModeEnvironment(
        pageSize: 5,
        calculate: { CalculatorEvaluator.evaluateFormatted($0) },
        snippets: { SnippetStore.matching(SnippetStore.defaults, query: $0) },
        symbolCategories: SymbolPalette.builtIn.categoryNames,
        symbols: { SymbolPalette.builtIn.symbols(categoryIndex: $0, query: $1) },
        dateTimeItems: { DateTimeTemplates(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!).candidates(for: fixedDate) })
    let reducer = VModeReducer(environment: Self.environment)
    let plain = VModeContext()

    static func text(_ character: Character, _ modifiers: KeyModifiers = []) -> VModeInput {
        .key(KeyEvent(keyCode: 0x00, characters: String(character), modifiers: modifiers))
    }

    static func key(_ code: UInt16, _ characters: String = "", _ modifiers: KeyModifiers = []) -> VModeInput {
        .key(KeyEvent(keyCode: code, characters: characters, modifiers: modifiers))
    }

    static let returnKey = key(VirtualKeyCode.return, "\r")
    static let space = key(VirtualKeyCode.space, " ")
    static let escape = key(VirtualKeyCode.escape, "\u{1B}")
    static let backspace = key(VirtualKeyCode.delete, "\u{7F}")

    /// Feeds `inputs` from `state`; returns the final state and every effect.
    func run(_ inputs: [VModeInput], from state: VModeState = .idle, context: VModeContext = VModeContext()) -> (VModeState, [VModeEffect]) {
        var state = state
        var effects: [VModeEffect] = []
        for input in inputs {
            let (next, effect) = reducer.reduce(state, input, context: context)
            state = next
            effects.append(effect)
        }
        return (state, effects)
    }

    func type(_ text: String, from state: VModeState = .idle) -> (VModeState, [VModeEffect]) {
        run(text.map { Self.text($0) }, from: state)
    }

    // MARK: - Entering and leaving

    @Test func plainVOpensTheMenu() {
        let (state, effect) = reducer.reduce(.idle, Self.text("v"), context: plain)
        #expect(state == .vMenu(highlightedIndex: 0) && effect == .consumeOnly)
        #expect(state.preedit == "v" && state.isActive)
    }

    @Test(arguments: [KeyModifiers.shift, .capsLock, .command, .control, .option])
    func modifiedVIsNotTheMenu(_ modifiers: KeyModifiers) {
        let character: Character = modifiers.contains(.shift) || modifiers.contains(.capsLock) ? "V" : "v"
        let (state, effect) = reducer.reduce(.idle, Self.text(character, modifiers), context: plain)
        #expect(state == .idle && effect == .passToRime)
        // Even a lowercase `v` with Shift or Caps Lock is not the menu.
        #expect(reducer.reduce(.idle, Self.text("v", modifiers), context: plain).0 == .idle)
    }

    @Test func otherLettersGoToRime() {
        #expect(reducer.reduce(.idle, Self.text("n"), context: plain) == (.idle, .passToRime))
    }

    /// `lv` and `nv`: once Rime composes, `v` is Rime's (绿, 女).
    @Test func vDuringACompositionGoesToRime() {
        let composing = VModeContext(isEngineComposing: true)
        #expect(reducer.reduce(.idle, Self.text("v"), context: composing) == (.composing, .passToRime))
        #expect(reducer.reduce(.composing, Self.text("v"), context: composing) == (.composing, .passToRime))
        #expect(reducer.reduce(.composing, Self.text("v"), context: plain) == (.vMenu(highlightedIndex: 0), .consumeOnly))
    }

    @Test(arguments: [
        VModeContext(isSecureInput: true), VModeContext(isSafeMode: true), VModeContext(isASCIIMode: true),
    ])
    func secureInputSafeModeAndASCIIEndVModeAndPassThrough(_ context: VModeContext) {
        let states: [VModeState] = [
            .idle, .composing, .vMenu(highlightedIndex: 3),
            .vSub(.calculator(expression: "1+2", pendingLeadingOne: false, highlightedIndex: 0)),
            .vSub(.literal(buffer: "vim")),
        ]
        for state in states {
            for input in [Self.text("v"), Self.returnKey, .click(index: 0)] {
                #expect(reducer.reduce(state, input, context: context) == (.idle, .passThroughToClient))
            }
        }
    }

    @Test func escapeAndBackspaceCloseTheMenuWithoutTyping() {
        #expect(run([Self.text("v"), Self.escape]) == (.idle, [.consumeOnly, .consumeOnly]))
        #expect(run([Self.text("v"), Self.backspace]) == (.idle, [.consumeOnly, .consumeOnly]))
    }

    /// `⌘V` in the menu or a sub-mode: v-mode ends and the shortcut reaches the client.
    @Test func shortcutChordsEndVModeAndPassThrough() {
        let command = Self.text("v", .command)
        #expect(reducer.reduce(.vMenu(highlightedIndex: 0), command, context: plain) == (.idle, .passThroughToClient))
        let calc = VModeState.vSub(.calculator(expression: "1", pendingLeadingOne: false, highlightedIndex: 0))
        #expect(reducer.reduce(calc, Self.text("c", .control), context: plain) == (.idle, .passThroughToClient))
        #expect(reducer.reduce(.vSub(.literal(buffer: "vi")), Self.text("a", .option), context: plain) == (.idle, .passThroughToClient))
    }

    @Test func keyUpIsConsumedWithoutAChange() {
        let up = VModeInput.key(KeyEvent(keyCode: 0, characters: "1", isKeyDown: false))
        #expect(reducer.reduce(.vMenu(highlightedIndex: 2), up, context: plain) == (.vMenu(highlightedIndex: 2), .consumeOnly))
    }

    // MARK: - Menu

    @Test func vvCommitsALiteralV() {
        let (state, effects) = type("vv")
        #expect(state == .idle && effects.last == .commitText("v"))
    }

    @Test func vimThenReturnCommitsVim() {
        var (state, _) = type("vim")
        #expect(state == .vSub(.literal(buffer: "vim")) && state.preedit == "vim")
        let (final, effects) = run([Self.returnKey], from: state)
        #expect(final == .idle && effects == [.commitText("vim")])
        // Backspace back to `v` returns to the menu.
        (state, _) = run([Self.backspace, Self.backspace], from: .vSub(.literal(buffer: "vim")))
        #expect(state == .vMenu(highlightedIndex: 0))
    }

    @Test func literalBufferIsCapped() {
        let long = String(repeating: "a", count: VModeReducer.maxLiteralLength + 10)
        let (state, _) = type("v" + long)
        guard case .vSub(.literal(let buffer)) = state else { Issue.record("\(state)"); return }
        #expect(buffer.count == VModeReducer.maxLiteralLength)
    }

    @Test(arguments: [(2, QuickActionID.clipboard), (4, .voiceInput), (6, .translate), (7, .rewrite), (9, .settings)])
    func agentShortcutsDispatch(_ digit: Int, _ action: QuickActionID) {
        let (state, effects) = type("v\(digit)")
        #expect(state == .idle && effects == [.consumeOnly, .dispatchAgent(action)])
        #expect(reducer.reduce(.vMenu(highlightedIndex: 0), .click(index: digit - 1), context: plain) == (.idle, .dispatchAgent(action)))
    }

    @Test func offlineShortcutsOpenTheirSubModes() {
        #expect(type("v3").0 == .vSub(.snippets(query: "", highlightedIndex: 0, pageIndex: 0)))
        #expect(type("v5").0 == .vSub(.symbols(categoryIndex: 0, query: "", highlightedIndex: 0, pageIndex: 0)))
        #expect(type("v8").0 == .vSub(.dateTime(highlightedIndex: 0)))
        #expect(type("v8").0.preedit == "v8" && type("v3").0.preedit == "v3" && type("v5").0.preedit == "v5")
    }

    /// The 2-column grid: `(1,2) (3,4) (5,6) (7,8) (9)`.
    @Test func gridArrowsAndTab() {
        let up = Self.key(VirtualKeyCode.upArrow)
        let down = Self.key(VirtualKeyCode.downArrow)
        let left = Self.key(VirtualKeyCode.leftArrow)
        let right = Self.key(VirtualKeyCode.rightArrow)
        let tab = Self.key(VirtualKeyCode.tab, "\t")
        let shiftTab = Self.key(VirtualKeyCode.tab, "\t", .shift)
        func at(_ index: Int, _ input: VModeInput) -> VModeState {
            reducer.reduce(.vMenu(highlightedIndex: index), input, context: plain).0
        }
        #expect(at(0, down) == .vMenu(highlightedIndex: 2))
        #expect(at(2, up) == .vMenu(highlightedIndex: 0))
        #expect(at(0, up) == .vMenu(highlightedIndex: 0))
        #expect(at(1, left) == .vMenu(highlightedIndex: 0) && at(0, left) == .vMenu(highlightedIndex: 0))
        #expect(at(0, right) == .vMenu(highlightedIndex: 1) && at(8, right) == .vMenu(highlightedIndex: 8))
        #expect(at(7, down) == .vMenu(highlightedIndex: 8), "down from 8 lands on the lone 9")
        #expect(at(6, down) == .vMenu(highlightedIndex: 8))
        #expect(at(8, down) == .vMenu(highlightedIndex: 8))
        #expect(at(8, up) == .vMenu(highlightedIndex: 6))
        #expect(at(8, tab) == .vMenu(highlightedIndex: 0) && at(0, shiftTab) == .vMenu(highlightedIndex: 8))
        // Return opens the highlighted cell.
        #expect(reducer.reduce(.vMenu(highlightedIndex: 7), Self.returnKey, context: plain).0 == .vSub(.dateTime(highlightedIndex: 0)))
        #expect(reducer.reduce(.vMenu(highlightedIndex: 8), Self.space, context: plain) == (.idle, .dispatchAgent(.settings)))
    }

    // MARK: - Calculator

    /// `v1+2` then Space: the `1` of `v1` continues into `1+2`, and Space commits 3.
    @Test func v1Plus2CommitsThree() {
        var (state, _) = type("v1")
        #expect(state == .vSub(.calculator(expression: "", pendingLeadingOne: true, highlightedIndex: 0)) && state.preedit == "v1")
        (state, _) = type("+2", from: state)
        #expect(state.preedit == "v1+2")
        guard case .vSub(let sub) = state else { Issue.record("\(state)"); return }
        #expect(reducer.rows(for: sub) == ["3", "1+2=3"])
        let (final, effects) = run([Self.space], from: state)
        #expect(final == .idle && effects == [.commitText("3")])
    }

    /// `v1` then `3+4`: a digit after the pending 1 starts a fresh expression.
    @Test func v1ThenADigitStartsAfresh() {
        let (state, _) = type("v13+4")
        #expect(state == .vSub(.calculator(expression: "3+4", pendingLeadingOne: false, highlightedIndex: 0)) && state.preedit == "v3+4")
        #expect(run([Self.returnKey], from: state).1 == [.commitText("7")])
    }

    @Test func vEqualsOpensAnEmptyCalculator() {
        let (state, _) = type("v=2+3")
        #expect(state == .vSub(.calculator(expression: "2+3", pendingLeadingOne: false, highlightedIndex: 0)))
        // Down highlights the equation row; Return commits it.
        let (final, effects) = run([Self.key(VirtualKeyCode.downArrow), Self.returnKey], from: state)
        #expect(final == .idle && effects.last == .commitText("2+3=5"))
    }

    @Test func zeroAndParenthesisOpenTheCalculator() {
        #expect(type("v0").0 == .vSub(.calculator(expression: "0", pendingLeadingOne: false, highlightedIndex: 0)))
        #expect(type("v(").0 == .vSub(.calculator(expression: "(", pendingLeadingOne: false, highlightedIndex: 0)))
        #expect(type("v(1+2)*3").0.preedit == "v(1+2)*3")
    }

    @Test func fullWidthCharactersMapToTheCalculator() {
        let (state, _) = type("v（２＋３）×４")
        #expect(state == .vSub(.calculator(expression: "(2+3)*4", pendingLeadingOne: false, highlightedIndex: 0)))
        #expect(run([Self.returnKey], from: state).1 == [.commitText("20")])
    }

    @Test func incompleteExpressionDoesNotCommit() {
        let state = type("v=2+").0
        guard case .vSub(let sub) = state else { Issue.record("\(state)"); return }
        #expect(reducer.rows(for: sub).isEmpty)
        #expect(reducer.reduce(state, Self.returnKey, context: plain) == (state, .consumeOnly))
        #expect(reducer.reduce(state, .click(index: 0), context: plain) == (state, .consumeOnly))
    }

    @Test func calculatorBackspace() {
        var (state, _) = type("v=2+3")
        (state, _) = run([Self.backspace], from: state)
        #expect(state == .vSub(.calculator(expression: "2+", pendingLeadingOne: false, highlightedIndex: 0)))
        (state, _) = run([Self.backspace, Self.backspace], from: state)
        #expect(state == .vSub(.calculator(expression: "", pendingLeadingOne: false, highlightedIndex: 0)))
        (state, _) = run([Self.backspace], from: state)
        #expect(state == .vMenu(highlightedIndex: VMenuItem.calculator.index))
        #expect(run([Self.backspace], from: type("v1").0).0 == .vMenu(highlightedIndex: 0))
        #expect(run([Self.escape], from: type("v=2+3").0) == (.idle, [.consumeOnly]))
    }

    @Test func calculatorIgnoresLettersAndCapsItsLength() {
        let state = type("v=2+3").0
        #expect(reducer.reduce(state, Self.text("x"), context: plain) == (state, .consumeOnly))
        let long = type("v=" + String(repeating: "1", count: VModeReducer.maxExpressionLength + 5)).0
        guard case .vSub(.calculator(let expression, _, _)) = long else { Issue.record("\(long)"); return }
        #expect(expression.count == VModeReducer.maxExpressionLength)
    }

    // MARK: - Paged lists

    @Test func snippetsFilterPageAndSelect() {
        var state = type("v3").0
        guard case .vSub(let sub) = state else { Issue.record("\(state)"); return }
        #expect(reducer.rows(for: sub).count == 5 && reducer.pageCount(for: sub) == 3)
        state = run([Self.text("=")], from: state).0
        #expect(state == .vSub(.snippets(query: "", highlightedIndex: 0, pageIndex: 1)))
        state = run([Self.key(VirtualKeyCode.pageDown), Self.key(VirtualKeyCode.pageDown)], from: state).0
        #expect(state == .vSub(.snippets(query: "", highlightedIndex: 0, pageIndex: 2)), "the last page holds")
        state = run([Self.text("-"), Self.key(VirtualKeyCode.leftArrow)], from: state).0
        #expect(state == .vSub(.snippets(query: "", highlightedIndex: 0, pageIndex: 0)))
        // Letters filter, lowercased; `2` commits the second row of the page.
        state = type("XX", from: state).0
        #expect(state.preedit == "v3xx")
        guard case .vSub(let filtered) = state else { Issue.record("\(state)"); return }
        #expect(reducer.rows(for: filtered) == ["谢谢！"])
        #expect(run([Self.text("1")], from: state) == (.idle, [.commitText("谢谢！")]))
        #expect(run([Self.text("2")], from: state).0 == state, "no second row")
        state = run([Self.backspace, Self.backspace, Self.backspace], from: state).0
        #expect(state == .vMenu(highlightedIndex: VMenuItem.snippets.index))
    }

    @Test func symbolsTabCyclesCategories() {
        var state = type("v5").0
        state = run([Self.key(VirtualKeyCode.tab, "\t")], from: state).0
        #expect(state == .vSub(.symbols(categoryIndex: 1, query: "", highlightedIndex: 0, pageIndex: 0)))
        state = run([Self.key(VirtualKeyCode.tab, "\t", .shift), Self.key(VirtualKeyCode.tab, "\t", .shift)], from: state).0
        let last = SymbolPalette.builtIn.categoryNames.count - 1
        #expect(state == .vSub(.symbols(categoryIndex: last, query: "", highlightedIndex: 0, pageIndex: 0)))
        // 数学符号: `zf` filters to ±; Down then Return commits the highlighted row.
        state = run([Self.key(VirtualKeyCode.tab, "\t"), Self.key(VirtualKeyCode.tab, "\t")], from: state).0
        state = type("zf", from: state).0
        #expect(run([Self.returnKey], from: state) == (.idle, [.commitText("±")]))
        state = run([Self.key(VirtualKeyCode.downArrow)], from: type("v5").0).0
        #expect(state == .vSub(.symbols(categoryIndex: 0, query: "", highlightedIndex: 1, pageIndex: 0)))
        #expect(run([Self.space], from: state) == (.idle, [.commitText("。")]))
    }

    @Test func dateTimeSelectsByDigitArrowAndClick() {
        let state = type("v8").0
        #expect(run([Self.text("1")], from: state) == (.idle, [.commitText("2026-11-26")]))
        #expect(run([Self.key(VirtualKeyCode.downArrow), Self.returnKey], from: state).1.last == .commitText("2026年11月26日"))
        #expect(reducer.reduce(state, .click(index: 5), context: plain) == (.idle, .commitText("星期四")))
        #expect(reducer.reduce(state, .click(index: 40), context: plain) == (state, .consumeOnly))
        #expect(run([Self.backspace], from: state).0 == .vMenu(highlightedIndex: VMenuItem.dateTime.index))
    }

    @Test func calculatorCharacterMapping() {
        #expect(VModeReducer.calculatorCharacter("７") == "7")
        #expect(VModeReducer.calculatorCharacter("÷") == "/")
        #expect(VModeReducer.calculatorCharacter("−") == "-")
        #expect(VModeReducer.calculatorCharacter("a") == nil)
        #expect(VModeReducer.calculatorCharacter("=") == nil)
    }

    @Test func menuItemsAndQuickActions() {
        #expect(VMenuItem.allCases.count == 9 && VMenuItem.at(index: 8) == .settings && VMenuItem.at(index: 9) == nil)
        #expect(QuickActionID.allCases.filter(\.isImplemented) == [.settings])
        #expect(QuickActionID.clipboard.plannedMilestone == "M3" && QuickActionID.rewrite.plannedMilestone == "M4")
        #expect(VModeEnvironment(pageSize: 40).pageSize == 9 && VModeEnvironment(pageSize: 0).pageSize == 1)
    }
}
