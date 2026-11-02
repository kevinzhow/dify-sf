/// The workflow editor's Steps view: the phone's editing surface (mockup 2-steps), another presentation of the same
/// collaborative workflow document the canvas shows. The graph is read top to bottom as a list of steps, branches as
/// nested lanes, containers with their bodies, "continues at" links where the graph does not nest, and unconnected
/// steps last ([computeStepsLayout] has the rules).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/node_card.dart' show blockColor;
import '../../canvas/run_view.dart';
import '../../cards/card_chrome.dart' show BlockIcon;
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../store/store.dart';
import 'step_insert.dart';
import 'step_labels.dart';
import 'steps_layout.dart';

String _t(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('workflow', 'mobile.steps.$key', params);

/// The Steps view: the workflow as a scrolling list of steps (a lazy sliver list over [computeStepsLayout]'s rows,
/// memoised per document revision), for the editor's phone chrome to show instead of the canvas.
///
/// It edits through the objects the canvas and the node panel use, so undo, redo and collaboration work as there:
///
/// * [controller]: the document (rebuilt from its change notifications, collaborators' edits included), the
///   selection and the undo history.
/// * [canvas]: the canvas controller of the same editor (`WorkflowEditor`'s slot builders hand it out): its selection
///   is kept in step, its `nodeRun` is the run status the cards show, and [WorkflowActions] needs it.
/// * [options]: the same [WorkflowMenuOptions] the canvas's menus get (`canEdit`, `canRun`, chat mode, single runs).
/// * [store]: the editor's [WorkflowStore] (read-only states, the checklist, single runs); by default the
///   `WorkflowStoreScope` above.
///
/// It also needs, above it: the `BlockSelectorScope` (the blocks "+" offers), an `Overlay` and a `Navigator` (the
/// block selector and the action sheet), and the loaded `DifyI18n`. In the editor all of these are there for any
/// widget built inside `WorkflowEditor`'s slots (where the node panels are built).
///
/// Interactions: a tap on a card selects the step and opens its settings ([onOpenNode]: by default
/// [WorkflowActions.selectNode], what a tap on a canvas node does; the node panel follows the selection). A "+"
/// opens the canvas's block selector for its point ([InsertOnEdge] between two steps, [InsertAfter] after a last
/// step or in an empty lane; where branches meet, [StepsInsertion.insertStep]); the new step is selected and
/// scrolled into view. A long press opens an action sheet: Settings, Run this step, Add step after, Duplicate,
/// Delete. A "continues at" row scrolls to the step and highlights it.
///
/// Edge to edge: the list pads its end by the system's bottom inset plus [bottomInset] (the toolbar the chrome lays
/// over the list's bottom) and its sides by the side insets; it paints no background of its own.
class WorkflowStepsView extends StatefulWidget {
  const WorkflowStepsView({
    super.key,
    required this.controller,
    required this.canvas,
    this.options = const WorkflowMenuOptions(),
    this.store,
    this.bottomInset = 0,
    this.topPadding = 4,
    this.onOpenNode,
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions options;

  /// The editor's store; null: `WorkflowStoreScope.of(context)`.
  final WorkflowStore? store;

  /// Space the chrome covers at the bottom (its toolbar), added to `MediaQuery.paddingOf(context).bottom`.
  final double bottomInset;

  /// Space above the first row.
  final double topPadding;

  /// Opens a step's settings; null: [WorkflowActions.selectNode] (the canvas's node tap; the node panel opens for
  /// the selected node).
  final ValueChanged<String>? onOpenNode;

  @override
  State<WorkflowStepsView> createState() => WorkflowStepsViewState();
}

/// [WorkflowStepsView]'s state; [revealNode] scrolls a step into view (for the chrome: the checklist's "go to").
class WorkflowStepsViewState extends State<WorkflowStepsView> {
  final _scroll = ScrollController();
  final _cache = StepsLayoutCache();
  StepsLayout _layout = StepsLayout.empty;
  WorkflowStore? _store;
  late WorkflowActions _actions;
  String? _selected;
  bool _selectingHere = false;
  String? _highlighted;
  Timer? _highlightTimer;
  Map<String, ({String message})> _issues = const {};

  /// The built rows' contexts, by row key (to measure and reveal them).
  final _rows = <String, BuildContext>{};

  /// Rough row heights, to jump near a row that is not built yet.
  static const _estimates = {
    StepRowKind.card: 66.0,
    StepRowKind.connector: DifyStepMetrics.rowHeight,
    StepRowKind.laneHeader: 38.0,
    StepRowKind.link: DifyStepMetrics.rowHeight,
    StepRowKind.addStep: DifyStepMetrics.rowHeight,
    StepRowKind.bodyStart: DifyStepMetrics.rowHeight,
    StepRowKind.section: 44.0,
    StepRowKind.gap: 16.0,
  };

  EditorController get _c => widget.controller;
  Document get _doc => _c.doc;
  WorkflowActions get actions => _actions;

  @override
  void initState() {
    super.initState();
    _layout = _cache.layoutOf(_doc);
    _selected = _c.selectedNodeId;
    _c.addListener(_documentChanged);
    widget.canvas.nodeRun.addListener(_repaint);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindStore(widget.store ?? WorkflowStoreScope.of(context));
  }

  @override
  void didUpdateWidget(WorkflowStepsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.controller != widget.controller) {
      old.controller.removeListener(_documentChanged);
      widget.controller.addListener(_documentChanged);
      _layout = _cache.layoutOf(_doc);
    }
    if (old.canvas != widget.canvas) {
      old.canvas.nodeRun.removeListener(_repaint);
      widget.canvas.nodeRun.addListener(_repaint);
    }
    _bindStore(widget.store ?? WorkflowStoreScope.of(context), force: true);
  }

  Listenable? _storeListenable;

  void _bindStore(WorkflowStore store, {bool force = false}) {
    if (store != _store) {
      _storeListenable?.removeListener(_storeChanged);
      _store = store;
      _storeListenable = Listenable.merge([
        store.checklistItems,
        store.canvasReadOnly,
        store.workflowRunningData,
        store.historyWorkflowData,
        store.isRestoring,
      ])..addListener(_storeChanged);
      _readIssues();
    } else if (!force) {
      return;
    }
    _actions = WorkflowActions(
      controller: widget.controller,
      canvas: widget.canvas,
      store: store,
      options: widget.options,
    );
  }

  @override
  void dispose() {
    _c.removeListener(_documentChanged);
    widget.canvas.nodeRun.removeListener(_repaint);
    _storeListenable?.removeListener(_storeChanged);
    _highlightTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// setState, or on the next frame when a notification arrives while the tree is being built.
  void _repaint() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _repaint());
      return;
    }
    setState(() {});
  }

  void _storeChanged() {
    _readIssues();
    _repaint();
  }

  /// The checklist's problems by node: its first error message, or "not connected".
  void _readIssues() {
    final items = _store?.checklistItems.value ?? const [];
    _issues = {
      for (final item in items)
        if (item['id'] case final String id)
          id: (
            message: switch (item['errorMessages']) {
              final List l when l.isNotEmpty => '${l.first}',
              _ => item['unConnected'] == true ? DifyI18n.tr('workflow', 'common.needConnectTip') : '',
            },
          ),
    };
  }

  void _documentChanged() {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _documentChanged());
      return;
    }
    final next = _cache.layoutOf(_doc);
    final anchor = identical(next, _layout) ? null : _anchor(next);
    final selection = _c.selectedNodeId;
    final selectionChanged = selection != _selected;
    _selected = selection;
    setState(() => _layout = next);
    if (anchor != null) WidgetsBinding.instance.addPostFrameCallback((_) => _restoreAnchor(anchor));
    // A step selected elsewhere (the canvas, the checklist, a new step) comes into view.
    if (selectionChanged && selection != null && !_selectingHere) revealNode(selection);
  }

  // ----- scrolling -----

  RenderBox? _boxOf(String key) {
    final ctx = _rows[key];
    if (ctx == null || !ctx.mounted) return null;
    final box = ctx.findRenderObject();
    return box is RenderBox && box.attached && box.hasSize ? box : null;
  }

  /// The scroll offset that puts row [key]'s top at the top of the list, when it is built.
  double? _offsetOf(String key) {
    final box = _boxOf(key);
    if (box == null || !_scroll.hasClients) return null;
    final viewport = RenderAbstractViewport.maybeOf(box);
    return viewport?.getOffsetToReveal(box, 0).offset;
  }

  /// The first row at or below the list's top that the new layout still has, and where it is now.
  ({String key, double offset})? _anchor(StepsLayout next) {
    if (!_scroll.hasClients || _scroll.offset <= 0) return null;
    ({String key, double offset})? best;
    for (final key in _rows.keys) {
      if (next.rowOfKey(key) == null) continue;
      final at = _offsetOf(key);
      if (at == null) continue;
      final dy = at - _scroll.offset;
      if (dy < -1) continue;
      if (best == null || at < best.offset) best = (key: key, offset: at);
    }
    return best;
  }

  /// Keeps [anchor] where it was after rows above it came or went (a collaborator's edit): the list does not jump.
  void _restoreAnchor(({String key, double offset}) anchor) {
    if (!mounted || !_scroll.hasClients || _scroll.position.isScrollingNotifier.value) return;
    final now = _offsetOf(anchor.key);
    if (now == null) return;
    final delta = now - anchor.offset;
    if (delta.abs() < 0.5) return;
    final p = _scroll.position;
    _scroll.jumpTo((p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent));
  }

  /// Whether row [key] is on screen whole, clear of the system bar and the chrome's toolbar at the bottom.
  bool _fullyVisible(String key) {
    final box = _boxOf(key);
    final viewport = _scroll.position.context.storageContext.findRenderObject();
    if (box == null || viewport is! RenderBox) return false;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottomCover = MediaQuery.paddingOf(context).bottom + widget.bottomInset;
    return top >= 0 && top + box.size.height <= _scroll.position.viewportDimension - bottomCover;
  }

  /// Scrolls node [id]'s row into view (lazily built rows are reached in a few jumps); [highlight] marks it for a
  /// moment.
  void revealNode(String id, {bool highlight = false}) {
    if (!mounted) return;
    _layout = _cache.layoutOf(_doc);
    final index = _layout.rowOfNode(id);
    if (index == null) return;
    if (highlight) {
      _highlightTimer?.cancel();
      _highlighted = id;
      _highlightTimer = Timer(const Duration(milliseconds: 1600), () {
        if (mounted) setState(() => _highlighted = null);
      });
    }
    setState(() {});
    _scrollTo(_layout.rows[index].key);
  }

  void _scrollTo(String key, [int attempt = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final ctx = _rows[key];
      if (ctx != null && ctx.mounted && _boxOf(key) != null) {
        if (_fullyVisible(key)) return;
        unawaited(
          Scrollable.ensureVisible(
            ctx,
            alignment: 0.3,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          ),
        );
        return;
      }
      if (attempt >= 4) return;
      final target = _layout.rowOfKey(key);
      if (target == null) return;
      // From the nearest built row (or the top), add the rows' estimated heights.
      var from = 0, base = 0.0;
      for (final k in _rows.keys) {
        final i = _layout.rowOfKey(k), at = i == null ? null : _offsetOf(k);
        if (i == null || at == null) continue;
        if ((target - i).abs() < (target - from).abs() || (from == 0 && base == 0)) {
          from = i;
          base = at;
        }
      }
      var offset = base;
      final step = from <= target ? 1 : -1;
      for (var i = from; i != target; i += step) {
        offset += step * (_estimates[_layout.rows[step > 0 ? i : i - 1].kind] ?? 48);
      }
      final p = _scroll.position;
      _scroll.jumpTo((offset - p.viewportDimension * 0.3).clamp(p.minScrollExtent, p.maxScrollExtent));
      _scrollTo(key, attempt + 1);
    });
  }

  // ----- actions -----

  bool get _readOnly => _actions.nodesReadOnly;

  void _open(String id) {
    _selectingHere = true;
    try {
      (widget.onOpenNode ?? _actions.selectNode)(id);
      _selected = _c.selectedNodeId;
    } finally {
      _selectingHere = false;
    }
    _repaint();
  }

  /// Opens the block selector for [insert] at row [key]'s "+" and reveals the step it adds.
  Future<void> _insert(String key, StepInsert insert, {Rect? anchor}) async {
    final before = _doc.nodes.keys.toSet();
    await _actions.showStepBlockSelector(context, insert, anchor: anchor ?? _plusRect(key));
    if (mounted) _revealAdded(before);
  }

  /// The "+" of row [key] (at the connector's line, one indent per level), in global coordinates.
  Rect? _plusRect(String key) {
    final box = _boxOf(key);
    final index = _layout.rowOfKey(key);
    if (box == null || index == null) return null;
    final row = _layout.rows[index];
    final start = DifyStepMetrics.indent * row.depth + DifyStepMetrics.lineX;
    final x = Directionality.of(context) == TextDirection.rtl ? box.size.width - start : start;
    final center = box.localToGlobal(Offset(x, math.min(box.size.height, DifyStepMetrics.rowHeight) / 2));
    return Rect.fromCenter(center: center, width: 24, height: 24);
  }

  void _revealAdded(Set<String> before) {
    final added = [
      for (final id in _doc.nodes.keys)
        if (!before.contains(id)) id,
    ];
    _layout = _cache.layoutOf(_doc);
    for (final id in added) {
      if (_layout.rowOfNode(id) != null) return revealNode(id, highlight: true);
    }
  }

  Future<void> _duplicate(String id) async {
    final before = _doc.nodes.keys.toSet();
    await _actions.duplicateNodes(id);
    if (mounted) _revealAdded(before);
  }

  bool _canInsert(StepInsert? insert, BlockSelectorData data) =>
      insert != null && !_readOnly && _actions.stepBlocksAt(insert, data).isNotEmpty;

  Future<void> _showActions(String id, StepRow row) async {
    final n = _doc.nodes[id];
    if (n == null) return;
    final a = _actions, meta = a.metaOf(n), readOnly = a.nodesReadOnly;
    final data = BlockSelectorScope.of(context);
    final canRun = a.options.canRun && !readOnly && canRunBySingle(n.type, isChildNode: parentIdOf(n) != null);
    final box = _boxOf(row.key);
    final cardRect = box == null ? null : box.localToGlobal(Offset.zero) & box.size;
    await showDifyActionSheet(
      context,
      title: n.title.isEmpty ? blockName(n.type) : n.title,
      actions: [
        DifyActionSheetAction(
          label: DifyI18n.tr('common', 'operation.settings'),
          icon: const RemixIcon('settings-3-line', size: 20),
          onTap: () => _open(id),
        ),
        if (canRun)
          DifyActionSheetAction(
            label: a.isSingleRunning(id)
                ? DifyI18n.tr('workflow', 'debug.variableInspect.trigger.stop')
                : DifyI18n.tr('workflow', 'panel.runThisStep'),
            icon: RemixIcon(a.isSingleRunning(id) ? 'stop-circle-line' : 'play-circle-line', size: 20),
            onTap: () => a.runStep(id),
          ),
        if (_canInsert(row.insert, data))
          DifyActionSheetAction(
            label: _t('addStepAfter'),
            icon: const RemixIcon('add-line', size: 20),
            onTap: () => _insert(row.key, row.insert!, anchor: cardRect),
          ),
        if (!readOnly && !(meta?.isSingleton ?? false) && a.isNodeCopyable(n))
          DifyActionSheetAction(
            label: DifyI18n.tr('common', 'operation.duplicate'),
            icon: const RemixIcon('file-copy-line', size: 20),
            onTap: () => _duplicate(id),
          ),
        if (!readOnly && !(meta?.isUndeletable ?? false))
          DifyActionSheetAction(
            label: DifyI18n.tr('common', 'operation.delete'),
            icon: const RemixIcon('delete-bin-line', size: 20),
            destructive: true,
            onTap: () => a.deleteNode(id),
          ),
      ],
    );
  }

  // ----- rows -----

  Color _railColor(StepRail r) {
    final quiet = DifyColors.textQuaternary;
    switch (r.kind) {
      case StepLaneKind.elseCase || StepLaneKind.timeout || StepLaneKind.other:
        return quiet;
      case StepLaneKind.failBranch:
        return DifyColors.workflowLinkLineFailureHandle;
      case _:
        final owner = _doc.nodes[r.ownerId];
        final color = owner == null ? quiet : blockColor(owner.type);
        return color.a == 0 ? quiet : color;
    }
  }

  Widget _statusIcon(NodeRunView run) {
    if (run.isLoading) {
      return DifySpinner(key: const ValueKey('step-status-running'), size: 20, color: DifyColors.textAccent);
    }
    final (icon, color) = switch (run.status) {
      'failed' => ('error-warning-fill', DifyColors.textDestructive),
      'exception' => ('alert-fill', DifyColors.textWarningSecondary),
      'succeeded' => ('checkbox-circle-fill', DifyColors.textSuccess),
      'paused' => ('pause-circle-fill', DifyColors.textWarningSecondary),
      _ => ('', DifyColors.textTertiary),
    };
    return RemixIcon(icon, key: ValueKey('step-status-${run.status}'), size: 20, color: color);
  }

  Widget _card(StepRow row) {
    final n = _doc.nodes[row.nodeId]!;
    final run = widget.canvas.nodeRun.value[n.id] ?? NodeRunView.idle;
    final running = run.isLoading || run.status != 'idle';
    final issue = _issues[n.id];
    final status = running ? (run.isLoading ? DifyColors.stateAccentSolid : statusBorderColor(run.status)) : null;
    final title = n.title.isEmpty ? blockName(n.type) : n.title;
    return DifyStepCard(
      key: ValueKey('step-card-${n.id}'),
      leading: FittedBox(child: BlockIcon(type: n.type)),
      title: title,
      subtitle: issue != null && issue.message.isNotEmpty ? issue.message : stepSummary(n, _doc),
      subtitleColor: issue != null && issue.message.isNotEmpty ? DifyColors.textDestructive : null,
      statusColor: status ?? (issue != null ? DifyColors.stateDestructiveSolid : null),
      trailing: [
        if (issue != null)
          RemixIcon(
            'error-warning-fill',
            key: const ValueKey('step-issue'),
            size: 18,
            color: DifyColors.textDestructive,
          ),
        if (running) _statusIcon(run),
      ],
      chevron: !running,
      selected: _c.selectedNodeId == n.id,
      highlighted: _highlighted == n.id,
      dimmed: run.waiting,
      onTap: () => _open(n.id),
      onLongPress: () => _showActions(n.id, row),
    );
  }

  Widget _plus(StepRow row, BlockSelectorData data) {
    final insert = row.insert;
    final last = insert?.at is InsertAfter;
    final can = _canInsert(insert, data);
    if (row.kind == StepRowKind.bodyStart && row.emptyBody) return _addRow(row, data);
    if (last && !can) return const SizedBox.shrink();
    return DifyStepConnector(
      key: ValueKey('step-plus-${row.key}'),
      end: last && row.kind != StepRowKind.bodyStart,
      addLabel: _t('addStepHere'),
      onAdd: can ? () => _insert(row.key, insert!) : null,
    );
  }

  Widget _addRow(StepRow row, BlockSelectorData data) => DifyStepAddRow(
    key: ValueKey('step-add-${row.key}'),
    label: _t('addStep'),
    onTap: _canInsert(row.insert, data) ? () => _insert(row.key, row.insert!) : null,
  );

  Widget _row(StepRow row, BlockSelectorData data) {
    final rails = [for (final r in row.rails) _railColor(r)];
    final Widget child = switch (row.kind) {
      StepRowKind.card => _card(row),
      StepRowKind.connector || StepRowKind.bodyStart => _plus(row, data),
      StepRowKind.addStep => _addRow(row, data),
      StepRowKind.laneHeader => DifyStepLaneLabel(
        laneLabel(_doc.nodes[row.nodeId]!, row, _doc),
        key: ValueKey('step-lane-${row.key}'),
        color: rails.isEmpty ? DifyColors.textQuaternary : rails.last,
      ),
      StepRowKind.link => DifyStepLinkRow(
        key: ValueKey('step-link-${row.key}'),
        label: _t('continuesAt', {'title': _titleOf(row.nodeId!)}),
        onTap: () => revealNode(row.nodeId!, highlight: true),
      ),
      StepRowKind.section => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(4, 20, 4, 8),
        child: Semantics(
          header: true,
          child: DifyText(_t('notConnected'), DifyType.systemXsMediumUppercase, color: DifyColors.textTertiary),
        ),
      ),
      StepRowKind.gap => const SizedBox(height: 16),
    };
    return _RowSlot(
      key: ValueKey(row.key),
      rowKey: row.key,
      registry: _rows,
      child: DifyStepRails(rails: rails, opensLane: row.kind == StepRowKind.laneHeader, child: child),
    );
  }

  String _titleOf(String id) {
    final n = _doc.nodes[id];
    if (n == null) return id;
    return n.title.isEmpty ? blockName(n.type) : n.title;
  }

  @override
  Widget build(BuildContext context) {
    final data = BlockSelectorScope.of(context);
    final insets = MediaQuery.paddingOf(context);
    final rows = _layout.rows;
    final end = 24 + insets.bottom + widget.bottomInset;
    if (rows.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(bottom: end),
        child: Center(child: DifyText(_t('empty'), DifyType.systemSmRegular, color: DifyColors.textTertiary)),
      );
    }
    return CustomScrollView(
      key: const ValueKey('workflow-steps'),
      controller: _scroll,
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16 + insets.left, widget.topPadding, 16 + insets.right, end),
          sliver: SliverList(
            delegate: SliverChildBuilderDelegate(
              (context, i) => _row(rows[i], data),
              childCount: rows.length,
              findChildIndexCallback: (key) => key is ValueKey<String> ? _layout.rowOfKey(key.value) : null,
            ),
          ),
        ),
      ],
    );
  }
}

/// A built row: registers its context under [rowKey] while mounted (to measure and reveal it).
class _RowSlot extends StatefulWidget {
  const _RowSlot({super.key, required this.rowKey, required this.registry, required this.child});
  final String rowKey;
  final Map<String, BuildContext> registry;
  final Widget child;

  @override
  State<_RowSlot> createState() => _RowSlotState();
}

class _RowSlotState extends State<_RowSlot> {
  @override
  void initState() {
    super.initState();
    widget.registry[widget.rowKey] = context;
  }

  @override
  void didUpdateWidget(_RowSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    final old = oldWidget;
    if (old.rowKey != widget.rowKey) {
      if (identical(old.registry[old.rowKey], context)) old.registry.remove(old.rowKey);
      widget.registry[widget.rowKey] = context;
    }
  }

  @override
  void dispose() {
    if (identical(widget.registry[widget.rowKey], context)) widget.registry.remove(widget.rowKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
