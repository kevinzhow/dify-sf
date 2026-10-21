import Foundation
import Testing
@testable import CollabServer
import CollabMarkdown

/// Dify's mail body rendering (`render_markdown_body`) as this server does it: the template is cleaned, then rendered by a
/// real CommonMark parser, with links limited to the allowed protocols and nothing able to become an attribute.
@Suite("Mail markdown")
struct MailMarkdownTests {
    /// Winnie's independent regression: a link whose URL carries a quote must not produce an attribute.
    @Test func aQuoteInALinkCannotCreateAnAttribute() {
        let html = MailMarkdown.render(#"[open](https://example.test/"onmouseover="alert(1))"#)
        #expect(!html.contains("onmouseover"), "a markdown link became an executable attribute: \(html)")
        #expect(!html.contains("<a href=\"https://example.test/\"onmouseover"), "\(html)")
    }

    @Test func dangerousSchemesDoNotBecomeLinks() {
        for source in ["javascript:alert(1)", "JaVaScRiPt:alert(1)", "data:text/html;base64,AAA", "vbscript:x"] {
            let html = MailMarkdown.render("[x](\(source))")
            #expect(!html.lowercased().contains("href=\"javascript"), "\(source): \(html)")
            #expect(!html.lowercased().contains("<a "), "\(source) became a link: \(html)")
        }
        #expect(MailMarkdown.render("[ok](https://example.test/a?b=1&c=2)").contains("<a href=\"https://example.test/a?b=1&amp;c=2\">ok</a>"))
        #expect(MailMarkdown.render("[mail](mailto:a@example.test)").contains("href=\"mailto:a@example.test\""))
    }

    /// The template's own markup is stripped (Dify's `bleach.clean`), but text stays text — including a rendered value
    /// that carries `<` or a quote.
    @Test func theTemplateIsCleanedAndValuesStayText() {
        let cleaned = MailMarkdown.cleanTemplate("<script>alert(1)</script>Who: \"a < b\" <b>bold</b>")
        #expect(cleaned == "alert(1)Who: \"a < b\" bold", Comment(rawValue: cleaned))
        let html = MailMarkdown.render("Approve: \"a<b\" & done")
        #expect(html.contains("\"a&lt;b\""), Comment(rawValue: html))
        #expect(html.contains("&amp; done"), Comment(rawValue: html))
    }

    /// The block constructs Dify's Markdown produces, not just a paragraph: headings, lists, quotes, code, rules.
    @Test func blocksRender() {
        let html = MailMarkdown.render("""
        # Title

        Some **bold** and *em* and `code`.

        - one
        - two

        1. first
        2. second

        > quoted

        ```
        let x = 1
        ```

        ---
        """)
        for tag in ["<h1>Title</h1>", "<strong>bold</strong>", "<em>em</em>", "<code>code</code>", "<ul>",
                    "<li><p>one</p></li>", "<ol>", "<li><p>first</p></li>", "<blockquote>",
                    "<pre><code>let x = 1\n</code></pre>", "<hr>"] {
            #expect(html.contains(tag), Comment(rawValue: "missing \(tag) in \(html)"))
        }
    }

    @Test func twoNewlinesInAParagraphBecomeABreak() {
        let html = MailMarkdown.render("one\ntwo")
        #expect(html.contains("one\ntwo") || html.contains("one<br>two") || html.contains("one<br />two"), Comment(rawValue: html))
    }

    @Test func aSubjectIsOneLineWithoutMarkup() {
        #expect(MailMarkdown.sanitizeSubject("  Hello\n<b>world</b>\r\n  ") == "Hello world")
        #expect(MailMarkdown.sanitizeSubject("Approve <no-reply@example.com> please") == "Approve please")
    }
}
