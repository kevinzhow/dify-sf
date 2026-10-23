import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'text.dart';

/// Kbd colours: `gray` (`bg-components-kbd-bg-gray text-text-tertiary`) and `white`
/// (`bg-components-kbd-bg-white text-text-primary-on-surface`, for dark surfaces such as primary buttons).
enum DifyKbdColor {
  gray,
  white;

  Color get background => switch (this) {
    gray => DifyColors.componentsKbdBgGray,
    white => DifyColors.componentsKbdBgWhite,
  };

  Color get foreground => switch (this) {
    gray => DifyColors.textTertiary,
    white => DifyColors.textPrimaryOnSurface,
  };
}

/// dify-ui's Kbd keycap: `inline-flex h-4 min-w-4 items-center justify-center rounded-sm px-px system-kbd
/// capitalize`; disabled is `opacity-30`. Decorative: no pointer events, no semantics of its own beyond its text.
class DifyKbd extends StatelessWidget {
  const DifyKbd(this.text, {super.key, this.color = DifyKbdColor.gray, this.textColor, this.disabled = false});

  final String text;
  final DifyKbdColor color;

  /// Overrides the colour's text colour (ShortcutKbd's `textColor="secondary"`).
  final Color? textColor;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    Widget key = IgnorePointer(
      child: Container(
        height: 16,
        constraints: const BoxConstraints(minWidth: 16),
        padding: const EdgeInsets.symmetric(horizontal: 1),
        decoration: BoxDecoration(color: color.background, borderRadius: BorderRadius.circular(DifyRadius.sm)),
        child: Center(
          widthFactor: 1,
          child: DifyTextLine(
            cssCapitalize(text),
            maxLines: 1,
            softWrap: false,
            style: difyTextStyle(
              DifyType.systemKbd,
              textColor ?? color.foreground,
            ).copyWith(fontStyle: FontStyle.normal),
          ),
        ),
      ),
    );
    if (disabled) key = Opacity(opacity: 0.3, child: key);
    return key;
  }
}

/// KbdGroup: keycaps side by side, `inline-flex items-center gap-0.5`; [semanticLabel] names the chord.
class DifyKbdGroup extends StatelessWidget {
  const DifyKbdGroup({super.key, required this.children, this.semanticLabel});

  final List<Widget> children;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final row = Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: children);
    if (semanticLabel == null) return row;
    return Semantics(
      container: true,
      label: semanticLabel,
      child: ExcludeSemantics(child: row),
    );
  }
}
