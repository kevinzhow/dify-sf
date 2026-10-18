/// members-page/member-row.tsx and role-badges.tsx.
library;

import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';

/// The member table's column widths: name `w-65`, last active `w-30`.
const memberNameColumnWidth = 260.0;
const memberLastActiveColumnWidth = 120.0;

/// RoleBadges: the first [max] role names as badges (`h-5 rounded-md bg-background-body px-1.5 system-xs-medium
/// text-text-secondary shadow-xs`, truncated) and `+N` for the rest (`text-text-tertiary`).
class RoleBadges extends StatelessWidget {
  const RoleBadges({super.key, required this.roleNames, this.max = 2});

  final List<String> roleNames;
  final int max;

  @override
  Widget build(BuildContext context) {
    final visible = roleNames.take(max).toList();
    final overflow = roleNames.length - visible.length;
    Widget badge(String text, {required Color color, String? title}) => Container(
      key: title == null ? null : ValueKey('role-badge-$title'),
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: DifyColors.backgroundBody,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        boxShadow: DifyShadows.xs,
      ),
      child: Center(
        widthFactor: 1,
        child: Semantics(
          tooltip: title,
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: difyTextStyle(DifyType.systemXsMedium, color),
          ),
        ),
      ),
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 4,
      children: [
        for (final r in visible)
          Flexible(
            child: badge(r, color: DifyColors.textSecondary, title: r),
          ),
        if (overflow > 0) badge('+$overflow', color: DifyColors.textTertiary),
      ],
    );
  }
}

/// MemberRow: `relative border-b border-divider-subtle`; the whole row is one button "Open member details for
/// NAME" (`hover:bg-state-base-hover`, `pr-12` when managers have the menu at its end): avatar (`sm`), name
/// (`system-sm-medium`; "Pending..." for invitations not yet accepted, "(You)" for oneself) over the email; the last
/// activity ([lastActive]); the role badges. [menu] (managers only) sits over the
/// row's end (`absolute inset-y-0 right-0 px-3`), not
/// inside the button.
class MemberRow extends StatefulWidget {
  const MemberRow({
    super.key,
    required this.member,
    required this.roleNames,
    required this.isCurrentUser,
    required this.lastActive,
    required this.onOpenDetails,
    this.canManage = false,
    this.menu,
  });

  final Member member;
  final List<String> roleNames;
  final bool isCurrentUser;
  final String lastActive;
  final VoidCallback onOpenDetails;

  /// Managers see the actions column (`pr-12`), even on rows without actions.
  final bool canManage;
  final Widget? menu;

  @override
  State<MemberRow> createState() => _MemberRowState();
}

class _MemberRowState extends State<MemberRow> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final m = w.member;
    final label = stc(context, 'members.memberDetails.openAria', {'name': m.name});
    final row = Row(
      children: [
        SizedBox(
          width: memberNameColumnWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: DifyAvatar(name: m.name, url: m.avatarUrl, size: DifyAvatarSize.sm),
                ),
                Flexible(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(
                        TextSpan(
                          children: [
                            TextSpan(text: m.name),
                            if (m.isPending)
                              WidgetSpan(
                                alignment: PlaceholderAlignment.baseline,
                                baseline: TextBaseline.alphabetic,
                                child: Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Text(
                                    stc(context, 'members.pending'),
                                    style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textWarning),
                                  ),
                                ),
                              ),
                            if (w.isCurrentUser)
                              TextSpan(
                                text: stc(context, 'members.you'),
                                style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                              ),
                          ],
                        ),
                        style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary),
                      ),
                      Text(m.email, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SizedBox(
          width: memberLastActiveColumnWidth,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              w.lastActive,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textSecondary),
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Align(
              heightFactor: 1,
              alignment: AlignmentDirectional.centerStart,
              child: RoleBadges(roleNames: w.roleNames),
            ),
          ),
        ),
      ],
    );
    return Container(
      key: ValueKey('member-row-${m.id}'),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
      ),
      child: Stack(
        children: [
          Semantics(
            button: true,
            label: label,
            onTap: w.onOpenDetails,
            // `aria-label` names the button instead of its content.
            excludeSemantics: true,
            child: FocusableActionDetector(
              mouseCursor: SystemMouseCursors.click,
              onShowHoverHighlight: (v) => setState(() => _hovered = v),
              onFocusChange: (v) => setState(() => _focused = v),
              actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => w.onOpenDetails())},
              child: GestureDetector(
                key: ValueKey('member-details-${m.id}'),
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: w.onOpenDetails,
                child: Container(
                  color: _hovered || _focused ? DifyColors.stateBaseHover : null,
                  padding: EdgeInsets.only(right: w.canManage ? 48 : 0),
                  child: row,
                ),
              ),
            ),
          ),
          if (w.menu != null)
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Center(child: w.menu),
              ),
            ),
        ],
      ),
    );
  }
}
