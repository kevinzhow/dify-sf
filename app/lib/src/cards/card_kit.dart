import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../workflow/model_catalog.dart';

export 'variable_label.dart';

/// What a card body needs besides its own node: other nodes, for labels of the variables it references.
class BodyContext {
  const BodyContext(
    this.node,
    this.lookup, {
    this.start,
    this.viewOrigin = Offset.zero,
    this.models = ModelCatalog.empty,
    this.datasets = const {},
  });
  final Node node;
  final Node? Function(String id) lookup;

  /// The workflow's Start node (system variables are shown under it).
  final Node? start;

  /// Where the canvas origin was on screen when the view last came to rest (React Flow's viewport x, y), for
  /// content tied to the viewport: the dot background inside containers.
  final Offset viewOrigin;

  /// The workspace's model providers and models (model chips show their status from it).
  final ModelCatalog models;

  /// The knowledge bases the workspace has, by id (Dify's datasets-detail store: `name`, `icon_info`); none known
  /// until the host provides them.
  final Map<String, Map<String, Object?>> datasets;

  Value? operator [](String key) => node.config[key];
}

/// The font cards render with (the app theme's family); measurement outside the widget tree needs it explicitly.
String? cardFontFamily;

/// A Dify text style in a colour (uppercase styles are applied by [DifyText]).
TextStyle difyStyle(DifyTextStyle s, Color color) => s.style.copyWith(color: color, fontFamily: cardFontFamily);

/// The height of [text] in [style] laid out at [width] (description, answer text).
double textHeight(String text, TextStyle style, double width, {int? maxLines}) {
  if (text.isEmpty) return 0;
  final p = TextPainter(
    text: TextSpan(
      text: text,
      style: style.copyWith(fontFamily: cardFontFamily),
    ),
    textDirection: TextDirection.ltr,
    maxLines: maxLines,
  )..layout(maxWidth: width);
  final h = p.height;
  p.dispose();
  return h;
}

/// Text in a Dify typography utility (applies `uppercase`).
class DifyText extends StatelessWidget {
  const DifyText(
    this.text,
    this.style, {
    super.key,
    this.color = DifyColors.textPrimary,
    this.align,
    this.maxLines = 1,
  });
  final String text;
  final DifyTextStyle style;
  final Color color;
  final TextAlign? align;
  final int? maxLines;

  @override
  Widget build(BuildContext context) => Text(
    style.uppercase ? text.toUpperCase() : text,
    style: difyStyle(style, color),
    textAlign: align,
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
  );
}

/// A row on the card: `flex h-6 items-center rounded-md bg-workflow-block-parma-bg px-1`.
class ParamRow extends StatelessWidget {
  const ParamRow({super.key, required this.child, this.height = 24});
  final Widget child;
  final double height;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 4),
    decoration: BoxDecoration(
      color: DifyColors.workflowBlockParmaBg,
      borderRadius: BorderRadius.circular(DifyRadius.md),
    ),
    child: child,
  );
}

/// The small node icon in variable labels (VarBlockIcon): the type glyph, no tile, in text-secondary.
class VarBlockIcon extends StatelessWidget {
  const VarBlockIcon({super.key, required this.type, this.size = 12});
  final String type;
  final double size;

  @override
  Widget build(BuildContext context) => DifyIcon(varBlockGlyph(type), size: size, color: DifyColors.textSecondary);
}
