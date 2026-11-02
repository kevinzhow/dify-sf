/// dify-sf's phone lists: rows and section headers (a dify-sf divergence: Dify's console lists are cards and tables).
library;

import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';

/// A phone list row (mockup 1's app rows, gen.py `.row`): at least [minHeight] (52 px, 64 px with a [subtitle]),
/// `gap-3 px-4 py-2`, then [leading] (an icon or a 44 px tile), the one-line [title] over an optional one-line
/// [subtitle] (system-xs-regular text-tertiary), both ellipsized, [trailing] (a value, a [DifyListChevron]) and
/// [actions] ([DifyTouchIconButton]s). The title is body-lg-regular, or 15 px semibold ([DifyPhoneType.labelStrong])
/// when [strong]; text-destructive when [destructive].
///
/// Everything but [actions] is one touch target for [onTap] (state-base-hover while pressed) and [onLongPress],
/// named by [semanticLabel] (the title and subtitle by default); the actions keep their own taps and names. [divider]
/// draws a divider-subtle line along the bottom edge. The row has no background of its own: put rows on
/// `components-panel-bg`.
class DifyListRow extends StatelessWidget {
  const DifyListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing = const [],
    this.actions = const [],
    this.onTap,
    this.onLongPress,
    this.strong = false,
    this.destructive = false,
    this.divider = true,
    this.enabled = true,
    this.semanticLabel,
  });

  /// The height of a row without, and with, a subtitle.
  static const minHeight = 52.0, minHeightWithSubtitle = 64.0;

  final String title;
  final String? subtitle;
  final Widget? leading;

  /// Non-interactive widgets after the text (inside the row's touch target).
  final List<Widget> trailing;

  /// Buttons at the row's end, outside its touch target.
  final List<Widget> actions;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool strong, destructive, divider, enabled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? DifyColors.textDisabled
        : destructive
        ? DifyColors.textDestructive
        : DifyColors.textPrimary;
    final iconColor = !enabled
        ? DifyColors.textDisabled
        : destructive
        ? DifyColors.textDestructive
        : DifyColors.textSecondary;
    final interactive = onTap != null || onLongPress != null;
    Widget body(bool hovered, bool focused) => DecoratedBox(
      decoration: DifyFocusDecoration(
        color: hovered && enabled && interactive ? DifyColors.stateBaseHover : null,
        boxShadow: difyFocusRing(focused),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: subtitle == null ? minHeight : minHeightWithSubtitle),
        child: Padding(
          padding: EdgeInsets.fromLTRB(16, 8, actions.isEmpty ? 16 : 4, 8),
          child: Row(
            spacing: 12,
            children: [
              if (leading case final l?)
                IconTheme.merge(
                  data: IconThemeData(color: iconColor),
                  child: DefaultTextStyle.merge(
                    style: TextStyle(color: iconColor),
                    child: ExcludeSemantics(child: l),
                  ),
                ),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: [
                    DifyText(title, strong ? DifyPhoneType.labelStrong : DifyType.bodyLgRegular, color: color),
                    if (subtitle case final s?)
                      DifyText(
                        s,
                        DifyType.systemXsRegular,
                        color: enabled ? DifyColors.textTertiary : DifyColors.textDisabled,
                      ),
                  ],
                ),
              ),
              ...trailing,
            ],
          ),
        ),
      ),
    );
    final label = semanticLabel ?? [title, ?subtitle].join(', ');
    Widget main;
    if (!interactive) {
      main = MergeSemantics(child: body(false, false));
    } else {
      main = DifyPressable(
        onPressed: onTap ?? onLongPress,
        disabled: !enabled,
        semanticLabel: label,
        builder: (context, hovered, focused) => body(hovered, focused),
      );
      if (onLongPress case final long? when enabled) {
        main = Semantics(
          onLongPress: long,
          child: GestureDetector(onLongPress: long, child: main),
        );
      }
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        border: divider ? Border(bottom: BorderSide(color: DifyColors.dividerSubtle)) : null,
      ),
      child: actions.isEmpty
          ? main
          : Row(
              children: [
                Expanded(child: main),
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Row(mainAxisSize: MainAxisSize.min, children: actions),
                ),
              ],
            ),
    );
  }
}

/// A row's trailing chevron (`arrow-right-s-line`, 20 px, text-quaternary): the row opens a page.
class DifyListChevron extends StatelessWidget {
  const DifyListChevron({super.key});

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: RemixIcon('arrow-right-s-line', size: 20, color: DifyColors.textQuaternary));
}

/// A section label over phone list rows (gen.py `.lbl`: 12 px, uppercase, text-tertiary; `px-4 pt-5 pb-2`), a
/// heading for assistive technology.
class DifyListSectionHeader extends StatelessWidget {
  const DifyListSectionHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
    child: Semantics(
      header: true,
      child: DifyText(label, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
    ),
  );
}
