/// What the Human Input panel's parts share: the host data ([HumanInputHost]: workspace members, the current user,
/// the email-delivery feature flag, the test email service), Trans-style rich text, dialogs, method icon tiles and
/// section headers.
library;

import 'package:flutter/material.dart';

import '../../../../../cards/card_kit.dart';
import '../../../../../design/css_metrics.dart';
import '../../../../../design/dify_icon.dart';
import '../../../../../design/dify_tokens.g.dart';
import '../../../../panel_fields/panel_fields.dart';
import '../data_common.dart';
import 'human_input_model.dart';

/// `t(key)` under `nodes.humanInput.`.
String hi(String key, [Map<String, Object?> params = const {}]) => wf('nodes.humanInput.$key', params);

/// A workspace member (`Member`).
@immutable
class HiMember {
  const HiMember({required this.id, required this.email, this.name = '', this.avatarUrl, this.status = 'active'});
  final String id, email, name;
  final String? avatarUrl;
  final String status;
}

/// Sends a test email for delivery [deliveryId] of node [nodeId] with the form variables [inputs]
/// (`useTestEmailSender`); throwing keeps the dialog on the form.
typedef SendTestEmail = Future<void> Function({
  required String nodeId,
  required String deliveryId,
  required Map<String, Object?> inputs,
});

/// What the Human Input panel reads from Dify's backend, handed in by the app (each has an empty default).
class HumanInputHost extends InheritedWidget {
  const HumanInputHost({
    super.key,
    this.members = const [],
    this.userEmail = '',
    this.userName = '',
    this.workspaceName = '',
    this.emailDeliveryEnabled = true,
    this.sendTestEmail,
    this.onUpgrade,
    required super.child,
  });

  /// `useMembers().accounts`.
  final List<HiMember> members;

  /// The account's email and name (`userProfile`).
  final String userEmail, userName;

  /// `currentWorkspace.name`.
  final String workspaceName;

  /// `features.human_input_email_delivery_enabled`; null while it loads (the email option does nothing then).
  final bool? emailDeliveryEnabled;

  /// None: the test sender's Send button is disabled.
  final SendTestEmail? sendTestEmail;

  /// The upgrade modal's upgrade button (Dify opens the pricing page); none: no upgrade button.
  final VoidCallback? onUpgrade;

  static const _none = HumanInputHost(child: SizedBox.shrink());

  static HumanInputHost of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HumanInputHost>() ?? _none;

  @override
  bool updateShouldNotify(HumanInputHost old) =>
      members != old.members ||
      userEmail != old.userEmail ||
      userName != old.userName ||
      workspaceName != old.workspaceName ||
      emailDeliveryEnabled != old.emailDeliveryEnabled ||
      sendTestEmail != old.sendTestEmail ||
      onUpgrade != old.onUpgrade;
}

/// react-i18next's `<Trans>`: [text] with `<tag>inner</tag>` and `<tag/>` parts built by [tags] (unknown tags show
/// their inner text).
List<InlineSpan> transSpans(String text, Map<String, InlineSpan Function(String inner)> tags) {
  final re = RegExp(r'<(\w+)\s*/>|<(\w+)>(.*?)</\2>');
  final spans = <InlineSpan>[];
  var last = 0;
  for (final m in re.allMatches(text)) {
    if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
    final tag = m[1] ?? m[2]!, inner = m[3] ?? '';
    spans.add(tags[tag]?.call(inner) ?? TextSpan(text: inner));
    last = m.end;
  }
  if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
  return spans;
}

/// The icon tile of a delivery method: `rounded-sm border border-divider-regular` in the method's colour around its
/// icon in `text-text-primary-on-surface`; null for types without one.
Widget? methodTile(String type, {double iconSize = 14, double padding = 2, bool dim = false}) {
  final (Color bg, Widget icon) = switch (type) {
    DeliveryMethodType.webapp => (
      DifyColors.componentsIconBgIndigoSolid,
      RemixIcon('robot-2-fill', size: iconSize, color: DifyColors.textPrimaryOnSurface),
    ),
    DeliveryMethodType.email => (
      DifyColors.componentsIconBgBlueSolid,
      RemixIcon('mail-send-fill', size: iconSize, color: DifyColors.textPrimaryOnSurface),
    ),
    _ => (const Color(0x00000000), const SizedBox.shrink()),
  };
  if (type != DeliveryMethodType.webapp && type != DeliveryMethodType.email) return null;
  return Opacity(
    opacity: dim ? 0.5 : 1,
    child: Container(
      padding: EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: bg,
        border: Border.all(color: DifyColors.dividerRegular),
        borderRadius: BorderRadius.circular(DifyRadius.sm),
      ),
      child: icon,
    ),
  );
}

/// A section header (`flex items-center gap-0.5`: `system-sm-semibold-uppercase text-text-secondary` and an Infotip)
/// with [actions] on the right.
class HiSectionHeader extends StatelessWidget {
  const HiSectionHeader({super.key, required this.title, this.tooltip, this.actions});
  final String title;
  final String? tooltip;
  final Widget? actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Expanded(
          child: SizedBox(
            height: 24,
            child: Row(
              spacing: 2,
              children: [
                Flexible(child: DifyText(title, DifyType.systemSmSemiboldUppercase, color: DifyColors.textSecondary)),
                if (tooltip != null) Infotip(label: tooltip!, content: Text(tooltip!)),
              ],
            ),
          ),
        ),
        // Long translations shrink the actions rather than overflow.
        if (actions != null)
          Flexible(
            child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerRight, child: actions),
          ),
      ],
    ),
  );
}

/// The empty state box: `flex items-center justify-center rounded-[10px] bg-background-section p-3
/// system-xs-regular text-text-tertiary`.
class HiEmptyTip extends StatelessWidget {
  const HiEmptyTip(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    alignment: Alignment.center,
    decoration: BoxDecoration(color: DifyColors.backgroundSection, borderRadius: BorderRadius.circular(10)),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: difyStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
    ),
  );
}

/// The `px-4 py-2` divider (`Divider my-0! h-px! bg-divider-subtle!`).
class HiDivider extends StatelessWidget {
  const HiDivider({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Container(height: 1, color: DifyColors.dividerSubtle),
  );
}

/// Badge (base/badge): `h-5 rounded-[5px] border border-divider-deep px-1.25 system-2xs-medium-uppercase`, or the
/// `size="s"` / [color] variants the panel uses.
class HiBadge extends StatelessWidget {
  const HiBadge(this.text, {super.key, this.height = 20, this.color = DifyColors.textTertiary, this.border});
  final String text;
  final double height;
  final Color color;
  final Color? border;

  @override
  Widget build(BuildContext context) => Container(
    height: height,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: border ?? DifyColors.dividerDeep, width: Css.hairline * 2),
    ),
    child: DifyText(text, DifyType.system2xsMediumUppercase, color: color),
  );
}

/// dify-ui's StatusDot `warning`: a 6 px dot in the warning colour with its soft ring.
class HiStatusDot extends StatelessWidget {
  const HiStatusDot({super.key});

  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: DifyColors.componentsBadgeStatusLightWarningBg,
      border: Border.all(color: DifyColors.componentsBadgeStatusLightWarningBorderInner),
    ),
  );
}

/// A dialog's button row on the right (`flex justify-end gap-2`); long translations shrink it rather than overflow.
class HiFooter extends StatelessWidget {
  const HiFooter({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(mainAxisSize: MainAxisSize.min, spacing: 8, children: children),
    ),
  );
}
