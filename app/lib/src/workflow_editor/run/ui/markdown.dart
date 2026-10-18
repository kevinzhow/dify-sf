/// base/markdown: Dify's Markdown (streamdown with GFM and remark-breaks) in the `markdown-body` styles of
/// web/app/styles/markdown.css, rendered by flutter_markdown_plus (the maintained successor of flutter_markdown; a
/// style sheet maps Dify's CSS, so no renderer of our own).
///
/// Streaming text re-parses per chunk, which stays cheap at chat sizes; each paragraph is its own text widget.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../cards/card_kit.dart' show cardFontFamily;
import '../../../design/dify_tokens.g.dart';
import '../../code_editor/editor_view.dart' show codeEditorFontFamily;

/// markdown-utils.ts preprocessThinkTag: `<think>…</think>` becomes a quoted block (Dify's ThinkBlock collapses it
/// under "Thinking…"; the text stays visible here).
String preprocessThinkTag(String content) {
  final m = RegExp(r'^\s*<think>([\s\S]*?)(</think>|$)').firstMatch(content);
  if (m == null) return content;
  final think = m.group(1)!.trim().split('\n').map((l) => '> $l').join('\n');
  return '$think\n\n${content.substring(m.end).trimLeft()}';
}

/// `<Markdown content=… />`: `markdown-body text-text-primary` (15 px / 1.6), [color] overriding the text colour
/// (an error answer's `text-[#F04438]`).
class DifyMarkdown extends StatelessWidget {
  const DifyMarkdown({super.key, required this.content, this.color, this.onTapLink});

  final String content;
  final Color? color;
  final void Function(String href)? onTapLink;

  static MarkdownStyleSheet styleSheet(Color color) {
    final base = TextStyle(
      fontFamily: cardFontFamily,
      fontSize: 15,
      height: 1.6,
      color: color,
      letterSpacing: 0,
      leadingDistribution: TextLeadingDistribution.even,
    );
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
      blockquoteDecoration: const BoxDecoration(
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
      horizontalRuleDecoration: const BoxDecoration(
        border: Border(top: BorderSide(color: DifyColors.dividerRegular)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: preprocessThinkTag(content),
    styleSheet: styleSheet(color ?? DifyColors.textPrimary),
    extensionSet: md.ExtensionSet.gitHubFlavored,
    // remark-breaks: a single newline is a line break.
    softLineBreak: true,
    selectable: false,
    onTapLink: onTapLink == null ? null : (text, href, title) => href == null ? null : onTapLink!(href),
  );
}
