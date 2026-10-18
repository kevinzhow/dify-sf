import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../canvas/edge_curve.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../editor/editor_controller.dart';
import '../block_selector/block_selector.dart';
import '../context_menu/context_menu.dart';
import '../node_insertion/insert_block.dart';
import '../store/store.dart';

/// The canvas "+" buttons (node-handle.tsx and custom-edge.tsx): on the handles of the hovered or selected node (a
/// target handle only while unconnected) and at the middle of the hovered edge. Each is BlockSelector's default
/// trigger, a 16 px blue circle that scales with the canvas; picking a block inserts it after the node, before it, or
/// between the edge's nodes. While the store asks for it (`shouldAutoOpenStartNodeSelector`, onboarding), a Start
/// or trigger node opens its next-block selector by itself, once (not in chatflows).
class CanvasPlusButtons extends StatefulWidget {
  const CanvasPlusButtons({super.key, required this.controller, required this.canvas, this.options});

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions? options;

  @override
  State<CanvasPlusButtons> createState() => _CanvasPlusButtonsState();
}

class _CanvasPlusButtonsState extends State<CanvasPlusButtons> {
  /// The button under the pointer or whose selector is open: it stays even when the node or edge is no longer
  /// hovered (the pointer left it for the button).
  String? _held;

  WorkflowActions _actions(BuildContext context) => WorkflowActions(
    controller: widget.controller,
    canvas: widget.canvas,
    store: WorkflowStoreScope.of(context),
    options: widget.options ?? const WorkflowMenuOptions(),
  );

  /// The button whose selector is open (or closing).
  String? _openKey;

  Future<void> _open(BuildContext context, String key, InsertPoint at, Rect anchor) async {
    setState(() => _held = key);
    _openKey = key;
    await _actions(context).showInsertBlockSelector(context, at, anchor: anchor);
    _openKey = null;
    if (mounted) setState(() => _held = null);
  }

  /// What the buttons were drawn for when one was held (the pointer on a button is off the node or edge).
  Set<int> _slots = const {};
  String? _edge;

  WorkflowStore? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = WorkflowStoreScope.of(context);
    if (s == _store) return;
    _store?.shouldAutoOpenStartNodeSelector.removeListener(_autoOpenLater);
    _store = s..shouldAutoOpenStartNodeSelector.addListener(_autoOpenLater);
    widget.controller.addListener(_autoOpenLater);
    _autoOpenLater();
  }

  @override
  void dispose() {
    _store?.shouldAutoOpenStartNodeSelector.removeListener(_autoOpenLater);
    widget.controller.removeListener(_autoOpenLater);
    super.dispose();
  }

  void _autoOpenLater() {
    if (_store?.shouldAutoOpenStartNodeSelector.value ?? false) {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _autoOpen() : null);
    }
  }

  /// node-handle.tsx's auto-open: `canAutoOpenStartNodeSelector` (a Start, schedule, webhook or plugin trigger node,
  /// never in chat mode) opens the source handle's selector and clears the flags; chat mode only clears the flag.
  void _autoOpen() {
    final store = _store, graph = widget.canvas.graph;
    if (store == null || graph == null || !store.shouldAutoOpenStartNodeSelector.value) return;
    if (BlockSelectorScope.of(context).chatMode) {
      store.setShouldAutoOpenStartNodeSelector(false);
      return;
    }
    const entries = {'start', 'trigger-schedule', 'trigger-webhook', 'trigger-plugin'};
    final n = graph.nodes.where((n) => entries.contains(n.type)).firstOrNull;
    final handle = n?.layout.sources.keys.firstOrNull;
    if (n == null || handle == null) return;
    store
      ..setShouldAutoOpenStartNodeSelector(false)
      ..setHasSelectedStartNode(false);
    final view = widget.canvas.view, size = 16 * view.scale;
    final center = view.toScreen(n.outPortFor(handle) - const Offset(CanvasNode.handleBox / 2, 0));
    final rect = Rect.fromCenter(center: center, width: size, height: size);
    final box = context.findRenderObject() as RenderBox?;
    final global = box == null || !box.hasSize ? rect : box.localToGlobal(rect.topLeft) & rect.size;
    _slots = {..._slots, n.slot};
    _open(context, 'out-${n.id}-$handle', InsertAfter(n.id, handle), global);
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.canvas, graph = c.graph;
    if (graph == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: Listenable.merge([c.view, c.selection, c.selection.hoveredEdge, widget.controller]),
      builder: (context, _) {
        final hovered = {?c.selection.hovered, if (c.selection.nodes.length == 1) c.selection.nodes.first};
        final hoveredEdge = c.selection.hoveredEdge.value;
        if (_held == null) {
          _slots = hovered;
          _edge = hoveredEdge;
        } else {
          _slots = {..._slots, ...hovered};
          _edge = hoveredEdge ?? _edge;
        }
        if (_slots.isEmpty && _edge == null) return const SizedBox.shrink();
        final actions = _actions(context), data = BlockSelectorScope.of(context);
        if (actions.nodesReadOnly) return const SizedBox.shrink();
        final view = c.view, z = view.scale, size = 16 * z;
        final buttons = <Widget>[];
        void add(String key, Offset canvasCenter, InsertPoint at) {
          final center = view.toScreen(canvasCenter);
          final rect = Rect.fromCenter(center: center, width: size, height: size);
          buttons.add(
            Positioned.fromRect(
              rect: rect,
              child: _PlusButton(
                key: ValueKey(key),
                zoom: z,
                onHover: (on) => setState(() => _held = on ? key : (_held == key ? null : _held)),
                onTap: () {
                  // A click on the open selector's handle closes it (the press outside the popup did), as the
                  // handle's click toggles it in Dify.
                  if (_openKey == key) return;
                  final box = context.findRenderObject() as RenderBox?;
                  final global = box == null ? rect : box.localToGlobal(rect.topLeft) & rect.size;
                  _open(context, key, at, global);
                },
              ),
            ),
          );
        }

        // Handles of the hovered and the selected node, where a block may connect (isConnectable).
        for (final slot in _slots) {
          final n = graph.slots[slot];
          final doc = n == null ? null : widget.controller.doc.nodes[n.id];
          if (n == null || doc == null) continue;
          final blocks = actions.availableBlocksOf(doc, data);
          if (blocks.next.isNotEmpty) {
            for (final handle in n.layout.sources.keys) {
              final port = n.outPortFor(handle);
              add('out-${n.id}-$handle', port - const Offset(CanvasNode.handleBox / 2, 0), InsertAfter(n.id, handle));
            }
          }
          final connectedIn = graph.edges.any((e) => e.target == slot);
          if (n.layout.target && !connectedIn && blocks.prev.isNotEmpty) {
            add('in-${n.id}', n.inPort + const Offset(CanvasNode.handleBox / 2, 0), InsertBefore(n.id));
          }
        }
        // The hovered edge's middle (the bezier at t = 0.5).
        final e = _edge == null ? null : graph.edges.where((e) => e.id == _edge).firstOrNull;
        final a = e == null ? null : graph.slots[e.source], b = e == null ? null : graph.slots[e.target];
        if (e != null && a != null && b != null) {
          final pts = edgeCurve(a.outPortFor(e.sourceHandle), b.inPort);
          add('edge-${e.id}', pts[pts.length ~/ 2], InsertOnEdge(e.id));
        }
        return Stack(clipBehavior: Clip.none, children: buttons);
      },
    );
  }
}

/// BlockSelector's default trigger: IconButton primary xs, rounded, plus-02 10 px, at the canvas zoom.
class _PlusButton extends StatefulWidget {
  const _PlusButton({super.key, required this.zoom, required this.onTap, required this.onHover});
  final double zoom;
  final VoidCallback onTap;
  final ValueChanged<bool> onHover;

  @override
  State<_PlusButton> createState() => _PlusButtonState();
}

class _PlusButtonState extends State<_PlusButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    onEnter: (_) {
      setState(() => _hovered = true);
      widget.onHover(true);
    },
    onExit: (_) {
      setState(() => _hovered = false);
      widget.onHover(false);
    },
    child: GestureDetector(
      onTap: widget.onTap,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _hovered ? DifyColors.componentsButtonPrimaryBgHover : DifyColors.componentsButtonPrimaryBg,
          boxShadow: DifyShadows.primaryButton,
        ),
        child: Center(
          child: DifyIcon('vender/line/general/plus-02', size: 10 * widget.zoom, color: const Color(0xFFFFFFFF)),
        ),
      ),
    ),
  );
}
