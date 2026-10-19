/// Variable lists of panels (nodes/_base/components/variable/var-list.tsx, output-var-list.tsx, and
/// base/keyboard-sortable/use-keyboard-sortable.tsx).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'field.dart';
import 'selectors.dart';
import 'var_picker_model.dart';
import 'var_reference_picker.dart';
import '../../design/widgets/widgets.dart';

/// `replaceSpaceWithUnderscoreInVarNameInput`: spaces typed into a variable name become underscores.
final varNameFormatter = TextInputFormatter.withFunction(
  (old, value) => value.copyWith(text: value.text.replaceAll(' ', '_')),
);

/// The debounced name check of the lists (500 ms): the `varKeyError` message for an invalid or duplicate name.
String? varNameError(String newKey, Iterable<String> others) {
  final bad = checkKeys([newKey], canBeEmpty: true);
  if (bad != null) return DifyI18n.tr('app-debug', 'varKeyError.${bad.error}', {'key': bad.key});
  if (others.any((v) => v.trim() == newKey.trim())) {
    return DifyI18n.tr('app-debug', 'varKeyError.keyAlreadyExists', {'key': newKey});
  }
  return null;
}

/// One row of a [VarList] (Dify's `Variable`): its name, the selector it takes its value from (with the value's
/// type), or with constants allowed its kind and constant [value]. [id] is the document's item id, carried through
/// edits.
final class VarListItem {
  const VarListItem({
    required this.variable,
    this.valueSelector = const [],
    this.valueType,
    this.variableType,
    this.value,
    this.id,
  });

  final String variable;
  final List<String> valueSelector;
  final String? valueType;
  final VarKindType? variableType;
  final String? value;
  final String? id;

  VarListItem copyWith({
    String? variable,
    List<String>? valueSelector,
    String? valueType,
    VarKindType? variableType,
    String? value,
  }) => VarListItem(
    variable: variable ?? this.variable,
    valueSelector: valueSelector ?? this.valueSelector,
    valueType: valueType ?? this.valueType,
    variableType: variableType ?? this.variableType,
    value: value ?? this.value,
    id: id,
  );

  @override
  bool operator ==(Object other) =>
      other is VarListItem &&
      other.variable == variable &&
      other.valueType == valueType &&
      other.variableType == variableType &&
      other.value == value &&
      other.id == id &&
      other.valueSelector.join('\u0000') == valueSelector.join('\u0000');

  @override
  int get hashCode => Object.hash(variable, valueSelector.join('.'), valueType, variableType, value, id);

  @override
  String toString() => 'VarListItem($variable <- ${valueSelector.join('.')})';
}

/// VarList (var-list.tsx, used by End, Template, Code inputs): one row per variable, a name input (`w-30`), a
/// [VarReferencePicker] and a remove button. Choosing a variable for a row without a name names it after the
/// variable (`name`, `name_1`, …). Rows reorder by dragging (a long press, or the handle that shows left of a hovered
/// row) and from the keyboard: Enter / Space on a handle starts a move, arrows preview it, Enter / Space commits and
/// Escape cancels. Invalid or duplicate names are reported with [onError] after 500 ms (Dify's toast).
class VarList extends StatefulWidget {
  const VarList({
    super.key,
    required this.list,
    required this.onChange,
    required this.scope,
    this.readonly = false,
    this.onVarNameChange,
    this.isSupportConstantValue = false,
    this.filterVar,
    this.isSupportFileVar = true,
    this.onError = difyToastError,
  });

  final List<VarListItem> list;
  final ValueChanged<List<VarListItem>> onChange;
  final VarScope scope;
  final bool readonly;
  final void Function(String oldName, String newName)? onVarNameChange;
  final bool isSupportConstantValue;
  final VarFilter? filterVar;
  final bool isSupportFileVar;
  final ValueChanged<String>? onError;

  @override
  State<VarList> createState() => _VarListState();
}

class _VarListState extends State<VarList> {
  /// The keyboard move in progress: the list it started from, the previewed order and the moved row.
  ({List<VarListItem> source, List<int> order, int origin})? _session;
  final _handles = <int, FocusNode>{};
  Timer? _debounce;
  int? _hovered;

  @override
  void dispose() {
    _debounce?.cancel();
    for (final f in _handles.values) {
      f.dispose();
    }
    super.dispose();
  }

  FocusNode _handle(int key) => _handles.putIfAbsent(key, () => FocusNode(debugLabel: 'var sort handle $key'));

  ({List<VarListItem> source, List<int> order, int origin})? get _current =>
      _session != null && identical(_session!.source, widget.list) && !widget.readonly ? _session : null;

  List<VarListItem> get _shown => _current == null ? widget.list : [for (final i in _current!.order) widget.list[i]];

  int _keyOf(int index) => _current?.order[index] ?? index;

  void _focusHandle(int position) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _handles[_keyOf(position)]?.requestFocus();
  });

  void _toggleSort(int index) {
    final list = widget.list;
    if (widget.readonly || list.length < 2) return;
    final c = _current;
    if (c != null) {
      final active = c.order.indexOf(c.origin);
      final moved = [
        for (final (p, o) in c.order.indexed)
          if (o != p) o,
      ].isNotEmpty;
      final shown = _shown;
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
    if (k == LogicalKeyboardKey.tab) {
      setState(() => _session = null);
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final next = (position + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(0, widget.list.length - 1);
      if (next != position) {
        final order = [...c.order];
        order.insert(next, order.removeAt(position));
        setState(() => _session = (source: c.source, order: order, origin: c.origin));
        _focusHandle(next);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _rename(int index, String name) {
    final list = widget.list;
    _debounce?.cancel();
    final others = [
      for (final (i, v) in list.indexed)
        if (i != index) v.variable,
    ];
    _debounce = Timer(const Duration(milliseconds: 500), () {
      final error = varNameError(name, others);
      if (error != null) widget.onError?.call(error);
    });
    widget.onVarNameChange?.call(list[index].variable, name);
    widget.onChange([for (final (i, v) in list.indexed) i == index ? v.copyWith(variable: name) : v]);
  }

  void _setSelector(int index, List<String> selector, PickerVar? info) {
    final list = widget.list;
    var item = list[index].copyWith(valueSelector: selector);
    item = VarListItem(
      variable: item.variable,
      valueSelector: selector,
      valueType: info?.type,
      variableType: widget.isSupportConstantValue ? VarKindType.variable : item.variableType,
      value: item.value,
      id: item.id,
    );
    if (item.variable.isEmpty && selector.isNotEmpty) {
      final names = list.map((v) => v.variable).toSet();
      var name = selector.last;
      for (var n = 1; names.contains(name); n++) {
        name = '${selector.last}_$n';
      }
      item = item.copyWith(variable: name);
    }
    widget.onChange([for (final (i, v) in list.indexed) i == index ? item : v]);
  }

  void _setConstant(int index, String value) {
    final list = widget.list;
    widget.onChange([
      for (final (i, v) in list.indexed)
        i == index
            ? VarListItem(
                variable: v.variable,
                valueSelector: v.valueSelector,
                valueType: v.valueType,
                variableType: VarKindType.constant,
                value: value,
                id: v.id,
              )
            : v,
    ]);
  }

  void _remove(int index) {
    final list = widget.list;
    if (_session != null) setState(() => _session = null);
    widget.onChange([
      for (final (i, v) in list.indexed)
        if (i != index) v,
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final shown = _shown;
    final c = _current;
    final active = c?.order.indexOf(c.origin) ?? -1;
    final canDrag = !w.readonly && shown.length > 1;
    final nameLabel = DifyI18n.tr('workflow', 'common.variableNamePlaceholder');
    final rows = <Widget>[
      for (final (position, item) in shown.indexed)
        () {
          final index = _keyOf(position);
          final constant = item.variableType == VarKindType.constant;
          final row = Row(
            spacing: 4,
            children: [
              SizedBox(
                width: 120,
                child: DifyInput(
                  value: item.variable,
                  semanticLabel: nameLabel,
                  placeholder: nameLabel,
                  disabled: w.readonly,
                  formatters: [varNameFormatter],
                  onChanged: (v) => _rename(index, v),
                ),
              ),
              Expanded(
                child: VarReferencePicker(
                  value: constant ? const [] : item.valueSelector,
                  constantValue: constant ? item.value ?? '' : '',
                  scope: w.scope,
                  readonly: w.readonly,
                  isSupportConstantValue: w.isSupportConstantValue,
                  defaultVarKindType: item.variableType ?? VarKindType.constant,
                  filterVar: w.filterVar,
                  isSupportFileVar: w.isSupportFileVar,
                  onChange: (sel, info) => _setSelector(index, sel, info),
                  onConstantChange: (v) => _setConstant(index, v),
                ),
              ),
              if (!w.readonly) RemoveButton(onPressed: () => _remove(index)),
            ],
          );
          return MouseRegion(
            key: ValueKey(item.id ?? index),
            onEnter: (_) => setState(() => _hovered = index),
            onExit: (_) => setState(() => _hovered = _hovered == index ? null : _hovered),
            child: Padding(
              padding: EdgeInsets.only(top: position == 0 ? 0 : 8),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (canDrag)
                    ReorderableDelayedDragStartListener(index: position, enabled: c == null, child: row)
                  else
                    row,
                  if (canDrag)
                    Positioned(
                      left: -24,
                      top: 4,
                      child: _SortHandle(
                        focusNode: _handle(index),
                        label: DifyI18n.tr('common', 'sort.handle', {'item': item.variable}),
                        pressed: active == position,
                        visible: _hovered == index,
                        onKey: (e) => _onHandleKey(position, e),
                        onBlur: () {
                          if (_current != null && active == position) setState(() => _session = null);
                        },
                        dragIndex: position,
                      ),
                    ),
                ],
              ),
            ),
          );
        }(),
    ];
    return ReorderableList(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: rows.length,
      itemBuilder: (context, i) => rows[i],
      proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
      onReorderItem: (from, to) {
        if (from == to) return;
        final list = [...w.list];
        list.insert(to, list.removeAt(from));
        w.onChange(list);
      },
    );
  }
}

/// The drag handle of a [VarList] row: a 24 px toggle button with `i-ri-draggable`, shown while its row is hovered,
/// focused or moving ([pressed]).
class _SortHandle extends StatefulWidget {
  const _SortHandle({
    required this.focusNode,
    required this.label,
    required this.pressed,
    required this.visible,
    required this.onKey,
    required this.onBlur,
    required this.dragIndex,
  });
  final FocusNode focusNode;
  final String label;
  final bool pressed, visible;
  final KeyEventResult Function(KeyEvent e) onKey;
  final VoidCallback onBlur;
  final int dragIndex;

  @override
  State<_SortHandle> createState() => _SortHandleState();
}

class _SortHandleState extends State<_SortHandle> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    toggled: widget.pressed,
    label: widget.label,
    child: Focus(
      focusNode: widget.focusNode,
      onKeyEvent: (_, e) => widget.onKey(e),
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (!f) widget.onBlur();
      },
      child: Opacity(
        opacity: widget.visible || _focused || widget.pressed ? 1 : 0,
        child: ReorderableDragStartListener(
          index: widget.dragIndex,
          child: MouseRegion(
            cursor: SystemMouseCursors.grab,
            child: Container(
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                color: widget.pressed ? DifyColors.stateBaseHover : null,
                borderRadius: BorderRadius.circular(DifyRadius.md),
                boxShadow: _focused ? [BoxShadow(color: DifyColors.stateAccentSolid, spreadRadius: 2)] : null,
              ),
              child: Center(child: RemixIcon('draggable', size: 12, color: DifyColors.textTertiary)),
            ),
          ),
        ),
      ),
    ),
  );
}

/// OutputVarList (output-var-list.tsx, the Code node's outputs): a name input, a [VarTypePicker] and a remove
/// button per key of [outputKeyOrders]. Renaming moves the key's type to the new name (keeping the old key while
/// another row still uses it) and reports `onChange(outputs, index, newKey)`; a type change reports
/// `onChange(outputs)`.
class OutputVarList extends StatefulWidget {
  const OutputVarList({
    super.key,
    required this.outputs,
    required this.outputKeyOrders,
    required this.onChange,
    required this.onRemove,
    this.readonly = false,
    this.onError = difyToastError,
  });

  /// Output name to VarType.
  final Map<String, String> outputs;
  final List<String> outputKeyOrders;
  final void Function(Map<String, String> outputs, [int? changedIndex, String? newKey]) onChange;
  final ValueChanged<int> onRemove;
  final bool readonly;
  final ValueChanged<String>? onError;

  @override
  State<OutputVarList> createState() => _OutputVarListState();
}

class _OutputVarListState extends State<OutputVarList> {
  Timer? _debounce;

  @override
  void dispose() {
    _debounce?.cancel();
    super.dispose();
  }

  void _rename(int index, String newKey) {
    final keys = widget.outputKeyOrders;
    final oldKey = keys[index];
    final others = [
      for (final (i, k) in keys.indexed)
        if (i != index) k,
    ];
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), () {
      final error = varNameError(newKey, others);
      if (error != null) widget.onError?.call(error);
    });
    final outputs = {...widget.outputs};
    final type = outputs[oldKey];
    if (type != null) outputs[newKey] = type;
    if (!others.contains(oldKey) && oldKey != newKey) outputs.remove(oldKey);
    widget.onChange(outputs, index, newKey);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final label = DifyI18n.tr('workflow', 'common.variableNamePlaceholder');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 8,
      children: [
        for (final (i, key) in w.outputKeyOrders.indexed)
          Row(
            spacing: 4,
            children: [
              Expanded(
                child: DifyInput(
                  value: key,
                  readOnly: w.readonly,
                  semanticLabel: label,
                  placeholder: label,
                  formatters: [varNameFormatter],
                  onChanged: (v) => _rename(i, v),
                ),
              ),
              VarTypePicker(
                readonly: w.readonly,
                value: w.outputs[key] ?? 'string',
                onChanged: (type) => w.onChange({...w.outputs, key: type}),
              ),
              RemoveButton(onPressed: () => w.onRemove(i)),
            ],
          ),
      ],
    );
  }
}
