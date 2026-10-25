/// base/markdown: Dify's Markdown (streamdown with GFM and remark-breaks) in the `markdown-body` styles of
/// web/app/styles/markdown.css, rendered by flutter_markdown_plus (the maintained successor of flutter_markdown; a
/// style sheet maps Dify's CSS, so no renderer of our own).
///
/// Streaming text re-parses per chunk, which stays cheap at chat sizes; each paragraph is its own text widget.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../design/dify_tokens.g.dart';
import '../../code_editor/editor_view.dart' show codeEditorFontFamily;
import '../../../design/widgets/widgets.dart';
import 'thinking_details.dart';

/// `<Markdown content=… />`: `markdown-body text-text-primary` (15 px / 1.6), [color] overriding the text colour
/// (an error answer's `text-[#F04438]`).
class DifyMarkdown extends StatelessWidget {
  const DifyMarkdown({
    super.key,
    required this.content,
    this.color,
    this.onTapLink,
    this.isStreaming = false,
    this.paragraphStyle,
  });

  final String content;
  final bool isStreaming;
  final Color? color;
  final TextStyle? paragraphStyle;
  final void Function(String href)? onTapLink;

  static MarkdownStyleSheet styleSheet(Color color, {TextStyle? paragraphStyle}) {
    final base = TextStyle(
      fontFamily: cardFontFamily,
      fontSize: 15,
      height: 1.6,
      color: color,
      letterSpacing: 0,
      leadingDistribution: TextLeadingDistribution.even,
    ).merge(paragraphStyle);
    final mono = TextStyle(fontFamily: codeEditorFontFamily, fontSize: 12, height: 1.6, color: color);
    return MarkdownStyleSheet(
      p: base,
      a: base.copyWith(color: DifyColors.textAccent),
      code: mono.copyWith(fontSize: 12 * 0.85, backgroundColor: const Color(0x33AFB8C1)),
      h1: base.copyWith(fontSize: 18, fontWeight: FontWeight.w600),
      h2: base.copyWith(fontSize: 16, fontWeight: FontWeight.w600),
      h3: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      h4: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      h5: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      h6: base.copyWith(fontSize: 14, fontWeight: FontWeight.w600),
      h1Padding: const EdgeInsets.only(top: 8),
      h2Padding: const EdgeInsets.only(top: 8),
      em: const TextStyle(fontStyle: FontStyle.italic),
      strong: const TextStyle(fontWeight: FontWeight.w700),
      del: const TextStyle(decoration: TextDecoration.lineThrough),
      blockquote: base,
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 12),
      blockquoteDecoration: BoxDecoration(
        border: Border(left: BorderSide(color: DifyColors.textAccentSecondary, width: 3)),
      ),
      listBullet: base,
      listIndent: 24,
      blockSpacing: 16,
      tableHead: base.copyWith(fontSize: 12, fontWeight: FontWeight.w500, color: DifyColors.textTertiary),
      tableBody: base.copyWith(fontSize: 13, color: DifyColors.textSecondary),
      tableBorder: TableBorder.all(color: DifyColors.dividerSubtle),
      tableCellsPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      tableHeadCellsPadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 6),
      codeblockPadding: const EdgeInsets.all(16),
      codeblockDecoration: BoxDecoration(
        color: DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(top: BorderSide(color: DifyColors.dividerRegular)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => _MarkdownStream(
    active: isStreaming,
    child: MarkdownBody(
      data: content,
      blockSyntaxes: const [_ThinkBlockSyntax(), _CommentBlockSyntax()],
      inlineSyntaxes: [_CommentSyntax()],
      builders: {
        'dify-think': _ThinkBuilder(color: color, onTapLink: onTapLink),
        'dify-comment-tail': _CommentTailBuilder(color: color, onTapLink: onTapLink),
      },
      styleSheet: styleSheet(color ?? DifyColors.textPrimary, paragraphStyle: paragraphStyle),
      extensionSet: md.ExtensionSet.gitHubFlavored,
      // remark-breaks: a single newline is a line break.
      softLineBreak: true,
      selectable: false,
      onTapLink: onTapLink == null ? null : (text, href, title) => href == null ? null : onTapLink!(href),
    ),
  );
}

class _MarkdownStream extends InheritedWidget {
  const _MarkdownStream({required this.active, required super.child});
  final bool active;
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_MarkdownStream>()?.active ?? false;
  @override
  bool updateShouldNotify(_MarkdownStream oldWidget) => active != oldWidget.active;
}

// Extension points of the maintained Markdown parser preserve fenced/indented code and code spans. A comment
// is not answer text; suppress it without a global string replacement that would corrupt literal code examples.
class _CommentSyntax extends md.InlineSyntax {
  _CommentSyntax() : super(r'<!--[\s\S]*?(?:-->|$)', startCharacter: 60);
  @override
  bool onMatch(md.InlineParser parser, Match match) => true;
}

class _CommentBlockSyntax extends md.BlockSyntax {
  const _CommentBlockSyntax();
  @override
  RegExp get pattern => RegExp(r'^ {0,3}<!--');
  @override
  md.Node? parse(md.BlockParser parser) {
    final lines = <String>[];
    do {
      final line = parser.current.content;
      parser.advance();
      final end = line.indexOf('-->');
      if (end >= 0) {
        lines.add(line.substring(end + 3));
        break;
      }
    } while (!parser.isDone);
    final tail = lines.join('\n');
    if (tail.trim().isEmpty) return null;
    return md.Element.empty('dify-comment-tail')..attributes['tail'] = tail;
  }
}

class _ThinkBlockSyntax extends md.BlockSyntax {
  const _ThinkBlockSyntax();
  @override
  RegExp get pattern => RegExp(r'^ {0,3}<think>');
  @override
  md.Node parse(md.BlockParser parser) {
    final body = StringBuffer();
    var first = true;
    var closed = false;
    var tail = '';
    do {
      var line = parser.current.content;
      if (first) line = line.substring(line.indexOf('<think>') + 7);
      first = false;
      parser.advance();
      final end = line.indexOf('</think>');
      if (end >= 0) {
        body.write(line.substring(0, end));
        tail = line.substring(end + 8);
        closed = true;
        break;
      }
      body.writeln(line);
    } while (!parser.isDone);
    return md.Element.empty('dify-think')
      ..attributes['body'] = body.toString().trim()
      ..attributes['tail'] = tail
      ..attributes['closed'] = closed.toString();
  }
}

class _CommentTailBuilder extends MarkdownElementBuilder {
  _CommentTailBuilder({this.color, this.onTapLink});
  final Color? color;
  final void Function(String)? onTapLink;
  @override
  bool isBlockElement() => true;
  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) => Builder(
    builder: (context) => DifyMarkdown(
      content: element.attributes['tail'] ?? '',
      color: color,
      onTapLink: onTapLink,
      isStreaming: _MarkdownStream.of(context),
    ),
  );
}

class _ThinkBuilder extends _CommentTailBuilder {
  _ThinkBuilder({super.color, super.onTapLink});
  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final tail = element.attributes['tail'] ?? '';
    return Builder(
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ThinkingDetails(
            done: !_MarkdownStream.of(context) || element.attributes['closed'] == 'true',
            child: DifyMarkdown(
              content: element.attributes['body'] ?? '',
              color: DifyColors.textSecondary,
              onTapLink: onTapLink,
            ),
          ),
          if (tail.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            DifyMarkdown(content: tail, color: color, onTapLink: onTapLink, isStreaming: _MarkdownStream.of(context)),
          ],
        ],
      ),
    );
  }
}
