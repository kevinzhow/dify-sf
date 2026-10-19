/// member-details-modal/index.tsx and permission-role-chip.tsx with one role per member: who the member is and the
/// role they have, which managers can change here (pending until Save).
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

import '../../auth/auth_api.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import '../workspace_members.dart';
import 'assign_roles_modal.dart';

/// Opens the MemberDetailsModal for [member]; [onAssignSubmit] gets the roles chosen when Save is pressed.
Future<void> showMemberDetailsModal(
  BuildContext context, {
  required Member member,
  bool canAssignRoles = false,
  ValueChanged<List<WorkspaceRole>>? onAssignSubmit,
  List<WorkspaceRole>? roles,
}) => showSettingsDialog<void>(
  context,
  (context) => MemberDetailsModal(
    member: member,
    canAssignRoles: canAssignRoles,
    onAssignSubmit: onAssignSubmit,
    roles: roles ?? legacyWorkspaceRoles(),
  ),
);

/// MemberDetailsModal: `DialogContent className="w-110 p-0"`: the title "Member Details", the member (`2xl` avatar,
/// name `system-md-semibold`, email), then (`border-t border-divider-subtle px-6 py-4`) "Assigned Role" with the count
/// and, for managers, the ghost "Edit" button, and the role chip under "GENERAL" (built-in roles) or "CUSTOMIZED";
/// managers get Cancel / Save (`px-6 pt-2 pb-4`). A role picked with Edit stays pending until Save, which submits it
/// and closes.
class MemberDetailsModal extends StatefulWidget {
  const MemberDetailsModal({
    super.key,
    required this.member,
    required this.roles,
    this.canAssignRoles = false,
    this.onAssignSubmit,
    this.onClose,
    this.memberRoles,
  });

  final Member member;

  /// The roles Edit offers.
  final List<WorkspaceRole> roles;
  final bool canAssignRoles;
  final ValueChanged<List<WorkspaceRole>>? onAssignSubmit;

  /// Defaults to closing the dialog.
  final VoidCallback? onClose;

  /// The member's roles (`useRolesOfMember`); by default the member's role in the legacy shape.
  final List<WorkspaceRole>? memberRoles;

  @override
  State<MemberDetailsModal> createState() => _MemberDetailsModalState();
}

class _MemberDetailsModalState extends State<MemberDetailsModal> {
  List<WorkspaceRole>? _pending;

  List<WorkspaceRole> get _roles => widget.memberRoles ?? [legacyRoleOf(widget.member.role)];
  List<WorkspaceRole> get _selected => _pending ?? _roles;

  void _close() => widget.onClose != null ? widget.onClose!() : Navigator.of(context).maybePop();

  Future<void> _edit() async {
    final picked = await showAssignRolesModal(context, selectedRoles: _selected, roles: widget.roles);
    if (picked != null && mounted) setState(() => _pending = picked.take(1).toList());
  }

  void _save() {
    widget.onAssignSubmit?.call(_selected.take(1).toList());
    _close();
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final m = w.member;
    final selected = _selected;
    final builtin = selected.where((r) => r.isBuiltin).toList();
    final custom = selected.where((r) => !r.isBuiltin).toList();
    final title = stc(context, 'members.memberDetails.title');
    Widget group(String label, List<WorkspaceRole> roles) => Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              difyTransform(DifyType.system2xsMediumUppercase, label),
              style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textTertiary),
            ),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [for (final r in roles) PermissionRoleChip(key: ValueKey('chip-${r.id}'), role: r)],
          ),
        ],
      ),
    );
    return SettingsDialogContent(
      label: title,
      width: 440,
      padding: EdgeInsets.zero,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsetsDirectional.only(end: 32),
                      child: Text(title, style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary)),
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Row(
                        spacing: 12,
                        children: [
                          DifyAvatar(name: m.name, url: m.avatarUrl, size: DifyAvatarSize.xxl),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  m.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: difyTextStyle(DifyType.systemMdSemibold, DifyColors.textPrimary),
                                ),
                                Text(
                                  m.email,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                PositionedDirectional(top: 0, end: 0, child: SettingsDialogCloseButton(onPressed: _close)),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Row(
                        spacing: 6,
                        children: [
                          Flexible(
                            child: Text(
                              stc(
                                context,
                                selected.length == 1
                                    ? 'members.memberDetails.assignedRole'
                                    : 'members.memberDetails.assignedRoles',
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary),
                            ),
                          ),
                          Text(
                            '${selected.length}',
                            style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                    if (w.canAssignRoles)
                      DifyButton(
                        key: const ValueKey('details-edit-role'),
                        variant: DifyButtonVariant.ghost,
                        size: DifyButtonSize.small,
                        onPressed: _edit,
                        leading: const RemixIcon('edit-line', size: 14),
                        child: Text(stc(context, 'operation.edit')),
                      ),
                  ],
                ),
                if (builtin.isNotEmpty) group(stc(context, 'members.memberDetails.generalGroup'), builtin),
                if (custom.isNotEmpty) group(stc(context, 'members.memberDetails.customGroup'), custom),
              ],
            ),
          ),
          if (w.canAssignRoles)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  DifyButton(
                    key: const ValueKey('details-cancel'),
                    onPressed: _close,
                    child: Text(stc(context, 'operation.cancel')),
                  ),
                  DifyButton(
                    key: const ValueKey('details-save'),
                    variant: DifyButtonVariant.primary,
                    disabled: w.onAssignSubmit == null,
                    onPressed: _save,
                    child: Text(stc(context, 'operation.save')),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// PermissionRoleChip (read-only: one role per member cannot be removed): `inline-flex h-6 rounded-full
/// border-[0.5px] border-components-panel-border-subtle bg-background-body px-1.5 system-xs-medium text-text-primary
/// shadow-xs`, hover `bg-background-section-burn`. Hovering it (300 ms) shows the role's permissions in a
/// `bg-components-tooltip-bg` card (`w-58 px-4 py-3.5`): the role (`title-xs-semi-bold`) and "ROLE can
/// PERMISSIONS" with the permissions in `text-text-accent`.
class PermissionRoleChip extends StatefulWidget {
  const PermissionRoleChip({super.key, required this.role});

  final WorkspaceRole role;

  @override
  State<PermissionRoleChip> createState() => _PermissionRoleChipState();
}

class _PermissionRoleChipState extends State<PermissionRoleChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final role = widget.role;
    final permissions = [for (final k in role.permissionKeys) st(context, 'permissionKeys', k)].join(', ');
    final summary = permissions.isEmpty
        ? Text(stc(context, 'members.memberDetails.roleNoPermissionSummary'))
        : _permissionSummary(context, role.name, permissions);
    final r = BorderRadius.circular(DifyRadius.lg);
    return DifyTooltip(
      placement: DifyPlacement.bottomStart,
      surface: false,
      content: DifyBlurredBox(
        blur: 5,
        borderRadius: r,
        decoration: BoxDecoration(
          color: DifyColors.componentsTooltipBg,
          borderRadius: r,
          border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
          boxShadow: DifyShadows.lg,
        ),
        child: Container(
          width: 232,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 4,
            children: [
              Text(
                role.name,
                softWrap: false,
                style: difyTextStyle(DifyType.titleXsSemiBold, DifyColors.textPrimary).copyWith(height: 16 / 12),
              ),
              DefaultTextStyle.merge(
                style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textSecondary),
                child: summary,
              ),
            ],
          ),
        ),
      ),
      child: Semantics(
        button: true,
        label: role.name,
        excludeSemantics: true,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _hovered ? DifyColors.backgroundSectionBurn : DifyColors.backgroundBody,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: DifyColors.componentsPanelBorderSubtle, width: Css.hairline),
              boxShadow: DifyShadows.xs,
            ),
            child: Center(
              widthFactor: 1,
              child: Text(
                role.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: difyTextStyle(DifyType.systemXsMedium, DifyColors.textPrimary).copyWith(height: 16 / 12),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// `members.memberDetails.rolePermissionSummary` (`{{role}} can <permissionList>{{permissions}}</permissionList>`)
  /// with the permission list in `text-text-accent`.
  Widget _permissionSummary(BuildContext context, String role, String permissions) {
    const open = '\u0001', close = '\u0002';
    final raw = stc(context, 'members.memberDetails.rolePermissionSummary', {
      'role': role,
      'permissions': permissions,
    }).replaceAll('<permissionList>', open).replaceAll('</permissionList>', close);
    final spans = <InlineSpan>[];
    final re = RegExp('$open(.*?)$close', dotAll: true);
    var at = 0;
    for (final m in re.allMatches(raw)) {
      if (m.start > at) spans.add(TextSpan(text: raw.substring(at, m.start)));
      spans.add(
        TextSpan(
          text: m[1],
          style: TextStyle(color: DifyColors.textAccent),
        ),
      );
      at = m.end;
    }
    if (at < raw.length) spans.add(TextSpan(text: raw.substring(at)));
    return Text.rich(TextSpan(children: spans), textHeightBehavior: const ui.TextHeightBehavior());
  }
}
