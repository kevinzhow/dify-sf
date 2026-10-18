/// members-page/member-menu.tsx with one role per member: a manager's actions on another member (edit the role,
/// remove from the team, behind a confirmation).
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import '../workspace_members.dart';
import 'assign_roles_modal.dart';

/// The message of a refused request, as Dify's request layer toasts it (the server's message).
String requestErrorMessage(Object e) => e is TransportException ? e.message : '$e';

/// MemberMenu: the `lg` IconButton "Member actions" (`i-ri-more-fill`, `bg-state-base-hover` while open) opening a
/// menu (`bottom-end`, 4 px, `min-w-45 rounded-xl`) with "Edit Role" and, after a separator, the destructive "Remove
/// from team". Nothing for the owner or oneself (Dify's `canAssignRoles` / `canRemove`); dify-sf has no ownership
/// transfer, so the owner's row has no menu at all (Dify with `is_allow_transfer_workspace` false).
///
/// Edit Role opens the AssignRolesModal; its confirmation calls [onUpdateRole] and toasts "Modified successfully".
/// Remove asks first (AlertDialog "Remove NAME from team"); its confirmation calls [onRemove] (the dialog stays
/// open on failure). Failures toast the server's message.
class MemberMenu extends StatefulWidget {
  const MemberMenu({
    super.key,
    required this.member,
    required this.isCurrentUser,
    required this.onUpdateRole,
    required this.onRemove,
    this.roles,
  });

  final Member member;
  final bool isCurrentUser;
  final Future<void> Function(String role) onUpdateRole;
  final Future<void> Function() onRemove;

  /// The roles Edit Role offers ([legacyWorkspaceRoles] by default).
  final List<WorkspaceRole>? roles;

  @override
  State<MemberMenu> createState() => _MemberMenuState();
}

class _MemberMenuState extends State<MemberMenu> {
  final _menu = DifyFloatingController();
  bool _open = false;

  bool get _isOwner => widget.member.role == AccountRole.owner;
  bool get _canAssign => !_isOwner && !widget.isCurrentUser;
  bool get _canRemove => !_isOwner && !widget.isCurrentUser;

  Future<void> _editRole() async {
    final success = stc(context, 'actionMsg.modifiedSuccessfully');
    final picked = await showAssignRolesModal(
      context,
      selectedRoles: [legacyRoleOf(widget.member.role)],
      roles: widget.roles,
    );
    if (picked == null || picked.isEmpty) return;
    try {
      await widget.onUpdateRole(picked.first.id);
      toast.success(success);
    } on Object catch (e) {
      toast.error(requestErrorMessage(e));
    }
  }

  Future<void> _remove() async {
    final success = stc(context, 'actionMsg.modifiedSuccessfully');
    final m = widget.member;
    await showSettingsAlert(
      context,
      title: stc(context, 'members.removeFromTeamConfirmTitle', {'memberName': m.name.isEmpty ? m.email : m.name}),
      description: stc(context, 'members.removeFromTeamConfirmDescription'),
      onConfirm: () async {
        try {
          await widget.onRemove();
          toast.success(success);
        } on Object catch (e) {
          toast.error(requestErrorMessage(e));
          rethrow;
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_canAssign && !_canRemove) return const SizedBox.shrink();
    final label = stc(context, 'members.memberActions');
    final itemStyle = difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary);
    return DifyDropdownMenu(
      controller: _menu,
      placement: DifyPlacement.bottomEnd,
      sideOffset: 4,
      width: 180,
      onOpenChange: (o) => setState(() => _open = o),
      builder: (context, controller) => DecoratedBox(
        decoration: BoxDecoration(
          color: _open ? DifyColors.stateBaseHover : null,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
        ),
        child: DifyIconButton(
          key: ValueKey('member-actions-${widget.member.id}'),
          label: label,
          size: DifyIconButtonSize.lg,
          icon: const RemixIcon('more-fill', size: 16, color: DifyColors.textTertiary),
          onPressed: controller.toggle,
        ),
      ),
      children: [
        if (_canAssign)
          DifyMenuItem(
            key: const ValueKey('member-edit-role'),
            onSelect: () => unawaited(_editRole()),
            child: Text(stc(context, 'members.editRole'), style: itemStyle),
          ),
        if (_canAssign && _canRemove) const DifyMenuSeparator(),
        if (_canRemove)
          DifyMenuItem(
            key: const ValueKey('member-remove'),
            variant: DifyMenuItemVariant.destructive,
            onSelect: () => unawaited(_remove()),
            child: Text(
              stc(context, 'members.removeFromTeam'),
              style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textDestructive),
            ),
          ),
      ],
    );
  }
}
