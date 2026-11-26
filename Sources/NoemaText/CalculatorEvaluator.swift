import Foundation

/// The `v1` calculator: a recursive-descent parser over exact base-10 `Decimal` arithmetic,
/// so `0.1+0.2` is `0.3`. Never `NSExpression` (it raises Objective-C exceptions on bad
/// input and evaluates arbitrary key paths); `check-imports.sh` bans it in the IME.
///
/// Grammar, loosest first: `+ -`, then `* / %`, then unary `+ -`, then right-associative
/// `^` (so `-2^2` is `-4`, `2^-3` is `0.125`, `2^3^2` is `512`), then numbers and
/// parentheses. Full-width and typographic symbols are normalized first
/// (`normalize(_:)`); a trailing `=` is allowed.
///
/// Hard limits against hostile input: at most `maxLength` characters, `maxDepth` nested
/// parentheses or unary signs, and `|exponent| <= maxExponent`. Division or modulo by zero,
/// overflow, NaN, and infinity fail instead of producing a value.
public enum CalculatorEvaluator {
    public static let maxLength = 128
    public static let maxDepth = 32
    public static let maxExponent = 1000
    /// Fraction digits kept by `format(_:)`.
    public static let maxFractionDigits = 10

    public enum Failure: Error, Sendable, Hashable {
        case empty
        case tooLong
        case invalidCharacter
        case syntax
        case tooDeep
        case divisionByZero
        case exponentTooLarge
        case overflow
        case notFinite
    }

    /// The formatted value of `expression`, or nil when it does not evaluate.
    public static func evaluateFormatted(_ expression: String) -> String? {
        guard case .success(let value) = evaluate(expression) else { return nil }
        return format(value)
    }

    /// `expression` with full-width digits and operators mapped to ASCII, typographic
    /// operators (`× · ÷ −`) mapped to `* * / -`, and whitespace removed.
    public static func normalize(_ expression: String) -> String {
        var out = ""
        out.reserveCapacity(expression.count)
        for ch in expression {
            if ch.isWhitespace { continue }
            switch ch {
            case "＋": out.append("+")
            case "－", "−", "–": out.append("-")
            case "×", "·", "＊", "✕": out.append("*")
            case "÷", "／": out.append("/")
            case "（": out.append("(")
            case "）": out.append(")")
            case "％": out.append("%")
            case "＾": out.append("^")
            case "．": out.append(".")
            case "＝": out.append("=")
            default:
                if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first, (0xFF10...0xFF19).contains(scalar.value) {
                    out.unicodeScalars.append(Unicode.Scalar(scalar.value - 0xFF10 + 0x30)!)
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    public static func evaluate(_ expression: String) -> Result<Decimal, Failure> {
        var text = normalize(expression)
        if text.hasSuffix("=") { text.removeLast() }
        guard !text.isEmpty else { return .failure(.empty) }
        guard text.count <= maxLength else { return .failure(.tooLong) }
        let allowed = Set("0123456789+-*/%^.()")
        guard text.allSatisfy(allowed.contains) else { return .failure(.invalidCharacter) }
        var parser = Parser(bytes: Array(text.utf8))
        do {
            let value = try parser.parseExpression(depth: 0)
            guard parser.isAtEnd else { throw Failure.syntax }
            return .success(value)
        } catch let failure as Failure {
            return .failure(failure)
        } catch {
            return .failure(.syntax)
        }
    }

    /// `value` rounded to `maxFractionDigits`, without trailing zeros, `-0`, or exponent
    /// notation below 10^21; larger magnitudes use `%.10g`.
    public static func format(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, maxFractionDigits, .plain)
        if rounded.isZero { return "0" }
        let magnitude = rounded.magnitude
        if magnitude >= Decimal(string: "1e21")! {
            // No `locale:`: the C formatter writes `1e+22` with a `.` separator (a locale gives `1E+22`).
            return String(format: "%.10g", NSDecimalNumber(decimal: rounded).doubleValue)
        }
        var text = NSDecimalNumber(decimal: rounded).description(withLocale: Locale(identifier: "en_US_POSIX"))
        if text.contains(".") {
            while text.hasSuffix("0") { text.removeLast() }
            if text.hasSuffix(".") { text.removeLast() }
        }
        return text == "-0" ? "0" : text
    }

    // MARK: - Parser

    private struct Parser {
        let bytes: [UInt8]
        var position = 0

        var isAtEnd: Bool { position == bytes.count }

        private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

        private mutating func take(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            position += 1
            return true
        }

        /// expression := term (('+' | '-') term)*
        mutating func parseExpression(depth: Int) throws -> Decimal {
            guard depth < CalculatorEvaluator.maxDepth else { throw Failure.tooDeep }
            var value = try parseTerm(depth: depth)
            while let op = current, op == UInt8(ascii: "+") || op == UInt8(ascii: "-") {
                position += 1
                let rhs = try parseTerm(depth: depth)
                value = try op == UInt8(ascii: "+") ? Arithmetic.add(value, rhs) : Arithmetic.subtract(value, rhs)
            }
            return value
        }

        /// term := unary (('*' | '/' | '%') unary)*
        mutating func parseTerm(depth: Int) throws -> Decimal {
            var value = try parseUnary(depth: depth)
            while let op = current, op == UInt8(ascii: "*") || op == UInt8(ascii: "/") || op == UInt8(ascii: "%") {
                position += 1
                let rhs = try parseUnary(depth: depth)
                switch op {
                case UInt8(ascii: "*"): value = try Arithmetic.multiply(value, rhs)
                case UInt8(ascii: "/"): value = try Arithmetic.divide(value, rhs)
                default: value = try Arithmetic.remainder(value, rhs)
                }
            }
            return value
        }

        /// unary := ('+' | '-') unary | power
        mutating func parseUnary(depth: Int) throws -> Decimal {
            guard depth < CalculatorEvaluator.maxDepth else { throw Failure.tooDeep }
            if take(UInt8(ascii: "+")) { return try parseUnary(depth: depth + 1) }
            if take(UInt8(ascii: "-")) { return try Arithmetic.negate(parseUnary(depth: depth + 1)) }
            return try parsePower(depth: depth)
        }

        /// power := primary ('^' unary)?   (right-associative through `unary`)
        mutating func parsePower(depth: Int) throws -> Decimal {
            let base = try parsePrimary(depth: depth)
            guard take(UInt8(ascii: "^")) else { return base }
            let exponent = try parseUnary(depth: depth + 1)
            return try Arithmetic.power(base, exponent)
        }

        /// primary := number | '(' expression ')'
        mutating func parsePrimary(depth: Int) throws -> Decimal {
            if take(UInt8(ascii: "(")) {
                let value = try parseExpression(depth: depth + 1)
                guard take(UInt8(ascii: ")")) else { throw Failure.syntax }
                return value
            }
            return try parseNumber()
        }

        mutating func parseNumber() throws -> Decimal {
            let start = position
            var digits = 0
            var dots = 0
            while let byte = current {
                if byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9") {
                    digits += 1
                } else if byte == UInt8(ascii: ".") {
                    dots += 1
                } else {
                    break
                }
                position += 1
            }
            guard digits > 0, dots <= 1 else { throw Failure.syntax }
            var literal = String(decoding: bytes[start..<position], as: UTF8.self)
            if literal.hasPrefix(".") { literal = "0" + literal }
            if literal.hasSuffix(".") { literal.removeLast() }
            guard let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else {
                throw Failure.overflow
            }
            return value
        }
    }

    // MARK: - Arithmetic

    private enum Arithmetic {
        static func check(_ error: NSDecimalNumber.CalculationError, _ result: Decimal) throws -> Decimal {
            switch error {
            case .noError, .lossOfPrecision: break
            case .divideByZero: throw Failure.divisionByZero
            case .overflow, .underflow: throw Failure.overflow
            @unknown default: throw Failure.overflow
            }
            guard !result.isNaN else { throw Failure.notFinite }
            return result
        }

        static func add(_ a: Decimal, _ b: Decimal) throws -> Decimal {
            var (l, r, out) = (a, b, Decimal())
            return try check(NSDecimalAdd(&out, &l, &r, .plain), out)
        }

        static func subtract(_ a: Decimal, _ b: Decimal) throws -> Decimal {
            var (l, r, out) = (a, b, Decimal())
            return try check(NSDecimalSubtract(&out, &l, &r, .plain), out)
        }

        static func multiply(_ a: Decimal, _ b: Decimal) throws -> Decimal {
            var (l, r, out) = (a, b, Decimal())
            return try check(NSDecimalMultiply(&out, &l, &r, .plain), out)
        }

        static func divide(_ a: Decimal, _ b: Decimal) throws -> Decimal {
            guard !b.isZero else { throw Failure.divisionByZero }
            var (l, r, out) = (a, b, Decimal())
            return try check(NSDecimalDivide(&out, &l, &r, .plain), out)
        }

        static func negate(_ a: Decimal) throws -> Decimal {
            try subtract(Decimal(), a)
        }

        /// `a - b * trunc(a / b)`: the sign follows the dividend, as in C `fmod`.
        static func remainder(_ a: Decimal, _ b: Decimal) throws -> Decimal {
            guard !b.isZero else { throw Failure.divisionByZero }
            var quotient = try divide(a, b)
            var truncated = Decimal()
            NSDecimalRound(&truncated, &quotient, 0, quotient < 0 ? .up : .down)
            return try subtract(a, multiply(b, truncated))
        }

        static func power(_ base: Decimal, _ exponent: Decimal) throws -> Decimal {
            guard exponent.magnitude <= Decimal(CalculatorEvaluator.maxExponent) else { throw Failure.exponentTooLarge }
            var e = exponent
            var whole = Decimal()
            NSDecimalRound(&whole, &e, 0, .plain)
            if whole == exponent {
                let n = NSDecimalNumber(decimal: whole).intValue
                if n == 0 { return 1 }
                var b = base
                var out = Decimal()
                let raised = try check(NSDecimalPower(&out, &b, abs(n), .plain), out)
                return n > 0 ? raised : try divide(1, raised)
            }
            // A fractional exponent: Double, then back through its shortest decimal text.
            let value = pow(NSDecimalNumber(decimal: base).doubleValue, NSDecimalNumber(decimal: exponent).doubleValue)
            guard value.isFinite else { throw Failure.notFinite }
            guard let decimal = Decimal(string: "\(value)", locale: Locale(identifier: "en_US_POSIX")), !decimal.isNaN else {
                throw Failure.overflow
            }
            return decimal
        }
    }
}
