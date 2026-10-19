/// The LLM node's prompt list (workflow/nodes/llm/components/config-prompt.tsx, config-prompt-item.tsx): one
/// prompt editor per chat message with its role, reordered by dragging or with the keyboard
/// (base/keyboard-sortable), or a single prompt for completion models.
library;

import 'dart:math';

import 'package:flutter/material.dart' show ReorderableDragStartListener, ReorderableListView;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../panel_fields/controls.dart' show Infotip;
import '../panel_fields/field.dart' show AddButton;
import '../panel_fields/selectors.dart' show TypeSelector;
import '../panel_fields/var_picker_model.dart';
import 'prompt_editor_panel.dart';
import 'prompt_editor_types.dart';

/// `PromptRole`.
enum PromptRole { system, user, assistant }

/// `PromptItem`.
class PromptItem {
  const PromptItem({this.id, this.role, this.text = '', this.editionType, this.jinja2Text});

  final String? id;
  final PromptRole? role;
  final String text;
  final PromptEditionType? editionType;
  final String? jinja2Text;

  bool get isJinja => editionType == PromptEditionType.jinja2;

  PromptItem copyWith({
    String? id,
    PromptRole? role,
    String? text,
    PromptEditionType? editionType,
    String? jinja2Text,
  }) => PromptItem(
    id: id ?? this.id,
    role: role ?? this.role,
    text: text ?? this.text,
    editionType: editionType ?? this.editionType,
    jinja2Text: jinja2Text ?? this.jinja2Text,
  );

  /// The text the editor shows and edits: `jinja2_text` in jinja2 mode, else `text`.
  PromptItem withPrompt(String p) => isJinja ? copyWith(jinja2Text: p) : copyWith(text: p);

  @override
  bool operator ==(Object other) =>
      other is PromptItem &&
      other.id == id &&
      other.role == role &&
      other.text == text &&
      other.editionType == editionType &&
      other.jinja2Text == jinja2Text;

  @override
  int get hashCode => Object.hash(id, role, text, editionType, jinja2Text);

  @override
  String toString() => 'PromptItem($id, ${role?.name}, $text)';
}

final _random = Random();

/// A random v4 UUID (`uuid4()`).
String uuid4() {
  String hex(int n) => [for (var i = 0; i < n; i++) _random.nextInt(16).toRadixString(16)].join();
  return '${hex(8)}-${hex(4)}-4${hex(3)}-${(8 + _random.nextInt(4)).toRadixString(16)}${hex(3)}-${hex(12)}';
}

/// What every prompt editor of the list shares (the props ConfigPrompt passes down to Editor besides the item's own).
class PromptEditorEnv {
  const PromptEditorEnv({
    this.nodesOutputVars = const [],
    this.availableNodes = const {},
    this.getVarType,
    this.onJumpToNode,
    this.isModelPluginInstalled,
    this.expandedWidth = 419,
    this.onOpenUrl,
    this.jinjaEditorBuilder,
    this.headerExtra,
  });

  final List<VarGroup> nodesOutputVars;
  final Map<String, WorkflowNodeInfo> availableNodes;
  final PromptGetVarType? getVarType;
  final void Function(String nodeId)? onJumpToNode;
  final bool Function(String pluginId)? isModelPluginInstalled;
  final double expandedWidth;
  final void Function(String url)? onOpenUrl;
  final Widget Function(BuildContext context, JinjaEditorArgs args)? jinjaEditorBuilder;

  /// The prompt generator button of an item (by its id; null for the completion prompt).
  final Widget? Function(String? id)? headerExtra;
}

/// ConfigPromptItem's title: "SYSTEM", or the role selector; then the role's description in an infotip.
class PromptRoleTitle extends StatelessWidget {
  const PromptRoleTitle({super.key, required this.role, required this.onChange, this.canNotChooseSystemRole = false});
  final PromptRole? role;
  final ValueChanged<PromptRole> onChange;
  final bool canNotChooseSystemRole;

  @override
  Widget build(BuildContext context) {
    final r = role;
    final description = r == null ? null : DifyI18n.tr('workflow', 'nodes.llm.roleDescription.${r.name}');
    final style = difyTextStyle(DifyType.systemXsSemiboldUppercase, DifyColors.textSecondary);
    return Transform.translate(
      offset: const Offset(4, 0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (r == PromptRole.system)
            Transform.translate(
              offset: const Offset(-4, 0),
              child: Text('SYSTEM', style: style),
            )
          else
            Transform.translate(
              offset: const Offset(-8, 0),
              child: TypeSelector<PromptRole>(
                value: r,
                options: [
                  for (final o in PromptRole.values)
                    if (!(canNotChooseSystemRole && o == PromptRole.system)) (value: o, label: o.name),
                ],
                onChanged: onChange,
                trigger: _RoleTrigger(label: r?.name ?? '', style: style),
              ),
            ),
          if (description != null) Infotip(label: description, width: 180, content: Text(description)),
        ],
      ),
    );
  }
}

class _RoleTrigger extends StatefulWidget {
  const _RoleTrigger({required this.label, required this.style});
  final String label;
  final TextStyle style;

  @override
  State<_RoleTrigger> createState() => _RoleTriggerState();
}

class _RoleTriggerState extends State<_RoleTrigger> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Container(
      height: 20,
      padding: const EdgeInsets.only(left: 4, right: 2),
      decoration: BoxDecoration(
        color: _hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(widget.label.toUpperCase(), style: widget.style),
          DifyIcon('vender/line/arrows/chevron-selector-vertical', size: 12, color: DifyColors.textSecondary),
        ],
      ),
    ),
  );
}

/// ConfigPrompt. [payload] is a `List<PromptItem>` for chat models, one [PromptItem] otherwise; [onChange] gets the
/// same shape back. [env] completes each item's editor.
class ConfigPrompt extends StatefulWidget {
  const ConfigPrompt({
    super.key,
    required this.payload,
    required this.onChange,
    required this.nodeId,
    this.readOnly = false,
    this.isChatModel = false,
    this.isChatApp = false,
    this.isShowContext = false,
    this.hasSetBlockStatus = (context: false, history: false, query: false),
    this.env = const PromptEditorEnv(),
  });

  final Object payload;
  final ValueChanged<Object> onChange;
  final String nodeId;
  final bool readOnly;
  final bool isChatModel;
  final bool isChatApp;
  final bool isShowContext;
  final BlockStatus hasSetBlockStatus;
  final PromptEditorEnv env;

  @override
  State<ConfigPrompt> createState() => _ConfigPromptState();
}

class _ConfigPromptState extends State<ConfigPrompt> {
  /// useKeyboardSortable's session: the list it started from, the previewed order and the moved item.
  ({List<PromptItem> source, List<int> order, int origin})? _session;
  final _handles = <int, FocusNode>{};
  final _ids = <int, String>{};

  List<PromptItem> get _prompts =>
      widget.isChatModel && widget.payload is List<PromptItem> ? widget.payload as List<PromptItem> : const [];

  int get _minIndex => _prompts.firstOrNull?.role == PromptRole.system ? 1 : 0;

  ({List<PromptItem> source, List<int> order, int origin})? get _current =>
      _session != null && identical(_session!.source, _prompts) && !widget.readOnly ? _session : null;

  List<PromptItem> get _shown => _current == null ? _prompts : [for (final i in _current!.order) _prompts[i]];

  int _keyOf(int index) => _current?.order[index] ?? index;

  @override
  void initState() {
    super.initState();
    _persistIds();
  }

  @override
  void didUpdateWidget(ConfigPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    _persistIds();
  }

  @override
  void dispose() {
    for (final f in _handles.values) {
      f.dispose();
    }
    super.dispose();
  }

  /// ReactSortable reports the list once mounted: prompts without ids get the ids generated for them.
  void _persistIds() {
    final prompts = _prompts;
    if (prompts.every((p) => p.id != null)) return;
    final withIds = [for (final (i, p) in prompts.indexed) p.id == null ? p.copyWith(id: _ids[i] ??= uuid4()) : p];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_prompts, prompts)) widget.onChange(withIds);
    });
  }

  FocusNode _handle(int key) => _handles.putIfAbsent(key, () => FocusNode(debugLabel: 'prompt sort handle $key'));

  void _focusHandle(int position) => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted) _handles[_keyOf(position)]?.requestFocus();
  });

  bool _sortable(int index) => !widget.readOnly && index >= _minIndex && _prompts.length - _minIndex >= 2;

  void _toggle(int index) {
    if (!_sortable(index)) return;
    final c = _current;
    if (c != null) {
      final active = c.order.indexOf(c.origin);
      final shown = _shown;
      final moved = c.order.indexed.any((e) => e.$1 != e.$2);
      setState(() => _session = null);
      if (moved) widget.onChange(shown);
      _focusHandle(active);
      return;
    }
    setState(() => _session = (source: _prompts, order: [for (var i = 0; i < _prompts.length; i++) i], origin: index));
  }

  KeyEventResult _onHandleKey(int position, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final kb = HardwareKeyboard.instance;
    if (kb.isAltPressed || kb.isControlPressed || kb.isMetaPressed) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.enter) {
      _toggle(_keyOf(position));
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
      final next = (position + (k == LogicalKeyboardKey.arrowUp ? -1 : 1)).clamp(_minIndex, _prompts.length - 1);
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

  void _update(int index, PromptItem Function(PromptItem p) f) =>
      widget.onChange([for (final (i, p) in _prompts.indexed) i == index ? f(p) : p]);

  void _add() {
    final list = _prompts;
    if (list.isEmpty) {
      widget.onChange([PromptItem(role: PromptRole.system, id: uuid4())]);
      return;
    }
    final lastUser = list.last.role == PromptRole.user;
    widget.onChange([...list, PromptItem(role: lastUser ? PromptRole.assistant : PromptRole.user, id: uuid4())]);
  }

  /// setList after a drag: the leading system prompt keeps its place.
  void _onReorder(int from, int to) {
    final list = [..._prompts];
    list.insert(to, list.removeAt(from));
    if (_prompts.firstOrNull?.role == PromptRole.system && list.first.role != PromptRole.system) return;
    widget.onChange(list);
  }

  DifyPromptEditorPanel _panel({
    Key? key,
    String? id,
    required Widget title,
    required PromptItem item,
    required ValueChanged<String> onChange,
    required ValueChanged<PromptEditionType> onEditionTypeChange,
    bool showRemove = false,
    VoidCallback? onRemove,
    bool isSupportFileVar = false,
  }) {
    final w = widget, e = w.env;
    return DifyPromptEditorPanel(
      key: key,
      title: title,
      value: item.isJinja ? item.jinja2Text ?? '' : item.text,
      onChange: onChange,
      readOnly: w.readOnly,
      showRemove: showRemove,
      onRemove: onRemove,
      isChatModel: w.isChatModel,
      isChatApp: w.isChatApp,
      isShowContext: w.isShowContext,
      hasSetBlockStatus: w.hasSetBlockStatus,
      nodesOutputVars: e.nodesOutputVars,
      availableNodes: e.availableNodes,
      getVarType: e.getVarType,
      onJumpToNode: e.onJumpToNode,
      isModelPluginInstalled: e.isModelPluginInstalled,
      expandedWidth: e.expandedWidth,
      onOpenUrl: e.onOpenUrl,
      jinjaEditorBuilder: e.jinjaEditorBuilder,
      headerExtra: e.headerExtra?.call(id),
      isSupportJinja: true,
      editionType: item.editionType ?? PromptEditionType.basic,
      onEditionTypeChange: onEditionTypeChange,
      isSupportFileVar: isSupportFileVar,
    );
  }

  Widget _item(int index, PromptItem item) {
    final w = widget;
    final key = _keyOf(index);
    final canDrag = !w.readOnly && !(index == 0 && item.role == PromptRole.system);
    final canChooseSystem = !_prompts.any((p) => p.role == PromptRole.system);
    final editor = _panel(
      key: ValueKey(item.id ?? 'prompt-$key'),
      id: item.id,
      title: PromptRoleTitle(
        role: item.role,
        canNotChooseSystemRole: !canChooseSystem,
        onChange: (r) => _update(key, (p) => p.copyWith(role: r)),
      ),
      item: item,
      onChange: (v) => _update(key, (p) => p.withPrompt(v)),
      showRemove: _prompts.length > 1 && !(index == 0 && item.role == PromptRole.system),
      onRemove: () => widget.onChange([
        for (final (i, p) in _prompts.indexed)
          if (i != key) p,
      ]),
      onEditionTypeChange: (t) => _update(key, (p) => p.copyWith(editionType: t)),
      isSupportFileVar: true,
    );
    final c = _current;
    final pressed = c != null && c.order.indexOf(c.origin) == index;
    final label = DifyI18n.tr('common', 'sort.handle', {'item': item.role?.name ?? ''});
    return _Hoverable(
      key: ValueKey('prompt-item-$key'),
      builder: (context, hovered) => Stack(
        clipBehavior: Clip.none,
        children: [
          editor,
          if (canDrag)
            Positioned(
              top: 4,
              left: -24,
              child: Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (_, e) => _onHandleKey(index, e),
                onFocusChange: (f) => setState(() {}),
                child: Builder(
                  builder: (context) {
                    final visible = hovered || pressed || _handle(key).hasFocus;
                    return Semantics(
                      button: true,
                      toggled: pressed,
                      label: label,
                      child: Opacity(
                        opacity: visible ? 1 : 0,
                        child: IgnorePointer(
                          ignoring: !visible,
                          child: ReorderableDragStartListener(
                            index: index,
                            enabled: !w.readOnly && c == null,
                            child: DifyIconButton(
                              key: ValueKey('sort-handle-$index'),
                              focusNode: _handle(key),
                              label: label,
                              icon: const DifyIcon('vender/line/others/drag-handle', size: 14),
                            ),
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

  @override
  Widget build(BuildContext context) {
    final w = widget;
    if (!(w.isChatModel && w.payload is List<PromptItem>)) {
      final p = w.payload as PromptItem;
      final jinja = !(p.editionType == null || p.editionType == PromptEditionType.basic);
      return _panel(
        title: Text(
          cssCapitalize(DifyI18n.tr('workflow', 'nodes.llm.prompt')),
          style: difyTextStyle(DifyType.systemXsSemibold, DifyColors.textSecondary),
        ),
        item: jinja ? p : p.copyWith(editionType: PromptEditionType.basic),
        onChange: (v) => w.onChange(jinja ? p.copyWith(jinja2Text: v) : p.copyWith(text: v)),
        onEditionTypeChange: (t) => w.onChange(p.copyWith(editionType: t)),
      );
    }
    final shown = _shown;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ReorderableListView(
          shrinkWrap: true,
          buildDefaultDragHandles: false,
          physics: const NeverScrollableScrollPhysics(),
          onReorderItem: _onReorder,
          proxyDecorator: (child, _, _) => Opacity(opacity: 0.5, child: child),
          children: [
            for (final (i, p) in shown.indexed)
              Padding(
                key: ValueKey('row-${_keyOf(i)}'),
                padding: EdgeInsets.only(top: i == 0 ? 0 : 4),
                child: _item(i, p),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: AddButton(text: DifyI18n.tr('workflow', 'nodes.llm.addMessage'), onPressed: _add),
        ),
      ],
    );
  }
}

class _Hoverable extends StatefulWidget {
  const _Hoverable({super.key, required this.builder});
  final Widget Function(BuildContext context, bool hovered) builder;

  @override
  State<_Hoverable> createState() => _HoverableState();
}

class _HoverableState extends State<_Hoverable> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: widget.builder(context, _hovered),
  );
}
