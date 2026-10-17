import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';

/// What a card body needs besides its own node: other nodes, for labels of the variables it references.
class BodyContext {
  const BodyContext(this.node, this.lookup, {this.start});
  final Node node;
  final Node? Function(String id) lookup;

  /// The workflow's Start node (system variables are shown under it).
  final Node? start;

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
  Widget build(BuildContext context) => DifyIcon(blockGlyph(type), size: size, color: DifyColors.textSecondary);
}

/// A reference to a variable as the card shows it: the node it comes from (null for sys/env/conversation
/// variables), the variable name, its kind (for icon and colour).
class VarRef {
  const VarRef({this.node, required this.name, this.kind = VarKind.node, this.broken = false});
  final Node? node;
  final String name;
  final VarKind kind;
  final bool broken;

  /// Resolves a `[node, output]` selector as the document stores it (a reference, a broken reference, or a plain
  /// list for sys/env/conversation variables).
  static VarRef? of(Value? v, BodyContext ctx) {
    switch (v) {
      case VRef(:final ref):
        return VarRef(node: ctx.lookup(ref.node), name: ref.output);
      case VBroken(:final ref):
        return VarRef(name: ref.output, broken: true);
      case VList(:final items) when items.isNotEmpty:
        final parts = [
          for (final i in items)
            if (i is VString) i.value,
        ];
        if (parts.length < 2) return null;
        final kind = switch (parts.first) {
          'sys' => VarKind.system,
          'env' => VarKind.environment,
          'conversation' => VarKind.conversation,
          _ => VarKind.node,
        };
        if (kind == VarKind.system) {
          // System variables show under the Start node.
          return VarRef(node: ctx.start, name: parts.join('.'), kind: kind);
        }
        return VarRef(
          node: kind == VarKind.node ? ctx.lookup(parts.first) : null,
          name: parts.sublist(1).join('.'),
          kind: kind,
        );
      default:
        return null;
    }
  }
}

enum VarKind { node, system, environment, conversation }

/// Variable colour by kind (variable-label hooks: useVarColor).
Color varColor(VarKind k) => switch (k) {
  VarKind.environment => const Color(0xFF7839EE), // util-colors violet-600
  VarKind.conversation => const Color(0xFF107569), // util-colors teal-700
  VarKind.system => const Color(0xFFDC6803), // util-colors orange-600
  VarKind.node => DifyColors.textAccent,
};

String varIcon(VarKind k) => switch (k) {
  VarKind.environment => 'vender/line/others/env',
  VarKind.conversation => 'vender/line/others/bubble-x',
  VarKind.system => 'vender/line/others/global-variable',
  VarKind.node => 'vender/solid/development/variable-02',
};

/// VariableLabel (variable-label/base/variable-label.tsx): node icon + title + "/", variable icon + name.
/// [inNode]: the InNode variant (full width, parameter background, no shadow, 24 px); otherwise InText (18 px).
class VariableLabel extends StatelessWidget {
  const VariableLabel({super.key, required this.ref, this.inNode = true, this.type});
  final VarRef ref;
  final bool inNode;
  final String? type;

  @override
  Widget build(BuildContext context) {
    final color = ref.broken ? DifyColors.textWarning : varColor(ref.kind);
    final node = ref.node;
    final children = <Widget>[
      if (node != null) ...[
        VarBlockIcon(type: node.type),
        const SizedBox(width: 1),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 60),
          child: DifyText(node.title, DifyType.systemXsMedium, color: DifyColors.textSecondary),
        ),
        const DifyText('/', DifyType.systemXsRegular, color: DifyColors.dividerDeep),
      ],
      DifyIcon(varIcon(ref.kind), size: 14, color: color),
      const SizedBox(width: 1),
      Flexible(child: DifyText(ref.name, DifyType.systemXsMedium, color: color)),
      if (type != null) ...[
        const SizedBox(width: 1),
        DifyText(type!, DifyType.systemXsRegular, color: DifyColors.textTertiary),
      ],
    ];
    return Container(
      height: inNode ? 24 : 18,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: inNode
          ? BoxDecoration(color: DifyColors.workflowBlockParmaBg, borderRadius: BorderRadius.circular(DifyRadius.md))
          : null,
      child: Row(mainAxisSize: inNode ? MainAxisSize.max : MainAxisSize.min, children: children),
    );
  }
}
