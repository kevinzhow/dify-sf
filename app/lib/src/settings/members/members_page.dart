/// members-page/index.tsx: the workspace's members (the account setting's Members tab).
library;

import 'dart:async';

import 'package:flutter/rendering.dart' show OverflowBoxFit;
import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/app_locale.dart';
import '../../workflow_editor/header/format.dart' as fmt;
import '../settings_kit.dart';
import '../workspace_members.dart';
import 'invite_modal.dart';
import 'invited_modal.dart';
import 'member_details_modal.dart';
import 'member_menu.dart';
import 'member_row.dart';

/// MembersPage: the workspace header (`2xl` workspace avatar, the name, "N Member(s)", the primary "Add" button
/// for managers) and the member table (NAME, LAST ACTIVE, ROLE). Managers (owners and admins: Dify's
/// `workspace.member.manage`) invite (the InviteModal, then the InvitedModal with the links), change roles and remove
/// members (each row's menu, or Edit in the member's details); everybody opens a member's details.
///
/// Dify's owner-only "edit workspace" pencil and ownership transfer are not offered: dify-sf's server has neither.
/// It has no billing plans either, so the header counts members the way Dify's community edition does.
class MembersPage extends StatefulWidget {
  const MembersPage({super.key, required this.members, this.formatTimeFromNow, this.invitationOrigin, this.roles});

  final WorkspaceMembers members;

  /// `useFormatTimeFromNow().formatTimeFromNow` (milliseconds); dayjs's English wording by default.
  final String Function(int milliseconds)? formatTimeFromNow;

  /// The origin relative invitation links are completed with ([defaultInvitationOrigin] when null).
  final String? invitationOrigin;

  /// The roles offered when inviting and editing ([legacyWorkspaceRoles] by default).
  final List<WorkspaceRole>? roles;

  @override
  State<MembersPage> createState() => _MembersPageState();
}

class _MembersPageState extends State<MembersPage> {
  WorkspaceMembers get _m => widget.members;

  @override
  void initState() {
    super.initState();
    _m.addListener(_changed);
    unawaited(_m.refresh());
  }

  @override
  void didUpdateWidget(MembersPage old) {
    super.didUpdateWidget(old);
    if (old.members != widget.members) {
      old.members.removeListener(_changed);
      widget.members.addListener(_changed);
    }
  }

  @override
  void dispose() {
    _m.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  bool _isCurrentUser(Member m) => _m.me?.email.toLowerCase() == m.email.toLowerCase();

  Future<void> _invite() async {
    final results = await showInviteModal(
      context,
      roles: widget.roles,
      send: (emails, role) => _m.invite(emails: emails, role: role),
    );
    if (results == null || !mounted) return;
    await showInvitedModal(context, results, origin: widget.invitationOrigin);
  }

  Future<void> _openDetails(Member member) async {
    final success = stc(context, 'actionMsg.modifiedSuccessfully');
    await showMemberDetailsModal(
      context,
      member: member,
      roles: widget.roles,
      canAssignRoles: _m.canManage && member.role != AccountRole.owner && !_isCurrentUser(member),
      onAssignSubmit: (roles) async {
        if (roles.isEmpty) return;
        try {
          await _m.updateRole(member.id, roles.first.id);
          toast.success(success);
        } on Object catch (e) {
          toast.error(requestErrorMessage(e));
        }
      },
    );
  }

  String _lastActive(Member m) {
    final t = m.lastLoginAt ?? m.createdAt;
    if (t == null) return '';
    return (widget.formatTimeFromNow ?? fmt.formatTimeFromNow)(t.millisecondsSinceEpoch);
  }

  @override
  Widget build(BuildContext context) {
    final accounts = _m.members;
    final canManage = _m.canManage;
    final name = _m.workspaceName ?? '';
    // `locale !== LanguagesSupported[1] && accounts.length > 1 && 's'` (no plural "s" in Chinese).
    final plural = AppLocaleScope.of(context) != 'zh-Hans' && accounts.length > 1 ? 's' : '';
    final header = CustomPaint(
      foregroundPainter: const _TopLeftBorderPainter(),
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        padding: const EdgeInsets.fromLTRB(8, 8, 20, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(DifyRadius.xl),
          gradient: const LinearGradient(
            colors: [DifyColors.backgroundGradientBgFillChatBg2, DifyColors.backgroundGradientBgFillChatBg1],
          ),
        ),
        child: Row(
          spacing: 12,
          children: [
            WorkspaceAvatar(name: name, size: WorkspaceAvatarSize.xxl),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    key: const ValueKey('workspace-name'),
                    style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textSecondary),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      spacing: 4,
                      children: [
                        Text(
                          '${accounts.length}',
                          style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                        ),
                        Flexible(
                          child: Text(
                            '${st(context, 'billing', 'plansCommon.memberAfter')}$plural',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (canManage)
              DifyButton(
                key: const ValueKey('invite-button'),
                variant: DifyButtonVariant.primary,
                leading: const RemixIcon('user-add-line', size: 16),
                onPressed: () => unawaited(_invite()),
                child: Text(stc(context, 'members.invite')),
              ),
          ],
        ),
      ),
    );
    final headStyle = difyTextStyle(DifyType.systemXsMediumUppercase, DifyColors.textTertiary);
    String up(String s) => difyTransform(DifyType.systemXsMediumUppercase, s);
    final table = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(vertical: 7),
          decoration: const BoxDecoration(
            border: Border(bottom: BorderSide(color: DifyColors.dividerRegular)),
          ),
          child: Row(
            children: [
              SizedBox(
                width: memberNameColumnWidth,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(up(stc(context, 'members.name')), style: headStyle),
                ),
              ),
              SizedBox(
                width: memberLastActiveColumnWidth,
                child: Text(up(stc(context, 'members.lastActive')), style: headStyle),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(up(stc(context, 'members.role')), style: headStyle),
                ),
              ),
            ],
          ),
        ),
        for (final a in accounts)
          MemberRow(
            key: ValueKey(a.id),
            member: a,
            roleNames: [legacyRoleOf(a.role).name],
            isCurrentUser: _isCurrentUser(a),
            lastActive: _lastActive(a),
            canManage: canManage,
            onOpenDetails: () => unawaited(_openDetails(a)),
            menu: canManage
                ? MemberMenu(
                    member: a,
                    isCurrentUser: _isCurrentUser(a),
                    roles: widget.roles,
                    onUpdateRole: (role) => _m.updateRole(a.id, role),
                    onRemove: () => _m.remove(a.id),
                  )
                : null,
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        LayoutBuilder(
          // `min-w-120`: narrower than that, the table keeps its width (and is cut).
          builder: (context, c) => c.maxWidth >= 480
              ? table
              : ClipRect(
                  child: OverflowBox(
                    alignment: AlignmentDirectional.topStart,
                    minWidth: 480,
                    maxWidth: 480,
                    fit: OverflowBoxFit.deferToChild,
                    child: table,
                  ),
                ),
        ),
      ],
    );
  }
}

/// `border-t-[0.5px] border-l-[0.5px] border-divider-subtle` around the `rounded-xl` header.
class _TopLeftBorderPainter extends CustomPainter {
  const _TopLeftBorderPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const r = DifyRadius.xl, w = 0.5;
    final h = size.height - 24; // the header's box, above its margin
    final path = Path()
      ..moveTo(w / 2, h - r)
      ..lineTo(w / 2, r)
      ..arcToPoint(const Offset(r, w / 2), radius: const Radius.circular(r - w / 2))
      ..lineTo(size.width - r, w / 2);
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w
        ..color = DifyColors.dividerSubtle,
    );
  }

  @override
  bool shouldRepaint(_TopLeftBorderPainter old) => false;
}
