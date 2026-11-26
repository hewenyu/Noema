import Darwin
import Foundation
import NoemaCore
import NoemaText
import Testing

/// The v-mode offline tools of `NoemaText`.
@Suite struct CalculatorEvaluatorTests {
    @Test(arguments: [
        ("1+2", "3"), ("1+2*3", "7"), ("(1+2)*3", "9"), ("10/4", "2.5"), ("2^10", "1024"), ("2^3^2", "512"),
        ("-3+5", "2"), ("--3", "3"), ("7%3", "1"), ("-7%3", "-1"), ("0.1+0.2", "0.3"), ("1/3", "0.3333333333"),
        ("2/3", "0.6666666667"), ("3-3", "0"), ("-0", "0"), ("1.50*2", "3"), ("（２＋３）×４", "20"), ("6÷4", "1.5"),
        ("2 + 3", "5"), ("1+2=", "3"), ("4^0.5", "2"), ("10^-2", "0.01"), ("123456789*987654321", "121932631112635269"),
    ])
    func evaluates(_ expression: String, _ expected: String) {
        #expect(CalculatorEvaluator.evaluateFormatted(expression) == expected, "\(expression)")
    }

    @Test(arguments: [
        ("", CalculatorEvaluator.Failure.empty), ("=", .empty), ("1/0", .divisionByZero), ("5%0", .divisionByZero),
        ("1+", .syntax), ("(1+2", .syntax), ("1+2)", .syntax), ("1..2", .syntax), ("2^2000", .exponentTooLarge),
        ("abc", .invalidCharacter), ("1+x", .invalidCharacter), ("sqrt(4)", .invalidCharacter),
    ])
    func rejects(_ expression: String, _ failure: CalculatorEvaluator.Failure) {
        #expect(CalculatorEvaluator.evaluate(expression) == .failure(failure), "\(expression)")
        #expect(CalculatorEvaluator.evaluateFormatted(expression) == nil)
    }

    @Test func boundsLengthAndDepth() {
        let long = String(repeating: "1+", count: 64) + "1"
        #expect(CalculatorEvaluator.evaluate(long) == .failure(.tooLong))
        let deep = String(repeating: "(", count: 40) + "1" + String(repeating: ")", count: 40)
        #expect(CalculatorEvaluator.evaluate(deep) == .failure(.tooDeep))
        let fine = String(repeating: "(", count: 20) + "1" + String(repeating: ")", count: 20)
        #expect(CalculatorEvaluator.evaluateFormatted(fine) == "1")
    }

    /// Decimal arithmetic: no binary floating-point drift.
    @Test func decimalNotDouble() {
        #expect(CalculatorEvaluator.evaluateFormatted("0.1*3") == "0.3")
        #expect(CalculatorEvaluator.evaluateFormatted("1.1+2.2") == "3.3")
        #expect(CalculatorEvaluator.format(Decimal(string: "-0.00000000001")!) == "0")
        #expect(CalculatorEvaluator.evaluateFormatted("10^22") == "1e+22")
    }

    @Test func normalizeMapsFullWidthAndTypographicForms() {
        #expect(CalculatorEvaluator.normalize("１２ × ３ − ４ ÷ ２＝") == "12*3-4/2=")
    }
}

@Suite struct DateTimeTemplatesTests {
    static let instant = Date(timeIntervalSince1970: 1_795_656_600)  // 2026-11-26T01:30:00Z

    @Test func beijing() {
        let items = DateTimeTemplates(timeZone: TimeZone(secondsFromGMT: 8 * 3600)!).candidates(for: Self.instant)
        #expect(items == [
            "2026-11-26", "2026年11月26日", "2026/11/26", "2026-11-26 09:30", "09:30:00", "星期四",
            "2026-11-26T09:30:00+08:00", "1795656600",
        ])
    }

    @Test func utcAndNegativeOffsetsCrossTheDate() {
        let utc = DateTimeTemplates(timeZone: TimeZone(secondsFromGMT: 0)!).candidates(for: Self.instant)
        #expect(utc[6] == "2026-11-26T01:30:00Z" && utc[4] == "01:30:00")
        let newYork = DateTimeTemplates(timeZone: TimeZone(secondsFromGMT: -5 * 3600)!).candidates(for: Self.instant)
        #expect(newYork[0] == "2026-11-25" && newYork[5] == "星期三" && newYork[6] == "2026-11-25T20:30:00-05:00")
        let india = DateTimeTemplates(timeZone: TimeZone(secondsFromGMT: 5 * 3600 + 1800)!).candidates(for: Self.instant)
        #expect(india[6].hasSuffix("+05:30"))
    }
}

@Suite struct SymbolPaletteTests {
    @Test func builtInCategoriesAndFiltering() {
        let palette = SymbolPalette.builtIn
        #expect(palette.categoryNames == ["常用标点", "数学符号", "箭头序号", "括号引号", "货币单位"])
        #expect(palette.symbols(categoryIndex: 0, query: "").first == "，")
        #expect(palette.symbols(categoryIndex: 1, query: "zf") == ["±"])
        #expect(palette.symbols(categoryIndex: 99, query: "") == palette.symbols(categoryIndex: 4, query: ""), "clamped")
        #expect(palette.symbols(categoryIndex: 0, query: "nomatch").isEmpty)
        for category in palette.categories {
            #expect(!category.symbols.isEmpty)
            #expect(Set(category.symbols.map(\.text)).count == category.symbols.count, "\(category.name) has duplicates")
        }
        #expect(SymbolPalette(categories: []).symbols(categoryIndex: 0, query: "").isEmpty)
    }
}

@Suite struct SnippetStoreTests {
    let directory: URL
    var file: URL { directory.appending(path: SnippetStore.fileName) }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "noema-snippets-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    @Test func missingFileOrNoURLGivesTheDefaults() {
        defer { cleanUp() }
        #expect(SnippetStore(fileURL: file).load() == SnippetStore.defaults)
        #expect(SnippetStore(fileURL: nil).load() == SnippetStore.defaults)
        #expect(SnippetStore.defaults.count == 12)
    }

    @Test func saveIsAtomicPrivateAndRoundTrips() throws {
        defer { cleanUp() }
        let store = SnippetStore(fileURL: file)
        let mine = [Snippet(text: "我的常用语", keywords: ["wd"]), Snippet(text: "第二条")]
        try store.save(mine)
        #expect(store.load() == mine)
        var info = stat()
        #expect(lstat(file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [SnippetStore.fileName], "no temp file left")
        try store.save([Snippet(text: "替换")])
        #expect(store.load() == [Snippet(text: "替换")])
    }

    @Test func symlinkIsNeitherReadNorReplaced() throws {
        defer { cleanUp() }
        let target = directory.appending(path: "elsewhere.json")
        try #"{"version":1,"snippets":[{"text":"外部","keywords":[]}]}"#.write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        let store = SnippetStore(fileURL: file)
        #expect(store.load() == SnippetStore.defaults, "O_NOFOLLOW: a symlinked file is not read")
        #expect(throws: SnippetStore.Failure.symlink) { try store.save([Snippet(text: "x")]) }
        #expect(try String(contentsOf: target, encoding: .utf8).contains("外部"), "the link target is untouched")
    }

    @Test func oversizedMalformedWrongVersionAndEmptyFallBack() throws {
        defer { cleanUp() }
        let store = SnippetStore(fileURL: file)
        let padding = String(repeating: " ", count: SnippetStore.maxFileSize)
        try (#"{"version":1,"snippets":[{"text":"大"}]}"# + padding).write(to: file, atomically: true, encoding: .utf8)
        #expect(store.load() == SnippetStore.defaults, "over 1 MiB")
        for text in ["not json", #"{"version":2,"snippets":[{"text":"新"}]}"#, #"{"version":1,"snippets":[]}"#, #"{"version":1,"snippets":[{"text":""}]}"#] {
            try text.write(to: file, atomically: true, encoding: .utf8)
            #expect(store.load() == SnippetStore.defaults, "\(text)")
        }
        try #"{"version":1,"snippets":[{"text":"只有文字"}]}"#.write(to: file, atomically: true, encoding: .utf8)
        #expect(store.load() == [Snippet(text: "只有文字")], "keywords are optional")
    }

    @Test func aDirectoryOrFIFOIsNotRead() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        #expect(SnippetStore(fileURL: file).load() == SnippetStore.defaults)
        try FileManager.default.removeItem(at: file)
        #expect(mkfifo(file.path, 0o600) == 0)
        #expect(SnippetStore(fileURL: file).load() == SnippetStore.defaults, "O_NONBLOCK: a FIFO never blocks the load")
    }

    @Test func matching() {
        defer { cleanUp() }
        #expect(SnippetStore.matching(SnippetStore.defaults, query: "").count == 12)
        #expect(SnippetStore.matching(SnippetStore.defaults, query: "XX") == ["谢谢！"])
        #expect(SnippetStore.matching(SnippetStore.defaults, query: "生日") == ["生日快乐！"])
        #expect(NoemaPaths.snippetsURL(homeDirectory: URL(filePath: "/Users/u")).path == "/Users/u/Library/Application Support/Noema/snippets.json")
    }
}
