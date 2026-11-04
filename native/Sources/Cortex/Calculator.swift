import Foundation

/// A small expression evaluator (+ − × ÷ % ^ parentheses, a few functions). Written by hand
/// because NSExpression raises Objective-C exceptions on bad input, which would crash the app.
enum Calculator {
    /// Returns a formatted result if `text` is a math expression worth showing, else nil.
    static func evaluate(_ text: String) -> String? {
        let cleaned = text
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        // Must contain a digit and an operator/function, or it's just a number or a word.
        guard cleaned.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        let operators = CharacterSet(charactersIn: "+-*/%^()")
        guard cleaned.rangeOfCharacter(from: operators) != nil || cleaned.lowercased().contains("sqrt") else { return nil }
        var parser = Parser(Array(cleaned))
        guard let value = parser.parse(), value.isFinite else { return nil }
        return format(value)
    }

    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 { return String(Int64(v)) }
        let f = NumberFormatter()
        f.maximumFractionDigits = 10
        f.minimumFractionDigits = 0
        f.usesGroupingSeparator = false
        f.decimalSeparator = "."
        return f.string(from: NSNumber(value: v)) ?? String(v)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        init(_ c: [Character]) { chars = c }

        mutating func parse() -> Double? {
            guard let v = expression() else { return nil }
            skipSpaces()
            return i == chars.count ? v : nil
        }

        mutating func skipSpaces() { while i < chars.count, chars[i] == " " { i += 1 } }

        mutating func peek() -> Character? { skipSpaces(); return i < chars.count ? chars[i] : nil }

        mutating func expression() -> Double? {
            guard var left = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let right = term() else { return nil }
                left = c == "+" ? left + right : left - right
            }
            return left
        }

        mutating func term() -> Double? {
            guard var left = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" || c == "%" {
                i += 1
                guard let right = power() else { return nil }
                switch c {
                case "*": left *= right
                case "/": if right == 0 { return nil }; left /= right
                default: if right == 0 { return nil }; left = left.truncatingRemainder(dividingBy: right)
                }
            }
            return left
        }

        mutating func power() -> Double? {
            guard let base = unary() else { return nil }
            if let c = peek(), c == "^" {
                i += 1
                guard let exp = power() else { return nil }
                return pow(base, exp)
            }
            return base
        }

        mutating func unary() -> Double? {
            if let c = peek(), c == "-" { i += 1; return unary().map { -$0 } }
            if let c = peek(), c == "+" { i += 1; return unary() }
            return primary()
        }

        mutating func primary() -> Double? {
            guard let c = peek() else { return nil }
            if c == "(" {
                i += 1
                guard let v = expression(), peek() == ")" else { return nil }
                i += 1
                return v
            }
            if c.isLetter {
                var name = ""
                while i < chars.count, chars[i].isLetter { name.append(chars[i]); i += 1 }
                switch name.lowercased() {
                case "pi": return Double.pi
                case "e": return M_E
                case "sqrt", "sin", "cos", "tan", "ln", "log", "abs":
                    guard peek() == "(" else { return nil }
                    i += 1
                    guard let v = expression(), peek() == ")" else { return nil }
                    i += 1
                    switch name.lowercased() {
                    case "sqrt": return v < 0 ? nil : v.squareRoot()
                    case "sin": return sin(v)
                    case "cos": return cos(v)
                    case "tan": return tan(v)
                    case "ln": return v <= 0 ? nil : log(v)
                    case "log": return v <= 0 ? nil : log10(v)
                    default: return abs(v)
                    }
                default: return nil
                }
            }
            var digits = ""
            while i < chars.count, chars[i].isNumber || chars[i] == "." { digits.append(chars[i]); i += 1 }
            return Double(digits)
        }
    }
}
