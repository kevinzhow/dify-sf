/// The node panel shell (nodes/_base/components/workflow-panel/index.tsx, BasePanel): resizable, with the header
/// (block icon, title, run this step, docs, the node actions "…", close), the description, the Settings / Last Run
/// tabs, the node type's body and the shared sections (retry, error handling, next step).
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:flutter/widgets.dart';

import '../../cards/card_chrome.dart';
import '../../cards/card_kit.dart';
import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/undo_manager.dart';
import '../../i18n/dify_i18n.dart';
import '../../workflow/dify_json.dart';
import '../block_selector/block_selector.dart' show BlockSelectorPlacements;
import '../code_editor/code_editor.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../panel_fields/panel_fields.dart';
import '../run/run_scope.dart';
import '../run/ui/node_run_ui.dart';
import '../store/store.dart';
import 'node_panel_bodies.dart';
import 'resize_handle.dart';
import 'title_description_input.dart';

String _tw(String key) => DifyI18n.tr('workflow', key);

/// workflow-panel/types.ts TabType (`relations` is never rendered).
enum NodePanelTab { settings, lastRun }

/// utils/node.ts hasRetryNode.
bool hasRetryNode(String? type) => const {'llm', 'tool', 'http-request', 'code'}.contains(type);

/// use-available-blocks.ts: the blocks with no next step to add.
bool hasNextStep(String type) => !const {'start-placeholder', 'loop-end', 'knowledge-index'}.contains(type);

/// `data._targetBranches` (utils/workflow-init.ts): an if-else's cases then ELSE (`false`) with branchNameCorrect's
/// names, a question classifier's classes; empty for other nodes.
List<({String id, String name})> nodeTargetBranches(Node node) {
  final data = difyDataOf(node);
  switch (node.type) {
    case 'if-else':
      final ids = [
        for (final c in jsList(data['cases'])) ?jsStr(jsGet(c, 'case_id')),
        'false',
      ];
      return [
        for (final (i, id) in ids.indexed)
          (id: id, name: id == 'false' ? 'ELSE' : (ids.length == 2 ? 'IF' : 'CASE ${i + 1}')),
      ];
    case 'question-classifier':
      return [
        for (final c in jsList(data['classes']))
          if (jsGet(c, 'id') != null) (id: jsKey(jsGet(c, 'id')), name: jsStr(jsGet(c, 'name')) ?? ''),
      ];
  }
  return const [];
}

/// BasePanel for [node]: [store]'s `nodePanelWidth` wide (400 to `getMaxNodePanelWidth`, shrunk without saving when
/// the canvas is too narrow), resized from its left edge by pointer or keyboard (the width a user picks is saved in
/// the stored preferences). Remount it per node id and type (Dify keys it `${id}-${type}`).
///
/// "Run this step" asks for a single run through the store ([WorkflowActions.runStep]); the panel then shows the
/// Last Run tab and hands the request to [onSingleRun] / [onStopSingleRun] (none yet in dify-sf).
class WorkflowNodePanel extends StatefulWidget {
  const WorkflowNodePanel({
    super.key,
    required this.node,
    required this.actions,
    this.bodies = NodePanelBodies.defaults,
    this.onSingleRun,
    this.onStopSingleRun,
  });

  final Node node;

  /// The canvas actions (selection, delete, the "…" menu) on the editor's controller and store.
  final WorkflowActions actions;
  final NodePanelBodies bodies;
  final ValueChanged<String>? onSingleRun, onStopSingleRun;

  @override
  State<WorkflowNodePanel> createState() => _WorkflowNodePanelState();
}

class _WorkflowNodePanelState extends State<WorkflowNodePanel> {
  WorkflowStore get store => widget.actions.store;
  late NodePanelTab _tab = store.initShowLastRunTab.value ? NodePanelTab.lastRun : NodePanelTab.settings;
  late final Listenable _widthInputs = Listenable.merge([
    store.nodePanelWidth,
    store.workflowCanvasWidth,
    store.otherPanelWidth,
  ]);
  bool _dragging = false;
  double _dragFrom = 0;

  @override
  void initState() {
    super.initState();
    store.initShowLastRunTab.addListener(_showLastRunTab);
    store.pendingSingleRun.addListener(_pendingSingleRun);
    _widthInputs.addListener(_compress);
    // The store may not notify while the tree builds.
    scheduleMicrotask(() {
      if (!mounted) return;
      _showLastRunTab();
      _pendingSingleRun();
      _compress();
    });
  }

  @override
  void dispose() {
    store.initShowLastRunTab.removeListener(_showLastRunTab);
    store.pendingSingleRun.removeListener(_pendingSingleRun);
    _widthInputs.removeListener(_compress);
    super.dispose();
  }

  // ----- tabs and single run (use-last-run.ts) -----

  void _showLastRunTab() {
    if (!store.initShowLastRunTab.value) return;
    if (mounted) setState(() => _tab = NodePanelTab.lastRun);
    store.setInitShowLastRunTab(false);
  }

  void _pendingSingleRun() {
    final p = store.pendingSingleRun.value;
    if (p == null || p.nodeId != widget.node.id) return;
    store.setPendingSingleRun();
    final handler = p.action == SingleRunAction.run ? widget.onSingleRun : widget.onStopSingleRun;
    if (handler != null) return handler(p.nodeId);
    // The editor's run host (use-last-run.ts handleSingleRun / handleStop).
    if (p.action == SingleRunAction.run) {
      handleNodeSingleRun(context, widget.node, widget.actions.doc);
    } else {
      WorkflowRunScope.maybeOf(context)?.singleRunOf(p.nodeId).handleStop();
    }
  }

  // ----- width (helpers.tsx; updateNodePanelWidth) -----

  double get _max => getMaxNodePanelWidth(store.workflowCanvasWidth.value, store.otherPanelWidth.value);

  void _setWidth(double width, {bool user = true}) {
    final w = clampNodePanelWidth(width, _max);
    if (user) WorkflowStoreScope.preferencesOf(context)?.workflowNodePanelWidth.value = w;
    store.setNodePanelWidth(w);
  }

  /// The canvas got too narrow (or the other panel wider): shrink without saving.
  void _compress() {
    final c = getCompressedNodePanelWidth(
      store.nodePanelWidth.value,
      store.workflowCanvasWidth.value,
      store.otherPanelWidth.value,
    );
    if (c == null || c == store.nodePanelWidth.value) return;
    scheduleMicrotask(() {
      if (mounted) _setWidth(c, user: false);
    });
  }

  // ----- actions -----

  /// useNodesInteractions handleNodeDisconnect: every edge of [nodeId] goes, as one EdgeDelete step.
  void _disconnect(String nodeId) {
    final a = widget.actions;
    if (a.nodesReadOnly) return;
    final ids = [
      for (final e in a.doc.edges.values)
        if (e.source == nodeId || e.target == nodeId) e.id,
    ];
    if (ids.isEmpty) return;
    final undo = a.controller.undo..begin(HistoryEvent.edgeDelete, nodeId: nodeId);
    try {
      ids.forEach(a.controller.deleteEdge);
    } finally {
      undo.end();
    }
  }

  void _close() {
    widget.actions.canvas.selection.selectNodes(const []);
    widget.actions.controller.selectNode(null);
  }

  @override
  Widget build(BuildContext context) {
    final panel = ListenableBuilder(
      listenable: widget.actions.readOnlyChanges,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Run this step / Stop follows the node's single run (local run state).
          ValueListenableBuilder(valueListenable: store.nodeRunData, builder: (context, _, _) => _header()),
          Expanded(
            child: switch (_tab) {
              NodePanelTab.settings => SingleChildScrollView(child: _settings(context)),
              NodePanelTab.lastRun => NodeLastRun(
                nodeId: widget.node.id,
                canSingleRun: canRunBySingle(widget.node.type, isChildNode: parentIdOf(widget.node) != null),
                onSingleRun: () => widget.actions.runStep(widget.node.id),
              ),
            },
          ),
        ],
      ),
    );
    final box = Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        borderRadius: BorderRadius.circular(DifyRadius.xxl),
        border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        boxShadow: DifyShadows.lg,
      ),
      // The single-run form covers the panel while it is open (before-run-form/panel-wrap.tsx).
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          panel,
          NodeSingleRunOverlay(node: widget.node, doc: widget.actions.doc),
        ],
      ),
    );
    return ListenableBuilder(
      listenable: _widthInputs,
      builder: (context, child) {
        final width = store.nodePanelWidth.value, max = _max;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // `absolute top-0 -left-1 w-1`: the strip left of the panel.
            SizedBox(
              width: 4,
              child: ResizeHandle(
                value: width,
                min: minNodePanelWidth,
                max: max,
                label: _tw('panel.nodePanel'),
                onResize: _setWidth,
                onDragStart: () => setState(() {
                  _dragging = true;
                  _dragFrom = store.nodePanelWidth.value;
                }),
                // Dragging moves the left edge: the panel grows by the distance travelled leftwards.
                onDrag: (dx) => store.setNodePanelWidth(clampNodePanelWidth(_dragFrom - dx, _max)),
                onDragEnd: () {
                  setState(() => _dragging = false);
                  _setWidth(store.nodePanelWidth.value);
                },
              ),
            ),
            // `transition-[width] ease-linear` (150 ms), except while dragging.
            AnimatedContainer(
              duration: _dragging ? Duration.zero : const Duration(milliseconds: 150),
              width: width,
              child: child,
            ),
            const SizedBox(width: 4), // mr-1
          ],
        );
      },
      child: box,
    );
  }

  // ----- header -----

  Widget _header() {
    final a = widget.actions, node = widget.node, c = a.controller;
    final running = a.isSingleRunning(node.id);
    final canRun =
        canRunBySingle(node.type, isChildNode: parentIdOf(node) != null) && a.options.canRun && !a.nodesReadOnly;
    final runLabel = running ? _tw('debug.variableInspect.trigger.stop') : _tw('panel.runThisStep');
    final desc = switch (node.config['desc']) {
      VString(:final value) => value,
      _ => '',
    };
    return Container(
      decoration: BoxDecoration(
        color: DifyColors.componentsPanelBg,
        border: Border(
          bottom: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                BlockIcon(type: node.type),
                const SizedBox(width: 4),
                Expanded(
                  child: TitleInput(
                    key: ValueKey('title-${node.id}'),
                    value: node.title,
                    currentVersion: () => c.seenVersion,
                    onCommit: (text, base) => c.setTitle(node.id, text, base: base),
                  ),
                ),
                const SizedBox(width: 8),
                if (canRun)
                  Padding(
                    padding: const EdgeInsets.only(right: 4),
                    child: DifyTooltip(
                      disabled: running,
                      content: Text(_tw('panel.runThisStep')),
                      child: _HeaderButton(
                        label: runLabel,
                        onPressed: () => a.runStep(node.id),
                        icon: running
                            ? const DifyIcon(
                                'vender/line/mediaAndDevices/stop',
                                size: 16,
                                color: DifyColors.textTertiary,
                              )
                            : const RemixIcon('play-large-line', size: 16, color: DifyColors.textTertiary),
                      ),
                    ),
                  ),
                HelpLink(
                  link: nodeHelpLink(node.type, chatMode: a.chatMode, product: a.options.docsProduct),
                  onOpen: (url) => a.options.openUrl?.call(url),
                ),
                NodeActionsDropdown(key: const Key('node-panel-more'), actions: a, node: node, showHelpLink: false),
                Container(
                  width: 1,
                  height: 14,
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  color: DifyColors.dividerRegular,
                ),
                _HeaderButton(
                  label: DifyI18n.tr('common', 'operation.close'),
                  onPressed: _close,
                  icon: const RemixIcon('close-line', size: 16, color: DifyColors.textTertiary),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: DescriptionInput(
              key: ValueKey('desc-${node.id}'),
              value: desc,
              currentVersion: () => c.seenVersion,
              onCommit: (text, base) => c.setConfig(node.id, const ['desc'], VString(text), base: base),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 16, right: 12),
            child: Row(
              spacing: 16,
              children: [
                for (final (tab, key) in const [
                  (NodePanelTab.settings, 'debug.settingsTab'),
                  (NodePanelTab.lastRun, 'debug.lastRunTab'),
                ])
                  Flexible(
                    child: _Tab(
                      label: _tw(key).toUpperCase(),
                      active: _tab == tab,
                      onTap: () => setState(() => _tab = tab),
                    ),
                  ),
              ],
            ),
          ),
          const PanelSplit(),
        ],
      ),
    );
  }

  // ----- settings tab -----

  Widget _settings(BuildContext context) {
    final a = widget.actions, node = widget.node;
    final props = NodePanelProps(node: node, controller: a.controller, actions: a);
    final broken = [for (final v in node.config.values) ...v.brokenRefs];
    final readOnly = a.nodesReadOnly;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (broken.isNotEmpty) BrokenReferences(broken: broken),
        widget.bodies.of(node.type)(context, props),
        const PanelSplit(),
        if (hasRetryNode(node.type))
          RetryOnPanel(
            retryConfig: switch (plainOf(node.config['retry_config'])) {
              final Map<String, Object?> m => m,
              _ => null,
            },
            onChange: (config) => props.setData('retry_config', config),
          ),
        if (hasErrorHandleNode(node.type)) _errorHandle(props),
        if (hasNextStep(node.type))
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: DifyColors.dividerRegular, width: Css.hairline),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: DifyText(
                    _tw('panel.nextStep'),
                    DifyType.systemSmSemiboldUppercase,
                    color: DifyColors.textSecondary,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DifyText(
                    _tw('panel.addNextStep'),
                    DifyType.systemXsRegular,
                    color: DifyColors.textTertiary,
                    maxLines: null,
                  ),
                ),
                NextStep(
                  nodeType: node.type,
                  readonly: readOnly,
                  branches: nextStepBranches(
                    node: node,
                    nodes: a.doc.nodes,
                    // dify-sf's default source handle is `out`, Dify's `source`.
                    edges: [
                      for (final e in a.doc.edges.values)
                        if (e.source == node.id)
                          e.sourceHandle == 'out'
                              ? Edge(id: e.id, source: e.source, sourceHandle: 'source', target: e.target)
                              : e,
                    ],
                    targetBranches: nodeTargetBranches(node),
                  ),
                  actions: NextStepActions(
                    onSelectNode: a.selectNode,
                    // next-step/add.tsx: the block selector above the button; the block goes after the handle.
                    onAdd: (anchor, handle) => a.showInsertBlockSelector(
                      anchor,
                      InsertAfter(node.id, handle),
                      placement: BlockSelectorPlacements.nextStep,
                      popupWidth: 328,
                      showStartTab: false,
                    ),
                    // next-step/operator.tsx: Change replaces the next node.
                    onChange: (anchor, nextId, handle) => a.showChangeBlockSelector(anchor, nextId, handle),
                    onDisconnect: _disconnect,
                    onDelete: a.deleteNode,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _errorHandle(NodePanelProps props) {
    final node = props.node, data = props.data;
    final strategy = jsStr(data['error_strategy']);
    final defaults = [
      for (final f in jsList(data['default_value']))
        if (f is Map<String, Object?>) f,
    ];
    final codeOutputs = node.type != 'code'
        ? const <String, String>{}
        : {for (final v in nodeOutputVars(node)) v.name: v.type};
    return ErrorHandleOnPanel(
      errorStrategy: strategy,
      defaultValue: data['default_value'] == null ? null : defaults,
      onStrategyChange: (type) {
        final change = errorStrategyChange(strategy, type, node.type, codeOutputs: codeOutputs);
        if (change == null) return;
        for (final MapEntry(:key, :value) in change.changes.entries) {
          props.setData(key, value);
        }
        if (change.deleteFailBranch) props.actions.deleteBranch(node.id, 'fail-branch');
      },
      onDefaultValueChange: (form) => props.setData('default_value', defaultValueFormChange(defaults, form)),
      onOpenLink: (url) => props.actions.options.openUrl?.call(url),
      jsonEditor: (context, value, onChange) =>
          DifyCodeEditor(value: value, language: CodeLanguage.json, onChange: onChange),
    );
  }
}

/// The header's 24 px icon buttons (`flex size-6 items-center justify-center rounded-md hover:bg-state-base-hover`).
class _HeaderButton extends StatelessWidget {
  const _HeaderButton({required this.label, required this.icon, required this.onPressed});
  final String label;
  final Widget icon;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onPressed,
    builder: (context, hovered, focused) => Container(
      width: 24,
      height: 24,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: hovered ? DifyColors.stateBaseHover : null,
        borderRadius: BorderRadius.circular(DifyRadius.md),
        border: focused ? Border.all(color: DifyColors.componentsInputBorderHover) : null,
      ),
      child: icon,
    ),
  );
}

/// dify-ui's TabsTab: `border-b-2 border-transparent pt-2.5 pb-2 system-md-semibold text-text-tertiary`; active:
/// `border-components-tab-active text-text-primary`.
class _Tab extends StatelessWidget {
  const _Tab({required this.label, required this.active, required this.onTap});
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    selected: active,
    child: DifyPressable(
      semanticLabel: label,
      onPressed: onTap,
      builder: (context, hovered, focused) => Container(
        padding: const EdgeInsets.only(top: 10, bottom: 8),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: active ? DifyColors.componentsTabActive : const Color(0x00000000), width: 2),
          ),
        ),
        child: DifyText(
          label,
          DifyType.systemMdSemibold,
          color: active ? DifyColors.textPrimary : DifyColors.textTertiary,
        ),
      ),
    ),
  );
}

/// dify-sf: the node holds references whose nodes were deleted by someone (explicit broken markers); the fields
/// below show each one. `mx-4 mt-2 rounded-lg border-[0.5px]` in the destructive state colours.
class BrokenReferences extends StatelessWidget {
  const BrokenReferences({super.key, required this.broken});
  final List<OutputRef> broken;

  @override
  Widget build(BuildContext context) {
    final one = broken.map((r) => r.node).toSet().length == 1;
    final n = broken.length;
    return Container(
      key: const Key('broken-summary'),
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: DifyColors.stateDestructiveHover,
        borderRadius: BorderRadius.circular(DifyRadius.lg),
        border: Border.all(color: DifyColors.stateDestructiveBorder, width: Css.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 8,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: RemixIcon('link-unlink-m', size: 16, color: DifyColors.textDestructive),
          ),
          Expanded(
            child: DifyText(
              '$n broken reference${n == 1 ? '' : 's'}: the node${one ? '' : 's'} they pointed to '
              '${one ? 'was' : 'were'} deleted. Pick new variables below.',
              DifyType.systemXsRegular,
              color: DifyColors.textDestructive,
              maxLines: null,
            ),
          ),
        ],
      ),
    );
  }
}
