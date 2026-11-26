/// The `v5` symbol palette: categories of built-in symbols, each with ASCII keywords
/// (pinyin initials or words) the user filters by typing letters. Original data.
public struct SymbolPalette: Sendable, Hashable {
    public struct Symbol: Sendable, Hashable {
        public let text: String
        /// Lowercase ASCII keywords; a query matches when one of them contains it.
        public let keywords: [String]

        public init(_ text: String, _ keywords: [String] = []) {
            self.text = text
            self.keywords = keywords
        }
    }

    public struct Category: Sendable, Hashable {
        public let name: String
        public let symbols: [Symbol]

        public init(name: String, symbols: [Symbol]) {
            self.name = name
            self.symbols = symbols
        }
    }

    public let categories: [Category]

    public init(categories: [Category]) {
        self.categories = categories
    }

    public var categoryNames: [String] { categories.map(\.name) }

    /// The symbols of category `index` (clamped) whose keywords contain `query`
    /// (case-insensitive); every symbol of the category for an empty query.
    public func symbols(categoryIndex index: Int, query: String) -> [String] {
        guard !categories.isEmpty else { return [] }
        let category = categories[min(max(index, 0), categories.count - 1)]
        let needle = query.lowercased()
        guard !needle.isEmpty else { return category.symbols.map(\.text) }
        return category.symbols.filter { $0.keywords.contains { $0.contains(needle) } }.map(\.text)
    }

    /// The shipped palette: 常用标点, 数学符号, 箭头序号, 括号引号, 货币单位.
    public static let builtIn = SymbolPalette(categories: [
        Category(name: "常用标点", symbols: [
            Symbol("，", ["douhao", "comma", "dh"]), Symbol("。", ["juhao", "period", "jh"]),
            Symbol("、", ["dunhao", "dh"]), Symbol("；", ["fenhao", "semicolon", "fh"]),
            Symbol("：", ["maohao", "colon", "mh"]), Symbol("？", ["wenhao", "question", "wh"]),
            Symbol("！", ["gantanhao", "exclamation", "gth"]), Symbol("……", ["shenglvehao", "ellipsis", "slh"]),
            Symbol("——", ["pozhehao", "dash", "pzh"]), Symbol("·", ["jiangehao", "dot", "jgh"]),
            Symbol("～", ["bolanghao", "tilde", "blh"]), Symbol("※", ["cankao", "reference", "ck"]),
            Symbol("§", ["jie", "section"]), Symbol("¶", ["duan", "pilcrow"]),
            Symbol("•", ["yuandian", "bullet", "yd"]), Symbol("°", ["du", "degree"]),
        ]),
        Category(name: "数学符号", symbols: [
            Symbol("±", ["zhengfu", "plusminus", "zf"]), Symbol("×", ["cheng", "times", "c"]),
            Symbol("÷", ["chu", "divide"]), Symbol("≈", ["yuedengyu", "approx", "ydy"]),
            Symbol("≠", ["budengyu", "notequal", "bdy"]), Symbol("≤", ["xiaoyudengyu", "le", "xydy"]),
            Symbol("≥", ["dayudengyu", "ge", "dydy"]), Symbol("∞", ["wuqiong", "infinity", "wq"]),
            Symbol("√", ["genhao", "sqrt", "gh"]), Symbol("∑", ["qiuhe", "sum", "qh"]),
            Symbol("∏", ["qiuji", "product", "qj"]), Symbol("∫", ["jifen", "integral", "jf"]),
            Symbol("π", ["pai", "pi"]), Symbol("‰", ["qianfenhao", "permille", "qfh"]),
            Symbol("∈", ["shuyu", "in", "sy"]), Symbol("∵", ["yinwei", "because", "yw"]),
            Symbol("∴", ["suoyi", "therefore", "sy"]), Symbol("°C", ["sheshidu", "celsius", "ssd"]),
        ]),
        Category(name: "箭头序号", symbols: [
            Symbol("→", ["you", "right", "jiantou"]), Symbol("←", ["zuo", "left", "jiantou"]),
            Symbol("↑", ["shang", "up", "jiantou"]), Symbol("↓", ["xia", "down", "jiantou"]),
            Symbol("⇒", ["tuichu", "implies", "jiantou"]), Symbol("↔", ["shuangxiang", "both", "jiantou"]),
            Symbol("①", ["yi", "one", "xuhao"]), Symbol("②", ["er", "two", "xuhao"]),
            Symbol("③", ["san", "three", "xuhao"]), Symbol("④", ["si", "four", "xuhao"]),
            Symbol("⑤", ["wu", "five", "xuhao"]), Symbol("⑥", ["liu", "six", "xuhao"]),
            Symbol("⑦", ["qi", "seven", "xuhao"]), Symbol("⑧", ["ba", "eight", "xuhao"]),
            Symbol("⑨", ["jiu", "nine", "xuhao"]), Symbol("⑩", ["shi", "ten", "xuhao"]),
            Symbol("✓", ["dui", "check", "gou"]), Symbol("✗", ["cuo", "cross", "cha"]),
        ]),
        Category(name: "括号引号", symbols: [
            Symbol("（）", ["kuohao", "paren", "kh"]), Symbol("【】", ["fangkuohao", "bracket", "fkh"]),
            Symbol("《》", ["shuminghao", "title", "smh"]), Symbol("〈〉", ["danshuminghao", "angle", "dsmh"]),
            Symbol("「」", ["zhijiao", "corner", "zj"]), Symbol("『』", ["shuangzhijiao", "corner", "szj"]),
            Symbol("“”", ["shuangyinhao", "quote", "syh"]), Symbol("‘’", ["danyinhao", "quote", "dyh"]),
            Symbol("〔〕", ["guikuohao", "tortoise", "gkh"]), Symbol("｛｝", ["huakuohao", "brace", "hkh"]),
        ]),
        Category(name: "货币单位", symbols: [
            Symbol("¥", ["renminbi", "yuan", "rmb"]), Symbol("$", ["meiyuan", "dollar", "my"]),
            Symbol("€", ["ouyuan", "euro", "oy"]), Symbol("£", ["yingbang", "pound", "yb"]),
            Symbol("₩", ["hanyuan", "won", "hy"]), Symbol("₿", ["bitebi", "bitcoin", "btb"]),
            Symbol("㎡", ["pingfangmi", "sqm", "pfm"]), Symbol("㎏", ["qianke", "kg", "qk"]),
            Symbol("㎞", ["gongli", "km", "gl"]), Symbol("℃", ["sheshidu", "celsius", "ssd"]),
            Symbol("℉", ["huashidu", "fahrenheit", "hsd"]), Symbol("％", ["baifenhao", "percent", "bfh"]),
        ]),
    ])
}
