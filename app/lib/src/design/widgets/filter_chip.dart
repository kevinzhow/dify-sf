/// dify-sf's phone filter chips (a dify-sf divergence: Dify's console filters are 32 px dropdown triggers).
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import '../dify_type_tw.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';
import 'responsive.dart' show DifyTouch;
import 'touch_target.dart';

/// A phone filter chip (mockup 1, gen.py `.chip`): [height] 34 px, fully rounded, `gap-1 px-3`, 13 px text in
/// text-secondary on components-input-bg-normal; [selected] state-accent-active with text-accent. An optional
/// [leading] and [trailing] icon (16 px, without a colour of their own) take the text colour. Its hit area is at
/// least 48 px tall ([DifyTouchTarget]); [selected] is reported to assistive technology.
class DifyFilterChip extends StatelessWidget {
  const DifyFilterChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onPressed,
    this.leading,
    this.trailing,
    this.semanticLabel,
  });

  static const height = 34.0;

  final String label;
  final bool selected;
  final VoidCallback? onPressed;
  final Widget? leading, trailing;

  /// The accessible name ([label] by default).
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = selected ? DifyColors.textAccent : DifyColors.textSecondary;
    Widget chip(bool hovered, bool focused) => DecoratedBox(
      decoration: DifyFocusDecoration(
        color: selected
            ? DifyColors.stateAccentActive
            : hovered
            ? DifyColors.componentsInputBgHover
            : DifyColors.componentsInputBgNormal,
        borderRadius: BorderRadius.circular(height / 2),
        boxShadow: difyFocusRing(focused),
      ),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: IconTheme.merge(
            data: IconThemeData(color: color),
            child: DefaultTextStyle.merge(
              style: TextStyle(color: color),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                spacing: 4,
                children: [
                  ?leading,
                  DifyText(label, DifyTw.text13Leading16, color: color),
                  ?trailing,
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return DifyTouchTarget(
      child: DifyPressable(
        onPressed: onPressed,
        builder: (context, hovered, focused) => Semantics(
          selected: selected,
          label: semanticLabel,
          child: ExcludeSemantics(excluding: semanticLabel != null, child: chip(hovered, focused)),
        ),
      ),
    );
  }
}

/// One horizontally scrolling row of [DifyFilterChip]s (mockup 1's filters): `gap-2 px-4 pt-1 pb-2.5`, tall enough
/// for the chips' 48 px hit areas.
class DifyChipBar extends StatelessWidget {
  const DifyChipBar({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    // The row is as tall as the chips' hit areas: a touch target only reaches as far as its parent's box.
    child: SizedBox(
      height: DifyTouch.minTarget,
      child: Row(spacing: 8, children: children),
    ),
  );
}
