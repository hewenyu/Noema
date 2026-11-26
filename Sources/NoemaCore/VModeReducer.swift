/// One cell of the v-mode menu, numbered as its shortcut key (`v1` … `v9`).
public enum VMenuItem: Int, CaseIterable, Sendable, Hashable, Codable {
    case calculator = 1
    case clipboard
    case snippets
    case voiceInput
    case symbols
    case translate
    case rewrite
    case dateTime
    case settings

    /// Columns of the menu grid; cells run row-major: `(1,2) (3,4) (5,6) (7,8) (9)`.
    public static let columns = 2

    public var title: String {
        switch self {
        case .calculator: "计算"
        case .clipboard: "剪贴板"
        case .snippets: "常用语"
        case .voiceInput: "语音输入"
        case .symbols: "符号"
        case .translate: "翻译"
        case .rewrite: "改写"
        case .dateTime: "日期时间"
        case .settings: "设置"
        }
    }

    /// The agent action this cell dispatches; nil for an offline tool the IME runs itself.
    public var quickAction: QuickActionID? {
        switch self {
        case .clipboard: .clipboard
        case .voiceInput: .voiceInput
        case .translate: .translate
        case .rewrite: .rewrite
        case .settings: .settings
        case .calculator, .snippets, .symbols, .dateTime: nil
        }
    }

    /// The 0-based cell index (`rawValue - 1`).
    public var index: Int { rawValue - 1 }

    /// The item at 0-based cell `index`, if any.
    public static func at(index: Int) -> VMenuItem? { VMenuItem(rawValue: index + 1) }
}

/// An offline tool open under the v-mode menu. Every case is a plain value; the rows it
/// shows come from `VModeEnvironment`.
public enum VSubMode: Sendable, Hashable {
    /// `expression` is what the user typed (ASCII-normalized). `pendingLeadingOne` is true
    /// right after `v1`: the `1` is shown but not yet part of `expression`, because the next
    /// key decides whether it was the menu shortcut (`v1` then `3+4`) or a digit (`v1+2`).
    /// Rows: 0 the result, 1 the whole equation.
    case calculator(expression: String, pendingLeadingOne: Bool, highlightedIndex: Int)
    case snippets(query: String, highlightedIndex: Int, pageIndex: Int)
    case symbols(categoryIndex: Int, query: String, highlightedIndex: Int, pageIndex: Int)
    case dateTime(highlightedIndex: Int)
    /// The escape hatch: `v` plus a letter types literal ASCII (`vim` then Return commits `vim`).
    case literal(buffer: String)

    /// The menu item the sub-mode belongs to; Backspace on an empty sub-mode returns there.
    public var menuItem: VMenuItem {
        switch self {
        case .calculator: .calculator
        case .snippets: .snippets
        case .symbols: .symbols
        case .dateTime: .dateTime
        case .literal: .calculator
        }
    }
}

/// Where v-mode is. `.composing` means Rime owns a composition: every key goes to Rime, so
/// `lv` and `nv` still spell 绿 and 女.
public enum VModeState: Sendable, Hashable {
    case idle
    case composing
    case vMenu(highlightedIndex: Int)
    case vSub(VSubMode)

    /// True while v-mode owns the keyboard (menu or a sub-mode).
    public var isActive: Bool {
        switch self {
        case .vMenu, .vSub: true
        case .idle, .composing: false
        }
    }

    /// The marked text shown in the client while v-mode is active; empty otherwise.
    public var preedit: String {
        switch self {
        case .idle, .composing: ""
        case .vMenu: "v"
        case .vSub(let sub):
            switch sub {
            case .calculator(let expression, let pendingOne, _): "v" + (pendingOne ? "1" : expression)
            case .snippets(let query, _, _): "v3" + query
            case .symbols(_, let query, _, _): "v5" + query
            case .dateTime: "v8"
            case .literal(let buffer): buffer
            }
        }
    }
}

/// What the shell does with the key after a transition.
public enum VModeEffect: Sendable, Hashable {
    /// Hand the key to the typing engine.
    case passToRime
    /// Return `false`: the client receives the key.
    case passThroughToClient
    /// The key is v-mode's; refresh the marked text and the panel.
    case consumeOnly
    /// Insert the text, clear the marked text, and hide the panel.
    case commitText(String)
    /// Clear the marked text, hide the panel, and ask the agent to run the action.
    case dispatchAgent(QuickActionID)
}

/// What v-mode reacts to.
public enum VModeInput: Sendable, Hashable {
    case key(KeyEvent)
    /// A click on menu cell (0-based) or sub-mode row on the current page (0-based).
    case click(index: Int)
}

/// The facts outside v-mode a transition depends on.
public struct VModeContext: Sendable, Hashable {
    public var isSecureInput: Bool
    public var isSafeMode: Bool
    public var isASCIIMode: Bool
    /// The typing engine has an open composition.
    public var isEngineComposing: Bool

    public init(isSecureInput: Bool = false, isSafeMode: Bool = false, isASCIIMode: Bool = false, isEngineComposing: Bool = false) {
        self.isSecureInput = isSecureInput
        self.isSafeMode = isSafeMode
        self.isASCIIMode = isASCIIMode
        self.isEngineComposing = isEngineComposing
    }
}

/// The rows each sub-mode shows, supplied by the shell (`NoemaText`'s offline tools). Every
/// closure is pure for a given call, so a transition is a function of its arguments.
public struct VModeEnvironment: Sendable {
    /// Rows per page of the snippet and symbol lists; `1`…`9` select on the page.
    public var pageSize: Int
    /// The formatted result of `expression`, or nil when it does not evaluate.
    public var calculate: @Sendable (String) -> String?
    /// Snippets matching the query, in order.
    public var snippets: @Sendable (String) -> [String]
    /// Symbol category names, in order.
    public var symbolCategories: [String]
    /// Symbols of a category matching the query, in order.
    public var symbols: @Sendable (Int, String) -> [String]
    /// The date and time candidates, in order.
    public var dateTimeItems: @Sendable () -> [String]

    public init(
        pageSize: Int = 9,
        calculate: @escaping @Sendable (String) -> String? = { _ in nil },
        snippets: @escaping @Sendable (String) -> [String] = { _ in [] },
        symbolCategories: [String] = [],
        symbols: @escaping @Sendable (Int, String) -> [String] = { _, _ in [] },
        dateTimeItems: @escaping @Sendable () -> [String] = { [] }
    ) {
        self.pageSize = min(max(pageSize, 1), 9)
        self.calculate = calculate
        self.snippets = snippets
        self.symbolCategories = symbolCategories
        self.symbols = symbols
        self.dateTimeItems = dateTimeItems
    }
}

/// The v-mode state machine: a pure function of the state, one input, the context, and the
/// environment. No timer, no I/O, no AppKit: the same arguments always give the same
/// transition, so every edge is unit-tested without an engine or a window.
public struct VModeReducer: Sendable {
    public static let maxExpressionLength = 128
    public static let maxLiteralLength = 64

    public let environment: VModeEnvironment

    public init(environment: VModeEnvironment) {
        self.environment = environment
    }

    // MARK: - Rows

    /// The rows `sub` shows on its current page.
    public func rows(for sub: VSubMode) -> [String] {
        switch sub {
        case .calculator(let expression, let pendingOne, _):
            let shown = pendingOne ? "1" : expression
            guard !shown.isEmpty, let result = environment.calculate(shown) else { return [] }
            return [result, "\(shown)=\(result)"]
        case .snippets(let query, _, let page):
            return Self.page(environment.snippets(query), page, environment.pageSize)
        case .symbols(let category, let query, _, let page):
            return Self.page(environment.symbols(category, query), page, environment.pageSize)
        case .dateTime:
            return Array(environment.dateTimeItems().prefix(9))
        case .literal(let buffer):
            return [buffer]
        }
    }

    /// Every item of a paged list (snippets or symbols); empty for other sub-modes.
    public func allItems(for sub: VSubMode) -> [String] {
        switch sub {
        case .snippets(let query, _, _): environment.snippets(query)
        case .symbols(let category, let query, _, _): environment.symbols(category, query)
        default: rows(for: sub)
        }
    }

    /// The number of pages of a paged list (at least 1).
    public func pageCount(for sub: VSubMode) -> Int {
        let count = allItems(for: sub).count
        return max((count + environment.pageSize - 1) / environment.pageSize, 1)
    }

    static func page(_ items: [String], _ page: Int, _ size: Int) -> [String] {
        let start = max(page, 0) * size
        guard start < items.count else { return [] }
        return Array(items[start..<min(start + size, items.count)])
    }

    // MARK: - Transitions

    public func reduce(_ state: VModeState, _ input: VModeInput, context: VModeContext) -> (VModeState, VModeEffect) {
        // Secure input, Safe Mode, and ASCII mode end v-mode at once; the key is the client's.
        if context.isSecureInput || context.isSafeMode || context.isASCIIMode {
            return (.idle, .passThroughToClient)
        }
        switch state {
        case .idle, .composing:
            guard case .key(let event) = input else { return (context.isEngineComposing ? .composing : .idle, .consumeOnly) }
            if context.isEngineComposing { return (.composing, .passToRime) }
            if Self.isPlainV(event) { return (.vMenu(highlightedIndex: 0), .consumeOnly) }
            return (.idle, .passToRime)
        case .vMenu(let highlighted):
            return reduceMenu(highlighted, input)
        case .vSub(let sub):
            return reduceSub(sub, input)
        }
    }

    /// A lowercase `v` with no modifier but Fn: Shift, Caps Lock, and every shortcut chord
    /// leave it to the engine or the client.
    public static func isPlainV(_ event: KeyEvent) -> Bool {
        event.isKeyDown && event.characters == "v" && event.modifiers.subtracting(.function).isEmpty
    }

    private func reduceMenu(_ highlighted: Int, _ input: VModeInput) -> (VModeState, VModeEffect) {
        let count = VMenuItem.allCases.count
        let current = min(max(highlighted, 0), count - 1)
        let event: KeyEvent
        switch input {
        case .click(let index):
            guard let item = VMenuItem.at(index: index) else { return (.vMenu(highlightedIndex: current), .consumeOnly) }
            return activate(item)
        case .key(let key):
            event = key
        }
        guard event.isKeyDown else { return (.vMenu(highlightedIndex: current), .consumeOnly) }
        if event.modifiers.isShortcut { return (.idle, .passThroughToClient) }
        switch Self.classify(event) {
        case .escape, .backspace:
            return (.idle, .consumeOnly)
        case .commit:
            return activate(VMenuItem.at(index: current) ?? .calculator)
        case .tab(let backward):
            return (.vMenu(highlightedIndex: backward ? (current + count - 1) % count : (current + 1) % count), .consumeOnly)
        case .arrow(let direction):
            return (.vMenu(highlightedIndex: Self.move(current, direction, count: count)), .consumeOnly)
        case .page, .other:
            return (.vMenu(highlightedIndex: current), .consumeOnly)
        case .character(let ch):
            switch ch {
            case "1":
                return (.vSub(.calculator(expression: "", pendingLeadingOne: true, highlightedIndex: 0)), .consumeOnly)
            case "0", "(", "=":
                return (.vSub(.calculator(expression: ch == "=" ? "" : String(ch), pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
            case "2", "3", "4", "5", "6", "7", "8", "9":
                return activate(VMenuItem(rawValue: Int(String(ch))!)!)
            case "v":
                return (.idle, .commitText("v"))
            default:
                if let calc = Self.calculatorCharacter(ch), !ch.isASCII, calc.isNumber || calc == "(" {
                    // A full-width digit or `（` starts the calculator like its ASCII form.
                    return calc == "1"
                        ? (.vSub(.calculator(expression: "", pendingLeadingOne: true, highlightedIndex: 0)), .consumeOnly)
                        : (.vSub(.calculator(expression: String(calc), pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
                }
                // Any other printable ASCII starts the literal escape hatch: `vim`, `v.`.
                guard ch.isASCII else { return (.vMenu(highlightedIndex: current), .consumeOnly) }
                return (.vSub(.literal(buffer: "v" + String(ch))), .consumeOnly)
            }
        }
    }

    /// Opens `item`: an offline tool's sub-mode, or an agent action.
    private func activate(_ item: VMenuItem) -> (VModeState, VModeEffect) {
        if let action = item.quickAction { return (.idle, .dispatchAgent(action)) }
        switch item {
        case .calculator: return (.vSub(.calculator(expression: "", pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
        case .snippets: return (.vSub(.snippets(query: "", highlightedIndex: 0, pageIndex: 0)), .consumeOnly)
        case .symbols: return (.vSub(.symbols(categoryIndex: 0, query: "", highlightedIndex: 0, pageIndex: 0)), .consumeOnly)
        case .dateTime: return (.vSub(.dateTime(highlightedIndex: 0)), .consumeOnly)
        default: return (.idle, .consumeOnly)
        }
    }

    private func reduceSub(_ sub: VSubMode, _ input: VModeInput) -> (VModeState, VModeEffect) {
        if case .key(let event) = input {
            guard event.isKeyDown else { return (.vSub(sub), .consumeOnly) }
            if event.modifiers.isShortcut { return (.idle, .passThroughToClient) }
            if Self.classify(event) == .escape { return (.idle, .consumeOnly) }
        }
        switch sub {
        case .calculator(let expression, let pendingOne, let highlighted):
            return reduceCalculator(expression, pendingOne, highlighted, input)
        case .literal(let buffer):
            return reduceLiteral(buffer, input)
        case .dateTime(let highlighted):
            return reduceList(sub, highlighted: highlighted, input) { .dateTime(highlightedIndex: $0) }
        case .snippets(let query, let highlighted, let page):
            return reducePaged(sub, query: query, highlighted: highlighted, page: page, input) { query, highlighted, page in
                .snippets(query: query, highlightedIndex: highlighted, pageIndex: page)
            }
        case .symbols(let category, let query, let highlighted, let page):
            if case .key(let event) = input, case .tab(let backward) = Self.classify(event) {
                let count = max(environment.symbolCategories.count, 1)
                let next = backward ? (category + count - 1) % count : (category + 1) % count
                return (.vSub(.symbols(categoryIndex: next, query: query, highlightedIndex: 0, pageIndex: 0)), .consumeOnly)
            }
            return reducePaged(sub, query: query, highlighted: highlighted, page: page, input) { query, highlighted, page in
                .symbols(categoryIndex: category, query: query, highlightedIndex: highlighted, pageIndex: page)
            }
        }
    }

    private func reduceCalculator(
        _ expression: String, _ pendingOne: Bool, _ highlighted: Int, _ input: VModeInput
    ) -> (VModeState, VModeEffect) {
        let sub = VSubMode.calculator(expression: expression, pendingLeadingOne: pendingOne, highlightedIndex: highlighted)
        let rows = rows(for: sub)
        func commit(_ index: Int) -> (VModeState, VModeEffect) {
            guard rows.indices.contains(index) else { return (.vSub(sub), .consumeOnly) }
            return (.idle, .commitText(rows[index]))
        }
        let event: KeyEvent
        switch input {
        case .click(let index): return commit(index)
        case .key(let key): event = key
        }
        switch Self.classify(event) {
        case .commit:
            return commit(min(max(highlighted, 0), 1))
        case .backspace:
            if pendingOne { return (.vMenu(highlightedIndex: VMenuItem.calculator.index), .consumeOnly) }
            guard !expression.isEmpty else { return (.vMenu(highlightedIndex: VMenuItem.calculator.index), .consumeOnly) }
            return (.vSub(.calculator(expression: String(expression.dropLast()), pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
        case .arrow(.up), .arrow(.down):
            guard rows.count == 2 else { return (.vSub(sub), .consumeOnly) }
            return (.vSub(.calculator(expression: expression, pendingLeadingOne: pendingOne, highlightedIndex: highlighted == 0 ? 1 : 0)), .consumeOnly)
        case .character(let raw):
            guard let ch = Self.calculatorCharacter(raw) else { return (.vSub(sub), .consumeOnly) }
            if pendingOne {
                // `v1` then an operator continues the number 1; a digit or `(` starts afresh.
                let fresh = ch.isNumber || ch == "("
                let next = fresh ? String(ch) : "1" + String(ch)
                return (.vSub(.calculator(expression: next, pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
            }
            guard expression.count < Self.maxExpressionLength else { return (.vSub(sub), .consumeOnly) }
            return (.vSub(.calculator(expression: expression + String(ch), pendingLeadingOne: false, highlightedIndex: 0)), .consumeOnly)
        case .escape, .tab, .arrow, .page, .other:
            return (.vSub(sub), .consumeOnly)
        }
    }

    private func reduceLiteral(_ buffer: String, _ input: VModeInput) -> (VModeState, VModeEffect) {
        let event: KeyEvent
        switch input {
        case .click: return (.idle, .commitText(buffer))
        case .key(let key): event = key
        }
        switch Self.classify(event) {
        case .commit:
            return (.idle, .commitText(buffer))
        case .backspace:
            let shorter = String(buffer.dropLast())
            if shorter.count <= 1 { return (.vMenu(highlightedIndex: 0), .consumeOnly) }
            return (.vSub(.literal(buffer: shorter)), .consumeOnly)
        case .character(let ch):
            guard ch.isASCII, buffer.count < Self.maxLiteralLength else { return (.vSub(.literal(buffer: buffer)), .consumeOnly) }
            return (.vSub(.literal(buffer: buffer + String(ch))), .consumeOnly)
        case .escape, .tab, .arrow, .page, .other:
            return (.vSub(.literal(buffer: buffer)), .consumeOnly)
        }
    }

    /// A short list without paging (date and time): digits, Return, Space, clicks, arrows.
    private func reduceList(
        _ sub: VSubMode, highlighted: Int, _ input: VModeInput, make: (Int) -> VSubMode
    ) -> (VModeState, VModeEffect) {
        let rows = rows(for: sub)
        let current = rows.isEmpty ? 0 : min(max(highlighted, 0), rows.count - 1)
        func commit(_ index: Int) -> (VModeState, VModeEffect) {
            guard rows.indices.contains(index) else { return (.vSub(sub), .consumeOnly) }
            return (.idle, .commitText(rows[index]))
        }
        let event: KeyEvent
        switch input {
        case .click(let index): return commit(index)
        case .key(let key): event = key
        }
        switch Self.classify(event) {
        case .commit: return commit(current)
        case .backspace: return (.vMenu(highlightedIndex: sub.menuItem.index), .consumeOnly)
        case .arrow(.up), .arrow(.left): return (.vSub(make(max(current - 1, 0))), .consumeOnly)
        case .arrow(.down), .arrow(.right): return (.vSub(make(min(current + 1, max(rows.count - 1, 0)))), .consumeOnly)
        case .character(let ch):
            if let digit = ch.wholeNumberValue, (1...9).contains(digit) { return commit(digit - 1) }
            return (.vSub(sub), .consumeOnly)
        default: return (.vSub(sub), .consumeOnly)
        }
    }

    /// A filtered, paged list (snippets, symbols): letters filter, `-`/`=` and Page Up/Down
    /// page, `1`…`9` select on the page.
    private func reducePaged(
        _ sub: VSubMode, query: String, highlighted: Int, page: Int, _ input: VModeInput,
        make: (String, Int, Int) -> VSubMode
    ) -> (VModeState, VModeEffect) {
        let rows = rows(for: sub)
        let pages = pageCount(for: sub)
        let current = rows.isEmpty ? 0 : min(max(highlighted, 0), rows.count - 1)
        func commit(_ index: Int) -> (VModeState, VModeEffect) {
            guard rows.indices.contains(index) else { return (.vSub(sub), .consumeOnly) }
            return (.idle, .commitText(rows[index]))
        }
        func turn(_ backward: Bool) -> (VModeState, VModeEffect) {
            let next = backward ? max(page - 1, 0) : min(page + 1, pages - 1)
            return (.vSub(make(query, 0, next)), .consumeOnly)
        }
        let event: KeyEvent
        switch input {
        case .click(let index): return commit(index)
        case .key(let key): event = key
        }
        switch Self.classify(event) {
        case .commit: return commit(current)
        case .backspace:
            guard !query.isEmpty else { return (.vMenu(highlightedIndex: sub.menuItem.index), .consumeOnly) }
            return (.vSub(make(String(query.dropLast()), 0, 0)), .consumeOnly)
        case .page(let backward): return turn(backward)
        case .arrow(.up): return (.vSub(make(query, max(current - 1, 0), page)), .consumeOnly)
        case .arrow(.down): return (.vSub(make(query, min(current + 1, max(rows.count - 1, 0)), page)), .consumeOnly)
        case .arrow(.left): return turn(true)
        case .arrow(.right): return turn(false)
        case .character(let ch):
            if let digit = ch.wholeNumberValue, (1...9).contains(digit) { return commit(digit - 1) }
            if ch == "-" { return turn(true) }
            if ch == "=" { return turn(false) }
            if ch.isASCII && ch.isLetter, query.count < Self.maxLiteralLength {
                return (.vSub(make(query + String(ch).lowercased(), 0, 0)), .consumeOnly)
            }
            return (.vSub(sub), .consumeOnly)
        default: return (.vSub(sub), .consumeOnly)
        }
    }

    // MARK: - Keys

    enum Direction: Sendable, Hashable { case up, down, left, right }

    enum KeyClass: Sendable, Hashable {
        case escape
        case backspace
        /// Return, keypad Enter, or Space.
        case commit
        case tab(backward: Bool)
        case arrow(Direction)
        case page(backward: Bool)
        /// One printable ASCII character other than Space.
        case character(Character)
        case other
    }

    /// Classifies by key code first (special keys), then by the typed character, so a key
    /// event that only carries characters (`"\r"`, `" "`) classifies the same.
    static func classify(_ event: KeyEvent) -> KeyClass {
        switch event.keyCode {
        case VirtualKeyCode.escape: return .escape
        case VirtualKeyCode.delete: return .backspace
        case VirtualKeyCode.return, VirtualKeyCode.keypadEnter, VirtualKeyCode.space: return .commit
        case VirtualKeyCode.tab: return .tab(backward: event.modifiers.contains(.shift))
        case VirtualKeyCode.upArrow: return .arrow(.up)
        case VirtualKeyCode.downArrow: return .arrow(.down)
        case VirtualKeyCode.leftArrow: return .arrow(.left)
        case VirtualKeyCode.rightArrow: return .arrow(.right)
        case VirtualKeyCode.pageUp: return .page(backward: true)
        case VirtualKeyCode.pageDown: return .page(backward: false)
        default: break
        }
        switch event.characters {
        case "\u{1B}": return .escape
        case "\u{7F}", "\u{8}": return .backspace
        case "\r", "\n", " ": return .commit
        case "\t": return .tab(backward: event.modifiers.contains(.shift))
        default: break
        }
        if let scalar = event.printableASCII { return .character(Character(scalar)) }
        // One non-ASCII character (a full-width digit or operator from a CJK layout).
        if event.isKeyDown, !event.modifiers.isShortcut, event.characters.count == 1, let ch = event.characters.first,
           !ch.isASCII, !(ch.unicodeScalars.first?.properties.generalCategory == .control) {
            return .character(ch)
        }
        return .other
    }

    /// Moves `index` in the row-major grid of `columns` columns: Left and Right step through
    /// the cells in order, Up and Down jump a row (Down from the second-to-last row lands on
    /// the last cell when its column is empty).
    static func move(_ index: Int, _ direction: Direction, count: Int, columns: Int = VMenuItem.columns) -> Int {
        switch direction {
        case .left: return max(index - 1, 0)
        case .right: return min(index + 1, count - 1)
        case .up: return index - columns >= 0 ? index - columns : index
        case .down:
            if index + columns < count { return index + columns }
            let lastRow = (count - 1) / columns
            return index / columns < lastRow ? count - 1 : index
        }
    }

    /// `character` as an ASCII calculator character, or nil: digits, `+ - * / % ^ . ( )`,
    /// and their full-width or typographic forms (`＋ － − × · ÷ （ ） ％ ０-９ ．`).
    public static func calculatorCharacter(_ character: Character) -> Character? {
        switch character {
        case "0"..."9", "+", "-", "*", "/", "%", "^", ".", "(", ")": return character
        case "＋": return "+"
        case "－", "−": return "-"
        case "×", "·", "＊": return "*"
        case "÷", "／": return "/"
        case "（": return "("
        case "）": return ")"
        case "％": return "%"
        case "＾": return "^"
        case "．": return "."
        default:
            guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1,
                  (0xFF10...0xFF19).contains(scalar.value)
            else { return nil }
            return Character(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
        }
    }
}
