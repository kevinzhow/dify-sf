// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0):
// graphon/nodes/base/variable_template_parser.py, graphon/variables/template_resolution.py,
// graphon/nodes/base/entities.py (VariableSelector). See NOTICE.md.

/// A named reference to a value (`{"variable": "#node.text#", "value_selector": ["node", "text"]}`).
public struct VariableSelector: Hashable, Sendable {
    public var variable: String
    public var valueSelector: [String]
    public init(variable: String, valueSelector: [String]) {
        self.variable = variable
        self.valueSelector = valueSelector
    }

    /// From node data JSON (`{"variable", "value_selector"}`); nil when malformed.
    public init?(json: JSONValue) {
        guard let v = json["variable"]?.string, let sel = json["value_selector"]?.array else { return nil }
        let parts = sel.compactMap(\.string)
        guard parts.count == sel.count else { return nil }
        self.init(variable: v, valueSelector: parts)
    }
}

/// `{{#node_id.var.attr#}}` references in prompt templates.
public enum VariableTemplate {
    /// One reference: `{{#` + a node id of 1-50 `[a-zA-Z0-9_]` + 1-10 `.name` parts (`[a-zA-Z_][a-zA-Z0-9_]{0,29}`) + `#}}`.
    /// Returns the range of the whole match and the inner key (`#node.var#`).
    static func matches(in template: String) -> [(range: Range<String.Index>, key: String)] {
        var out: [(Range<String.Index>, String)] = []
        let chars = template
        var i = chars.startIndex
        while let open = chars[i...].range(of: "{{#") {
            if let (end, key) = scanReference(chars, from: open.upperBound) {
                out.append((open.lowerBound..<end, key))
                i = end
            } else {
                i = chars.index(after: open.lowerBound)
            }
        }
        return out
    }

    /// Scans `node.var...#}}` starting after `{{#`; returns the end index (after `}}`) and the key `#node.var...#`.
    private static func scanReference(_ s: String, from start: String.Index) -> (String.Index, String)? {
        func isAlnumUnderscore(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "_") }
        func isAlphaUnderscore(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c == "_") }
        var i = start
        var nodeLen = 0
        while i < s.endIndex, isAlnumUnderscore(s[i]), nodeLen < 51 { nodeLen += 1; i = s.index(after: i) }
        guard (1...50).contains(nodeLen) else { return nil }
        var parts = 0
        while i < s.endIndex, s[i] == "." {
            let afterDot = s.index(after: i)
            guard afterDot < s.endIndex, isAlphaUnderscore(s[afterDot]) else { break }
            var j = s.index(after: afterDot)
            var len = 1
            while j < s.endIndex, isAlnumUnderscore(s[j]), len < 31 { len += 1; j = s.index(after: j) }
            guard len <= 30 else { return nil }
            parts += 1
            i = j
        }
        guard (1...10).contains(parts) else { return nil }
        guard s[i...].hasPrefix("#}}") else { return nil }
        let inner = String(s[start..<i])
        return (s.index(i, offsetBy: 3), "#" + inner + "#")
    }

    /// `VariableTemplateParser(template).extract_variable_selectors()`: one selector per distinct key (graphon builds them
    /// from a set; here in first-appearance order).
    public static func extractSelectors(_ template: String) -> [VariableSelector] {
        var seen = Set<String>()
        var out: [VariableSelector] = []
        for (_, key) in matches(in: template) where seen.insert(key).inserted {
            let parts = key.replacingOccurrences(of: "#", with: "").split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            if parts.count < VariablePool.selectorsLength { continue }
            out.append(VariableSelector(variable: key, valueSelector: parts))
        }
        return out
    }

    /// `convert_template(pool, template)`: the template split at references; a reference whose value exists becomes that
    /// value, anything else (text, unknown references) a string segment.
    public static func convert(_ pool: VariablePool, _ template: String) -> SegmentGroup {
        // `VARIABLE_PATTERN.split` yields the texts and the captures (`node.var...`) alike, and every non-empty part that
        // contains a dot is looked up (a plain text part that happens to be a selector, e.g. `sys.query`, too).
        var segments: [Segment] = []
        var cursor = template.startIndex
        func part(_ s: String) {
            if s.isEmpty { return }
            if s.contains("."), let v = pool.get(s.split(separator: ".", omittingEmptySubsequences: false).map(String.init)) {
                segments.append(v)
            } else {
                segments.append(Segment(.string, .string(s)))
            }
        }
        for (range, key) in matches(in: template) {
            part(String(template[cursor..<range.lowerBound]))
            part(String(key.dropFirst().dropLast()))
            cursor = range.upperBound
        }
        part(String(template[cursor...]))
        return SegmentGroup(segments)
    }
}
