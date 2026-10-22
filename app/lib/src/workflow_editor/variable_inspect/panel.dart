/// The variable inspect panel (variable-inspect/index.tsx, panel.tsx, left.tsx, group.tsx, right.tsx, empty.tsx and
/// listening.tsx): the bottom panel the trigger opens, with the variables listed on the left and the selected one's
/// value on the right.
library;

import 'dart:async';
import 'dart:convert';

import 'package:collab_client/collab_client.dart' show Node, Value, VString;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../canvas/node_card.dart' show blockColor;
import '../../cards/bodies/entry_bodies.dart' show TriggerScheduleBody;
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../i18n/dify_i18n.dart';
import '../block_selector/selector_widgets.dart' show SelectorBlockIcon, SelectorIconSize;
import '../node_panel/resize_handle.dart';
import '../panel_fields/var_reference_vars.dart' show CategoryVarIcon;
import '../store/store.dart';
import 'inspect_vars.dart';
import 'value_content.dart';

String _tw(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', key, params);
String _close() => DifyI18n.tr('common', 'operation.close');

/// index.tsx: while the store shows it, the panel at [WorkflowStore.variableInspectPanelHeight] (120 px up to the
/// canvas height less 60) under its top resize handle: `rounded-2xl border-[0.5px] border-components-panel-border
/// bg-components-panel-bg shadow-xl`, `pb-1` below. The handle's 4 px strip (`absolute -top-1`) is laid out above
/// the box: the operator bar gives up that much of its `pb-2` while the panel shows. Dragging or the keyboard
/// resizes it; the height is stored (a shrinking canvas only lowers the store's height).
class VariableInspectPanel extends StatefulWidget {
  const VariableInspectPanel({super.key});

  @override
  State<VariableInspectPanel> createState() => _VariableInspectPanelState();
}

class _VariableInspectPanelState extends State<VariableInspectPanel> {
  late final WorkflowStore store = WorkflowStoreScope.of(context);
  late final Listenable _inputs = Listenable.merge([
    store.showVariableInspectPanel,
    store.variableInspectPanelHeight,
    store.workflowCanvasHeight,
  ]);
  double _dragFrom = 0;

  double get _max => getVariableInspectPanelMaxHeight(store.workflowCanvasHeight.value);

  @override
  void initState() {
    super.initState();
    _inputs.addListener(_constrain);
    scheduleMicrotask(_constrain);
  }

  @override
  void dispose() {
    _inputs.removeListener(_constrain);
    super.dispose();
  }

  /// The canvas got shorter than the panel allows: the store's height follows, the stored one stays.
  void _constrain() {
    if (!mounted || store.workflowCanvasHeight.value == null) return;
    if (store.variableInspectPanelHeight.value > _max) store.setVariableInspectPanelHeight(_max);
  }

  double _clamp(double h) => h.clamp(minVariableInspectPanelHeight, _max).toDouble();

  void _resize(double height, {bool save = true}) {
    if (save) WorkflowStoreScope.preferencesOf(context)?.workflowVariableInspectPanelHeight.value = height;
    store.setVariableInspectPanelHeight(height);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _inputs,
    builder: (context, child) {
      if (!store.showVariableInspectPanel.value) return const SizedBox.shrink();
      final height = store.variableInspectPanelHeight.value;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 4,
            child: ResizeHandle(
              side: ResizeSide.top,
              value: height,
              min: minVariableInspectPanelHeight,
              max: _max,
              label: _tw('debug.variableInspect.title'),
              onResize: _resize,
              onDragStart: () => _dragFrom = store.variableInspectPanelHeight.value,
              // The top edge moves: the panel grows by the distance dragged upwards.
              onDrag: (dy) => _resize(_clamp(_dragFrom - dy), save: false),
              onDragEnd: () => _resize(store.variableInspectPanelHeight.value),
            ),
          ),
          Container(
            height: height,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: BorderRadius.circular(DifyRadius.xxl),
              border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
              boxShadow: DifyShadows.xl,
            ),
            child: child,
          ),
          const SizedBox(height: 4),
        ],
      );
    },
    child: const InspectPanel(),
  );
}

/// The selected variable, as panel.tsx's `currentNodeInfo` (`currentVarType`): the group's node id, type and title
/// and the variable ([varJson] null while none of the group is selected).
typedef CurrentVar = ({
  String nodeId,
  String nodeType,
  String title,
  DifyJson? nodeData,
  DifyJson? varJson,
  bool isSingRunRunning,
});

const _maskedSecret = '******************';

/// panel.tsx: the listening state, the empty state, or the variables list and the selected one's value. Below
/// 488 px of bottom panel width the list is a popup over the value, opened from its menu button.
class InspectPanel extends StatefulWidget {
  const InspectPanel({super.key});

  @override
  State<InspectPanel> createState() => _InspectPanelState();
}

class _InspectPanelState extends State<InspectPanel> {
  bool _showLeftPanel = true;
  String _currentVarId = '';
  final _fetching = <String>{};

  CurrentVar? _currentNodeInfo(InspectVarsCrud crud, String? focus) {
    if (focus == null || focus.isEmpty) return null;
    DifyJson? find(List<DifyJson> vars) => vars.where((v) => v['id'] == _currentVarId).firstOrNull;
    CurrentVar group(String type, DifyJson? v) =>
        (nodeId: type, nodeType: type, title: type, nodeData: null, varJson: v, isSingRunRunning: false);
    switch (focus) {
      case VarInInspectType.environment:
        final v = find(crud.store.environmentVariables.value);
        return group(
          focus,
          v == null
              ? null
              : {
                  ...v,
                  'type': VarInInspectType.environment,
                  'visible': true,
                  if (v['value_type'] == 'secret') 'value': _maskedSecret,
                },
        );
      case VarInInspectType.conversation:
        return group(focus, find(crud.conversationVars));
      case VarInInspectType.system:
        final v = find(crud.systemVars);
        return group(focus, v == null ? null : {...v, 'type': VarInInspectType.system});
    }
    final node = crud.nodesWithInspectVars.where((n) => n['nodeId'] == focus).firstOrNull;
    if (node == null) return null;
    return (
      nodeId: focus,
      nodeType: '${node['nodeType']}',
      title: '${node['title'] ?? ''}',
      nodeData: node['nodePayload'] as DifyJson?,
      varJson: find(InspectVarsCrud.varsOf(node)),
      isSingRunRunning: node['isSingRunRunning'] == true,
    );
  }

  void _select(String nodeId, String varId) {
    setState(() => _currentVarId = varId);
    WorkflowStoreScope.of(context).setCurrentFocusNodeId(nodeId);
  }

  /// The selected variable's node has not had its values fetched: fetch them (once at a time).
  void _fetchValues(InspectVarsCrud crud, String? focus, DifyJson? node) {
    if (focus == null || focus.isEmpty || _currentVarId.isEmpty || node == null) return;
    if (node['isValueFetched'] == true || !_fetching.add(focus)) return;
    scheduleMicrotask(() => crud.fetchInspectVarValue(focus).whenComplete(() => _fetching.remove(focus)));
  }

  @override
  Widget build(BuildContext context) {
    final scope = VariableInspectScope.of(context), crud = scope.crud, store = crud.store;
    return ListenableBuilder(
      listenable: Listenable.merge([
        crud.changes,
        store.isListening,
        store.currentFocusNodeId,
        store.bottomPanelWidth,
      ]),
      builder: (context, _) {
        Widget headed(Widget body) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: DifyText(_tw('debug.variableInspect.title'), DifyType.systemSmSemiboldUppercase),
                  ),
                  DifyIconButton(
                    label: _close(),
                    icon: const RemixIcon('close-line', size: 16),
                    onPressed: () => store.setShowVariableInspectPanel(false),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Padding(padding: const EdgeInsets.all(8), child: body),
            ),
          ],
        );
        if (store.isListening.value) return headed(Listening(onStop: () => scope.onStop?.call()));
        if (!crud.hasVars) return headed(const InspectEmpty());

        final focus = store.currentFocusNodeId.value;
        final current = _currentNodeInfo(crud, focus);
        final focusNode = crud.nodesWithInspectVars.where((n) => n['nodeId'] == current?.nodeId).firstOrNull;
        _fetchValues(crud, focus, focusNode);
        final narrow = store.bottomPanelWidth.value < 488;
        final left = InspectLeft(
          currentVarId: current?.varJson?['id'] as String?,
          onSelect: (nodeId, varId) => _select(nodeId, varId),
        );
        final right = InspectRight(
          currentNodeVar: current,
          isValueFetching: focusNode != null && focusNode['isValueFetched'] != true,
          handleOpenMenu: () => setState(() => _showLeftPanel = true),
        );
        if (!narrow) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                width: 240,
                decoration: BoxDecoration(
                  border: Border(right: BorderSide(color: DifyColors.dividerBurn)),
                ),
                child: left,
              ),
              Expanded(child: right),
            ],
          );
        }
        return Stack(
          fit: StackFit.expand,
          children: [
            right,
            if (_showLeftPanel) ...[
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => setState(() => _showLeftPanel = false),
              ),
              Positioned(
                top: 0,
                left: 0,
                bottom: 0,
                width: 217,
                child: DifyBlurredBox(
                  blur: 4,
                  borderRadius: BorderRadius.circular(DifyRadius.xl),
                  decoration: BoxDecoration(
                    color: DifyColors.componentsPanelBg,
                    borderRadius: BorderRadius.circular(DifyRadius.xl),
                    border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
                    boxShadow: DifyShadows.lg,
                  ),
                  child: left,
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

InspectVarsCrud _crudOf(BuildContext context) => VariableInspectScope.of(context).crud;

/// empty.tsx: `flex h-full flex-col gap-3 rounded-xl bg-background-section p-8`, the variable tile, the title, the
/// tip and "Learn more".
class InspectEmpty extends StatelessWidget {
  const InspectEmpty({super.key});

  @override
  Widget build(BuildContext context) {
    final services = VariableInspectScope.maybeOf(context)?.crud.services;
    return _FullHeight(
      child: Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: DifyColors.backgroundSection,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 12,
          children: [
            DifyBlurredBox(
              blur: 4,
              borderRadius: BorderRadius.circular(DifyRadius.container),
              decoration: BoxDecoration(
                color: DifyColors.componentsCardBg,
                borderRadius: BorderRadius.circular(DifyRadius.container),
                border: Border.all(color: DifyColors.componentsCardBorder, width: Css.hairline),
                boxShadow: DifyShadows.lg,
              ),
              child: SizedBox.square(
                dimension: 40,
                child: Center(
                  child: DifyIcon('vender/solid/development/variable-02', size: 20, color: DifyColors.textAccent),
                ),
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                DifyText(
                  _tw('debug.variableInspect.title'),
                  DifyType.systemSmSemibold,
                  color: DifyColors.textSecondary,
                ),
                DifyText(
                  _tw('debug.variableInspect.emptyTip'),
                  DifyType.systemXsRegular,
                  color: DifyColors.textTertiary,
                  maxLines: null,
                ),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => services?.openUrl('https://docs.dify.ai/en/use-dify/debug/variable-inspect'),
                    child: DifyText(
                      _tw('debug.variableInspect.emptyLink'),
                      DifyType.systemXsRegular,
                      color: DifyColors.textAccent,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `h-full` in an `overflow-hidden` box: at least as tall as the room, clipped when taller.
class _FullHeight extends StatelessWidget {
  const _FullHeight({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => SingleChildScrollView(
      physics: const NeverScrollableScrollPhysics(),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: c.maxHeight),
        child: child,
      ),
    ),
  );
}

/// left.tsx: "VARIABLE INSPECT" with "Reset all", then the environment, conversation and system groups, a divider,
/// and a group per node with variables.
class InspectLeft extends StatelessWidget {
  const InspectLeft({super.key, this.currentVarId, required this.onSelect});
  final String? currentVarId;
  final void Function(String nodeId, String varId) onSelect;

  @override
  Widget build(BuildContext context) {
    final crud = _crudOf(context), store = crud.store;
    final scope = VariableInspectScope.of(context);
    final env = store.environmentVariables.value, conversation = crud.conversationVars, system = crud.systemVars;
    InspectGroup group(String type, List<DifyJson> vars) => InspectGroup(
      varType: type,
      varList: vars,
      currentVarId: currentVarId,
      handleSelect: (v) => onSelect(type, '${v['id']}'),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // `justify-between gap-1`: the title truncates, the button keeps its width.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 4, 0),
          child: SizedBox(
            height: 24,
            child: CustomMultiChildLayout(
              delegate: _TitleAndAction(),
              children: [
                LayoutId(
                  id: 0,
                  child: DifyText(_tw('debug.variableInspect.title'), DifyType.systemSmSemiboldUppercase),
                ),
                LayoutId(
                  id: 1,
                  child: DifyButton(
                    variant: DifyButtonVariant.ghost,
                    size: DifyButtonSize.small,
                    onPressed: () {
                      crud.deleteAllInspectorVars();
                      store.setCurrentFocusNodeId('');
                    },
                    child: Text(_tw('debug.variableInspect.clearAll')),
                  ),
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.symmetric(vertical: 4),
            children: [
              if (env.isNotEmpty) group(VarInInspectType.environment, env),
              if (conversation.isNotEmpty) group(VarInInspectType.conversation, conversation),
              if (system.isNotEmpty) group(VarInInspectType.system, system),
              if (env.isNotEmpty || conversation.isNotEmpty || system.isNotEmpty)
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: SizedBox(height: 1, child: ColoredBox(color: DifyColors.dividerSubtle)),
                ),
              for (final node in crud.nodesWithInspectVars)
                InspectGroup(
                  key: ValueKey(node['nodeId']),
                  nodeData: node,
                  varType: VarInInspectType.node,
                  varList: InspectVarsCrud.varsOf(node),
                  currentVarId: currentVarId,
                  handleSelect: (v) => onSelect('${node['nodeId']}', '${v['id']}'),
                  handleView: () => scope.onViewNode?.call('${node['nodeId']}'),
                  handleClear: () {
                    crud.deleteNodeInspectorVars('${node['nodeId']}');
                    store.setCurrentFocusNodeId('');
                  },
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A title that truncates (child 0) beside an action at the end that keeps its width (child 1), 4 px apart.
class _TitleAndAction extends MultiChildLayoutDelegate {
  _TitleAndAction();

  @override
  void performLayout(Size size) {
    final action = layoutChild(1, BoxConstraints(maxHeight: size.height));
    final title = layoutChild(0, BoxConstraints(maxWidth: (size.width - action.width - 4).clamp(0, size.width)));
    positionChild(0, Offset(0, (size.height - title.height) / 2));
    positionChild(1, Offset(size.width - action.width, (size.height - action.height) / 2));
  }

  @override
  bool shouldRelayout(_TitleAndAction oldDelegate) => false;
}

/// The variable's icon in its category's colour (VariableIconWithColor with `variableCategory`, `size-4`).
Widget _categoryIcon(String type, {String name = '', bool exception = false}) => CategoryVarIcon(
  variables: [type == VarInInspectType.node ? 'node' : type, name],
  category: type == VarInInspectType.environment ? 'environment' : type,
  isException: exception,
  size: 16,
);

/// group.tsx: a collapsible group (the node's icon and title, or Environment / Conversation / System) of variables;
/// a node group shows "View log" and "Clear cached variable" on hover, and a spinner while the node runs. Hidden
/// variables (`visible: false`) are not listed, environment variables always are.
class InspectGroup extends StatefulWidget {
  const InspectGroup({
    super.key,
    this.nodeData,
    this.currentVarId,
    required this.varType,
    required this.varList,
    required this.handleSelect,
    this.handleView,
    this.handleClear,
  });

  final DifyJson? nodeData;
  final String? currentVarId;
  final String varType;
  final List<DifyJson> varList;

  /// The variable picked (secrets masked).
  final ValueChanged<DifyJson> handleSelect;
  final VoidCallback? handleView, handleClear;

  @override
  State<InspectGroup> createState() => _InspectGroupState();
}

class _InspectGroupState extends State<InspectGroup> {
  bool _collapsed = false, _hovered = false;

  void _selectVar(DifyJson v) => widget.handleSelect(switch (widget.varType) {
    VarInInspectType.environment => {
      ...v,
      'type': VarInInspectType.environment,
      if (v['value_type'] == 'secret') 'value': _maskedSecret,
    },
    VarInInspectType.conversation || VarInInspectType.system => {...v, 'type': widget.varType},
    _ => v,
  });

  @override
  Widget build(BuildContext context) {
    final w = widget, node = w.nodeData;
    final running = node?['isSingRunRunning'] == true;
    final visible = w.varType == VarInInspectType.environment
        ? w.varList
        : [
            for (final v in w.varList)
              if (v['visible'] != false) v,
          ];
    final title = node != null
        ? '${node['title'] ?? ''}'
        : switch (w.varType) {
            VarInInspectType.environment => _tw('debug.variableInspect.envNode'),
            VarInInspectType.conversation => _tw('debug.variableInspect.chatNode'),
            VarInInspectType.system => _tw('debug.variableInspect.systemNode'),
            _ => '',
          };
    final header = DifyPressable(
      semanticLabel: title,
      onPressed: () => setState(() => _collapsed = !_collapsed),
      builder: (context, hovered, focused) => Container(
        decoration: focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(DifyRadius.sm),
                border: Border.all(color: DifyColors.componentsInputBorderHover),
              )
            : null,
        child: Row(
          spacing: 2,
          children: [
            SizedBox.square(
              dimension: 12,
              child: running
                  ? DifySpinner(size: 12, color: DifyColors.textAccent)
                  : visible.isNotEmpty
                  ? RotatedBox(
                      quarterTurns: _collapsed ? 0 : 1,
                      child: RemixIcon('arrow-right-s-line', size: 12, color: DifyColors.textTertiary),
                    )
                  : null,
            ),
            if (node != null)
              SelectorBlockIcon(
                type: '${node['nodeType']}',
                size: SelectorIconSize.xs,
                toolIcon: (node['nodePayload'] as Map?)?['provider_icon'],
              ),
            Flexible(
              child: DifyText(title, DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
            ),
          ],
        ),
      ),
    );
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Padding(
        padding: const EdgeInsets.all(2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 24,
              child: Row(
                spacing: 2,
                children: [
                  Expanded(child: header),
                  // `hidden group-hover:flex`.
                  if (node != null && !running && _hovered)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _TipButton(
                          label: _tw('debug.variableInspect.view'),
                          icon: 'file-list-3-line',
                          onPressed: w.handleView,
                        ),
                        _TipButton(
                          label: _tw('debug.variableInspect.clearNode'),
                          icon: 'delete-bin-line',
                          onPressed: w.handleClear,
                        ),
                      ],
                    ),
                ],
              ),
            ),
            if (!_collapsed && !running)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final v in visible)
                      _VarItem(
                        key: ValueKey(v['id']),
                        varJson: v,
                        varType: w.varType,
                        selected: v['id'] == w.currentVarId,
                        onTap: () => _selectVar(v),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// An IconButton with its label as the tooltip.
class _TipButton extends StatelessWidget {
  const _TipButton({required this.label, required this.icon, this.onPressed});
  final String label, icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => DifyTooltip(
    content: Text(label),
    child: DifyIconButton(label: label, icon: RemixIcon(icon, size: 16), onPressed: onPressed),
  );
}

/// A variable of a group: `flex w-full items-center gap-1 rounded-md px-3 py-1`, hover `bg-state-base-hover`,
/// selected `bg-state-base-hover-alt`; its icon, name and value type.
class _VarItem extends StatelessWidget {
  const _VarItem({
    super.key,
    required this.varJson,
    required this.varType,
    required this.selected,
    required this.onTap,
  });
  final DifyJson varJson;
  final String varType;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final name = '${varJson['name'] ?? ''}';
    return DifyPressable(
      semanticLabel: '$name ${varJson['value_type'] ?? ''}',
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? DifyColors.stateBaseHoverAlt
              : hovered
              ? DifyColors.stateBaseHover
              : null,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: focused ? Border.all(color: DifyColors.componentsInputBorderHover) : null,
        ),
        child: Row(
          spacing: 4,
          children: [
            _categoryIcon(varType, name: name, exception: name == 'error_type' || name == 'error_message'),
            Expanded(child: DifyText(name, DifyType.systemSmMedium, color: DifyColors.textSecondary)),
            DifyText('${varJson['value_type'] ?? ''}', DifyType.systemXsRegular, color: DifyColors.textTertiary),
          ],
        ),
      ),
    );
  }
}

/// right.tsx: the selected variable's header (its node or category, name, value type and size; Edited, reset,
/// export, copy, close) over its [ValueContent], the empty state, or a spinner while its values load.
class InspectRight extends StatelessWidget {
  const InspectRight({super.key, this.currentNodeVar, required this.handleOpenMenu, this.isValueFetching = false});

  final CurrentVar? currentNodeVar;
  final VoidCallback handleOpenMenu;
  final bool isValueFetching;

  static const _categories = [VarInInspectType.environment, VarInInspectType.conversation, VarInInspectType.system];

  @override
  Widget build(BuildContext context) {
    final crud = _crudOf(context), store = crud.store;
    final current = currentNodeVar, v = current?.varJson;
    final isTruncated = v?['is_truncated'] == true;
    final fullContent = v?['full_content'] as Map?;
    final narrow = store.bottomPanelWidth.value < 488;
    final schemaType = '${v?['schemaType'] ?? ''}';
    final edited = !isTruncated && v?['edited'] == true;
    final isConversation = v?['type'] == VarInInspectType.conversation;

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        spacing: 4,
        children: [
          if (narrow)
            DifyIconButton(
              label: _tw('debug.variableInspect.title'),
              icon: const RemixIcon('menu-line', size: 16),
              onPressed: handleOpenMenu,
            ),
          Expanded(
            child: v == null
                ? const SizedBox.shrink()
                : Row(
                    spacing: 4,
                    children: [
                      if (_categories.contains(current!.nodeType))
                        _categoryIcon(current.nodeType)
                      else ...[
                        SelectorBlockIcon(
                          type: current.nodeType,
                          size: SelectorIconSize.xs,
                          toolIcon: current.nodeData?['provider_icon'],
                        ),
                        DifyText(current.title, DifyType.systemSmRegular, color: DifyColors.textSecondary),
                        DifyText('/', DifyType.systemSmRegular, color: DifyColors.textQuaternary),
                      ],
                      Flexible(
                        child: DifyTooltip(
                          content: Text('${v['name']}'),
                          delay: const Duration(milliseconds: 600),
                          child: DifyText(
                            '${v['name']}',
                            DifyType.systemSmSemibold,
                            color: DifyColors.textSecondary,
                          ),
                        ),
                      ),
                      // `ml-1 space-x-2`.
                      Padding(
                        padding: const EdgeInsets.only(left: 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 8,
                          children: [
                            for (final part in [
                              '${v['value_type']}${schemaType.isEmpty ? '' : '($schemaType)'}',
                              if (isTruncated) ...[
                                '·',
                                '${(((fullContent?['size_bytes'] as num?) ?? 0) / 1024 / 1024).toStringAsFixed(1)}MB',
                              ],
                            ])
                              DifyText(part, DifyType.systemXsMedium, color: DifyColors.textTertiary),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 4,
            children: [
              if (current != null && v != null) ...[
                if (isTruncated)
                  _TipButton(
                    label: _tw('debug.variableInspect.exportToolTip'),
                    icon: 'file-download-fill',
                    onPressed: () => crud.services.openUrl('${fullContent?['download_url'] ?? ''}'),
                  ),
                if (edited) const _EditedBadge(),
                if (edited && !isConversation)
                  _TipButton(
                    label: _tw('debug.variableInspect.reset'),
                    icon: 'arrow-go-back-line',
                    onPressed: () => crud.resetToLastRunVar(current.nodeId, '${v['id']}'),
                  ),
                if (edited && isConversation)
                  _TipButton(
                    label: _tw('debug.variableInspect.resetConversationVar'),
                    icon: 'arrow-go-back-line',
                    onPressed: () => crud.resetConversationVar('${v['id']}'),
                  ),
                if (v['value_type'] != 'secret') DifyCopyFeedback(content: _copyContent(v['value'])),
              ],
              DifyIconButton(
                label: _close(),
                icon: const RemixIcon('close-line', size: 16),
                onPressed: () {
                  store.setShowVariableInspectPanel(false);
                  store.setCurrentFocusNodeId('');
                },
              ),
            ],
          ),
        ],
      ),
    );
    final Widget content;
    if (v == null) {
      content = const InspectEmpty();
    } else if (isValueFetching) {
      content = Center(
        child: DifySpinner(size: 16, color: DifyColors.textTertiary),
      );
    } else {
      content = ValueContent(
        key: ValueKey('${current!.nodeId}-${v['id']}'),
        currentVar: v,
        isTruncated: isTruncated,
        handleValueChange: (varId, value) => crud.editInspectVarValue(current.nodeId, varId, value),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        header,
        Expanded(
          child: Padding(padding: const EdgeInsets.all(8), child: content),
        ),
      ],
    );
  }

  static String _copyContent(Object? value) => switch (value) {
    null => '',
    Map() || List() => jsonEncode(value),
    _ => '$value',
  };
}

/// Badge with a dot: "EDITED".
class _EditedBadge extends StatelessWidget {
  const _EditedBadge();

  @override
  Widget build(BuildContext context) => Container(
    height: 20,
    padding: const EdgeInsets.symmetric(horizontal: 5),
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(DifyRadius.badge),
      border: Border.all(color: DifyColors.dividerDeep),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 3,
          height: 3,
          margin: const EdgeInsets.only(left: 2.5, right: 4.5),
          decoration: BoxDecoration(
            color: DifyColors.textAccentSecondary,
            borderRadius: BorderRadius.circular(DifyRadius.sm),
          ),
        ),
        DifyText(
          _tw('debug.variableInspect.edited'),
          DifyType.system2xsMediumUppercase,
          color: DifyColors.textTertiary,
        ),
      ],
    ),
  );
}

/// listening.tsx: the trigger nodes being listened to (40 px icons), "Listening for events from triggers…", what
/// to do (the schedule's next run, the plugin, the webhook node), the webhook's debug URL to copy, and Stop.
class Listening extends StatefulWidget {
  const Listening({super.key, required this.onStop, this.message});
  final VoidCallback onStop;
  final String? message;

  @override
  State<Listening> createState() => _ListeningState();
}

class _ListeningState extends State<Listening> {
  static const _triggers = ['trigger-schedule', 'trigger-webhook', 'trigger-plugin'];
  bool _copied = false;
  Timer? _timer;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static String? _str(Value? v) => v is VString && v.value.isNotEmpty ? v.value : null;

  String _description(Node? node, String type) {
    if (widget.message != null) return widget.message!;
    final title = node == null ? null : _str(node.config['title']) ?? (node.title.isEmpty ? null : node.title);
    switch (type) {
      case 'trigger-schedule':
        final next = node == null ? '' : TriggerScheduleBody.nextExecutionTime(node.config);
        return _tw('debug.variableInspect.listening.tipSchedule', {
          'nextTriggerTime': next.isEmpty || next == '--'
              ? _tw('debug.variableInspect.listening.defaultScheduleTime')
              : next,
        });
      case 'trigger-plugin':
        return _tw('debug.variableInspect.listening.tipPlugin', {
          'pluginName':
              _str(node?.config['provider_name']) ?? title ?? _tw('debug.variableInspect.listening.defaultPluginName'),
        });
      case 'trigger-webhook':
        return _tw('debug.variableInspect.listening.tip', {
          'nodeName': title ?? _tw('debug.variableInspect.listening.defaultNodeName'),
        });
    }
    return _str(node?.config['desc']) ?? _tw('debug.variableInspect.listening.tipFallback');
  }

  @override
  Widget build(BuildContext context) {
    final crud = _crudOf(context), store = crud.store;
    final nodes = crud.nodes().toList();
    final nodeId = store.listeningTriggerNodeId.value, isAll = store.listeningTriggerIsAll.value;
    final triggerNode = nodeId == null ? null : nodes.where((n) => n.id == nodeId).firstOrNull;
    final triggerType = store.listeningTriggerType.value ?? triggerNode?.type ?? 'trigger-webhook';
    final debugUrl = triggerType == 'trigger-webhook' ? _str(triggerNode?.config['webhook_debug_url']) : null;
    final ids = store.listeningTriggerNodeIds.value;
    final display = isAll
        ? [
            for (final n in nodes)
              if (ids.isNotEmpty ? ids.contains(n.id) : _triggers.contains(n.type)) n,
          ]
        : [?triggerNode];
    final icons = display.isEmpty ? [isAll ? 'trigger-webhook' : triggerType] : [for (final n in display) n.type];
    final String description;
    if (isAll) {
      final titles = [
        for (final n in display) ?(_str(n.config['title']) ?? (n.title.isEmpty ? null : n.title)),
      ];
      description = titles.isEmpty
          ? _tw('debug.variableInspect.listening.tipFallback')
          : _tw('debug.variableInspect.listening.tip', {'nodeName': titles.join(', ')});
    } else {
      description = _description(triggerNode, triggerType);
    }
    final copyLabel = _tw('nodes.triggerWebhook.${_copied ? 'debugUrlCopied' : 'debugUrlCopy'}');
    return _FullHeight(
      child: Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: DifyColors.backgroundSection,
          borderRadius: BorderRadius.circular(DifyRadius.xl),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 16,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                for (final type in icons)
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: blockColor(type),
                      borderRadius: BorderRadius.circular(DifyRadius.xl),
                      border: Border.all(color: DifyTailwind.white.withValues(alpha: 0.02), width: Css.hairline),
                      boxShadow: DifyShadows.md,
                    ),
                    child: Center(child: DifyIcon(blockGlyph(type), size: 28, color: DifyTailwind.white)),
                  ),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 4,
              children: [
                DifyText(
                  _tw('debug.variableInspect.listening.title'),
                  DifyType.systemSmSemibold,
                  color: DifyColors.textSecondary,
                ),
                DifyText(description, DifyType.systemXsRegular, color: DifyColors.textTertiary, maxLines: null),
              ],
            ),
            if (debugUrl != null)
              Row(
                spacing: 8,
                children: [
                  DifyText(
                    _tw('nodes.triggerWebhook.debugUrlTitle'),
                    DifyType.systemXsRegular,
                    color: DifyColors.textTertiary,
                  ),
                  Flexible(
                    child: DifyTooltip(
                      content: Text(copyLabel),
                      child: DifyPressable(
                        semanticLabel: _tw('nodes.triggerWebhook.debugUrlCopy'),
                        onPressed: () {
                          Clipboard.setData(ClipboardData(text: debugUrl));
                          setState(() => _copied = true);
                          _timer?.cancel();
                          _timer = Timer(const Duration(seconds: 2), () {
                            if (mounted) setState(() => _copied = false);
                          });
                        },
                        builder: (context, hovered, focused) => Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: hovered || _copied
                                ? DifyColors.componentsPanelOnPanelItemBgHover
                                : DifyColors.componentsBadgeWhiteToDark,
                            borderRadius: BorderRadius.circular(DifyRadius.md),
                            border: Border.all(color: DifyColors.dividerRegular),
                          ),
                          child: Text(
                            debugUrl,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: difyTextStyle(
                              DifyTw.text13Leading18,
                              DifyColors.textPrimary,
                            ).copyWith(fontFamily: 'monospace'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            DifyButton(
              variant: DifyButtonVariant.primary,
              paddingX: 12,
              onPressed: widget.onStop,
              leading: const DifyIcon('vender/line/mediaAndDevices/stop-circle', size: 16),
              child: Text(_tw('debug.variableInspect.listening.stopButton')),
            ),
          ],
        ),
      ),
    );
  }
}
