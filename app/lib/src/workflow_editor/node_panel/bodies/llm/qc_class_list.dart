/// The Question Classifier's classes (nodes/question-classifier/components/class-list.tsx, class-item.tsx,
/// class-label-utils.ts, storage.ts): one prompt editor per class with its inline-editable label, reordered by
/// dragging or from the keyboard, the rename hint and "Add Class".
library;

import 'package:flutter/material.dart' show ReorderableDragStartListener, ReorderableListView;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../../design/dify_icon.dart';
import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';
import '../../../../i18n/dify_i18n.dart';
import '../../../../workflow/dify_json.dart';
import '../../../panel_fields/panel_fields.dart';
import '../../../prompt_editor/config_prompt.dart' show PromptEditorEnv;
import '../../../prompt_editor/prompt_editor_panel.dart';

const _p = 'nodes.questionClassifiers';
String _w(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);

// ---- class-label-utils.ts ----------------------------------------------------------------------------------------

const _equivalentPrefixes = ['CLASS', '分类', '分類', 'クラス'];

/// `getCanonicalDefaultClassLabel` / `getDefaultClassLabel`: `CLASS n`.
String defaultClassLabel(int index) => 'CLASS $index';

/// `getTranslatedDefaultClassLabel`: the translated "CLASS n", or null while the translation is missing (the key
/// comes back).
String? translatedDefaultClassLabel(int index) {
  final resolved = _w('$_p.defaultLabel', {'index': index}).replaceAll('{{index}}', '$index');
  const rawKey = '$_p.defaultLabel', rawWorkflowKey = 'workflow.$rawKey';
  if (resolved == rawKey ||
      resolved == rawWorkflowKey ||
      resolved.startsWith('$rawKey:') ||
      resolved.startsWith('$rawWorkflowKey:')) {
    return null;
  }
  return resolved;
}

/// `getDisplayClassLabel`.
String displayClassLabel(String? label, int index) {
  final l = label?.trim() ?? '';
  return l.isNotEmpty ? l : translatedDefaultClassLabel(index) ?? defaultClassLabel(index);
}

/// `isDefaultClassLabel`.
bool isDefaultClassLabel(String? label, int index) {
  final l = label?.trim() ?? '';
  if (l.isEmpty) return true;
  return _equivalentPrefixes.any((p) => l == '$p $index') || l == translatedDefaultClassLabel(index);
}

/// `getCanonicalClassLabel`.
String canonicalClassLabel(String? label, int index) {
  final l = label?.trim() ?? '';
  if (l.isEmpty || isDefaultClassLabel(l, index)) return defaultClassLabel(index);
  return l;
}

// ---- storage.ts --------------------------------------------------------------------------------------------------

/// `question-classifier-inline-label-hint-dismissed`: dify-sf keeps it for the process (no stored preference slot).
final inlineLabelHintDismissed = ValueNotifier<bool>(false);

// ---- class-item.tsx ----------------------------------------------------------------------------------------------

/// ClassItem: the class's prompt editor (its topic, variables only, a remove button) titled by its label, which a
/// double-click (or Enter / Space) turns into an `h-6` input: Enter or leaving saves the normalised label, Escape
/// cancels.
class ClassItem extends StatefulWidget {
  const ClassItem({
    super.key,
    required this.payload,
    required this.index,
    required this.onChange,
    required this.onRemove,
    required this.env,
    this.readonly = false,
    this.onLabelEditStart,
  });

  /// The topic (`{id, name, label?}`).
  final Json payload;

  /// 1-based.
  final int index;
  final ValueChanged<Json> onChange;
  final VoidCallback onRemove;
  final PromptEditorEnv env;
  final bool readonly;
  final VoidCallback? onLabelEditStart;

  @override
  State<ClassItem> createState() => _ClassItemState();
}

class _ClassItemState extends State<ClassItem> {
  bool _editing = false;
  final _draft = TextEditingController();
  final _focus = FocusNode(debugLabel: 'class label');
  final _titleFocus = FocusNode(debugLabel: 'class title');

  String get _display => displayClassLabel(jsStr(widget.payload['label']), widget.index);

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && _editing) _save(_draft.text);
    });
  }

  @override
  void dispose() {
    _draft.dispose();
    _focus.dispose();
    _titleFocus.dispose();
    super.dispose();
  }

  void _startEdit() {
    if (widget.readonly) return;
    _draft.value = TextEditingValue(
      text: _display,
      selection: TextSelection(baseOffset: 0, extentOffset: _display.length),
    );
    setState(() => _editing = true);
    widget.onLabelEditStart?.call();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  void _save(String value) {
    final normalized = canonicalClassLabel(value, widget.index);
    final display = _display;
    setState(() => _editing = false);
    final label = jsStr(widget.payload['label']);
    if (normalized != display || (label != null && label != normalized)) {
      widget.onChange({...widget.payload, 'label': normalized});
    }
  }

  void _cancel() => setState(() => _editing = false);

  Widget _title() {
    final style = difyTextStyle(DifyType.systemXsSemibold, DifyColors.textSecondary);
    if (_editing) {
      return SizedBox(
        height: 24,
        child: Semantics(
          textField: true,
          label: _w('$_p.labelEditorAriaLabel'),
          child: Focus(
            onKeyEvent: (_, e) {
              if (e is! KeyDownEvent) return KeyEventResult.ignored;
              if (e.logicalKey == LogicalKeyboardKey.enter) {
                _save(_draft.text);
                return KeyEventResult.handled;
              }
              if (e.logicalKey == LogicalKeyboardKey.escape) {
                _cancel();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: DifyColors.componentsInputBgNormal,
                borderRadius: BorderRadius.circular(DifyRadius.md),
                border: Border.all(color: DifyColors.componentsInputBorderActive),
              ),
              child: EditableText(
                controller: _draft,
                focusNode: _focus,
                style: style,
                cursorColor: const Color(0xFF155EEF),
                backgroundCursorColor: DifyColors.textTertiary,
              ),
            ),
          ),
        ),
      );
    }
    final text = Text(_display, style: style);
    if (widget.readonly) {
      return Transform.translate(
        offset: const Offset(-4, 0),
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2), child: text),
      );
    }
    return Transform.translate(
      offset: const Offset(-4, 0),
      child: Focus(
        focusNode: _titleFocus,
        onKeyEvent: (_, e) {
          if (e is KeyDownEvent &&
              (e.logicalKey == LogicalKeyboardKey.enter || e.logicalKey == LogicalKeyboardKey.space)) {
            _startEdit();
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
          container: true,
          button: true,
          label: _display,
          excludeSemantics: true,
          child: _Hover(
            builder: (hovered) => MouseRegion(
              cursor: SystemMouseCursors.text,
              child: GestureDetector(
                onDoubleTap: _startEdit,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  decoration: BoxDecoration(
                    color: hovered ? DifyColors.stateBaseHover : null,
                    borderRadius: BorderRadius.circular(DifyRadius.sm),
                  ),
                  child: text,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.env;
    return DifyPromptEditorPanel(
      title: _title(),
      placeholder: _w('$_p.topicPlaceholder'),
      value: jsStr(widget.payload['name']) ?? '',
      onChange: (v) => widget.onChange({...widget.payload, 'name': v}),
      showRemove: true,
      onRemove: widget.onRemove,
      readOnly: widget.readonly,
      justVar: true,
      isSupportFileVar: true,
      nodesOutputVars: e.nodesOutputVars,
      availableNodes: e.availableNodes,
      getVarType: e.getVarType,
      onOpenUrl: e.onOpenUrl,
    );
  }
}

// ---- class-list.tsx ----------------------------------------------------------------------------------------------

/// ClassList: the "CLASS *" header (it folds the list), the rename hint while a class has a default label, the
/// classes (reordered with the hover handle, by dragging or from the keyboard: Enter / Space starts a move, arrows
/// preview it, Enter / Space commits, Escape cancels) and "Add Class". [onRemove] deletes a class's branch and the
/// class; [onSort] gets a new order.
class ClassList extends StatefulWidget {
  const ClassList({
    super.key,
    required this.list,
    required this.onChange,
    required this.onRemove,
    required this.env,
    this.onSort,
    this.readonly = false,
  });

  final List<Json> list;
  final ValueChanged<List<Json>> onChange;
  final ValueChanged<int> onRemove;
  final ValueChanged<List<Json>>? onSort;
  final PromptEditorEnv env;
  final bool readonly;

  @override
  State<ClassList> createState() => _ClassListState();
}

class _ClassListState extends State<ClassList> {
  bool _collapsed = false;

  /// useKeyboardSortable's session: the list it started from, the previewed order and the moved item.
  ({List<Json> source, List<int> order, int origin})? _session;
  final _handles = <String, FocusNode>{};

  List<Json> get _list => widget.list;

  @override
  void dispose() {
    for (final f in _handles.values) {
      f.dispose();
    }
    super.dispose();
  }

  ({List<Json> source, List<int> order, int origin})? get _current =>
      _session != null && identical(_session!.source, _list) && !widget.readonly ? _session : null;

  List<Json> get _shown => _current == null ? _list : [for (final i in _current!.order) _list[i]];

  /// The index in [ClassList.list] of the row shown at [position] (`getItemKey`).
  int _keyOf(int position) => _current?.order[position] ?? position;

  String _idOf(Json t) => jsKey(t['id']);

  FocusNode _handle(String id) => _handles.putIfAbsent(id, () => FocusNode(debugLabel: 'class sort handle $id'));

  void _toggle(int position) {
    final c = _current;
    if (c != null) {
      final shown = _shown;
      final moved = c.order.indexed.any((e) => e.$1 != e.$2);
      setState(() => _session = null);
      if (moved) widget.onSort?.call(shown);
      _refocus(_idOf(_list[c.origin]));
      return;
    }
    setState(() => _session = (source: _list, order: [for (var i = 0; i < _list.length; i++) i], origin: position));
  }

  void _refocus(String id) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _handles[id]?.requestFocus();
  });

  KeyEventResult _onHandleKey(int position, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      _toggle(_keyOf(position));
      return KeyEventResult.handled;
    }
    final c = _current;
    if (c == null || c.order.indexOf(c.origin) != position) return KeyEventResult.ignored;
    if (k == LogicalKeyboardKey.escape) {
      setState(() => _session = null);
      _refocus(_idOf(_list[c.origin]));
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.tab) {
      setState(() => _session = null);
      return KeyEventResult.ignored;
    }
    if (k == LogicalKeyboardKey.arrowUp || k == LogicalKeyboardKey.arrowDown) {
      final next = (position + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(0, _list.length - 1);
      if (next != position) {
        final order = [...c.order];
        order.insert(next, order.removeAt(position));
        setState(() => _session = (source: c.source, order: order, origin: c.origin));
        _refocus(_idOf(_list[c.origin]));
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _add() {
    widget.onChange([
      ..._list,
      {'id': '${DateTime.now().millisecondsSinceEpoch}', 'name': '', 'label': defaultClassLabel(_list.length + 1)},
    ]);
    if (_collapsed) setState(() => _collapsed = false);
  }

  void _onReorder(int from, int to) {
    final items = [..._list];
    items.insert(to, items.removeAt(from));
    if (items.indexed.any((e) => _idOf(e.$2) != _idOf(_list[e.$1]))) widget.onSort?.call(items);
  }

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final shown = _shown;
    final canDrag = !w.readonly && _list.length >= 2;
    final headerStyle = difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textSecondary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: DifyPressable(
              semanticLabel: _w('$_p.class'),
              onPressed: () => setState(() => _collapsed = !_collapsed),
              builder: (context, hovered, focused) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text.rich(
                      TextSpan(
                        text: '${_w('$_p.class').toUpperCase()} ',
                        children: const [
                          TextSpan(
                            text: '*',
                            style: TextStyle(color: DifyColors.textDestructive),
                          ),
                        ],
                      ),
                      style: headerStyle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_list.isNotEmpty)
                    AnimatedRotation(
                      turns: _collapsed ? -0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: const DifyIcon(
                        'vender/solid/general/arrow-down-round-fill',
                        size: 16,
                        color: DifyColors.textQuaternary,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
        ValueListenableBuilder(
          valueListenable: inlineLabelHintDismissed,
          builder: (context, dismissed, _) {
            final show =
                !w.readonly &&
                !dismissed &&
                _list.indexed.any((e) => isDefaultClassLabel(jsStr(e.$2['label']), e.$1 + 1));
            if (!show) return const SizedBox.shrink();
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: DifyColors.componentsPanelBg,
                borderRadius: BorderRadius.circular(DifyRadius.lg),
                border: Border.all(color: DifyColors.dividerSubtle),
              ),
              child: Text(
                _w('$_p.renameHint'),
                style: const TextStyle(fontSize: 12, height: 16 / 12, color: DifyColors.textTertiary),
              ),
            );
          },
        ),
        if (!_collapsed)
          ReorderableListView(
            shrinkWrap: true,
            buildDefaultDragHandles: false,
            physics: const NeverScrollableScrollPhysics(),
            onReorderItem: _onReorder,
            proxyDecorator: (child, _, _) => child,
            children: [
              for (final (i, t) in shown.indexed)
                Padding(
                  key: ValueKey('class-${_idOf(t)}'),
                  padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
                  child: _row(i, t, canDrag),
                ),
            ],
          ),
        if (!w.readonly && !_collapsed)
          Padding(
            // The list's margin from the panel's `space-y-4` (16 px) and Add's own `mt-2` collapse to 16 px.
            padding: const EdgeInsets.only(top: 16),
            child: AddButton(text: _w('$_p.addClass'), onPressed: _add),
          ),
      ],
    );
  }

  Widget _row(int position, Json t, bool canDrag) {
    final key = _keyOf(position);
    final id = _idOf(t);
    final c = _current;
    final pressed = c != null && c.order.indexOf(c.origin) == position;
    final item = ClassItem(
      key: ValueKey('class-item-$id'),
      payload: t,
      index: position + 1,
      readonly: widget.readonly,
      env: widget.env,
      onChange: (v) => widget.onChange([
        for (final (i, x) in _list.indexed) i == key ? v : x,
      ]),
      onRemove: () => widget.onRemove(key),
      onLabelEditStart: () {
        if (!inlineLabelHintDismissed.value) inlineLabelHintDismissed.value = true;
      },
    );
    if (!canDrag) return item;
    final label = DifyI18n.tr('common', 'sort.handle', {'item': displayClassLabel(jsStr(t['label']), position + 1)});
    return _Hover(
      builder: (hovered) => Stack(
        clipBehavior: Clip.none,
        children: [
          item,
          Positioned(
            top: 6,
            left: -22,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: (_, e) => _onHandleKey(position, e),
              onFocusChange: (_) => setState(() {}),
              child: Builder(
                builder: (context) {
                  final visible = hovered || pressed || _handle(id).hasFocus;
                  return Semantics(
                    button: true,
                    toggled: pressed,
                    label: label,
                    child: Opacity(
                      opacity: visible ? 1 : 0,
                      child: ReorderableDragStartListener(
                        index: position,
                        enabled: c == null,
                        child: DifyIconButton(
                          key: ValueKey('class-sort-handle-$position'),
                          focusNode: _handle(id),
                          label: label,
                          icon: const RemixIcon('draggable', size: 12),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Hover extends StatefulWidget {
  const _Hover({required this.builder});
  final Widget Function(bool hovered) builder;

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(_hovered),
  );
}
