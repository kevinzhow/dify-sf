import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_graph.dart';
import '../../editor/editor_controller.dart';
import '../context_menu/context_menu.dart' show WorkflowActions, WorkflowMenuOptions;
import '../store/store.dart';
import 'node_resizers.dart' show nodeResizerSize, writeNodeResizerSize;

/// `ITERATION_PADDING` / `LOOP_PADDING`'s right and bottom.
const _paddingRight = 16.0, _paddingBottom = 20.0;

/// The containers whose children [ContainerChildSizeObserver] watches.
bool isContainerType(String type) => type == 'iteration' || type == 'loop';

/// `getContainerResize(current, getContainerBounds(children))`: the size [container] grows to so that its children
/// fit (the child reaching furthest right / down plus the container padding), or null when they already fit. Only
/// the dimensions the children overflow change.
Size? containerGrowth(CanvasNode container, Iterable<CanvasNode> children) {
  final size = nodeResizerSize(container), origin = container.rect.topLeft;
  double? right, bottom;
  for (final c in children) {
    right = math.max(right ?? double.negativeInfinity, c.rect.right - origin.dx);
    bottom = math.max(bottom ?? double.negativeInfinity, c.rect.bottom - origin.dy);
  }
  final w = right != null && size.width < right ? right + _paddingRight : null;
  final h = bottom != null && size.height < bottom ? bottom + _paddingBottom : null;
  if (w == null && h == null) return null;
  return Size(w ?? size.width, h ?? size.height);
}

/// node.tsx's `useNodeResizeObserver` for the selected children of iterations and loops (`enabled: data.selected &&
/// data.isInIteration / isInLoop`), with `handleNode…ChildSizeChange` as the callback: when such a node is selected,
/// and whenever its card changes size while selected, its container grows to fit its children
/// (`handleNode…Rerender`). The write is not an undo step (Dify's setNodes there saves no history). A read-only
/// canvas writes nothing.
class ContainerChildSizeObserver extends StatefulWidget {
  const ContainerChildSizeObserver({super.key, required this.controller, required this.canvas, this.options});

  final EditorController controller;
  final CanvasController canvas;
  final WorkflowMenuOptions? options;

  @override
  State<ContainerChildSizeObserver> createState() => _ContainerChildSizeObserverState();
}

class _ContainerChildSizeObserverState extends State<ContainerChildSizeObserver> {
  /// The observed nodes and the size they were last seen at.
  final _observed = <String, Size>{};
  bool _scheduled = false;
  WorkflowStore? _store;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    widget.canvas.selection.addListener(_changed);
    _changed();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _store = WorkflowStoreScope.of(context);
  }

  @override
  void didUpdateWidget(ContainerChildSizeObserver old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
    if (old.canvas != widget.canvas) {
      old.canvas.selection.removeListener(_changed);
      widget.canvas.selection.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    widget.canvas.selection.removeListener(_changed);
    super.dispose();
  }

  /// Looks once the frame has laid the cards out (the graph follows the document from its own listener).
  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        _scheduled = false;
        if (mounted) _observe();
      })
      ..scheduleFrame();
  }

  void _observe() {
    final graph = widget.canvas.graph, store = _store;
    if (graph == null || store == null) return;
    final actions = WorkflowActions(
      controller: widget.controller,
      canvas: widget.canvas,
      store: store,
      options: widget.options ?? const WorkflowMenuOptions(),
    );
    final seen = <String>{};
    final grow = <String>{};
    for (final slot in widget.canvas.selection.nodes) {
      final n = graph.slots[slot];
      final parent = n?.parentId == null ? null : graph[n!.parentId!];
      if (n == null || parent == null || !isContainerType(parent.type)) continue;
      seen.add(n.id);
      // ResizeObserver reports on observe, then on every size change.
      if (_observed[n.id] != n.size) grow.add(parent.id);
      _observed[n.id] = n.size;
    }
    _observed.removeWhere((id, _) => !seen.contains(id));
    if (grow.isEmpty || actions.nodesReadOnly) return;
    for (final id in grow) {
      final container = graph[id]!;
      final size = containerGrowth(container, [
        for (final c in graph.nodes)
          if (c.parentId == id) c,
      ]);
      if (size != null) writeNodeResizerSize(widget.controller, id, size);
    }
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
