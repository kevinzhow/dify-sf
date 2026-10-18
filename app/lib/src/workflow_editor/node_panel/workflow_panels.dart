/// The right panel host (web/app/components/workflow/panel/index.tsx): the selected node's panel, then the other
/// panels, with the widths the node panel's limits depend on measured into the store.
library;

import 'package:collab_client/collab_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../canvas/canvas_controller.dart';
import '../../cards/card_kit.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../../editor/graph_info.dart';
import '../../i18n/dify_i18n.dart';
import '../context_menu/context_menu.dart';
import '../store/store.dart';
import 'node_panel_bodies.dart';
import 'workflow_node_panel.dart';

/// Asks whether to delete a node whose outputs [refs] other nodes reference.
typedef ConfirmNodeDelete = Future<bool> Function(
  String nodeId,
  List<({String node, FieldKey field, OutputRef ref, bool broken})> refs,
);

/// [WorkflowActions] for the node panel: deleting a node that others reference asks first (dify-sf: the references
/// become explicit broken markers), as Dify does nothing of the kind.
class NodePanelActions extends WorkflowActions {
  NodePanelActions({
    required super.controller,
    required super.canvas,
    required super.store,
    super.options,
    required this.confirmDelete,
  });

  final ConfirmNodeDelete confirmDelete;

  @override
  void deleteNode(String nodeId) {
    if (nodesReadOnly) return;
    final refs = controller.referencesTo(nodeId);
    if (refs.isEmpty) return super.deleteNode(nodeId);
    confirmDelete(nodeId, refs).then((ok) {
      if (ok) super.deleteNode(nodeId);
    });
  }
}

/// Panel (panel/index.tsx) in the editor's panels slot (`absolute top-14 right-0 bottom-1 z-10 flex`): the node panel
/// while a node is selected (remounted per node id and type), then [others] (the debug, variable, version history
/// panels; none ported yet), whose width is the store's `otherPanelWidth`; the whole row's is `rightPanelWidth`.
/// A selected edge has no panel (as in Dify): it shows as selected on the canvas, Delete or its menu removes it.
///
/// The node panel rebuilds when the document changes in a way it shows (the node, any node's title, type or config,
/// the edges), not when nodes only move.
class WorkflowPanels extends StatefulWidget {
  const WorkflowPanels({
    super.key,
    required this.controller,
    required this.canvas,
    this.options = const WorkflowMenuOptions(),
    this.bodies = NodePanelBodies.defaults,
    this.others = const [],
    this.onSingleRun,
    this.onStopSingleRun,
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions options;
  final NodePanelBodies bodies;
  final List<Widget> others;
  final ValueChanged<String>? onSingleRun, onStopSingleRun;

  @override
  State<WorkflowPanels> createState() => _WorkflowPanelsState();
}

class _WorkflowPanelsState extends State<WorkflowPanels> {
  WorkflowStore? _store;
  late NodePanelActions _actions;

  /// What the node panel showed: the selected node, and per node its title, type and config, and the edges.
  Node? _node;
  final _nodes = <String, (String, String, Map<String, Value>)>{};
  final _edges = <String, Edge>{};

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_documentChanged);
    _snapshot();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = WorkflowStoreScope.of(context);
    if (s == _store) return;
    _store?.workflowCanvasWidth.removeListener(_limitPreviewWidth);
    _store = s..workflowCanvasWidth.addListener(_limitPreviewWidth);
    _makeActions();
  }

  @override
  void didUpdateWidget(WorkflowPanels old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_documentChanged);
      widget.controller.addListener(_documentChanged);
      _snapshot();
    }
    _makeActions();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_documentChanged);
    _store?.workflowCanvasWidth.removeListener(_limitPreviewWidth);
    super.dispose();
  }

  void _makeActions() => _actions = NodePanelActions(
    controller: widget.controller,
    canvas: widget.canvas,
    store: _store!,
    options: widget.options,
    confirmDelete: (id, refs) => confirmNodeDelete(context, widget.controller, id, refs),
  );

  bool _snapshot() {
    final c = widget.controller, doc = c.doc, node = c.selectedNode;
    var changed =
        node?.id != _node?.id ||
        node?.type != _node?.type ||
        node?.title != _node?.title ||
        !identical(node?.config, _node?.config);
    _node = node;
    if (node == null) {
      _nodes.clear();
      _edges.clear();
      return changed;
    }
    if (_nodes.length != doc.nodes.length || _edges.length != doc.edges.length) changed = true;
    for (final n in doc.nodes.values) {
      final was = _nodes[n.id];
      if (was == null || was.$1 != n.title || was.$2 != n.type || !identical(was.$3, n.config)) {
        changed = true;
        _nodes[n.id] = (n.title, n.type, n.config);
      }
    }
    for (final e in doc.edges.values) {
      if (!identical(_edges[e.id], e)) {
        changed = true;
        _edges[e.id] = e;
      }
    }
    if (changed) {
      _nodes.removeWhere((id, _) => !doc.nodes.containsKey(id));
      _edges.removeWhere((id, _) => !doc.edges.containsKey(id));
    }
    return changed;
  }

  void _documentChanged() {
    final selectionChanged = widget.controller.selectedNodeId != _node?.id;
    if (_snapshot()) setState(() {});
    if (selectionChanged) _limitPreviewWidth();
  }

  /// The preview panel may not exceed what the canvas leaves (more narrowly while a node panel is open).
  void _limitPreviewWidth() {
    final s = _store!;
    if (s.workflowCanvasWidth.value == null) return;
    final max = getPreviewPanelMaxWidth(s.workflowCanvasWidth.value, widget.controller.selectedNode != null);
    if (s.previewPanelWidth.value > max) s.setPreviewPanelWidth(max);
  }

  @override
  Widget build(BuildContext context) {
    final node = _node;
    final store = _store!;
    // Only workflow blocks have a panel (not notes or container starts: Panel renders CUSTOM_NODE only).
    final panelNode = node != null && reactFlowTypeOf(node) == 'custom' ? node : null;
    return _SizeReporter(
      // The node panel's resize strip (`absolute -left-1 w-1`) lies outside Dify's row: not part of its width.
      onSize: (size) => store.setRightPanelWidth(size.width - (panelNode != null ? 4 : 0)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (panelNode != null)
            WorkflowNodePanel(
              key: ValueKey('${panelNode.id}-${panelNode.type}'),
              node: panelNode,
              actions: _actions,
              bodies: widget.bodies,
              onSingleRun: widget.onSingleRun,
              onStopSingleRun: widget.onStopSingleRun,
            ),
          _SizeReporter(
            onSize: (size) => store.setOtherPanelWidth(size.width),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: widget.others,
            ),
          ),
        ],
      ),
    );
  }
}

/// Reports its size after each layout that changed it (Dify's ResizeObserver, a frame later).
class _SizeReporter extends SingleChildRenderObjectWidget {
  const _SizeReporter({required this.onSize, required super.child});
  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeReporter(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeReporter renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeReporter extends RenderProxyBox {
  _RenderSizeReporter(this.onSize);
  ValueChanged<Size> onSize;
  Size? _reported;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _reported) return;
    _reported = size;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) onSize(size);
    });
  }
}

/// dify-sf's warning before deleting a node others reference, in dify-ui's AlertDialog (`w-120 rounded-2xl
/// shadow-xl`, `p-6 pb-4` title and description, `p-6` actions): which references will break.
Future<bool> confirmNodeDelete(
  BuildContext context,
  EditorController controller,
  String nodeId,
  List<({String node, FieldKey field, OutputRef ref, bool broken})> refs,
) async {
  final n = refs.length;
  final ok = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    barrierColor: DifyColors.backgroundOverlay,
    transitionDuration: difyTransitionDuration,
    transitionBuilder: (context, animation, _, child) {
      final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
      );
    },
    pageBuilder: (context, _, _) => Center(
      child: Container(
        key: const Key('delete-dialog'),
        width: 480,
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: BorderRadius.circular(DifyRadius.xxl),
          boxShadow: DifyShadows.xl,
        ),
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 8,
                  children: [
                    DifyText(
                      'Delete ${controller.titleOf(nodeId)}?',
                      DifyType.title2xlSemiBold,
                      maxLines: null,
                    ),
                    DifyText(
                      'Its connections will be removed, and $n reference${n == 1 ? '' : 's'} to it will be marked '
                      'as broken:',
                      DifyType.systemMdRegular,
                      color: DifyColors.textSecondary,
                      maxLines: null,
                    ),
                    for (final r in refs)
                      DifyText(
                        '• ${controller.titleOf(r.node)} › ${fieldLabel(r.field)}  (${r.ref.node}.${r.ref.output})',
                        DifyType.systemSmRegular,
                        color: DifyColors.textSecondary,
                        maxLines: null,
                      ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: [
                    DifyButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(DifyI18n.tr('common', 'operation.cancel')),
                    ),
                    DifyButton(
                      key: const Key('confirm-delete'),
                      variant: DifyButtonVariant.primary,
                      tone: DifyButtonTone.destructive,
                      onPressed: () => Navigator.pop(context, true),
                      child: Text(DifyI18n.tr('common', 'operation.delete')),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  return ok ?? false;
}
