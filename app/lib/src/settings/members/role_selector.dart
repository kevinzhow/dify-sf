/// invite-modal/role-selector.tsx: the invitation form's role field (dify-ui's Select with a label, two-line items
/// and the field error).
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../settings_kit.dart';
import '../workspace_members.dart';

/// A role's description: its own, else the legacy role's tip (`members.adminTip`, ...), else "No description".
String roleDescription(BuildContext context, WorkspaceRole role, {bool legacyTips = true}) {
  if (role.description.isNotEmpty) return role.description;
  final key = legacyTips ? legacyRoleDescriptionKey(role) : null;
  if (key != null) return stc(context, key);
  return st(context, 'permission', 'role.noDescription');
}

/// RoleSelector: `Field name="role"` with `SelectLabel` "Role", the medium trigger showing the role's name or the
/// "Select a role" placeholder, and the popup (`bottom-start`, 4 px below, at least as wide as the trigger,
/// `rounded-xl border-[0.5px] bg-components-panel-bg shadow-lg`, list `max-h-70 p-1`) whose items show the name
/// (`text-sm text-text-secondary`) over the description (`text-xs leading-4.5 text-text-tertiary`, two lines) with
/// the check on the selected one. [error] is the field error ("Select a role" after a submit without a role, or the
/// server's).
class RoleSelector extends StatefulWidget {
  const RoleSelector({
    super.key,
    required this.roles,
    required this.value,
    required this.onChanged,
    this.disabled = false,
    this.error,
    this.focusNode,
  });

  final List<WorkspaceRole> roles;
  final WorkspaceRole? value;
  final ValueChanged<WorkspaceRole> onChanged;
  final bool disabled;
  final String? error;

  /// The trigger's focus (the form focuses it when the field is invalid).
  final FocusNode? focusNode;

  @override
  State<RoleSelector> createState() => _RoleSelectorState();
}

class _RoleSelectorState extends State<RoleSelector> {
  final _floating = DifyFloatingController();
  FocusNode? _own;
  final _itemNodes = <FocusNode>[];
  bool _hovered = false;
  bool _open = false;

  FocusNode get _trigger => widget.focusNode ?? (_own ??= FocusNode(debugLabel: 'RoleSelector'));

  @override
  void dispose() {
    _own?.dispose();
    for (final n in _itemNodes) {
      n.dispose();
    }
    super.dispose();
  }

  FocusNode _item(int i) {
    while (_itemNodes.length <= i) {
      _itemNodes.add(FocusNode(debugLabel: 'role option ${_itemNodes.length}'));
    }
    return _itemNodes[i];
  }

  void _toggle() {
    if (widget.disabled) return;
    _floating.toggle();
  }

  void _select(WorkspaceRole role) {
    widget.onChanged(role);
    _floating.close();
  }

  KeyEventResult _listKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final n = widget.roles.length;
    if (n == 0) return KeyEventResult.ignored;
    final i = _itemNodes.take(n).toList().indexWhere((f) => f.hasFocus);
    if (e.logicalKey == LogicalKeyboardKey.arrowDown) {
      _item(i < 0 ? 0 : (i + 1) % n).requestFocus();
      return KeyEventResult.handled;
    }
    if (e.logicalKey == LogicalKeyboardKey.arrowUp) {
      _item(i <= 0 ? n - 1 : i - 1).requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final label = stc(context, 'members.role');
    final selected = w.value;
    final placeholder = selected == null;
    final text = selected?.name ?? stc(context, 'members.selectRole');
    final active = !w.disabled && (_hovered || _open || _trigger.hasFocus);
    final color = w.disabled
        ? (placeholder ? DifyColors.componentsInputTextDisabled : DifyColors.componentsInputTextFilledDisabled)
        : placeholder
        ? DifyColors.componentsInputTextPlaceholder
        : DifyColors.componentsInputTextFilled;
    final selectedIndex = selected == null ? -1 : w.roles.indexWhere((r) => r.id == selected.id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 4,
      children: [
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: ExcludeSemantics(
              child: Text(label, style: difyTextStyle(DifyType.systemSmMedium, DifyColors.textSecondary)),
            ),
          ),
        ),
        LayoutBuilder(
          builder: (context, c) => DifyFloating(
            controller: _floating,
            placement: DifyPlacement.bottomStart,
            sideOffset: 4,
            collision: DifyCollision.dropdown,
            constrainHeight: true,
            initialFocus: w.roles.isEmpty ? null : _item(selectedIndex < 0 ? 0 : selectedIndex),
            onOpenChange: (o) => setState(() => _open = o),
            builder: (context, _) => Semantics(
              key: const ValueKey('role-selector-trigger'),
              button: true,
              enabled: !w.disabled,
              label: label,
              value: text,
              expanded: _open,
              onTap: w.disabled ? null : _toggle,
              excludeSemantics: true,
              child: FocusableActionDetector(
                focusNode: _trigger,
                enabled: !w.disabled,
                mouseCursor: w.disabled ? SystemMouseCursors.forbidden : SystemMouseCursors.click,
                onShowHoverHighlight: (v) => setState(() => _hovered = v),
                onFocusChange: (_) => setState(() {}),
                actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => _toggle())},
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: _toggle,
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: w.disabled
                          ? DifyColors.componentsInputBgDisabled
                          : active
                          ? DifyColors.stateBaseHoverAlt
                          : DifyColors.componentsInputBgNormal,
                      borderRadius: BorderRadius.circular(DifyRadius.lg),
                    ),
                    child: Row(
                      spacing: 2,
                      children: [
                        Expanded(
                          child: Text(
                            text,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(DifyType.systemSmRegular, color),
                          ),
                        ),
                        RemixIcon(
                          'arrow-down-s-line',
                          size: 16,
                          color: (_hovered || _open) && !w.disabled
                              ? DifyColors.textSecondary
                              : DifyColors.textQuaternary,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            popupBuilder: (context) => ConstrainedBox(
              constraints: BoxConstraints(minWidth: c.maxWidth.isFinite ? c.maxWidth : 0),
              child: Container(
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBg,
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                  border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
                  boxShadow: DifyShadows.lg,
                ),
                clipBehavior: Clip.antiAlias,
                child: Semantics(
                  container: true,
                  explicitChildNodes: true,
                  child: Focus(
                    onKeyEvent: _listKey,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxHeight: 280, maxWidth: c.maxWidth.isFinite ? c.maxWidth : 480),
                      child: SingleChildScrollView(
                        padding: const EdgeInsets.all(4),
                        child: w.roles.isEmpty
                            ? Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
                                child: Text(
                                  stc(context, 'dynamicSelect.noData'),
                                  textAlign: TextAlign.center,
                                  style: difyTextStyle(DifyType.systemSmRegular, DifyColors.textTertiary),
                                ),
                              )
                            : Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  for (final (i, r) in w.roles.indexed)
                                    _RoleOption(
                                      key: ValueKey('role-option-${r.id}'),
                                      role: r,
                                      description: roleDescription(context, r),
                                      selected: r.id == selected?.id,
                                      focusNode: _item(i),
                                      onSelect: () => _select(r),
                                    ),
                                ],
                              ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
        if (w.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Text(
              w.error!,
              key: const ValueKey('role-error'),
              style: difyTextStyle(DifyType.bodyXsRegular, DifyColors.textDestructive),
            ),
          ),
      ],
    );
  }
}

/// SelectItem `h-auto items-start py-2` (`rounded-lg px-2`, highlighted `bg-state-base-hover`): the name and the
/// description in `grid gap-0.5`, the check (`mt-0.5`, `text-text-accent`) when selected.
class _RoleOption extends StatefulWidget {
  const _RoleOption({
    super.key,
    required this.role,
    required this.description,
    required this.selected,
    required this.focusNode,
    required this.onSelect,
  });

  final WorkspaceRole role;
  final String description;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onSelect;

  @override
  State<_RoleOption> createState() => _RoleOptionState();
}

class _RoleOptionState extends State<_RoleOption> {
  @override
  Widget build(BuildContext context) {
    final w = widget;
    final highlighted = w.focusNode.hasFocus;
    return Semantics(
      button: true,
      selected: w.selected,
      label: '${w.role.name} ${w.description}',
      onTap: w.onSelect,
      excludeSemantics: true,
      child: Focus(
        focusNode: w.focusNode,
        onFocusChange: (_) => setState(() {}),
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.enter ||
                  e.logicalKey == LogicalKeyboardKey.numpadEnter ||
                  e.logicalKey == LogicalKeyboardKey.space)) {
            w.onSelect();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => w.focusNode.requestFocus(),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: w.onSelect,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: highlighted ? DifyColors.stateBaseHover : null,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsetsDirectional.only(start: 4, end: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 2,
                        children: [
                          Text(
                            w.role.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, height: 20 / 14, color: DifyColors.textSecondary),
                          ),
                          Text(
                            w.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (w.selected)
                    Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: RemixIcon('check-line', size: 16, color: DifyColors.textAccent),
                    )
                  else
                    const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
