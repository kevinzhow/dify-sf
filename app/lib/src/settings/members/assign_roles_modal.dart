/// assign-roles-modal/index.tsx and account-setting/workspace-role-checkbox-list.tsx with one role per member (Dify's
/// `allowMultipleRoles={false}`, RBAC off): the "Edit Role" dialog with the searchable radio list.
library;

import 'package:flutter/widgets.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../workflow_editor/block_selector/selector_widgets.dart' show SelectorSearchInput;
import '../settings_kit.dart';
import '../workspace_members.dart';
import 'role_selector.dart' show roleDescription;

/// Opens the AssignRolesModal on [selectedRoles]; resolves with the chosen roles (one) on Confirm, null when closed.
Future<List<WorkspaceRole>?> showAssignRolesModal(
  BuildContext context, {
  required List<WorkspaceRole> selectedRoles,
  List<WorkspaceRole>? roles,
}) => showSettingsDialog<List<WorkspaceRole>>(
  context,
  (context) => AssignRolesModal(selectedRoles: selectedRoles, roles: roles ?? legacyWorkspaceRoles()),
);

/// AssignRolesModal: `DialogContent className="flex h-121 w-120 flex-col p-0"`: the header (`px-6 pt-6 pb-4`, the
/// title "Edit Role" in `system-xl-semibold`, the description, the close button), the role list, and the footer
/// (`border-t border-divider-subtle px-6 py-4`) with Cancel and Confirm (disabled without a role). Confirm pops the
/// selection.
class AssignRolesModal extends StatefulWidget {
  const AssignRolesModal({super.key, required this.selectedRoles, required this.roles});

  final List<WorkspaceRole> selectedRoles;
  final List<WorkspaceRole> roles;

  @override
  State<AssignRolesModal> createState() => _AssignRolesModalState();
}

class _AssignRolesModalState extends State<AssignRolesModal> {
  late List<WorkspaceRole> _selected = widget.selectedRoles;

  @override
  Widget build(BuildContext context) {
    final title = stc(context, 'members.editRole');
    return SettingsDialogContent(
      label: title,
      height: 484,
      padding: EdgeInsets.zero,
      scrollable: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 32),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(title, style: difyTextStyle(DifyType.systemXlSemibold, DifyColors.textPrimary)),
                      Text(
                        stc(context, 'members.assignRolesModal.singleDescription'),
                        style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                      ),
                    ],
                  ),
                ),
                const PositionedDirectional(top: 0, end: 0, child: SettingsDialogCloseButton()),
              ],
            ),
          ),
          Expanded(
            child: WorkspaceRoleList(
              roles: widget.roles,
              selectedRoleIds: [for (final r in _selected) r.id],
              onSelectedRolesChange: (v) => setState(() => _selected = v),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: DifyColors.dividerSubtle)),
            ),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 8,
              runSpacing: 8,
              children: [
                DifyButton(
                  key: const ValueKey('assign-cancel'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(stc(context, 'operation.cancel')),
                ),
                DifyButton(
                  key: const ValueKey('assign-confirm'),
                  variant: DifyButtonVariant.primary,
                  disabled: _selected.isEmpty,
                  onPressed: () => Navigator.of(context).pop(_selected),
                  child: Text(stc(context, 'operation.confirm')),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// WorkspaceRoleCheckboxList in its single-role form: the search (`px-6 pt-3 pb-2`, "Search roles...", filtering by
/// name and description) over a radio group (`px-3`, items `gap-0.5`): `flex items-start gap-3 rounded-lg px-3
/// py-2.5`, hover `bg-state-base-hover`, checked `bg-state-accent-hover`, the radio control then the name
/// (`system-sm-semibold text-text-secondary`) over the description (`system-xs-regular text-text-tertiary`, the
/// legacy role's tip when it has none). [disabledRoleIds] cannot be chosen.
class WorkspaceRoleList extends StatefulWidget {
  const WorkspaceRoleList({
    super.key,
    required this.roles,
    required this.selectedRoleIds,
    required this.onSelectedRolesChange,
    this.disabledRoleIds = const [],
  });

  final List<WorkspaceRole> roles;
  final List<String> selectedRoleIds;
  final ValueChanged<List<WorkspaceRole>> onSelectedRolesChange;
  final List<String> disabledRoleIds;

  @override
  State<WorkspaceRoleList> createState() => _WorkspaceRoleListState();
}

class _WorkspaceRoleListState extends State<WorkspaceRoleList> {
  final _search = FocusNode(debugLabel: 'role search');
  String _keyword = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<WorkspaceRole> _filtered(BuildContext context) {
    final k = _keyword.trim().toLowerCase();
    if (k.isEmpty) return widget.roles;
    return [
      for (final r in widget.roles)
        if (r.name.toLowerCase().contains(k) || r.description.toLowerCase().contains(k)) r,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final roles = _filtered(context);
    final placeholder = st(context, 'permission', 'role.searchPlaceholder');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 8),
          child: SelectorSearchInput(
            value: _keyword,
            placeholder: placeholder,
            focusNode: _search,
            onChanged: (v) => setState(() => _keyword = v),
          ),
        ),
        Expanded(
          child: roles.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
                  child: Text(
                    st(context, 'permission', 'role.noMatchingRoles'),
                    textAlign: TextAlign.center,
                    style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                  ),
                )
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Semantics(
                    container: true,
                    label: st(context, 'permission', 'role.workspaceRoles.title'),
                    explicitChildNodes: true,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      spacing: 2,
                      children: [
                        for (final r in roles)
                          _RoleRadio(
                            key: ValueKey('role-radio-${r.id}'),
                            role: r,
                            description: roleDescription(context, r),
                            checked: widget.selectedRoleIds.firstOrNull == r.id,
                            disabled: widget.disabledRoleIds.contains(r.id),
                            onSelect: () => widget.onSelectedRolesChange([r]),
                          ),
                      ],
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _RoleRadio extends StatefulWidget {
  const _RoleRadio({
    super.key,
    required this.role,
    required this.description,
    required this.checked,
    required this.disabled,
    required this.onSelect,
  });

  final WorkspaceRole role;
  final String description;
  final bool checked, disabled;
  final VoidCallback onSelect;

  @override
  State<_RoleRadio> createState() => _RoleRadioState();
}

class _RoleRadioState extends State<_RoleRadio> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final bg = w.checked
        ? (w.disabled ? null : DifyColors.stateAccentHover)
        : (_hovered && !w.disabled ? DifyColors.stateBaseHover : null);
    Widget row = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(DifyRadius.lg)),
      foregroundDecoration: _focused
          ? BoxDecoration(
              borderRadius: BorderRadius.circular(DifyRadius.lg),
              border: Border.all(color: DifyColors.componentsInputBorderActive, width: 2),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 12,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: DifyRadioControl(checked: w.checked, disabled: w.disabled, hovered: false),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 2,
              children: [
                Text(w.role.name, style: difyTextStyle(DifyType.systemSmSemibold, DifyColors.textSecondary)),
                Text(w.description, style: difyTextStyle(DifyType.systemXsRegular, DifyColors.textTertiary)),
              ],
            ),
          ),
        ],
      ),
    );
    if (w.disabled) row = Opacity(opacity: 0.5, child: row);
    return Semantics(
      checked: w.checked,
      inMutuallyExclusiveGroup: true,
      enabled: !w.disabled,
      label: '${w.role.name} ${w.description}',
      onTap: w.disabled ? null : w.onSelect,
      excludeSemantics: true,
      child: FocusableActionDetector(
        enabled: !w.disabled,
        mouseCursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => w.onSelect())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: w.disabled ? null : w.onSelect,
          child: row,
        ),
      ),
    );
  }
}
