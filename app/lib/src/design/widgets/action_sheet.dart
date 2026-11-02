/// dify-sf's phone action sheet: the touch replacement for right-click and "…" menus (a dify-sf divergence).
library;

import 'package:flutter/widgets.dart';

import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'bottom_sheet.dart';
import 'button_style.dart';
import 'form_control_shared.dart' show DifyFocusDecoration, difyFocusRing;
import 'text.dart';

/// One row of [showDifyActionSheet]: an optional [icon] (20 px by convention, without a colour of its own), a
/// [label], [onTap] (called after the sheet has closed, so it may open another sheet or dialog), [destructive]
/// (text-destructive) and [enabled].
@immutable
class DifyActionSheetAction {
  const DifyActionSheetAction({
    required this.label,
    this.icon,
    this.onTap,
    this.destructive = false,
    this.enabled = true,
  });

  final String label;
  final Widget? icon;
  final VoidCallback? onTap;
  final bool destructive;
  final bool enabled;
}

/// Shows [actions] in a modal bottom sheet ([showDifyBottomSheet], sized to its rows): an optional [title]
/// (system-sm-medium text-tertiary), 52 px rows (`gap-3 px-4`, body-lg-regular) and a Cancel row (common
/// `operation.cancel` unless [cancelLabel]) under a divider. A tap on a row closes the sheet, then calls its
/// `onTap`; Cancel, the scrim, a drag down and back just close it. Rows scroll when they do not fit.
Future<void> showDifyActionSheet(
  BuildContext context, {
  String? title,
  required List<DifyActionSheetAction> actions,
  String? cancelLabel,
}) async {
  final picked = await showDifyBottomSheet<DifyActionSheetAction>(
    context,
    (context) => Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (title case final t?)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Semantics(
              header: true,
              child: DifyText(t, DifyType.systemSmMedium, color: DifyColors.textTertiary, maxLines: 2),
            ),
          ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final a in actions)
                  _ActionRow(
                    icon: a.icon,
                    label: a.label,
                    enabled: a.enabled,
                    color: !a.enabled
                        ? DifyColors.textDisabled
                        : a.destructive
                        ? DifyColors.textDestructive
                        : DifyColors.textSecondary,
                    onPressed: () => Navigator.pop(context, a),
                  ),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
        ),
        _ActionRow(
          label: cancelLabel ?? DifyI18n.tr('common', 'operation.cancel'),
          strong: true,
          color: DifyColors.textSecondary,
          onPressed: () => Navigator.pop(context),
        ),
        const SizedBox(height: 8),
      ],
    ),
  );
  picked?.onTap?.call();
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.label,
    required this.color,
    required this.onPressed,
    this.icon,
    this.enabled = true,
    this.strong = false,
  });

  final String label;
  final Color color;
  final VoidCallback onPressed;
  final Widget? icon;
  final bool enabled;

  /// Cancel: centred, semibold.
  final bool strong;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    disabled: !enabled,
    builder: (context, hovered, focused) => DecoratedBox(
      decoration: DifyFocusDecoration(
        color: hovered && enabled ? DifyColors.stateBaseHover : null,
        boxShadow: difyFocusRing(focused),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            mainAxisAlignment: strong ? MainAxisAlignment.center : MainAxisAlignment.start,
            spacing: 12,
            children: [
              if (icon case final i?)
                DefaultTextStyle.merge(
                  style: TextStyle(color: color),
                  child: ExcludeSemantics(child: i),
                ),
              Flexible(
                child: DifyText(label, strong ? DifyPhoneType.labelStrong : DifyType.bodyLgRegular, color: color),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
