import Foundation

/// Text helpers shared by lexicon import and learning (pure Swift; Foundation only for the
/// Han-Latin transform of `mandarinPinyinSyllables`).
public enum TextNormalization {
    /// Collapses each run of Unicode whitespace to one ASCII space and trims both ends.
    public static func collapsingWhitespace(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace { result.append(" ") }
                pendingSpace = false
                result.append(character)
            }
        }
        return result
    }

    /// Lowercased ASCII letters only, as typed into a Rime spelling (e.g. "Ni Hao!" -> "nihao").
    public static func asciiSpellingKey(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.compactMap { scalar in
            switch scalar.value {
            case 0x61...0x7A: scalar
            case 0x41...0x5A: Unicode.Scalar(scalar.value + 0x20)
            default: nil
            }
        }))
    }

    /// Han ideograph blocks: CJK Unified Ideographs (basic and Extensions A–J) and
    /// CJK Compatibility Ideographs (and their Supplement).
    static let hanIdeographRanges: [ClosedRange<UInt32>] = [
        0x3400...0x4DBF,   // Extension A
        0x4E00...0x9FFF,   // CJK Unified Ideographs
        0xF900...0xFAFF,   // CJK Compatibility Ideographs
        0x20000...0x2A6DF, // Extension B
        0x2A700...0x2EBEF, // Extensions C, D, E, F
        0x2EBF0...0x2EE5F, // Extension I
        0x2F800...0x2FA1F, // CJK Compatibility Ideographs Supplement
        0x30000...0x3134F, // Extension G
        0x31350...0x323AF, // Extension H
        0x323B0...0x3347F, // Extension J
    ]

    /// True when every scalar lies in one of `hanIdeographRanges`.
    public static func isAllHanIdeographs(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy(isHanIdeograph)
    }

    /// True when at least one scalar lies in one of `hanIdeographRanges`.
    public static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isHanIdeograph)
    }

    public static func isHanIdeograph(_ scalar: Unicode.Scalar) -> Bool {
        hanIdeographRanges.contains { $0.contains(scalar.value) }
    }

    /// Precomposed pinyin letters and the base letter each decomposes to (NFD), lowercase;
    /// `v` stands for `ü` in every tone. Combining marks (U+0300–U+036F) after a plain
    /// letter are dropped separately, so decomposed input reads the same.
    static let pinyinDecompositions: [UInt32: Unicode.Scalar] = {
        var table: [UInt32: Unicode.Scalar] = [:]
        let groups: [(Unicode.Scalar, [UInt32])] = [
            ("a", [0x101, 0xE1, 0x1CE, 0xE0, 0x100, 0xC1, 0x1CD, 0xC0]),
            ("e", [0x113, 0xE9, 0x11B, 0xE8, 0x112, 0xC9, 0x11A, 0xC8, 0xEA, 0xCA]),
            ("i", [0x12B, 0xED, 0x1D0, 0xEC, 0x12A, 0xCD, 0x1CF, 0xCC]),
            ("o", [0x14D, 0xF3, 0x1D2, 0xF2, 0x14C, 0xD3, 0x1D1, 0xD2]),
            ("u", [0x16B, 0xFA, 0x1D4, 0xF9, 0x16A, 0xDA, 0x1D3, 0xD9]),
            ("v", [0x1D6, 0x1D8, 0x1DA, 0x1DC, 0x1D5, 0x1D7, 0x1D9, 0x1DB, 0xFC, 0xDC]),
            ("n", [0x144, 0x148, 0x1F9, 0x143, 0x147, 0x1F8]),
            ("m", [0x1E3F, 0x1E3E]),
        ]
        for (base, scalars) in groups {
            for scalar in scalars { table[scalar] = base }
        }
        return table
    }()

    /// The canonical learning key of a pinyin spelling: tone marks and other diacritics
    /// dropped, ASCII letters lowercased, `ü` (also `u` + U+0308 and a typed `u:`) written
    /// `v`, syllables separated by exactly one space. Whitespace, `'`, `-`, tone digits, and
    /// every other non-letter separate syllables and are dropped. "Nǐ hǎo" -> "ni hao",
    /// "xi'an" -> "xi an", "ni3hao3" -> "ni hao", "lü4" -> "lv", "你好" -> "".
    public static func tonelessPinyinKey(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        var previousWasU = false
        func append(_ letter: Unicode.Scalar) {
            if pendingSpace, !result.isEmpty { result.append(" ") }
            pendingSpace = false
            result.append(letter)
            previousWasU = letter == "u"
        }
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x61...0x7A:
                append(scalar)
            case 0x41...0x5A:
                append(Unicode.Scalar(scalar.value + 0x20)!)
            case 0x0308 where previousWasU, 0x3A where previousWasU:
                // u + combining diaeresis, or a typed `u:`, is ü.
                result.removeLast()
                result.append("v")
                previousWasU = false
            case 0x0300...0x036F:
                continue
            case 0x30...0x39:
                pendingSpace = true
                previousWasU = false
            default:
                if let base = pinyinDecompositions[scalar.value] {
                    append(base)
                } else {
                    pendingSpace = true
                    previousWasU = false
                }
            }
        }
        return String(result)
    }

    /// `tonelessPinyinKey` without its separators ("ni hao" -> "nihao"): the key
    /// `noema_learned.tsv` and its Lua translator look typed input up by.
    public static func compactPinyinKey(_ text: String) -> String {
        String(String.UnicodeScalarView(tonelessPinyinKey(text).unicodeScalars.filter { $0 != " " }))
    }

    /// The number of syllables of a `tonelessPinyinKey` result.
    public static func syllableCount(ofPinyinKey key: String) -> Int {
        key.isEmpty ? 0 : key.unicodeScalars.reduce(1) { $0 + ($1 == " " ? 1 : 0) }
    }

    /// Every toneless Standard Mandarin syllable in `tonelessPinyinKey` spelling (`ü` as
    /// `v`: `lv`, `lve`, `nv`, `nve`), the closed set a full-pinyin learning key is made of.
    /// Bare initials (`b`, `n`, `zh`, ...) and the syllabic nasals `m`, `n`, `ng`, `hm`,
    /// `hng` are not in it, so an abbreviated (jianpin) spelling never passes for one.
    public static let standardMandarinSyllables: Set<String> = Set("""
        a ai an ang ao e ei en eng er o ou
        ba bai ban bang bao bei ben beng bi bian biao bie bin bing bo bu
        pa pai pan pang pao pei pen peng pi pian piao pie pin ping po pou pu
        ma mai man mang mao me mei men meng mi mian miao mie min ming miu mo mou mu
        fa fan fang fei fen feng fo fou fu
        da dai dan dang dao de dei den deng di dia dian diao die ding diu dong dou du duan dui dun duo
        ta tai tan tang tao te tei teng ti tian tiao tie ting tong tou tu tuan tui tun tuo
        na nai nan nang nao ne nei nen neng ni nian niang niao nie nin ning niu nong nou nu nuan nun nuo nv nve
        la lai lan lang lao le lei leng li lia lian liang liao lie lin ling liu lo long lou lu luan lun luo lv lve
        ga gai gan gang gao ge gei gen geng gong gou gu gua guai guan guang gui gun guo
        ka kai kan kang kao ke kei ken keng kong kou ku kua kuai kuan kuang kui kun kuo
        ha hai han hang hao he hei hen heng hong hou hu hua huai huan huang hui hun huo
        ji jia jian jiang jiao jie jin jing jiong jiu ju juan jue jun
        qi qia qian qiang qiao qie qin qing qiong qiu qu quan que qun
        xi xia xian xiang xiao xie xin xing xiong xiu xu xuan xue xun
        zha zhai zhan zhang zhao zhe zhei zhen zheng zhi zhong zhou zhu zhua zhuai zhuan zhuang zhui zhun zhuo
        cha chai chan chang chao che chen cheng chi chong chou chu chua chuai chuan chuang chui chun chuo
        sha shai shan shang shao she shei shen sheng shi shou shu shua shuai shuan shuang shui shun shuo
        ran rang rao re ren reng ri rong rou ru rua ruan rui run ruo
        za zai zan zang zao ze zei zen zeng zi zong zou zu zuan zui zun zuo
        ca cai can cang cao ce cen ceng ci cong cou cu cuan cui cun cuo
        sa sai san sang sao se sen seng si song sou su suan sui sun suo
        ya yan yang yao ye yi yin ying yo yong you yu yuan yue yun
        wa wai wan wang wei wen weng wo wu
        """.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))

    /// Whether `syllable` is one of `standardMandarinSyllables` (`ni`, `lv`, `er`; not `n`, `zh`).
    public static func isStandardMandarinSyllable(_ syllable: String) -> Bool {
        standardMandarinSyllables.contains(syllable)
    }

    /// The toneless Mandarin reading of all-Han `text`, one `standardMandarinSyllables`
    /// entry per character, from the system's Han-Latin transform (CFStringTransform,
    /// `kCFStringTransformMandarinLatin`): "女孩" -> ["nv", "hai"], "时间" -> ["shi", "jian"].
    /// Nil when `text` is empty or not all Han, or the reading is not one standard syllable
    /// per character. The Latin result goes through `tonelessPinyinKey`, which turns `ü`
    /// (precomposed, or `u` + U+0308) into `v` before it drops other marks; stripping all
    /// combining marks first would read `nǚ` as `nu`. A polyphone gets the transform's
    /// reading (银行 -> `yin xing`), so callers prefer a verified typed spelling.
    public static func mandarinPinyinSyllables(for text: String) -> [String]? {
        guard isAllHanIdeographs(text) else { return nil }
        let latin = NSMutableString(string: text)
        guard CFStringTransform(latin, nil, kCFStringTransformMandarinLatin, false) else { return nil }
        let syllables = tonelessPinyinKey(latin as String).split(separator: " ").map(String.init)
        guard syllables.count == text.unicodeScalars.count, syllables.allSatisfy(isStandardMandarinSyllable) else { return nil }
        return syllables
    }
}
