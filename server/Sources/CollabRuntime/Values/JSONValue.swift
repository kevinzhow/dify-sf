import Foundation

/// A JSON value whose objects keep their key order, as Python's `dict` does. The runtime needs the order: graphon renders
/// objects into prompts with `json.dumps` (insertion order), and node outputs are ordered dicts. Integers and fractional
/// numbers stay apart (`1` vs `1.0`), as in Python.
public indirect enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let s) = self { return s }; return nil }
    public var object: JSONObject? { if case .object(let o) = self { return o }; return nil }
    public var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var isNull: Bool { self == .null }
    public var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d) where d.isFinite && d == d.rounded(.towardZero) && abs(d) < 9e15: return Int(d)
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    /// Python's truthiness (`not value`).
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .double(let d): return d != 0
        case .string(let s): return !s.isEmpty
        case .array(let a): return !a.isEmpty
        case .object(let o): return !o.isEmpty
        }
    }
}

/// An insertion-ordered string-keyed map (Python's `dict`). Replacing a key keeps its position; removing it drops it.
public struct JSONObject: Hashable, Sendable, Codable, Sequence, ExpressibleByDictionaryLiteral {
    public private(set) var keys: [String] = []
    private var storage: [String: JSONValue] = [:]

    public init() {}
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        for (k, v) in elements { self[k] = v }
    }
    public init(_ pairs: [(String, JSONValue)]) {
        for (k, v) in pairs { self[k] = v }
    }

    public subscript(key: String) -> JSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }
    public var values: [JSONValue] { keys.map { storage[$0]! } }

    public func makeIterator() -> AnyIterator<(key: String, value: JSONValue)> {
        var i = 0
        return AnyIterator {
            guard i < keys.count else { return nil }
            defer { i += 1 }
            return (keys[i], storage[keys[i]]!)
        }
    }

    /// Python's `a | b`: `b`'s keys win, new keys are appended.
    public func merging(_ other: JSONObject) -> JSONObject {
        var out = self
        for (k, v) in other { out[k] = v }
        return out
    }

    public static func == (a: JSONObject, b: JSONObject) -> Bool {
        // Python's dict equality ignores order.
        a.storage == b.storage
    }

    public func hash(into h: inout Hasher) {
        for k in keys.sorted() { h.combine(k); h.combine(storage[k]!) }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(stringLiteral v: String) { self = .string(v) }
    public init(integerLiteral v: Int) { self = .int(v) }
    public init(floatLiteral v: Double) { self = .double(v) }
    public init(booleanLiteral v: Bool) { self = .bool(v) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(JSONObject(elements.map { ($0.0, $0.1) })) }
    public init(nilLiteral: ()) { self = .null }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible, Sendable {
    public var description: String
}

extension JSONValue {
    /// Parses JSON text keeping object key order (a repeated key keeps its first position and its last value, as
    /// Python's `json.loads`). Numbers without a fraction or exponent are integers when they fit.
    public static func parse(_ data: some Collection<UInt8>) throws -> JSONValue {
        var p = Parser(bytes: Array(data))
        p.skipWhitespace()
        let v = try p.value(depth: 0)
        p.skipWhitespace()
        guard p.i == p.bytes.count else { throw JSONParseError(description: "trailing characters at offset \(p.i)") }
        return v
    }

    public static func parse(_ text: String) throws -> JSONValue { try parse(Array(text.utf8)) }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0

        mutating func skipWhitespace() {
            while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
        }

        func fail(_ m: String) -> JSONParseError { JSONParseError(description: "\(m) at offset \(i)") }

        mutating func value(depth: Int) throws -> JSONValue {
            guard depth < 512 else { throw fail("nesting too deep") }
            guard i < bytes.count else { throw fail("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var o = JSONObject()
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
                    let k = try string()
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected ':'") }
                    i += 1
                    skipWhitespace()
                    o[k] = try value(depth: depth + 1)
                    skipWhitespace()
                    guard i < bytes.count else { throw fail("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                    throw fail("expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var a: [JSONValue] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true {
                    skipWhitespace()
                    a.append(try value(depth: depth + 1))
                    skipWhitespace()
                    guard i < bytes.count else { throw fail("unexpected end") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                    throw fail("expected ',' or ']'")
                }
            case UInt8(ascii: "\""):
                return .string(try string())
            case UInt8(ascii: "t"): try literal("true"); return .bool(true)
            case UInt8(ascii: "f"): try literal("false"); return .bool(false)
            case UInt8(ascii: "n"): try literal("null"); return .null
            case UInt8(ascii: "N"): try literal("NaN"); return .double(.nan)
            case UInt8(ascii: "I"): try literal("Infinity"); return .double(.infinity)
            default: return try number()
            }
        }

        mutating func literal(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw fail("invalid literal") }
            i += u.count
        }

        mutating func number() throws -> JSONValue {
            let start = i
            var fractional = false
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "I") { try literal("Infinity"); return .double(-.infinity) }
            }
            while i < bytes.count {
                let c = bytes[i]
                if c >= 0x30 && c <= 0x39 { i += 1; continue }
                if c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E") || c == UInt8(ascii: "+") || c == UInt8(ascii: "-") {
                    fractional = true
                    i += 1
                    continue
                }
                break
            }
            guard i > start else { throw fail("unexpected character") }
            let text = String(decoding: bytes[start..<i], as: UTF8.self)
            if !fractional, let n = Int(text) { return .int(n) }
            guard let d = Double(text) else { throw fail("invalid number '\(text)'") }
            return .double(d)
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw fail("bad \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                i += 1
                v <<= 4
                switch c {
                case 0x30...0x39: v |= UInt32(c - 0x30)
                case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
                case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
                default: throw fail("bad \\u escape")
                }
            }
            return v
        }

        mutating func string() throws -> String {
            i += 1  // opening quote
            var out: [UInt8] = []
            while true {
                guard i < bytes.count else { throw fail("unterminated string") }
                let c = bytes[i]
                i += 1
                if c == UInt8(ascii: "\"") { break }
                if c != UInt8(ascii: "\\") { out.append(c); continue }
                guard i < bytes.count else { throw fail("unterminated escape") }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try hex4()
                    if (0xD800...0xDBFF).contains(scalar), i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if (0xDC00...0xDFFF).contains(low) {
                            scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let u = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(u)).utf8))
                default: throw fail("bad escape")
                }
            }
            return String(decoding: out, as: UTF8.self)
        }
    }
}

// MARK: - Encoding

extension JSONValue {
    /// Compact JSON for the wire and the database (no spaces, key order kept, non-ASCII as is, non-finite numbers as null).
    public func compactJSON() -> String {
        var out = ""
        write(&out, python: false, indent: nil, level: 0)
        return out
    }

    public func compactData() -> Data { Data(compactJSON().utf8) }

    /// Python's `json.dumps(value, ensure_ascii=False)` (separators `", "` and `": "`), or with `indent` its indented form
    /// (separators `","` and `": "`).
    public func pythonJSONDumps(indent: Int? = nil) -> String {
        var out = ""
        write(&out, python: true, indent: indent, level: 0)
        return out
    }

    private func write(_ out: inout String, python: Bool, indent: Int?, level: Int) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d):
            if d.isNaN { out += python ? "NaN" : "null" }
            else if d.isInfinite { out += python ? (d < 0 ? "-Infinity" : "Infinity") : "null" }
            else { out += PythonText.floatRepr(d) }
        case .string(let s): JSONValue.writeString(s, &out)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (n, x) in a.enumerated() {
                if n > 0 { out += python && indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                x.write(&out, python: python, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{"
            for (n, (k, v)) in o.enumerated() {
                if n > 0 { out += python && indent == nil ? ", " : "," }
                if let indent { out += "\n" + String(repeating: " ", count: indent * (level + 1)) }
                JSONValue.writeString(k, &out)
                out += python ? ": " : ":"
                v.write(&out, python: python, indent: indent, level: level + 1)
            }
            if let indent { out += "\n" + String(repeating: " ", count: indent * level) }
            out += "}"
        }
    }

    /// JSON string escaping as Python's `json.dumps(..., ensure_ascii=False)`: quotes, backslashes and control characters.
    static func writeString(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    let h = String(u.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - h.count) + h
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
    }
}

// Snapshot encoding opts into literal text: ordinary Codable JSON sorts object keys and may turn 1.0 into 1.
// The default API encoding remains unchanged.
extension CodingUserInfoKey {
    static let runtimeSnapshot = CodingUserInfoKey(rawValue: "dify-sf.runtime-snapshot")!
}

extension JSONValue: Codable {
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if decoder.userInfo[.runtimeSnapshot] as? Bool == true {
            self = try JSONValue.parse(c.decode(String.self))
            return
        }
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        if let d = try? c.decode(Double.self) { self = .double(d); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let m = try? c.decode([String: JSONValue].self) {
            // Codable loses the order: keys sorted (use `parse` where the order matters).
            self = .object(JSONObject(m.keys.sorted().map { ($0, m[$0]!) }))
            return
        }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "not JSON")
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        if encoder.userInfo[.runtimeSnapshot] as? Bool == true {
            try c.encode(compactJSON())
            return
        }
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): if d.isFinite { try c.encode(d) } else { try c.encodeNil() }
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o):
            var m: [String: JSONValue] = [:]
            for (k, v) in o { m[k] = v }
            try c.encode(m)
        }
    }
}
