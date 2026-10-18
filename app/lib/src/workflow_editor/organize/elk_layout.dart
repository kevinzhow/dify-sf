/// utils/elk-layout.ts: the ELK graph Dify builds from React Flow's nodes and edges (output ports in branch order,
/// children and edges in DFS order), laid out by `package:elk_layered` (elkjs 0.11.1's layered algorithm in Dart),
/// and the layout collected and normalised as Dify does.
///
/// Nodes and edges are Dify's React Flow JSON (`{id, type, parentId, width, height, data}`, `{id, source,
/// sourceHandle, target, data}`). Layout runs synchronously; the engine is a parameter ([ElkEngine]) so tests can
/// stand in for elkjs as Dify's spec does.
library;

import 'package:elk_layered/elk_layered.dart';

import '../store/workflow_store.dart' show DifyJson;

const defaultNodeWidth = 244;
const defaultNodeHeight = 100;

/// NODE_LAYOUT_HORIZONTAL_PADDING / NODE_LAYOUT_VERTICAL_PADDING (constants.ts).
const nodeLayoutHorizontalPadding = 60.0;
const nodeLayoutVerticalPadding = 60.0;

const rootLayoutOptions = {
  'elk.algorithm': 'layered',
  'elk.direction': 'RIGHT',
  'elk.layered.spacing.nodeNodeBetweenLayers': '100',
  'elk.spacing.nodeNode': '80',
  'elk.spacing.edgeNode': '50',
  'elk.spacing.edgeEdge': '30',
  'elk.spacing.edgeLabel': '10',
  'elk.spacing.portPort': '20',
  'elk.portConstraints': 'FIXED_ORDER',
  'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
  'elk.layered.crossingMinimization.forceNodeModelOrder': 'true',
  'elk.layered.nodePlacement.strategy': 'BRANDES_KOEPF',
  'elk.layered.nodePlacement.favorStraightEdges': 'true',
  'elk.layered.nodePlacement.bk.fixedAlignment': 'BALANCED',
  'elk.edgeRouting': 'SPLINES',
  'elk.layered.edgeRouting.selfLoopPlacement': 'NORTH',
  'elk.layered.edgeRouting.sloppySplineRouting': 'false',
  'elk.layered.edgeRouting.splines.mode': 'CONSERVATIVE',
  'elk.layered.edgeRouting.splines.sloppy.layerSpacingFactor': '1.2',
  'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
  'elk.layered.crossingMinimization.greedySwitch.type': 'TWO_SIDED',
  'elk.layered.crossingMinimization.greedySwitchHierarchical.type': 'TWO_SIDED',
  'elk.layered.crossingMinimization.semiInteractive': 'false',
  'elk.layered.crossingMinimization.hierarchicalSweepiness': '0.9',
  'elk.layered.layering.strategy': 'NETWORK_SIMPLEX',
  'elk.layered.layering.networkSimplex.nodeFlexibility': 'NODE_SIZE',
  'elk.layered.layering.layerConstraint': 'NONE',
  'elk.layered.layering.minWidth.upperBoundOnWidth': '4',
  'elk.layered.cycleBreaking.strategy': 'DEPTH_FIRST',
  'elk.separateConnectedComponents': 'true',
  'elk.spacing.componentComponent': '100',
  'elk.nodeSize.constraints': 'NODE_LABELS',
  'elk.nodeSize.options': 'DEFAULT_MINIMUM_SIZE MINIMUM_SIZE_ACCOUNTS_FOR_PADDING',
  'elk.edgeLabels.placement': 'CENTER',
  'elk.edgeLabels.inline': 'true',
  'elk.layered.compaction.postCompaction.strategy': 'EDGE_LENGTH',
  'elk.layered.compaction.postCompaction.constraints': 'EDGE_LENGTH',
  'elk.layered.thoroughness': '10',
  'elk.layered.wrapping.strategy': 'OFF',
  'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
  'elk.layered.feedbackEdges': 'true',
  'elk.layered.mergeEdges': 'false',
  'elk.layered.mergeHierarchyEdges': 'false',
  'elk.layered.allowNonFlowPortsToSwitchSides': 'false',
  'elk.layered.northOrSouthPort': 'false',
  'elk.partitioning.activate': 'false',
  'elk.junctionPoints': 'true',
  'elk.contentAlignment': 'V_TOP H_LEFT',
  'elk.alignment': 'AUTOMATIC',
};

const childLayoutOptions = {
  'elk.algorithm': 'layered',
  'elk.direction': 'RIGHT',
  'elk.layered.spacing.nodeNodeBetweenLayers': '80',
  'elk.spacing.nodeNode': '60',
  'elk.spacing.edgeNode': '40',
  'elk.spacing.edgeEdge': '25',
  'elk.spacing.edgeLabel': '8',
  'elk.spacing.portPort': '15',
  'elk.portConstraints': 'FIXED_ORDER',
  'elk.layered.considerModelOrder.strategy': 'NODES_AND_EDGES',
  'elk.layered.crossingMinimization.forceNodeModelOrder': 'true',
  'elk.layered.nodePlacement.strategy': 'BRANDES_KOEPF',
  'elk.layered.nodePlacement.favorStraightEdges': 'true',
  'elk.layered.nodePlacement.bk.fixedAlignment': 'BALANCED',
  'elk.edgeRouting': 'SPLINES',
  'elk.layered.edgeRouting.sloppySplineRouting': 'false',
  'elk.layered.edgeRouting.splines.mode': 'CONSERVATIVE',
  'elk.layered.crossingMinimization.strategy': 'LAYER_SWEEP',
  'elk.layered.crossingMinimization.greedySwitch.type': 'TWO_SIDED',
  'elk.layered.crossingMinimization.semiInteractive': 'false',
  'elk.layered.layering.strategy': 'NETWORK_SIMPLEX',
  'elk.layered.layering.networkSimplex.nodeFlexibility': 'NODE_SIZE',
  'elk.layered.cycleBreaking.strategy': 'DEPTH_FIRST',
  'elk.nodeSize.constraints': 'NODE_LABELS',
  'elk.layered.compaction.postCompaction.strategy': 'EDGE_LENGTH',
  'elk.layered.thoroughness': '10',
  'elk.hierarchyHandling': 'INCLUDE_CHILDREN',
  'elk.layered.feedbackEdges': 'true',
  'elk.layered.mergeEdges': 'false',
  'elk.junctionPoints': 'true',
};

class LayoutInfo {
  const LayoutInfo({required this.x, required this.y, required this.width, required this.height, this.layer});
  final double x;
  final double y;
  final double width;
  final double height;
  final int? layer;

  LayoutInfo at({double? x, double? y}) =>
      LayoutInfo(x: x ?? this.x, y: y ?? this.y, width: width, height: height, layer: layer);
}

class LayoutBounds {
  const LayoutBounds({required this.minX, required this.minY, required this.maxX, required this.maxY});
  static const zero = LayoutBounds(minX: 0, minY: 0, maxX: 0, maxY: 0);
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  @override
  bool operator ==(Object other) =>
      other is LayoutBounds && other.minX == minX && other.minY == minY && other.maxX == maxX && other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);

  @override
  String toString() => 'LayoutBounds($minX, $minY, $maxX, $maxY)';
}

class LayoutResult {
  const LayoutResult({required this.nodes, required this.bounds});
  final Map<String, LayoutInfo> nodes;
  final LayoutBounds bounds;
}

/// elkjs's `layout`: an ELK graph JSON in, the same graph with `x`/`y` on its children out.
typedef ElkEngine = Map<String, Object?> Function(Map<String, Object?> graph);

/// The real engine: elkjs 0.11.1's coordinates (unnormalised, as elkjs returns them) from `package:elk_layered`.
Map<String, Object?> elkLayout(Map<String, Object?> graph) {
  final laid = layoutGraph(graph, normalize: false).nodes;
  return {
    ...graph,
    'children': [
      for (final child in graph['children']! as List)
        {
          ...child as Map<String, Object?>,
          if (laid[child['id']] case final n?) ...{'x': n.x, 'y': n.y, 'width': n.width, 'height': n.height},
        },
    ],
  };
}

Object? _get(Object? map, String key) => map is Map ? map[key] : null;

bool _truthy(Object? v) => v != null && v != false && v != '' && v != 0;

/// JavaScript's `Array.prototype.sort` as V8 runs it, so comparators that are not consistent (Dify's branch sorts
/// put an unknown handle level with everything) order exactly as in Chrome: TimSort's first run, then binary
/// insertion; every array shorter than 64 is sorted that way alone. Longer arrays use a stable sort, which is the
/// same for consistent comparators.
List<T> jsSort<T>(List<T> list, int Function(T a, T b) compare) {
  final a = [...list];
  final n = a.length;
  if (n < 2) return a;
  if (n >= 64) {
    final indexed = [for (var i = 0; i < n; i++) (i, a[i])]
      ..sort((x, y) {
        final c = compare(x.$2, y.$2);
        return c != 0 ? c : x.$1 - y.$1;
      });
    return [for (final e in indexed) e.$2];
  }
  // CountAndMakeRun.
  var run = 2;
  final descending = compare(a[1], a[0]) < 0;
  for (var i = 2; i < n; i++) {
    final order = compare(a[i], a[i - 1]);
    if (descending ? order >= 0 : order < 0) break;
    run++;
  }
  if (descending) {
    for (var i = 0, j = run - 1; i < j; i++, j--) {
      final t = a[i];
      a[i] = a[j];
      a[j] = t;
    }
  }
  // BinaryInsertionSort.
  for (var start = run; start < n; start++) {
    final pivot = a[start];
    var left = 0, right = start;
    while (left < right) {
      final mid = left + ((right - left) >> 1);
      if (compare(pivot, a[mid]) < 0) {
        right = mid;
      } else {
        left = mid + 1;
      }
    }
    for (var p = start; p > left; p--) {
      a[p] = a[p - 1];
    }
    a[left] = pivot;
  }
  return a;
}

LayoutResult _collectLayout(Map<String, Object?> graph) {
  final result = <String, LayoutInfo>{};
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;

  void visit(Object? node) {
    for (final child in (_get(node, 'children') as List?) ?? const []) {
      final x = (_get(child, 'x') as num? ?? 0).toDouble();
      final y = (_get(child, 'y') as num? ?? 0).toDouble();
      final width = (_get(child, 'width') as num? ?? defaultNodeWidth).toDouble();
      final height = (_get(child, 'height') as num? ?? defaultNodeHeight).toDouble();
      final layer = _get(_get(child, 'layoutOptions'), 'org.eclipse.elk.layered.layerIndex');
      result[_get(child, 'id')! as String] = LayoutInfo(
        x: x,
        y: y,
        width: width,
        height: height,
        layer: _truthy(layer) ? int.tryParse('$layer') : null,
      );
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x + width > maxX) maxX = x + width;
      if (y + height > maxY) maxY = y + height;
      if (((_get(child, 'children') as List?) ?? const []).isNotEmpty) visit(child);
    }
  }

  visit(graph);
  final finite = minX.isFinite && minY.isFinite;
  return LayoutResult(
    nodes: result,
    bounds: finite ? LayoutBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY) : LayoutBounds.zero,
  );
}

int Function(DifyJson, DifyJson) _branchOrder(List ids, String idKey, {String? last}) => (edgeA, edgeB) {
  final handleA = edgeA['sourceHandle'], handleB = edgeB['sourceHandle'];
  if (_truthy(handleA) && _truthy(handleB)) {
    if (last != null && handleA == last) return 1;
    if (last != null && handleB == last) return -1;
    final indexA = ids.indexWhere((c) => _get(c, idKey) == handleA);
    final indexB = ids.indexWhere((c) => _get(c, idKey) == handleB);
    if (indexA != -1 && indexB != -1) return indexA - indexB;
  }
  return 0;
};

/// sortIfElseOutEdges / sortQuestionClassifierOutEdges / sortHumanInputOutEdges.
List<DifyJson> _sortOutEdges(DifyJson node, List<DifyJson> outEdges) {
  final data = node['data'];
  List list(String key) => (_get(data, key) as List?) ?? const [];
  return switch (_get(data, 'type')) {
    'if-else' => jsSort(outEdges, _branchOrder(list('cases'), 'case_id', last: 'false')),
    'question-classifier' => jsSort(outEdges, _branchOrder(list('classes'), 'id')),
    'human-input' => jsSort(outEdges, _branchOrder(list('user_actions'), 'id', last: '__timeout')),
    _ => outEdges,
  };
}

LayoutResult _normaliseBounds(LayoutResult layout) {
  if (layout.nodes.isEmpty) return layout;
  final b = layout.bounds;
  return LayoutResult(
    nodes: {
      for (final MapEntry(:key, :value) in layout.nodes.entries)
        key: value.at(x: value.x - b.minX, y: value.y - b.minY),
    },
    bounds: LayoutBounds(minX: 0, minY: 0, maxX: b.maxX - b.minX, maxY: b.maxY - b.minY),
  );
}

/// buildPortAwareGraph: ELK nodes with output ports (sorted for branching types) and edges ordered by a DFS
/// traversal that follows port order. Edge ids count from `elk-edge-0` on every call, as Dify resets its counter
/// before each build.
({List<DifyJson> elkNodes, List<DifyJson> elkEdges}) buildPortAwareGraph(List<DifyJson> nodes, List<DifyJson> edges) {
  final outEdgesByNode = <Object?, List<DifyJson>>{};
  for (final edge in edges) {
    (outEdgesByNode[edge['source']] ??= []).add(edge);
  }
  final elkNodes = <DifyJson>[];
  final sourcePortMap = <Object?, String>{};
  final sortedOutEdgesByNode = <Object?, List<DifyJson>>{};

  for (final node in nodes) {
    final outEdges = _sortOutEdges(node, outEdgesByNode[node['id']] ?? const []);
    sortedOutEdgesByNode[node['id']] = outEdges;
    final ports = [
      for (var index = 0; index < outEdges.length; index++)
        () {
          final edge = outEdges[index], handle = edge['sourceHandle'];
          final portId = '${node['id']}-out-${_truthy(handle) ? handle : index}';
          sourcePortMap[edge['id']] = portId;
          return <String, Object?>{
            'id': portId,
            'layoutOptions': {'elk.port.side': 'EAST', 'elk.port.index': '$index'},
          };
        }(),
    ];
    elkNodes.add({
      'id': node['id'],
      'width': node['width'] ?? defaultNodeWidth,
      'height': node['height'] ?? defaultNodeHeight,
      if (ports.isNotEmpty) ...{
        'ports': ports,
        'layoutOptions': {'elk.portConstraints': 'FIXED_ORDER'},
      },
    });
  }

  // DFS in port order fixes the vertical order of nodes: forceNodeModelOrder makes ELK keep the children's order
  // within each layer.
  final nodeIds = {for (final n in nodes) n['id']};
  final targets = {for (final e in edges) e['target']};
  final visited = <Object?>{};
  final orderedIds = <Object?>[];
  void dfs(Object? id) {
    if (visited.contains(id) || !nodeIds.contains(id)) return;
    visited.add(id);
    orderedIds.add(id);
    for (final e in sortedOutEdgesByNode[id] ?? const <DifyJson>[]) {
      dfs(e['target']);
    }
  }

  for (final n in nodes) {
    if (!targets.contains(n['id'])) dfs(n['id']);
  }
  for (final n in nodes) {
    dfs(n['id']);
  }

  final nodeOrder = <Object?, int>{for (var i = 0; i < orderedIds.length; i++) orderedIds[i]: i};
  final sortedNodes = jsSort(elkNodes, (a, b) => (nodeOrder[a['id']] ?? 0) - (nodeOrder[b['id']] ?? 0));

  var edgeCounter = 0;
  final elkEdges = <DifyJson>[
    for (final id in orderedIds)
      for (final edge in sortedOutEdgesByNode[id] ?? const <DifyJson>[])
        {
          'id': 'elk-edge-${edgeCounter++}',
          'sources': [edge['source']],
          'targets': [edge['target']],
          'sourcePort': ?sourcePortMap[edge['id']],
        },
  ];
  return (elkNodes: sortedNodes, elkEdges: elkEdges);
}

/// The ELK graph of the top level: nodes without a parent of React Flow type `custom`, edges outside iterations
/// and loops.
Map<String, Object?> rootElkGraph(List<DifyJson> nodes, List<DifyJson> edges) {
  final g = buildPortAwareGraph(
    [
      for (final n in nodes)
        if (!_truthy(n['parentId']) && n['type'] == 'custom') n,
    ],
    [
      for (final e in edges)
        if (!_truthy(_get(e['data'], 'isInIteration')) && !_truthy(_get(e['data'], 'isInLoop'))) e,
    ],
  );
  return {'id': 'workflow-root', 'layoutOptions': rootLayoutOptions, 'children': g.elkNodes, 'edges': g.elkEdges};
}

/// The ELK graph inside container [parentNodeId], or null when it has no children.
Map<String, Object?>? childElkGraph(String parentNodeId, List<DifyJson> nodes, List<DifyJson> edges) {
  final children = [
    for (final n in nodes)
      if (n['parentId'] == parentNodeId) n,
  ];
  if (children.isEmpty) return null;
  final g = buildPortAwareGraph(children, [
    for (final e in edges)
      if ((_truthy(_get(e['data'], 'isInIteration')) && _get(e['data'], 'iteration_id') == parentNodeId) ||
          (_truthy(_get(e['data'], 'isInLoop')) && _get(e['data'], 'loop_id') == parentNodeId))
        e,
  ]);
  return {'id': parentNodeId, 'layoutOptions': childLayoutOptions, 'children': g.elkNodes, 'edges': g.elkEdges};
}

/// getLayoutByELK.
LayoutResult getLayoutByELK(List<DifyJson> nodes, List<DifyJson> edges, {ElkEngine elk = elkLayout}) =>
    _normaliseBounds(_collectLayout(elk(rootElkGraph(nodes, edges))));

LayoutResult _normaliseChildLayout(LayoutResult layout, List<DifyJson> nodes) {
  final result = Map.of(layout.nodes);
  // Iteration / loop start nodes must not collapse into the children.
  final startNode = nodes
      .where(
        (n) =>
            n['type'] == 'custom-iteration-start' ||
            n['type'] == 'custom-loop-start' ||
            _get(n['data'], 'type') == 'loop-start' ||
            _get(n['data'], 'type') == 'iteration-start',
      )
      .firstOrNull;
  final startLayout = startNode == null ? null : result[startNode['id']];
  if (startLayout != null) {
    const desiredMinX = nodeLayoutHorizontalPadding / 1.5;
    if (startLayout.x > desiredMinX) {
      final shiftX = startLayout.x - desiredMinX;
      result.updateAll((_, v) => v.at(x: v.x - shiftX));
    }
    final desiredMinY = startLayout.y;
    const deltaY = nodeLayoutVerticalPadding / 2;
    result.updateAll((_, v) => v.at(y: v.y - desiredMinY + deltaY));
  }
  var minX = double.infinity, minY = double.infinity;
  var maxX = double.negativeInfinity, maxY = double.negativeInfinity;
  for (final v in result.values) {
    if (v.x < minX) minX = v.x;
    if (v.y < minY) minY = v.y;
    if (v.x + v.width > maxX) maxX = v.x + v.width;
    if (v.y + v.height > maxY) maxY = v.y + v.height;
  }
  if (!minX.isFinite || !minY.isFinite) return layout;
  return _normaliseBounds(
    LayoutResult(
      nodes: result,
      bounds: LayoutBounds(minX: minX, minY: minY, maxX: maxX, maxY: maxY),
    ),
  );
}

/// getLayoutForChildNodes: the layout inside an iteration or loop, or null when it has no children.
LayoutResult? getLayoutForChildNodes(
  String parentNodeId,
  List<DifyJson> nodes,
  List<DifyJson> edges, {
  ElkEngine elk = elkLayout,
}) {
  final graph = childElkGraph(parentNodeId, nodes, edges);
  if (graph == null) return null;
  return _normaliseChildLayout(_collectLayout(elk(graph)), [
    for (final n in nodes)
      if (n['parentId'] == parentNodeId) n,
  ]);
}
