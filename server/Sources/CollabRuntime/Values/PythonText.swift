/// Python's text forms of JSON-like values (`str()`, `repr()`, float `repr`), which graphon puts into prompts and outputs
/// (`Segment.text` is `str(self.value)` for most segments).
public enum PythonText {
    /// `repr(float)`: the shortest round-tripping digits, in fixed notation for decimal exponents -4..15 (with `.0` when
    /// integral) and scientific notation otherwise (`1e-05`, `1e+16`, `1.5e+20`).
    public static func floatRepr(_ d: Double) -> String {
        if d.isNaN { return "nan" }
        if d.isInfinite { return d < 0 ? "-inf" : "inf" }
        if d == 0 { return d.sign == .minus ? "-0.0" : "0.0" }
        // Swift's description is also the shortest round-tripping representation; take its digits and exponent.
        var s = "\(abs(d))"
        var exp10 = 0
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exp10 = Int(s[s.index(after: e)...]) ?? 0
            s = String(s[..<e])
        }
        var intPart = s, fracPart = ""
        if let dot = s.firstIndex(of: ".") {
            intPart = String(s[..<dot])
            fracPart = String(s[s.index(after: dot)...])
        }
        // digits d1 d2 ... with the value = 0.d1d2... * 10^decpt
        var digits = intPart + fracPart
        var decpt = intPart.count + exp10
        while digits.first == "0", digits.count > 1 { digits.removeFirst(); decpt -= 1 }
        while digits.last == "0", digits.count > 1 { digits.removeLast() }
        let sign = d < 0 ? "-" : ""
        if decpt > -4 && decpt <= 16 {
            if decpt <= 0 {
                return sign + "0." + String(repeating: "0", count: -decpt) + digits
            }
            if decpt >= digits.count {
                return sign + digits + String(repeating: "0", count: decpt - digits.count) + ".0"
            }
            let i = digits.index(digits.startIndex, offsetBy: decpt)
            return sign + String(digits[..<i]) + "." + String(digits[i...])
        }
        let e = decpt - 1
        let mantissa = digits.count == 1 ? digits : String(digits.first!) + "." + String(digits.dropFirst())
        let es = e < 0 ? "-" + pad2(-e) : "+" + pad2(e)
        return sign + mantissa + "e" + es
    }

    private static func pad2(_ n: Int) -> String { n < 10 ? "0\(n)" : "\(n)" }

    /// `str(value)` of the Python object a JSON value stands for.
    public static func str(_ v: JSONValue) -> String {
        if case .string(let s) = v { return s }
        return repr(v)
    }

    /// `repr(value)`: `None`, `True`, `'text'`, `[1, 2.5]`, `{'a': 1}`.
    public static func repr(_ v: JSONValue) -> String {
        switch v {
        case .null: return "None"
        case .bool(let b): return b ? "True" : "False"
        case .int(let i): return String(i)
        case .double(let d): return floatRepr(d)
        case .string(let s): return stringRepr(s)
        case .array(let a): return "[" + a.map(repr).joined(separator: ", ") + "]"
        case .object(let o): return "{" + o.map { stringRepr($0.key) + ": " + repr($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// `repr(str)`: single quotes unless the text has a single quote and no double quote; backslash escapes for the quote,
    /// backslashes, `\n`, `\r`, `\t` and other control characters.
    public static func stringRepr(_ s: String) -> String {
        let useDouble = s.contains("'") && !s.contains("\"")
        let q: Character = useDouble ? "\"" : "'"
        var out = String(q)
        for u in s.unicodeScalars {
            switch u {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if Character(u) == q { out += "\\" + String(q); continue }
                if u.value < 0x20 || u.value == 0x7F || (0x80..<0xA0).contains(u.value) {
                    let h = String(u.value, radix: 16)
                    out += "\\x" + (h.count < 2 ? "0" + h : h)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out.append(q)
        return out
    }
}
