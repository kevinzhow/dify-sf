import Foundation
import Markdown

/// Dify's `render_markdown_body` and `sanitize_subject` (api/controllers/console/app/human_input.py,
/// `libs/helper.py`): a human-input email body is **sanitized first** (the template's own markup never reaches the message)
/// and then rendered as Markdown into the small set of tags a mail may carry.
///
/// The rendering is `swift-markdown`'s CommonMark walk (headings, paragraphs, emphasis, code, links, images, lists,
/// quotes, rules, fenced code) emitted as HTML, with HTML escaped on the way out: nothing a template or a rendered value
/// carries can become an attribute, a tag or an event handler. Only `http(s)` and `mailto:` links and `data:`-free images
/// survive (Dify's allowed protocols).
public enum MailMarkdown {
    /// The tags Dify's `bleach.clean` allows after rendering.
    public static let allowedTags: Set<String> = ["p", "br", "strong", "b", "em", "i", "u", "code", "pre", "blockquote",
                                                  "ul", "ol", "li", "h1", "h2", "h3", "h4", "h5", "h6", "a", "hr"]
    /// What a link's `href` may start with.
    public static let allowedSchemes: [String] = ["http://", "https://", "mailto:", "#"]

    /// `bleach.clean(body, tags=[], attributes={}, strip=True)`: the template's own HTML is removed, the text stays.
    public static func cleanTemplate(_ body: String) -> String {
        stripTags(body)
    }

    /// Dify's `sanitize_subject`: no line breaks, no HTML, one line.
    public static func sanitizeSubject(_ subject: String) -> String {
        let flat = subject.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        return stripTags(flat).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Markdown → the HTML a mail may carry.
    public static func render(_ markdown: String) -> String {
        var out: [String] = []
        // No smart quotes: a rendered value's `"` stays a plain quote (a mail, not a typographic page).
        let document = Document(parsing: markdown, options: [.parseBlockDirectives, .parseSymbolLinks, .disableSmartOpts])
        emit(document, into: &out)
        return out.joined()
    }

    // MARK: - rendering

    private static func emit(_ node: any Markup, into out: inout [String]) {
        switch node {
        case let heading as Heading:
            out.append("<h\(heading.level)>")
            emitChildren(heading, into: &out)
            out.append("</h\(heading.level)>")
        case let paragraph as Paragraph:
            out.append("<p>")
            emitChildren(paragraph, into: &out)
            out.append("</p>")
        case let quote as BlockQuote:
            out.append("<blockquote>")
            emitChildren(quote, into: &out)
            out.append("</blockquote>")
        case let list as UnorderedList:
            out.append("<ul>")
            emitChildren(list, into: &out)
            out.append("</ul>")
        case let list as OrderedList:
            out.append("<ol>")
            emitChildren(list, into: &out)
            out.append("</ol>")
        case let item as ListItem:
            out.append("<li>")
            emitChildren(item, into: &out)
            out.append("</li>")
        case let code as CodeBlock:
            out.append("<pre><code>")
            out.append(escape(code.code))
            out.append("</code></pre>")
        case let html as HTMLBlock:
            // Raw HTML in the rendered text is shown as text, never interpreted (Dify's sanitizer strips it too).
            let text = stripTags(html.rawHTML)
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("<p>" + escape(text) + "</p>") }
        case is ThematicBreak:
            out.append("<hr>")
        case let text as Text:
            out.append(escape(text.string))
        case let strong as Strong:
            out.append("<strong>")
            emitChildren(strong, into: &out)
            out.append("</strong>")
        case let emphasis as Emphasis:
            out.append("<em>")
            emitChildren(emphasis, into: &out)
            out.append("</em>")
        case let code as InlineCode:
            out.append("<code>" + escape(code.code) + "</code>")
        case let link as Markdown.Link:
            let destination = safeDestination(link.destination ?? "")
            guard !destination.isEmpty else {
                // A destination a mail may not carry: its text stays, the link does not.
                emitChildren(link, into: &out)
                break
            }
            out.append("<a href=\"" + escapeAttribute(destination) + "\">")
            emitChildren(link, into: &out)
            out.append("</a>")
        case let image as Markdown.Image:
            // A mail may reference a safe image; its alt text is what Dify keeps when the source is not allowed.
            let source = safeDestination(image.source ?? "")
            if source.isEmpty {
                out.append(escape(image.plainText))
            } else {
                out.append("<img src=\"" + escapeAttribute(source) + "\" alt=\"" + escapeAttribute(image.plainText) + "\" />")
            }
        case let soft as SoftBreak:
            _ = soft
            out.append("\n")
        case is LineBreak:
            out.append("<br>")
        case is InlineHTML:
            // Never interpreted: the tag itself is dropped (only its text would have been shown, and it carries none).
            break
        default:
            emitChildren(node, into: &out)
        }
    }

    private static func emitChildren(_ node: any Markup, into out: inout [String]) {
        for child in node.children { emit(child, into: &out) }
    }

    /// A link or image destination that a mail may carry; empty when it is not allowed (Dify's protocol allow-list).
    public static func safeDestination(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = value.lowercased()
        // A destination with whitespace or a quote cannot be written into an attribute without changing its meaning.
        guard !value.contains("\""), !value.contains("<"), !value.contains(">"), !value.contains(where: \.isWhitespace) else { return "" }
        return allowedSchemes.contains(where: { lower.hasPrefix($0) }) ? value : ""
    }

    // MARK: - escaping

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    public static func escapeAttribute(_ text: String) -> String {
        escape(text).replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    // MARK: - the template sanitizer

    /// Removes tags (and their attributes) from text: `<b>x</b>` → `x`, `<script>a</script>` → `a`, `<no-reply@x>` → ``.
    /// A tag is `<` + an optional `/` or `!`/`?` + a name that starts with a letter, up to the next `>` (bleach's
    /// grammar); a `<` that does not begin one (`a < b`) is text and stays.
    public static func stripTags(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "<" else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            var cursor = text.index(after: index)
            if cursor < text.endIndex, text[cursor] == "/" || text[cursor] == "!" || text[cursor] == "?" {
                cursor = text.index(after: cursor)
            }
            let startsTag = cursor < text.endIndex && text[cursor].isLetter
            guard startsTag, let close = text[cursor...].firstIndex(of: ">") else {
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            index = text.index(after: close)
        }
        return out
    }
}
