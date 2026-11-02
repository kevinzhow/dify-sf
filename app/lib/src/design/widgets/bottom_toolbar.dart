/// dify-sf's phone bottom bars: the editor toolbar and the selection bar (a dify-sf divergence: Dify's editor shows
/// these actions in hover toolbars and context menus).
library;

import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';
import 'responsive.dart';

/// One action of a [DifyBottomToolbar] or [DifySelectionBar] (gen.py `.tb`): an [icon] (22 px by convention) over an
/// 11 px [label], at least [minWidth] 52 px wide and as tall as its bar, so the whole cell is the touch target. Icons
/// without a colour of their own are text-secondary (labels text-tertiary), text-destructive when [destructive],
/// text-disabled unless [enabled]. Pressed or hovered, a state-base-hover rounded highlight shows inside the cell.
class DifyToolbarAction extends StatelessWidget {
  const DifyToolbarAction({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.enabled = true,
    this.destructive = false,
  });

  static const minWidth = 52.0;

  final Widget icon;
  final String label;
  final VoidCallback? onTap;
  final bool enabled;
  final bool destructive;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onTap,
    disabled: !enabled,
    builder: (context, hovered, focused) {
      final iconColor = !enabled
          ? DifyColors.textDisabled
          : destructive
          ? DifyColors.textDestructive
          : DifyColors.textSecondary;
      final labelColor = !enabled
          ? DifyColors.textDisabled
          : destructive
          ? DifyColors.textDestructive
          : DifyColors.textTertiary;
      return ConstrainedBox(
        constraints: const BoxConstraints(minWidth: minWidth),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: DecoratedBox(
            decoration: DifyFocusDecoration(
              color: hovered && enabled ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(DifyRadius.container),
              boxShadow: difyFocusRing(focused),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: 2,
                children: [
                  IconTheme.merge(
                    data: IconThemeData(color: iconColor),
                    child: DefaultTextStyle.merge(
                      style: TextStyle(color: iconColor),
                      child: ExcludeSemantics(child: icon),
                    ),
                  ),
                  DifyText(label, DifyPhoneType.toolbarLabel, color: labelColor),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The phone editor's bottom toolbar (mockups 2 and 3, gen.py `.toolbar`): [height] 60 px, `px-2`, the [actions] in
/// equal cells and, when given, a [center] slot (usually a regular [DifyFab]) between the first half of the actions
/// and the rest (with an odd count the extra action goes right). `bg-components-panel-bg` with a 1 px divider-subtle
/// top border.
///
/// Edge to edge: the background reaches the window's bottom and side edges, the actions stay above the bottom inset
/// and clear of the side insets (`MediaQuery.padding`, which is zero while the keyboard covers the navigation bar).
class DifyBottomToolbar extends StatelessWidget {
  const DifyBottomToolbar({super.key, required this.actions, this.center});

  /// The bar's height above the bottom inset.
  static const height = 60.0;

  final List<DifyToolbarAction> actions;
  final Widget? center;

  @override
  Widget build(BuildContext context) {
    final split = center == null ? actions.length : actions.length ~/ 2;
    return _DifyBottomBarSurface(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: _ActionRow(
          minHeight: height,
          children: [
            for (final a in actions.take(split)) Expanded(child: a),
            if (center case final c?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Center(child: c),
              ),
            for (final a in actions.skip(split)) Expanded(child: a),
          ],
        ),
      ),
    );
  }
}

/// The bar that replaces the toolbar while something is selected (mockup 3, "Count Android selected"): a 48 px header
/// row (`pl-4`: [leading], the one-line [title] in system-md-semibold, the [subtitle] in system-xs-regular
/// text-tertiary, and a 20 px close glyph when [onClose] is given) over a row of [actions] (48 px cells, `px-2 pb-1`),
/// on the same surface as [DifyBottomToolbar]. The close glyph sits in a 48 px square of its own: its whole target is
/// inside the bar and overlaps no action.
class DifySelectionBar extends StatelessWidget {
  const DifySelectionBar({
    super.key,
    required this.title,
    required this.actions,
    this.subtitle,
    this.leading,
    this.onClose,
    this.closeLabel,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final List<DifyToolbarAction> actions;
  final VoidCallback? onClose;

  /// The close glyph's accessible name (common `operation.close` by default).
  final String? closeLabel;

  @override
  Widget build(BuildContext context) => _DifyBottomBarSurface(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          // The glyph's right edge stays 16 px from the bar's (the mockup's `p-2` + `px-2`), its square 2 px.
          padding: EdgeInsets.only(left: 16, right: onClose == null ? 16 : 2),
          child: SizedBox(
            height: DifyTouch.minTarget,
            child: Row(
              spacing: 8,
              children: [
                ?leading,
                Flexible(
                  child: DifyText(title, DifyType.systemMdSemibold, color: DifyColors.textPrimary),
                ),
                if (subtitle case final s?) DifyText(s, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                if (onClose case final close?) ...[
                  const Spacer(),
                  DifyPressable(
                    onPressed: close,
                    semanticLabel: closeLabel ?? DifyI18n.tr('common', 'operation.close'),
                    builder: (context, hovered, focused) => SizedBox.square(
                      dimension: DifyTouch.minTarget,
                      child: Center(
                        child: DecoratedBox(
                          decoration: DifyFocusDecoration(
                            borderRadius: BorderRadius.circular(DifyRadius.sm),
                            boxShadow: difyFocusRing(focused),
                          ),
                          child: RemixIcon(
                            'close-line',
                            size: 20,
                            color: hovered ? DifyColors.textSecondary : DifyColors.textTertiary,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
          child: _ActionRow(
            minHeight: DifyTouch.minTarget,
            children: [for (final a in actions) Expanded(child: a)],
          ),
        ),
      ],
    ),
  );
}

/// A row of equal action cells, at least [minHeight] tall and as tall as its tallest cell (scaled text grows it).
class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.minHeight, required this.children});

  final double minHeight;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => IntrinsicHeight(
    child: ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    ),
  );
}

/// The phone bottom bars' surface (gen.py `.toolbar`): `bg-components-panel-bg`, a 1 px divider-subtle top border,
/// painted to the window's bottom and side edges; [child] is padded by the bottom and side insets.
class _DifyBottomBarSurface extends StatelessWidget {
  const _DifyBottomBarSurface({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final insets = MediaQuery.paddingOf(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(insets.left, 0, insets.right, insets.bottom),
        child: child,
      ),
    );
  }
}
