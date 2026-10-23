// SPDX-License-Identifier: EPL-2.0
/// Node positions for the flat ELK graphs built by Dify 1.17.1's elk-layout.ts.
///
/// This is a deliberately bounded subset of elkjs 0.11.1. It has no Flutter,
/// JavaScript, native, or runtime package dependencies. Container interiors are
/// separate flat layout calls, as in Dify. Returned edges/curve geometry are not
/// part of this API, but their spacing effects on node positions are preserved.
library;

import 'dart:math' as math;

import 'src/elk_crossmin.dart';
import 'src/elk_graph.dart';
import 'src/elk_layering.dart';
import 'src/elk_placement.dart';
import 'src/elk_routing.dart';

/// Immutable node geometry. Coordinates refer to the node's top-left corner.
class ElkNodeLayout {
  const ElkNodeLayout({required this.x, required this.y, required this.width, required this.height});

  final double x;
  final double y;
  final double width;
  final double height;

  Map<String, double> toJson() => {'x': x, 'y': y, 'width': width, 'height': height};
}

class ElkLayoutBounds {
  const ElkLayoutBounds({required this.minX, required this.minY, required this.maxX, required this.maxY});

  final double minX;
  final double minY;
  final double maxX;
  final double maxY;
  double get width => maxX - minX;
  double get height => maxY - minY;
}

class ElkLayoutResult {
  ElkLayoutResult(Map<String, ElkNodeLayout> nodes, this.bounds) : nodes = Map.unmodifiable(nodes);

  /// Input node IDs in input order. Algorithmic temporary nodes are excluded.
  final Map<String, ElkNodeLayout> nodes;
  final ElkLayoutBounds bounds;
}

/// Lays out a JSON-shaped graph produced by Dify's `buildPortAwareGraph`.
///
/// The graph has `children`, simple node-to-node `edges`, and the root or child
/// `layoutOptions` from Dify. This function does not mutate the supplied maps.
/// Branch sorting, DFS ordering, node filtering, and edge filtering belong to
/// the caller, exactly as they precede elkjs in Dify.
///
/// [normalize] defaults to true, matching Dify's final bounds normalization.
/// Set it to false for raw elkjs node coordinates, including default padding.
/// The legacy edge `sourcePort` field is ignored when `sources` is present,
/// just as in elkjs's JSON importer. Unused declared ports still occupy space.
///
/// Supported configurations are rightward layered layout, DFS cycle breaking,
/// network-simplex layering, model-order crossing minimization, balanced BK
/// placement, conservative spline spacing and EDGE_LENGTH post-compaction.
/// Nested graph JSON, self-loops, labels, nonzero-size ports, north/south ports,
/// and port-to-port edges are rejected rather than silently approximated.
ElkLayoutResult layoutGraph(Map<String, dynamic> input, {bool normalize = true}) {
  final options = _map(input['layoutOptions'], 'layoutOptions');
  _checkOptions(options);
  final graph = LGraph()
    ..options = ElkOptions(
      nodeNodeBetweenLayers: _spacing(options, 'elk.layered.spacing.nodeNodeBetweenLayers', 100),
      nodeNode: _spacing(options, 'elk.spacing.nodeNode', 80),
      edgeNode: _spacing(options, 'elk.spacing.edgeNode', 50),
      edgeEdge: _spacing(options, 'elk.spacing.edgeEdge', 30),
      portPort: _spacing(options, 'elk.spacing.portPort', 20),
      edgeNodeBetweenLayers: _spacing(options, 'elk.layered.spacing.edgeNodeBetweenLayers', 10),
      edgeEdgeBetweenLayers: _spacing(options, 'elk.layered.spacing.edgeEdgeBetweenLayers', 10),
      thoroughness: _thoroughness(options),
      greedySwitchHierarchical:
          options.isEmpty || options['elk.layered.crossingMinimization.greedySwitchHierarchical.type'] == 'TWO_SIDED',
    )
    ..random = GwtRandom(1);
  graph.spacings = Spacings(graph.options);

  final children = _list(input['children'], 'children');
  final originals = <LNode>[];
  final nodes = <String, LNode>{};
  final ids = <String>[];
  for (var i = 0; i < children.length; i++) {
    final child = _map(children[i], 'child');
    final id = _id(child['id'], 'node');
    if (nodes.containsKey(id)) throw ArgumentError('Duplicate node ID: $id');
    if (_list(child['children'], 'nested children').isNotEmpty) {
      throw UnsupportedError('Lay out each container interior in a separate flat graph, as Dify does.');
    }
    _rejectLabels(child);
    final nodeOptions = _map(child['layoutOptions'], 'node layoutOptions');
    final constraint = nodeOptions['elk.portConstraints'];
    if (constraint != null && constraint != 'FIXED_ORDER' && constraint != 'FREE') {
      throw UnsupportedError('Unsupported node port constraints: $constraint');
    }
    final node = LNode(graph)
      ..origin = i
      ..modelOrder = i
      ..portConstraints = constraint == 'FIXED_ORDER' ? PortConstraints.fixedOrder : PortConstraints.free;
    node.size
      ..x = _dimension(child['width'], 244)
      ..y = _dimension(child['height'], 100);
    final declared = _list(child['ports'], 'ports');
    for (var j = 0; j < declared.length; j++) {
      final port = _map(declared[j], 'port');
      _id(port['id'], 'port');
      _rejectLabels(port);
      final portOptions = _map(port['layoutOptions'], 'port layoutOptions');
      if (portOptions['elk.port.side'] != null && portOptions['elk.port.side'] != 'EAST') {
        throw UnsupportedError('Dify declares only EAST ports.');
      }
      if (_dimension(port['width'], 0) != 0 || _dimension(port['height'], 0) != 0) {
        throw UnsupportedError('Dify declares only zero-size ports.');
      }
      final portIndex = int.tryParse('${portOptions['elk.port.index'] ?? j}');
      if (portIndex == null) throw ArgumentError('Port index must be an integer.');
      LPort()
        ..portIndex = portIndex
        ..modelOrder = j
        ..setSide(PortSide.east)
        ..setNode(node);
    }
    ids.add(id);
    originals.add(node);
    nodes[id] = node;
    graph.layerlessNodes.add(node);
  }
  graph.maxModelOrderNodes = children.length;
  final edges = _list(input['edges'], 'edges');
  final edgeIds = <String>{};
  for (var i = 0; i < edges.length; i++) {
    final edge = _map(edges[i], 'edge');
    final edgeId = _id(edge['id'], 'edge');
    if (!edgeIds.add(edgeId)) throw ArgumentError('Duplicate edge ID: $edgeId');
    _rejectLabels(edge);
    final source = _endpoint(edge['sources'], nodes);
    final target = _endpoint(edge['targets'], nodes);
    if (identical(source, target)) throw UnsupportedError('Self-loops are outside Dify editor layout inputs.');
    LEdge()
      ..modelOrder = i
      ..setSource(
        LPort()
          ..setSide(PortSide.east)
          ..setNode(source),
      )
      ..setTarget(
        LPort()
          ..setSide(PortSide.west)
          ..setNode(target),
      );
  }

  if (originals.isEmpty) return _result(const {}, normalize);
  portSideProcessor(graph);
  depthFirstCycleBreaker(graph);
  networkSimplexLayerer(graph);
  longEdgeSplitter(graph);
  invertedPortProcessor(graph);
  portListSorter(graph);
  sortByInputModelProcessor(graph);
  layerSweepCrossingMinimizer(graph, CrossMinType.barycenter);
  if (graph.options.greedySwitchHierarchical) {
    layerSweepCrossingMinimizer(graph, CrossMinType.twoSidedGreedySwitch);
  }
  labelAndNodeSizeProcessor(graph);
  innermostNodeMarginCalculator(graph);
  bkNodePlacer(graph);
  layerSizeAndGraphHeightCalculator(graph);
  splineEdgeRouter(graph);
  longEdgeJoiner(graph);
  horizontalGraphCompactor(graph);
  return _result({
    for (var i = 0; i < originals.length; i++)
      ids[i]: ElkNodeLayout(
        x: originals[i].pos.x + graph.offset.x + graph.paddingLeft,
        y: originals[i].pos.y + graph.offset.y + graph.paddingTop,
        width: originals[i].size.x,
        height: originals[i].size.y,
      ),
  }, normalize);
}

ElkLayoutResult _result(Map<String, ElkNodeLayout> nodes, bool normalize) {
  if (nodes.isEmpty) {
    return ElkLayoutResult(nodes, const ElkLayoutBounds(minX: 0, minY: 0, maxX: 0, maxY: 0));
  }
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final node in nodes.values) {
    minX = math.min(minX, node.x);
    minY = math.min(minY, node.y);
    maxX = math.max(maxX, node.x + node.width);
    maxY = math.max(maxY, node.y + node.height);
  }
  if (!normalize) return ElkLayoutResult(nodes, ElkLayoutBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY));
  return ElkLayoutResult({
    for (final entry in nodes.entries)
      entry.key: ElkNodeLayout(
        x: entry.value.x - minX,
        y: entry.value.y - minY,
        width: entry.value.width,
        height: entry.value.height,
      ),
  }, ElkLayoutBounds(minX: 0, minY: 0, maxX: maxX - minX, maxY: maxY - minY));
}

Map<String, dynamic> _map(Object? value, String name) {
  if (value == null) return {};
  if (value is! Map) throw ArgumentError('$name must be a map.');
  return Map<String, dynamic>.from(value);
}

List<dynamic> _list(Object? value, String name) {
  if (value == null) return const [];
  if (value is! List) throw ArgumentError('$name must be a list.');
  return value;
}

String _id(Object? value, String kind) {
  if (value is! String || value.isEmpty) throw ArgumentError('$kind ID must be a nonempty string.');
  return value;
}

double _dimension(Object? value, double fallback) {
  final number = value == null
      ? fallback
      : value is num
      ? value.toDouble()
      : double.nan;
  if (!number.isFinite || number < 0) throw ArgumentError('Dimensions must be finite nonnegative numbers.');
  return number;
}

double _spacing(Map<String, dynamic> options, String key, double fallback) {
  final value = options[key];
  final number = value == null ? fallback : double.tryParse('$value');
  if (number == null || !number.isFinite || number < 0) throw ArgumentError('Invalid spacing option: $key');
  return number;
}

int _thoroughness(Map<String, dynamic> options) {
  final value = int.tryParse('${options['elk.layered.thoroughness'] ?? 10}');
  if (value == null || value < 1) throw ArgumentError('Thoroughness must be a positive integer.');
  return value;
}

LNode _endpoint(Object? endpoints, Map<String, LNode> nodes) {
  final ids = _list(endpoints, 'edge endpoints');
  if (ids.length != 1) throw UnsupportedError('Only simple single-source/single-target edges are supported.');
  final node = nodes[ids.single];
  if (node == null) throw ArgumentError('Edge endpoint must name an existing node: ${ids.single}');
  return node;
}

void _rejectLabels(Map<String, dynamic> element) {
  if (_list(element['labels'], 'labels').isNotEmpty) {
    throw UnsupportedError('ELK input labels are outside Dify node-placement inputs.');
  }
}

void _checkOptions(Map<String, dynamic> options) {
  const expected = {
    'elk.algorithm': 'layered',
    'elk.direction': 'RIGHT',
    'elk.layered.cycleBreaking.strategy': 'DEPTH_FIRST',
    'elk.layered.layering.strategy': 'NETWORK_SIMPLEX',
    'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
    'elk.layered.crossingMinimization.forceNodeModelOrder': 'true',
    'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
    'elk.layered.nodePlacement.strategy': 'BRANDES_KOEPF',
    'elk.layered.nodePlacement.bk.fixedAlignment': 'BALANCED',
    'elk.layered.nodePlacement.favorStraightEdges': 'true',
    'elk.edgeRouting': 'SPLINES',
    'elk.layered.edgeRouting.splines.mode': 'CONSERVATIVE',
    'elk.layered.compaction.postCompaction.strategy': 'EDGE_LENGTH',
    'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
  };
  for (final entry in expected.entries) {
    if (options.containsKey(entry.key) && '${options[entry.key]}' != entry.value) {
      throw UnsupportedError('Unsupported layout option ${entry.key}: ${options[entry.key]}');
    }
  }
}
