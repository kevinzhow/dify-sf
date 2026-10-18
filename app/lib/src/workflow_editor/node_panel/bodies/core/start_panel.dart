/// The User Input (Start) node's panel (nodes/start/panel.tsx, components/var-list.tsx, components/var-item.tsx).
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../node_panel_bodies.dart';
import '../../panel_edit.dart';
import 'core_kit.dart';
import 'start_config.dart';
import 'start_var_modal.dart';

/// The Start panel body.
Widget startPanelBody(BuildContext context, NodePanelProps props) => _StartPanel(props: props);

class _StartPanel extends StatefulWidget {
  const _StartPanel({required this.props});
  final NodePanelProps props;

  @override
  State<_StartPanel> createState() => _StartPanelState();
}

class _StartPanelState extends State<_StartPanel> {
  NodePanelProps get _p => widget.props;
  late final _crud = PanelInputs(_p);
  late final StartConfig _config = StartConfig(
    id: _p.id,
    inputs: () => _crud.inputs,
    setInputs: (next) => _crud.setInputs(next),
    handleOutVarRenameChange: (_, o, n) => handleOutVarRenameChange(_p.controller, o, n),
    isVarUsedInNodes: (s) => isVarUsedInNodes(_p.controller, s),
    removeUsedVarInNodes: (s) => removeUsedVarInNodes(_p.controller, s),
    nodesWithInspectVars: () => _p.actions.store.nodesWithInspectVars.value,
    deleteInspectVar: (n, v) => _p.actions.store.deleteInspectVar(n, v),
    deleteNodeInspectorVars: (n) => _p.actions.store.deleteNodeInspectVars(n),
    renameInspectVarName: (n, oldName, newName) {
      final store = _p.actions.store;
      final node = store.nodesWithInspectVars.value.where((x) => x['nodeId'] == n).firstOrNull;
      final v = jsList(node?['vars']).where((x) => jsGet(x, 'name') == oldName).firstOrNull;
      if (jsStr(jsGet(v, 'id')) case final id?) store.renameInspectVarName(n, id, [n, newName]);
    },
    toastError: (m) => CorePanelHost.of(context).toastError?.call(m),
    onChanged: _onConfigChanged,
  );

  void _onConfigChanged() {
    if (!mounted) return;
    setState(() {});
    if (_config.isShowRemoveVarConfirm) {
      showRemoveEffectVarConfirm(
        context,
        onConfirm: _config.onRemoveVarConfirm,
        onCancel: _config.hideRemoveVarConfirm,
      );
    }
  }

  void _showAddVarModal() {
    final host = CorePanelHost.of(context);
    showConfigVarModal(
      context,
      isCreate: true,
      supportFile: true,
      maxFileUploadLimit: host.workflowFileUploadLimit,
      toastError: host.toastError,
      onOpenUrl: _p.actions.options.openUrl,
      onConfirm: (payload, _) => _config.handleAddVariable(payload),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readOnly = _p.readOnly, chat = _p.chatMode;
    final title = tw('nodes.start.inputField');
    final list = [
      for (final v in jsList(_p.data['variables']))
        if (v is Map) v.cast<String, Object?>(),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Field(
        title: title,
        operations: readOnly
            ? null
            : FieldAddButton(label: '${tc('operation.add')} $title', onPressed: _showAddVarModal),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            StartVarList(readonly: readOnly, list: list, onChange: _config.handleVarListChange),
            // `mt-1` around the split's `my-2`: the margins collapse to 8 px.
            const PanelSplit(margin: EdgeInsets.symmetric(vertical: 8)),
            if (chat) ...[
              StartVarItem(
                readonly: true,
                payload: const {'variable': 'userinput.query'},
                rightContent: _sysType('String'),
              ),
              const SizedBox(height: 4),
            ],
            StartVarItem(
              readonly: true,
              showLegacyBadge: !chat,
              payload: const {'variable': 'userinput.files'},
              rightContent: _sysType('Array[File]'),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _sysType(String text) => Text(
    text,
    style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
  );
}

/// One edit of a [StartVarList]: the new list, and what changed at which index (a rename or a removal).
typedef StartVarListChange = void Function(List<Object?> list, [({int index, VarChange payload})? moreInfo]);

/// var-list.tsx: the input fields, or the "Set inputs…" placeholder. Rows reorder by dragging (the row, or the handle
/// that shows on its left while hovered) and from the keyboard (Enter / Space on a handle, arrows, Enter / Space to
/// drop, Escape to cancel). An edit that repeats a name or label is refused with a toast.
class StartVarList extends StatefulWidget {
  const StartVarList({super.key, required this.readonly, required this.list, required this.onChange});
  final bool readonly;
  final List<Map<String, Object?>> list;
  final StartVarListChange onChange;

  @override
  State<StartVarList> createState() => _StartVarListState();
}

class _StartVarListState extends State<StartVarList> {
  ({List<Map<String, Object?>> source, List<int> order, int origin})? _session;
  final _handles = <int, FocusNode>{};
  final _focused = <int>{};
  int? _hovered;

  @override
  void dispose() {
    for (final f in _handles.values) {
      f.dispose();
    }
    super.dispose();
  }

  ({List<Map<String, Object?>> source, List<int> order, int origin})? get _current =>
      _session != null && identical(_session!.source, widget.list) && !widget.readonly ? _session : null;

  int _keyOf(int position) => _current?.order[position] ?? position;

  FocusNode _handle(int key) =>
      _handles.putIfAbsent(key, () => FocusNode(debugLabel: 'start var handle ${widget.list[key]['variable']}'));

  void _focusHandle(int position) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _handles[_keyOf(position)]?.requestFocus();
  });

  void _toggleSort(int index) {
    final list = widget.list;
    if (widget.readonly || list.length < 2) return;
    final c = _current;
    if (c != null) {
      final active = c.order.indexOf(c.origin);
      final moved = [for (final (p, o) in c.order.indexed) p != o].any((x) => x);
      final shown = [for (final i in c.order) list[i]];
      setState(() => _session = null);
      if (moved) widget.onChange(shown);
      _focusHandle(active);
      return;
    }
    setState(() => _session = (source: list, order: [for (var i = 0; i < list.length; i++) i], origin: index));
  }

  KeyEventResult _onHandleKey(int position, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      _toggleSort(_keyOf(position));
      return KeyEventResult.handled;
    }
    final c = _current;
    if (c == null || c.order.indexOf(c.origin) != position) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _session = null);
      WidgetsBinding.instance.addPostFrameCallback((_) => _handles[c.origin]?.requestFocus());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final next = (position + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(0, widget.list.length - 1);
      if (next != position) {
        final order = [...c.order]..insert(next, c.order[position]);
        order.removeAt(position < next ? position : position + 1);
        setState(() => _session = (source: c.source, order: order, origin: c.origin));
        _focusHandle(next);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// handleVarChange.
  bool _change(int index, Map<String, Object?> payload, VarChange? moreInfo) {
    final list = [for (final (i, v) in widget.list.indexed) i == index ? payload : v];
    final error = startVarDuplicateError(list, DifyI18n.tr);
    if (error != null) {
      CorePanelHost.of(context).toastError?.call(error);
      return false;
    }
    widget.onChange(list, moreInfo == null ? null : (index: index, payload: moreInfo));
    return true;
  }

  void _remove(int index) {
    if (_session != null) setState(() => _session = null);
    widget.onChange(
      [
        for (final (i, v) in widget.list.indexed)
          if (i != index) v,
      ],
      (index: index, payload: VarChange.remove(jsKey(widget.list[index]['variable']))),
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (w.list.isEmpty) {
      return Container(
        height: 42,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.md),
        ),
        child: Text(
          tw('nodes.start.noVarTip'),
          style: const TextStyle(fontSize: 12, height: 18 / 12, color: DifyColors.textTertiary),
        ),
      );
    }
    final c = _current;
    final shown = c == null ? w.list : [for (final i in c.order) w.list[i]];
    final active = c?.order.indexOf(c.origin) ?? -1;
    final canDrag = !w.readonly && w.list.length > 1;
    final keys = [for (final v in w.list) jsKey(v['variable'])];
    return ReorderableList(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: shown.length,
      proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
      onReorderItem: (from, to) {
        if (from == to) return;
        final list = [...w.list]..insert(to, w.list[from]);
        list.removeAt(from < to ? from : from + 1);
        w.onChange(list);
      },
      itemBuilder: (context, position) {
        final index = _keyOf(position);
        final item = shown[position];
        final faded = canDrag && (_hovered == index || _focused.contains(index) || active == position);
        Widget row = StartVarItem(
          readonly: w.readonly,
          payload: item,
          varKeys: keys,
          iconHidden: faded,
          onChange: (p, m) => _change(index, p, m),
          onRemove: () => _remove(index),
        );
        if (canDrag) row = ReorderableDragStartListener(index: position, enabled: c == null, child: row);
        return MouseRegion(
          key: ValueKey('start-var-${item['variable']}'),
          onEnter: (_) => setState(() => _hovered = index),
          onExit: (_) => setState(() => _hovered = _hovered == index ? null : _hovered),
          child: Padding(
            padding: EdgeInsets.only(top: position == 0 ? 0 : 4),
            child: Stack(
              children: [
                row,
                if (canDrag)
                  Positioned(
                    left: 6,
                    top: 4,
                    child: _Handle(
                      focusNode: _handle(index),
                      label: DifyI18n.tr('common', 'sort.handle', {'item': jsKey(item['variable'])}),
                      pressed: active == position,
                      visible: faded,
                      onKey: (e) => _onHandleKey(position, e),
                      onFocus: (f) {
                        setState(() => f ? _focused.add(index) : _focused.remove(index));
                        if (!f && _current != null && active == position) setState(() => _session = null);
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The 24 px reorder handle (`i-ri-draggable size-3`), a toggle button pressed while its row moves.
class _Handle extends StatelessWidget {
  const _Handle({
    required this.focusNode,
    required this.label,
    required this.pressed,
    required this.visible,
    required this.onKey,
    required this.onFocus,
  });
  final FocusNode focusNode;
  final String label;
  final bool pressed, visible;
  final KeyEventResult Function(KeyEvent e) onKey;
  final ValueChanged<bool> onFocus;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: pressed,
    label: label,
    child: Focus(
      focusNode: focusNode,
      onKeyEvent: (_, e) => onKey(e),
      onFocusChange: onFocus,
      child: Opacity(
        opacity: visible ? 1 : 0,
        child: IgnorePointer(
          ignoring: !visible,
          child: Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: pressed ? DifyColors.stateBaseHover : null,
              borderRadius: BorderRadius.circular(DifyRadius.md),
              boxShadow: focusNode.hasFocus
                  ? const [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)]
                  : null,
            ),
            child: const Center(child: RemixIcon('draggable', size: 12, color: DifyColors.textTertiary)),
          ),
        ),
      ),
    ),
  );
}

/// var-item.tsx: an input field's row (`h-8 rounded-lg border bg-components-panel-on-panel-item-bg px-2.5`): its
/// key, `·` label, LEGACY badge; "required" and the type icon, or while hovered the edit (opening the dialog) and
/// remove buttons; [rightContent] replaces the right side.
class StartVarItem extends StatefulWidget {
  const StartVarItem({
    super.key,
    required this.readonly,
    required this.payload,
    this.onChange,
    this.onRemove,
    this.rightContent,
    this.varKeys = const [],
    this.showLegacyBadge = false,
    this.iconHidden = false,
  });

  final bool readonly;
  final Map<String, Object?> payload;

  /// The edited field and how its key changed; false keeps the dialog open.
  final bool Function(Map<String, Object?> payload, VarChange? moreInfo)? onChange;
  final VoidCallback? onRemove;
  final Widget? rightContent;
  final List<String> varKeys;
  final bool showLegacyBadge;

  /// The variable icon gives way to the reorder handle (`group-hover:opacity-0`).
  final bool iconHidden;

  @override
  State<StartVarItem> createState() => _StartVarItemState();
}

class _StartVarItemState extends State<StartVarItem> {
  bool _hovered = false;

  void _edit() {
    final host = CorePanelHost.of(context);
    showConfigVarModal(
      context,
      payload: widget.payload,
      supportFile: true,
      maxFileUploadLimit: host.workflowFileUploadLimit,
      toastError: host.toastError,
      onConfirm: (p, m) => widget.onChange?.call(p, m) ?? true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final variable = jsKey(w.payload['variable']);
    final label = jsStr(w.payload['label']) ?? '';
    const medium = TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelOnPanelItemBg,
          borderRadius: BorderRadius.circular(DifyRadius.lg),
          border: Border.all(color: DifyColors.componentsPanelBorderSubtle),
          boxShadow: _hovered ? DifyShadows.md : DifyShadows.xs,
        ),
        child: Row(
          children: [
            Expanded(
              child: Row(
                spacing: 4,
                children: [
                  Opacity(
                    opacity: w.iconHidden ? 0 : 1,
                    child: const DifyIcon(
                      'vender/solid/development/variable-02',
                      size: 14,
                      color: DifyColors.textAccent,
                    ),
                  ),
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: Text(
                        variable,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: medium.copyWith(color: DifyColors.textSecondary),
                      ),
                    ),
                  ),
                  if (label.isNotEmpty) ...[
                    const Text(
                      '·',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w500, color: DifyColors.textQuaternary),
                    ),
                    Flexible(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 130),
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: medium.copyWith(color: DifyColors.textTertiary),
                        ),
                      ),
                    ),
                  ],
                  if (w.showLegacyBadge) const _LegacyBadge(),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (w.rightContent != null)
              w.rightContent!
            else if (!_hovered || w.readonly) ...[
              if (w.payload['required'] == true)
                Container(
                  constraints: const BoxConstraints(maxWidth: 120),
                  padding: const EdgeInsets.only(right: 8),
                  child: Text(
                    tw('nodes.start.required'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
                  ),
                ),
              InputVarTypeIcon(type: jsKey(w.payload['type']), size: 14),
            ] else ...[
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: _ItemButton(
                  label: tc('operation.edit'),
                  onPressed: _edit,
                  icon: (hovered) =>
                      const DifyIcon('vender/solid/general/edit-03', size: 16, color: DifyColors.textTertiary),
                ),
              ),
              _ItemButton(
                label: tc('operation.remove'),
                destructive: true,
                onPressed: w.onRemove ?? () {},
                icon: (hovered) => RemixIcon(
                  'delete-bin-line',
                  size: 16,
                  color: hovered ? DifyColors.textDestructive : DifyColors.textTertiary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The row's `p-1 rounded-md` buttons (edit: `hover:bg-state-base-hover`, remove: `hover:bg-state-destructive-hover`).
class _ItemButton extends StatelessWidget {
  const _ItemButton({required this.label, required this.onPressed, required this.icon, this.destructive = false});
  final String label;
  final VoidCallback onPressed;
  final Widget Function(bool hovered) icon;
  final bool destructive;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: hovered ? (destructive ? DifyColors.stateDestructiveHover : DifyColors.stateBaseHover) : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: focused
            ? Border.all(
                color: destructive ? DifyColors.stateDestructiveBorder : DifyColors.componentsInputBorderActive,
              )
            : null,
      ),
      child: icon(hovered),
    ),
  );
}

/// Badge "LEGACY" (`border-text-accent-secondary text-text-accent-secondary`).
class _LegacyBadge extends StatelessWidget {
  const _LegacyBadge();

  @override
  Widget build(BuildContext context) => Container(
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    alignment: Alignment.center,
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: DifyColors.textAccentSecondary),
    ),
    child: Text(
      'LEGACY',
      style: difyTextStyle(DifyType.system2xsMediumUppercase, DifyColors.textAccentSecondary),
    ),
  );
}
