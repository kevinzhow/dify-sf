// Ported from graphon 0.7.0 (https://github.com/langgenius/graphon, Apache-2.0): graphon/nodes/llm/reasoning.py.
// See ../../NOTICE.md.

import Foundation

/// Inline `<think>...</think>` reasoning in LLM output: stripped while streaming (`separated` mode) by
/// `ThinkStreamFilter`, and in one pass from the buffered text by `Reasoning.split`.
public enum Reasoning {
    static let openAttrMaxChars = 512
    static let openPrefix = "<think"
    static let closeTag = "</think>"
    static let openTag = "<think(?:\\s[^<>]{0,\(openAttrMaxChars)})?>"
    static let thinkPattern = try! NSRegularExpression(pattern: "\(openTag)(.*?)</think>", options: [.caseInsensitive, .dotMatchesLineSeparators])
    static let openRE = try! NSRegularExpression(pattern: openTag, options: [.caseInsensitive])
    static let closeRE = try! NSRegularExpression(pattern: "</think>", options: [.caseInsensitive])
    static let openTrailingRE = try! NSRegularExpression(pattern: "\(openTag)((?:(?!</think>)[\\s\\S])*)\\z", options: [.caseInsensitive])
    static let blankRuns = try! NSRegularExpression(pattern: "\\n\\s*\\n")
    static let openPrefixMaxLen = openPrefix.count + 1 + openAttrMaxChars

    /// `split_reasoning(text, format)`: `tagged` keeps the text; `separated` removes the think blocks (and a trailing
    /// unclosed one), collapses blank-line runs, strips, and returns the reasoning parts joined by newlines.
    public static func split(_ text: String, format: String) -> (clean: String, reasoning: String) {
        if format == "tagged" { return (text, "") }
        let ns = text as NSString
        var parts: [String] = []
        for m in thinkPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let r = ns.substring(with: m.range(at: 1)).pythonStrip()
            if !r.isEmpty { parts.append(r) }
        }
        var clean = thinkPattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let cns = clean as NSString
        if let t = openTrailingRE.firstMatch(in: clean, range: NSRange(location: 0, length: cns.length)) {
            let r = cns.substring(with: t.range(at: 1)).pythonStrip()
            if !r.isEmpty { parts.append(r) }
            clean = cns.substring(to: t.range.location)
        }
        clean = blankRuns.stringByReplacingMatches(in: clean, range: NSRange(location: 0, length: (clean as NSString).length), withTemplate: "\n\n")
        return (clean.pythonStrip(), parts.joined(separator: "\n"))
    }

    /// `extract_stream_reasoning`.
    public static func extractStream(_ fullText: String, format: String) -> (clean: String, reasoning: String) {
        format == "tagged" ? (fullText, "") : split(fullText, format: format)
    }
}

/// `ThinkStreamFilter`: chunk-boundary-safe separation of `<think>` reasoning from the answer text.
public struct ThinkStreamFilter: Sendable {
    public enum Piece: Sendable, Equatable {
        case text(String)
        case reasoning(String)
    }

    private var insideThink = false
    private var hold = ""
    private var seenClean = false

    public init() {}

    public mutating func feed(_ textPart: String) -> [Piece] {
        var pieces: [Piece] = []
        var work = hold + textPart
        hold = ""
        while !work.isEmpty {
            let ns = work as NSString
            let all = NSRange(location: 0, length: ns.length)
            if !insideThink {
                if let m = Reasoning.openRE.firstMatch(in: work, range: all) {
                    appendText(&pieces, ns.substring(to: m.range.location))
                    insideThink = true
                    work = ns.substring(from: m.range.location + m.range.length)
                    continue
                }
                let keep = Self.openSuffixLength(work)
                if keep > 0 {
                    appendText(&pieces, String(work.unicodeScalars.dropLast(keep)))
                    hold = String(work.unicodeScalars.suffix(keep))
                } else {
                    appendText(&pieces, work)
                }
                work = ""
            } else {
                if let m = Reasoning.closeRE.firstMatch(in: work, range: all) {
                    appendReasoning(&pieces, ns.substring(to: m.range.location))
                    insideThink = false
                    work = ns.substring(from: m.range.location + m.range.length)
                    continue
                }
                let keep = Self.closeSuffixLength(work)
                if keep > 0 {
                    appendReasoning(&pieces, String(work.unicodeScalars.dropLast(keep)))
                    hold = String(work.unicodeScalars.suffix(keep))
                } else {
                    appendReasoning(&pieces, work)
                }
                work = ""
            }
        }
        return pieces
    }

    public mutating func finalize() -> [Piece] {
        let remainder = hold
        hold = ""
        if insideThink { return remainder.isEmpty ? [] : [.reasoning(remainder)] }
        let clean = stripLeading(remainder)
        return clean.isEmpty ? [] : [.text(clean)]
    }

    private mutating func appendText(_ pieces: inout [Piece], _ clean: String) {
        let c = stripLeading(clean)
        if !c.isEmpty { pieces.append(.text(c)) }
    }

    private func appendReasoning(_ pieces: inout [Piece], _ r: String) {
        if !r.isEmpty { pieces.append(.reasoning(r)) }
    }

    private mutating func stripLeading(_ clean: String) -> String {
        if seenClean || clean.isEmpty { return clean }
        let stripped = clean.pythonLStrip()
        if !stripped.isEmpty { seenClean = true }
        return stripped
    }

    /// Length (in unicode scalars) of the trailing suffix that could still become `<think...>`.
    static func openSuffixLength(_ work: String) -> Int {
        let scalars = Array(work.unicodeScalars)
        guard let lt = scalars.lastIndex(of: "<") else { return 0 }
        let tail = String(String.UnicodeScalarView(scalars[lt...]))
        let tailLower = tail.lowercased()
        let tailCount = scalars.count - lt
        if tail.contains(">") { return 0 }
        if tailCount <= Reasoning.openPrefix.count {
            return Reasoning.openPrefix.hasPrefix(tailLower) ? tailCount : 0
        }
        let afterPrefix = scalars[lt + Reasoning.openPrefix.count]
        if tailLower.hasPrefix(Reasoning.openPrefix), afterPrefix.properties.isWhitespace, tailCount <= Reasoning.openPrefixMaxLen {
            return tailCount
        }
        return 0
    }

    /// Length of the trailing suffix that could still become `</think>`.
    static func closeSuffixLength(_ work: String) -> Int {
        let scalars = Array(work.unicodeScalars)
        let maxK = min(scalars.count, Reasoning.closeTag.count - 1)
        var k = maxK
        while k > 0 {
            let suffix = String(String.UnicodeScalarView(scalars[(scalars.count - k)...])).lowercased()
            if Reasoning.closeTag.hasPrefix(suffix) { return k }
            k -= 1
        }
        return 0
    }
}

extension String {
    /// Python's `str.strip()` (Unicode whitespace).
    func pythonStrip() -> String {
        let s = unicodeScalars
        guard let first = s.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        let last = s.lastIndex(where: { !$0.properties.isWhitespace })!
        return String(s[first...last])
    }

    /// Python's `str.lstrip()`.
    func pythonLStrip() -> String {
        let s = unicodeScalars
        guard let first = s.firstIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(s[first...])
    }
}
