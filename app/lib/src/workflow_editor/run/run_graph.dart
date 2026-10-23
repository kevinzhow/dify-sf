/// The graph a run walks, as Dify's run code sees React Flow's nodes and edges (id, type, parent, position, size,
/// `data`), without their run fields: those are the store's local view state ([WorkflowStore.nodeRunData]).
library;

import 'dart:collection';

import 'package:collab_client/collab_client.dart' show Document, Node, VMap, VString;
import 'package:flutter/foundation.dart';

import '../../canvas/canvas_controller.dart';
import '../../editor/editor_controller.dart';
import '../../workflow/dify_json.dart' show difyDataOf;
import '../context_menu/clipboard.dart' show reactFlowTypeOf;
import '../organize/workflow_organize.dart' show reactFlowSizeOf;
import '../store/workflow_store.dart' show DifyJson;

@immutable
class RunGraphNode {
  const RunGraphNode({
    required this.id,
    required this.type,
    this.title = '',
    this.parentId,
    this.x = 0,
    this.y = 0,
    this.width = 240,
    this.height = 90,
    this.data = const {},
    this.rfType = 'custom',
  });

  final String id;

  /// React Flow's node type (`custom`; notes: `custom-note`).
  final String rfType;

  /// `data.type` (BlockEnum value).
  final String type;
  final String title;

  /// The iteration / loop the node is in.
  final String? parentId;

  /// React Flow's `position` (relative to the parent for nested nodes) and measured size.
  final double x;
  final double y;
  final double width;
  final double height;

  /// Dify's node `data` (config as plain JSON, `type`, `title`).
  final DifyJson data;
}

/// A node's `data`, converted from the document when first read (the run handlers walk the graph on every event and
/// rarely read it).
class _LazyData extends MapBase<String, Object?> {
  _LazyData(this._of);
  final DifyJson Function() _of;
  DifyJson? _map;
  DifyJson get _m => _map ??= _of();
  @override
  Object? operator [](Object? key) => _m[key];
  @override
  void operator []=(String key, Object? value) => _m[key] = value;
  @override
  void clear() => _m.clear();
  @override
  Iterable<String> get keys => _m.keys;
  @override
  Object? remove(Object? key) => _m.remove(key);
}

@immutable
class RunGraphEdge {
  const RunGraphEdge({
    required this.id,
    required this.source,
    required this.target,
    this.sourceHandle = 'source',
    this.targetHandle = 'target',
  });

  final String id;
  final String source;
  final String target;
  final String sourceHandle;
  final String targetHandle;
}

/// React Flow's `getNodes()` / `edges` for the run code.
abstract interface class RunGraph {
  List<RunGraphNode> get nodes;
  List<RunGraphEdge> get edges;
}

/// A fixed graph (tests, history views).
class StaticRunGraph implements RunGraph {
  const StaticRunGraph({this.nodes = const [], this.edges = const []});
  @override
  final List<RunGraphNode> nodes;
  @override
  final List<RunGraphEdge> edges;
}

/// React Flow's viewport as the run code moves it (`transform[2]`, `setViewport`).
abstract interface class RunViewport {
  double get zoom;
  void setViewport(double x, double y, double zoom);
}

/// The canvas's viewport.
class CanvasRunViewport implements RunViewport {
  const CanvasRunViewport(this.canvas);
  final CanvasController canvas;
  @override
  double get zoom => canvas.view.scale;
  @override
  void setViewport(double x, double y, double zoom) => canvas.setViewport(x, y, zoom);
}

/// The container a node sits in (Dify keeps `parentId` in `_dify_node`).
String? runParentOf(Node node) => switch (node.config['_dify_node']) {
  VMap(:final entries) => switch (entries['parentId']) {
    VString(:final value) when value.isNotEmpty => value,
    _ => null,
  },
  _ => null,
};

/// The editor's document (and the canvas's measured card sizes) as a [RunGraph]. dify-sf's own default handle id
/// `out` reads as Dify's `source`.
class EditorRunGraph implements RunGraph {
  EditorRunGraph(this.controller, [this.canvas]);
  final EditorController controller;
  final CanvasController? canvas;

  Document get _doc => controller.doc;

  @override
  List<RunGraphNode> get nodes => [
    for (final n in _doc.nodes.values)
      if (n.id != Document.appNode) _node(n),
  ];

  RunGraphNode _node(Node n) {
    final c = canvas?.graph?[n.id];
    // React Flow's measured size (card and frame): what Dify's run reads to centre a running node.
    final size = canvas == null ? null : reactFlowSizeOf(canvas!, n);
    return RunGraphNode(
      id: n.id,
      type: n.type,
      title: n.title,
      parentId: c?.parentId ?? runParentOf(n),
      x: n.x.toDouble(),
      y: n.y.toDouble(),
      width: size?.width ?? c?.size.width ?? 240,
      height: size?.height ?? c?.size.height ?? 90,
      data: _LazyData(() => difyDataOf(n)),
      rfType: reactFlowTypeOf(n),
    );
  }

  @override
  List<RunGraphEdge> get edges => [
    for (final e in _doc.edges.values)
      RunGraphEdge(
        id: e.id,
        source: e.source,
        target: e.target,
        sourceHandle: e.sourceHandle == 'out' || e.sourceHandle.isEmpty ? 'source' : e.sourceHandle,
        targetHandle: e.targetHandle == 'in' || e.targetHandle.isEmpty ? 'target' : e.targetHandle,
      ),
  ];
}
