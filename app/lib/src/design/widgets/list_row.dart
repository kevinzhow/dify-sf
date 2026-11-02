/// dify-sf's phone lists: rows and section headers (a dify-sf divergence: Dify's console lists are cards and tables).
library;

import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'action_sheet.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'responsive.dart';
import 'text.dart';
import 'touch_target.dart';

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

/// A row of a panel's list as Dify draws it (var-item.tsx and its kind: a card whose edit, remove and reorder actions
/// show on hover), with those actions reachable by touch on a phone (a dify-sf divergence; raft-flutter's
/// `RaftListRowAction`, the input layer of a row that brings its own layout).
///
/// In a window of 600 dp and wider it is [child], unchanged: Dify's row with its hover actions. In a compact window:
/// - [child] is laid out at least 48 px tall (a fixed-height Dify card grows to it) and is one node for assistive
///   technology named [label] (the child's own nodes are left out), with its actions as the node's custom actions;
/// - a tap runs [onTap] (the row's edit form: a sheet on a phone), or opens the actions when there is no [onTap];
/// - a long press and a trailing "…" (44 px, "More actions for [label]") open [actions] in an action sheet titled
///   [label]: Edit, Delete, Move up, Move down ([DifyActionRow.edit], [DifyActionRow.delete], [DifyActionRow.moveUp],
///   [DifyActionRow.moveDown]) and the row's own. Reordering is by these actions, not by a drag.
///
/// The child's hover-only controls get no pointer on a phone (they are not shown there); with [childInteractive] the
/// child keeps its own taps and nodes (a switch that is always visible: it wins a tap on it, the rest of the row is
/// the row's).
class DifyActionRow extends StatelessWidget {
  const DifyActionRow({
    super.key,
    required this.label,
    required this.child,
    this.onTap,
    this.actions = const [],
    this.childInteractive = false,
  });

  final String label;
  final Widget child;
  final VoidCallback? onTap;
  final List<DifyActionSheetAction> actions;
  final bool childInteractive;

  /// The row's height on a phone.
  static const minHeight = DifyTouch.minTarget;

  /// "Edit" (`edit-line`).
  static DifyActionSheetAction edit(VoidCallback onTap, {String? label}) => DifyActionSheetAction(
    label: label ?? DifyI18n.tr('common', 'operation.edit'),
    icon: const RemixIcon('edit-line', size: 20),
    onTap: onTap,
  );

  /// "Delete" (`delete-bin-line`, destructive). The action runs the row's own removal: a confirmation, if Dify asks
  /// for one there, is the caller's.
  static DifyActionSheetAction delete(VoidCallback onTap, {String? label}) => DifyActionSheetAction(
    label: label ?? DifyI18n.tr('common', 'operation.delete'),
    icon: const RemixIcon('delete-bin-line', size: 20),
    onTap: onTap,
    destructive: true,
  );

  /// "Move up" (`arrow-up-line`); off for the first row.
  static DifyActionSheetAction moveUp(VoidCallback onTap, {bool enabled = true}) => DifyActionSheetAction(
    label: DifyI18n.tr('common', 'operation.moveUp'),
    icon: const RemixIcon('arrow-up-line', size: 20),
    onTap: onTap,
    enabled: enabled,
  );

  /// "Move down" (`arrow-down-line`); off for the last row.
  static DifyActionSheetAction moveDown(VoidCallback onTap, {bool enabled = true}) => DifyActionSheetAction(
    label: DifyI18n.tr('common', 'operation.moveDown'),
    icon: const RemixIcon('arrow-down-line', size: 20),
    onTap: onTap,
    enabled: enabled,
  );

  @override
  Widget build(BuildContext context) {
    if (!DifyTouch.compactOf(context)) return child;
    final hasActions = actions.isNotEmpty;
    void open() => showDifyActionSheet(context, title: label, actions: actions);
    final tap = onTap ?? (hasActions ? open : null);
    Widget body = ConstrainedBox(constraints: const BoxConstraints(minHeight: minHeight), child: child);
    if (!childInteractive) body = ExcludeSemantics(child: IgnorePointer(child: body));
    body = Semantics(
      container: true,
      button: tap != null,
      label: label,
      onTap: tap,
      onLongPress: hasActions ? open : null,
      customSemanticsActions: {
        for (final a in actions)
          if (a.enabled && a.onTap != null) CustomSemanticsAction(label: a.label): a.onTap!,
      },
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        excludeFromSemantics: true,
        // With an interactive child its own controls win their taps; the rest of the row is the row's.
        onTap: tap,
        onLongPress: hasActions ? open : null,
        child: body,
      ),
    );
    if (!hasActions) return body;
    return Row(
      children: [
        Expanded(child: body),
        DifyTouchIconButton(
          key: ValueKey('dify-action-row-more-$label'),
          label: DifyI18n.tr('common', 'operation.moreActionsFor', {'name': label}),
          icon: const RemixIcon('more-fill', size: 20),
          onPressed: open,
        ),
      ],
    );
  }
}
