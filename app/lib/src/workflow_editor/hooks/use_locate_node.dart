/// hooks/use-locate-node.ts: an editor opened for a node (the web URL's `node_id`, `--node-id` on desktop; operators
/// paste a failing node's id from the server logs) selects it once it is in the document, brings it into view and says
/// so; a node that is still missing half a second after the nodes stopped changing is reported as not found.
library;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../design/widgets/toast.dart';
import '../../editor/editor_controller.dart';
import '../../i18n/dify_i18n.dart';

/// `useLocateNode(nodes)` for [nodeIdFromUrl]: feed it the nodes whenever they change ([update]).
class NodeLocator {
  NodeLocator({
    required this.nodeIdFromUrl,
    required this.select,
    required this.scrollTo,
    void Function(DifyToastType type, String message)? toast,
  }) : toast = toast ?? difyToast;

  /// The node to locate; null or empty: nothing to do.
  final String? nodeIdFromUrl;

  /// `handleNodeSelect`: selects the node (its panel opens).
  final void Function(String nodeId) select;

  /// `scrollToWorkflowNode`.
  final void Function(String nodeId) scrollTo;
  final void Function(DifyToastType type, String message) toast;

  bool _located = false;
  Timer? _scroll, _notFound;

  /// The document's nodes now (`id`, `title`).
  void update(Iterable<({String id, String title})> nodes) {
    final id = nodeIdFromUrl;
    if (id == null || id.isEmpty || _located) return;
    final list = nodes.toList();
    // Wait for the nodes to load.
    if (list.isEmpty) return;
    final target = list.where((n) => n.id == id).firstOrNull;
    _notFound?.cancel();
    if (target == null) {
      // The nodes may still be arriving: report only once they have settled.
      _notFound = Timer(const Duration(milliseconds: 500), () {
        if (_located) return;
        toast(DifyToastType.error, DifyI18n.tr('workflow', 'panel.locateNodeNotFound', {'nodeId': id}));
        _located = true;
      });
      return;
    }
    select(id);
    // After the selection has been applied.
    _scroll = Timer(const Duration(milliseconds: 200), () => scrollTo(id));
    toast(
      DifyToastType.success,
      DifyI18n.tr('workflow', 'panel.locateNodeSuccess', {'title': target.title.isNotEmpty ? target.title : id}),
    );
    _located = true;
  }

  void dispose() {
    _scroll?.cancel();
    _notFound?.cancel();
  }
}

/// `scrollToWorkflowNode` on the canvas (utils/node-navigation.ts `setupScrollToNodeListener`): zoom 1 with the
/// node's top-left a quarter of the [window] right of and below the view's centre, over 800 ms (d3-zoom's cubic
/// in-out); [vsync] drives the animation, the returned ticker can be disposed to stop it.
Ticker? scrollCanvasToNode(CanvasController canvas, String nodeId, Size window, TickerProvider vsync) {
  final n = canvas.graph?[nodeId];
  if (n == null) return null;
  final view = canvas.view;
  final fromCenter = view.center, fromScale = view.scale;
  final toCenter = Offset(n.x + window.width * 0.25, n.y + window.height * 0.25);
  const duration = Duration(milliseconds: 800);
  late final Ticker ticker;
  ticker = vsync.createTicker((elapsed) {
    final t = Curves.easeInOutCubic.transform((elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0));
    view
      ..scale = fromScale + (1 - fromScale) * t
      ..center = Offset.lerp(fromCenter, toCenter, t)!;
    if (elapsed >= duration) ticker.stop();
  })..start();
  return ticker;
}

/// Locates [nodeId] in [controller]'s document on [canvas] once (see [NodeLocator]).
class LocateNodeOnOpen extends StatefulWidget {
  const LocateNodeOnOpen({super.key, required this.controller, required this.canvas, required this.nodeId});

  final EditorController controller;
  final CanvasController canvas;
  final String? nodeId;

  @override
  State<LocateNodeOnOpen> createState() => _LocateNodeOnOpenState();
}

class _LocateNodeOnOpenState extends State<LocateNodeOnOpen> with TickerProviderStateMixin {
  late final NodeLocator _locator = NodeLocator(
    nodeIdFromUrl: widget.nodeId,
    select: (id) {
      final slot = widget.canvas.graph?[id]?.slot;
      if (slot != null) widget.canvas.selection.selectNodes([slot]);
      widget.controller.selectNode(id);
    },
    scrollTo: (id) {
      if (!mounted) return;
      _ticker?.dispose();
      _ticker = scrollCanvasToNode(widget.canvas, id, MediaQuery.sizeOf(context), this);
    },
  );
  Ticker? _ticker;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
    // After the first frame: the canvas has laid out its nodes by then.
    WidgetsBinding.instance.addPostFrameCallback((_) => _changed());
  }

  void _changed() {
    if (!mounted || !widget.controller.ready) return;
    _locator.update([for (final n in widget.controller.doc.nodes.values) (id: n.id, title: n.title)]);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _locator.dispose();
    _ticker?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
