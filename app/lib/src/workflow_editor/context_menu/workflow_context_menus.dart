import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../canvas/edge_curve.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../store/store.dart';
import 'menus.dart';
import 'node_control.dart';
import 'workflow_actions.dart';

/// workflow-contextmenu.tsx: one context menu around the canvas whose content follows what was right-clicked (or
/// long-pressed): the box around several selected nodes (selection menu), a node (node menu, selecting it), an
/// edge (edge menu, selecting it), or the pane. Also shows each hovered or selected node's [NodeControl] above its
/// card's top-right corner, and keeps the store's `mousePosition` (where pastes go) up to date.
///
/// Wrap the [WorkflowCanvas] with it, inside the editor's [WorkflowStoreScope].
class WorkflowContextMenus extends StatefulWidget {
  const WorkflowContextMenus({
    super.key,
    required this.controller,
    required this.canvas,
    this.options = const WorkflowMenuOptions(),
    required this.child,
  });

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions options;
  final Widget child;

  @override
  State<WorkflowContextMenus> createState() => _WorkflowContextMenusState();
}

class _WorkflowContextMenusState extends State<WorkflowContextMenus> {
  final _menu = DifyFloatingController();
  WorkflowStore? _store;
  late WorkflowActions actions;

  /// The target the menu shows (kept while it fades out after the store's target is cleared).
  WorkflowContextMenuTarget? _shown;
  Offset _at = Offset.zero;
  bool _opening = false;

  /// Node controls: the one whose bar the pointer is on, the one whose menu is open; [_layer] repaints them.
  String? _barHover, _menuFor;
  final _layer = ValueNotifier(0);
  bool _barsShown = false;

  WorkflowStore get store => _store!;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_documentChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final s = WorkflowStoreScope.of(context);
    if (s == _store) return;
    _store?.contextMenuTarget.removeListener(_targetChanged);
    _store = s..contextMenuTarget.addListener(_targetChanged);
    _makeActions();
  }

  @override
  void didUpdateWidget(WorkflowContextMenus old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_documentChanged);
      widget.controller.addListener(_documentChanged);
    }
    _makeActions();
  }

  void _makeActions() => actions = WorkflowActions(
    controller: widget.controller,
    canvas: widget.canvas,
    store: store,
    options: widget.options,
  );

  @override
  void dispose() {
    widget.controller.removeListener(_documentChanged);
    _store?.contextMenuTarget.removeListener(_targetChanged);
    _layer.dispose();
    super.dispose();
  }

  // ----- the menu -----

  bool get _shownExists => switch (_shown) {
    NodeContextMenuTarget(:final nodeId) => actions.doc.nodes.containsKey(nodeId),
    EdgeContextMenuTarget(:final edgeId) => actions.doc.edges.containsKey(edgeId),
    SelectionContextMenuTarget() => actions.selectedNodes.length > 1,
    _ => true,
  };

  /// Dify hides a menu whose node or edge is gone.
  void _documentChanged() {
    if (!_menu.isOpen) return;
    if (!_shownExists) return _menu.close(instant: true);
    setState(() {});
  }

  /// An action cleared the target (deleting the menu's edge): the menu goes.
  void _targetChanged() {
    if (store.contextMenuTarget.value == null && _menu.isOpen && !_opening) _menu.close(instant: true);
  }

  void _openChanged(bool open) {
    if (!open && !_opening) actions.handlePaneContextmenuCancel();
  }

  WorkflowContextMenuTarget? _hit(Offset local) {
    final g = widget.canvas.graph, view = widget.canvas.view, selection = widget.canvas.selection;
    final a = actions;
    WorkflowContextMenuTarget? pane() {
      a.handlePaneContextMenu();
      return WorkflowContextMenuTarget.panel;
    }

    if (g == null) return pane();
    final c = view.toCanvas(local);
    if (selection.nodes.length > 1) {
      Rect? box;
      for (final s in selection.nodes) {
        final n = g.slots.elementAtOrNull(s);
        if (n != null) box = box?.expandToInclude(n.visual) ?? n.visual;
      }
      if (box != null && box.contains(c) && a.handleSelectionContextMenu(onSelectionRect: true)) {
        return WorkflowContextMenuTarget.selection;
      }
    }
    final node = _nodeAt(g, c);
    if (node != null) return a.handleNodeContextMenu(node.id) ? NodeContextMenuTarget(node.id) : null;
    final edge = _edgeAt(g, c, 6 / view.scale);
    if (edge != null) return a.handleEdgeContextMenu(edge.id) ? EdgeContextMenuTarget(edge.id) : null;
    return pane();
  }

  /// The top-most node under [c] (CanvasInput.nodeAt: nested nodes above containers, selected above others).
  CanvasNode? _nodeAt(CanvasGraph g, Offset c) {
    final selected = widget.canvas.selection.nodes;
    int key(CanvasNode n) =>
        n.layout.underlay ? n.order - (1 << 50) : (n.depth << 44) + (selected.contains(n.slot) ? 1 << 40 : 0) + n.order;
    CanvasNode? hit;
    for (final slot in g.grid.near(Rect.fromCenter(center: c, width: 1, height: 1))) {
      final n = g.slots[slot];
      if (n == null || !n.rect.contains(c)) continue;
      if (hit == null || key(n) > key(hit)) hit = n;
    }
    return hit;
  }

  CanvasEdge? _edgeAt(CanvasGraph g, Offset c, double radius) {
    CanvasEdge? best;
    var bestD = radius;
    for (final e in g.edges) {
      final from = g.slots[e.source]!.outPortFor(e.sourceHandle), to = g.slots[e.target]!.inPort;
      if (!Rect.fromPoints(from, to).inflate(60 + radius).contains(c)) continue;
      final d = distanceToPolyline(c, edgeCurve(from, to));
      if (d <= bestD) {
        best = e;
        bestD = d;
      }
    }
    return best;
  }

  void _openAt(Offset local, Offset global) {
    _opening = true;
    final target = _hit(local);
    final items = target == null ? const <Widget>[] : _items(target, widget.canvas.view.toCanvas(local));
    if (items.isEmpty) {
      _opening = false;
      if (target != null) actions.handlePaneContextmenuCancel();
      return;
    }
    setState(() {
      _shown = target;
      _at = widget.canvas.view.toCanvas(local);
    });
    // After the tap region has seen this pointer down (which closes a menu already open).
    scheduleMicrotask(() {
      _opening = false;
      if (mounted) _menu.open(at: global);
    });
  }

  List<Widget> _items(WorkflowContextMenuTarget? t, Offset at) => switch (t) {
    PanelContextMenuTarget() => panelMenuItems(actions, at: at),
    NodeContextMenuTarget(:final nodeId) when actions.doc.nodes[nodeId] != null => nodeActionsMenuItems(
      actions,
      actions.doc.nodes[nodeId]!,
    ),
    EdgeContextMenuTarget(:final edgeId) when actions.doc.edges.containsKey(edgeId) => edgeMenuItems(actions, edgeId),
    SelectionContextMenuTarget() => selectionMenuItems(actions),
    _ => const [],
  };

  double? get _width => switch (_shown) {
    PanelContextMenuTarget() => panelMenuWidth,
    NodeContextMenuTarget() => nodeMenuWidth,
    SelectionContextMenuTarget() => selectionMenuWidth,
    _ => null,
  };

  void _track(PointerEvent e) {
    store.setMousePosition((
      pageX: e.position.dx,
      pageY: e.position.dy,
      elementX: e.localPosition.dx,
      elementY: e.localPosition.dy,
    ));
  }

  // ----- node controls -----

  void _setBar({String? hover, String? menu, bool clearMenu = false}) {
    _barHover = hover;
    if (menu != null || clearMenu) _menuFor = menu;
    _layer.value++;
  }

  List<Widget> _bars() {
    _barsShown = false;
    final g = widget.canvas.graph, view = widget.canvas.view, selection = widget.canvas.selection;
    if (g == null || actions.nodesReadOnly) return const [];
    final ids = <String>{};
    void add(CanvasNode? n, {required bool hover}) {
      if (n == null || hasNoNodeMenu(n.node.value)) return;
      if (hover && (widget.options.pluginInstallLocked?.call(n.node.value) ?? false)) return;
      ids.add(n.id);
    }

    add(selection.hovered == null ? null : g.slots.elementAtOrNull(selection.hovered!), hover: true);
    if (selection.nodes.length == 1) add(g.slots.elementAtOrNull(selection.nodes.single), hover: false);
    if (_barHover != null) add(g[_barHover!], hover: true);
    if (_menuFor != null) add(g[_menuFor!], hover: false);
    _barsShown = ids.isNotEmpty;
    return [
      for (final id in ids)
        if (g[id] case final n?)
          // node-control.tsx `absolute -top-7 right-0 h-7 pb-1` inside the card's 1 px border, scaled with the view.
          Positioned(
            key: ValueKey(id),
            right: view.viewport.width - view.toScreen(Offset(n.rect.right - 1, 0)).dx,
            top: view.toScreen(Offset(0, n.rect.top + 1 - 28)).dy,
            child: Transform.scale(
              scale: view.scale,
              alignment: Alignment.topRight,
              child: ValueListenableBuilder(
                valueListenable: n.run,
                // `!data._runningStatus && <NodeControl />`.
                builder: (context, run, _) => run.runningStatus != null
                    ? const SizedBox.shrink()
                    : MouseRegion(
                        onEnter: (_) => _setBar(hover: id),
                        onExit: (_) => _setBar(),
                        child: Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: NodeControl(
                            actions: actions,
                            node: n.node.value,
                            onMenuOpenChange: (open) => open
                                ? _setBar(hover: _barHover, menu: id)
                                : _setBar(hover: _barHover, clearMenu: _menuFor == id),
                          ),
                        ),
                      ),
              ),
            ),
          ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final canvas = widget.canvas;
    return DifyContextMenu(
      controller: _menu,
      // Opened here, once the target is known.
      disabled: true,
      sideOffset: 4,
      width: _width,
      onOpenChange: _openChanged,
      children: _items(_shown, _at),
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: (e) {
          _track(e);
          if (e.kind == PointerDeviceKind.mouse && e.buttons == kSecondaryButton) _openAt(e.localPosition, e.position);
        },
        onPointerHover: _track,
        onPointerMove: (e) {
          _track(e);
          // Dragged nodes move without telling anyone; their controls follow.
          if (_barsShown) _layer.value++;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          supportedDevices: const {PointerDeviceKind.touch, PointerDeviceKind.stylus},
          onLongPressStart: (d) => _openAt(d.localPosition, d.globalPosition),
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              Positioned.fill(
                child: ListenableBuilder(
                  listenable: Listenable.merge([
                    canvas.selection,
                    canvas.view,
                    widget.controller,
                    _layer,
                    actions.readOnlyChanges,
                  ]),
                  builder: (context, _) => Stack(clipBehavior: Clip.hardEdge, children: _bars()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
