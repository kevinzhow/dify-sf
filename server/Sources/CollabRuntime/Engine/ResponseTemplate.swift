// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/base/template.py.
// See ../NOTICE.md.

/// The template a response node (answer, end) streams: text and variable references in order (graphon's `Template`).
public struct ResponseTemplate: Sendable, Hashable {
    public enum Segment: Sendable, Hashable {
        case text(String)
        case variable([String])
    }

    public var segments: [Segment]

    public init(_ segments: [Segment]) { self.segments = segments }

    /// `Template.from_answer_template`: `"Hello, {{#node1.name#}}"` -> text "Hello, ", variable `[node1, name]`.
    public static func fromAnswer(_ template: String) -> ResponseTemplate {
        var segments: [Segment] = []
        var cursor = template.startIndex
        for (range, key) in VariableTemplate.matches(in: template) {
            let text = String(template[cursor..<range.lowerBound])
            if !text.isEmpty { segments.append(.text(text)) }
            let parts = key.dropFirst().dropLast().split(separator: ".", omittingEmptySubsequences: false).map(String.init)
            segments.append(.variable(parts))
            cursor = range.upperBound
        }
        let tail = String(template[cursor...])
        if !tail.isEmpty { segments.append(.text(tail)) }
        return ResponseTemplate(segments)
    }

    /// `Template.from_end_outputs`: the outputs' selectors joined by newlines (a trailing newline dropped).
    public static func fromEndOutputs(_ outputs: [(variable: String, selector: [String])]) -> ResponseTemplate {
        var segments: [Segment] = []
        for (i, o) in outputs.enumerated() {
            if i > 0 { segments.append(.text("\n")) }
            if !o.selector.isEmpty { segments.append(.variable(o.selector)) }
        }
        if case .text? = segments.last { segments.removeLast() }
        return ResponseTemplate(segments)
    }
}
