// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// Phase 5 of ELK Layered as far as it decides node coordinates: LayerSizeAndGraphHeightCalculator, the layer
/// spacing part of SplineEdgeRouter (spline segments and their slot ranking, no curve geometry), LongEdgeJoiner and
/// the HorizontalGraphCompactor (EDGE_LENGTH strategy with network simplex, edge aware scanline constraints).
library;

import 'dart:collection';
import 'dart:math' as math;

import 'elk_graph.dart';
import 'network_simplex.dart';

// ---------------------------------------------------------------------------------------------------------------
// LayerSizeAndGraphHeightCalculator

void layerSizeAndGraphHeightCalculator(LGraph graph) {
  var minY = double.infinity, maxY = double.negativeInfinity;
  var foundNodes = false;
  for (final layer in graph.layers) {
    final layerSize = layer.size
      ..x = 0.0
      ..y = 0.0;
    if (layer.nodes.isEmpty) continue;
    foundNodes = true;
    for (final node in layer.nodes) {
      layerSize.x = math.max(layerSize.x, node.size.x + node.margin.left + node.margin.right);
    }
    final first = layer.nodes.first, last = layer.nodes.last;
    final top = first.pos.y - first.margin.top;
    final bottom = last.pos.y + last.size.y + last.margin.bottom;
    layerSize.y = bottom - top;
    minY = math.min(minY, top);
    maxY = math.max(maxY, bottom);
  }
  if (!foundNodes) {
    minY = 0;
    maxY = 0;
  }
  graph.size.y = maxY - minY;
  graph.offset.y -= minY;
}

// ---------------------------------------------------------------------------------------------------------------
// SplineEdgeRouter

enum _Side { left, right }

class _SplineSegment {
  _SplineSegment(LEdge edge, _Side sourceSide, _Side targetSide) {
    (sourceSide == _Side.left ? leftPorts : rightPorts).add(edge.source!);
    (targetSide == _Side.left ? leftPorts : rightPorts).add(edge.target!);
    edges.add(edge);
    final sourceY = edge.source!.absoluteAnchorY, targetY = edge.target!.absoluteAnchorY;
    _setRelevantPositions(sourceY, targetY, targetY);
    isStraight = (sourceY - targetY).abs() < 0.2;
  }

  final Set<LPort> leftPorts = {};
  final Set<LPort> rightPorts = {};
  final List<_Dependency> outgoing = [];
  final List<_Dependency> incoming = [];
  int mark = 0;
  int inweight = 0;
  int outweight = 0;
  int rank = 0;
  final Set<LEdge> edges = {};
  late final bool isStraight;
  final ElkRectangle boundingBox = ElkRectangle();
  double hyperEdgeTopYPos = 0;
  double hyperEdgeBottomYPos = 0;
  bool initialSegment = false;
  bool lastSegment = false;
  LNode? sourceNode;
  LNode? targetNode;

  void _setRelevantPositions(double sourceY, double targetYMin, double targetYMax) {
    boundingBox.y = math.min(sourceY, targetYMin);
    boundingBox.height = math.max(sourceY, targetYMax) - boundingBox.y;
    if (sourceY < targetYMin) {
      final center = 0.5 * (sourceY + targetYMin);
      hyperEdgeTopYPos = _midRate * center + _outerRate * sourceY;
      hyperEdgeBottomYPos = _midRate * center + _outerRate * targetYMin;
    } else {
      final center = 0.5 * (sourceY + targetYMax);
      hyperEdgeTopYPos = _midRate * center + _outerRate * targetYMax;
      hyperEdgeBottomYPos = _midRate * center + _outerRate * sourceY;
    }
  }

  static const double _outerRate = 0.9;
  static const double _midRate = 1 - _outerRate;
}

class _Dependency {
  _Dependency(this.source, this.target, this.weight) {
    source.outgoing.add(this);
    target.incoming.add(this);
  }
  _SplineSegment source;
  _SplineSegment target;
  final int weight;
}

bool _isNormalNode(LNode n) => n.type == NodeType.normal || n.type == NodeType.breakingPoint;

bool _isBetween(double value, double b0, double b1) {
  const eps = 1e-6;
  if ((b0 - value).abs() < eps || (b1 - value).abs() < eps) return true;
  return (b0 - value) > eps ? (value - b1) > eps : (b1 - value) > eps;
}

void splineEdgeRouter(LGraph graph) {
  if (graph.layers.isEmpty) {
    graph.size.x = 0;
    return;
  }
  final nodeNodeSpacing = graph.options.nodeNodeBetweenLayers;
  final edgeNodeSpacing = graph.options.edgeNodeBetweenLayers;
  final edgeEdgeSpacing = graph.options.edgeEdgeBetweenLayers;
  final startEdges = <LEdge>[];
  final successingEdge = <LEdge, LEdge>{};
  final edgeToSegment = <LEdge, _SplineSegment>{};

  final leftPorts = <LPort>{}, rightPorts = <LPort>{};
  final edgesRemaining = <LEdge>[];
  final segments = <_SplineSegment>[];

  void findAndAddSuccessor(LEdge edge) {
    final targetNode = edge.target!.node!;
    if (_isNormalNode(targetNode)) return;
    final it = targetNode.outgoingEdges.iterator;
    if (it.moveNext()) successingEdge[edge] = it.current;
  }

  void collect(LEdge edge, Layer? leftLayer, Layer? rightLayer) {
    edgesRemaining.add(edge);
    findAndAddSuccessor(edge);
    final sourceType = edge.source!.node!.type;
    if (sourceType == NodeType.normal ||
        sourceType == NodeType.northSouthPort ||
        sourceType == NodeType.externalPort ||
        sourceType == NodeType.breakingPoint) {
      startEdges.add(edge);
    }
    final targetPort = edge.target!;
    final targetLayer = targetPort.node!.layer;
    if (targetLayer == rightLayer) {
      rightPorts.add(targetPort);
    } else if (targetLayer == leftLayer) {
      leftPorts.add(targetPort);
    } else {
      edgesRemaining.remove(edge);
    }
  }

  var xpos = 0.0;
  Layer? leftLayer;
  for (var li = 0; li <= graph.layers.length; li++) {
    final rightLayer = li < graph.layers.length ? graph.layers[li] : null;
    leftPorts.clear();
    rightPorts.clear();
    edgesRemaining.clear();
    segments.clear();
    if (leftLayer != null) {
      for (final node in leftLayer.nodes) {
        for (final sourcePort in node.portsOnSide(PortSide.east)) {
          leftPorts.add(sourcePort);
          for (final edge in sourcePort.outgoing) {
            if (edge.isSelfLoop) continue;
            collect(edge, leftLayer, rightLayer);
          }
        }
      }
    }
    if (rightLayer != null) {
      for (final node in rightLayer.nodes) {
        for (final sourcePort in node.portsOnSide(PortSide.west)) {
          rightPorts.add(sourcePort);
          for (final edge in sourcePort.outgoing) {
            if (edge.isSelfLoop) continue;
            collect(edge, leftLayer, rightLayer);
          }
        }
      }
    }
    // Hyperedge segments need a port with several edges, which never occurs; every remaining edge gets its own
    // segment.
    for (final edge in edgesRemaining) {
      final sourceSide = leftPorts.contains(edge.source)
          ? _Side.left
          : (rightPorts.contains(edge.source) ? _Side.right : throw ArgumentError('source port'));
      final targetSide = leftPorts.contains(edge.target)
          ? _Side.left
          : (rightPorts.contains(edge.target) ? _Side.right : throw ArgumentError('target port'));
      final seg = _SplineSegment(edge, sourceSide, targetSide);
      edgeToSegment[edge] = seg;
      segments.add(seg);
    }
    for (var i = 0; i < segments.length; i++) {
      for (var j = i + 1; j < segments.length; j++) {
        _createDependency(segments[i], segments[j]);
      }
    }
    _breakCycles(segments, graph.random);
    _topologicalNumbering(segments);

    var slotCount = 0;
    for (final s in segments) {
      if (!s.isStraight) slotCount = math.max(slotCount, s.rank + 1);
    }
    var rightLayerPosition = xpos;
    final isSpecialLeftLayer = leftLayer == null;
    final isSpecialRightLayer = rightLayer == null;
    if (slotCount > 0) {
      var increment = 0.0;
      if (leftLayer != null) increment += edgeNodeSpacing;
      increment += (slotCount - 1) * edgeEdgeSpacing;
      if (rightLayer != null) increment += edgeNodeSpacing;
      if (increment < nodeNodeSpacing && !isSpecialLeftLayer && !isSpecialRightLayer) {
        increment = nodeNodeSpacing;
      }
      rightLayerPosition += increment;
    } else if (!isSpecialLeftLayer && !isSpecialRightLayer) {
      rightLayerPosition += nodeNodeSpacing;
    }
    if (rightLayer != null) _placeNodesHorizontally(rightLayer, rightLayerPosition);
    for (final segment in segments) {
      segment.boundingBox.x = xpos;
      segment.boundingBox.width = rightLayerPosition - xpos;
    }
    xpos = rightLayerPosition;
    if (rightLayer != null) xpos += rightLayer.size.x;
    leftLayer = rightLayer;
  }
  for (final edge in startEdges) {
    final chain = <_SplineSegment>[];
    LEdge? current = edge;
    do {
      final segment = edgeToSegment[current]!;
      chain.add(segment);
      current = successingEdge[current];
    } while (current != null);
    chain.first
      ..initialSegment = true
      ..sourceNode = chain.first.edges.first.source!.node;
    chain.last
      ..lastSegment = true
      ..targetNode = chain.last.edges.first.target!.node;
    edge.splineRouteStart = chain;
  }
  graph.size.x = xpos;
}

void _createDependency(_SplineSegment e0, _SplineSegment e1) {
  if (e0.hyperEdgeTopYPos > e1.hyperEdgeBottomYPos || e1.hyperEdgeTopYPos > e0.hyperEdgeBottomYPos) return;
  var c0 = 0, c1 = 0;
  for (final p in e0.rightPorts) {
    if (_isBetween(p.absoluteAnchorY, e1.hyperEdgeTopYPos, e1.hyperEdgeBottomYPos)) c0++;
  }
  for (final p in e0.leftPorts) {
    if (_isBetween(p.absoluteAnchorY, e1.hyperEdgeTopYPos, e1.hyperEdgeBottomYPos)) c0--;
  }
  for (final p in e1.rightPorts) {
    if (_isBetween(p.absoluteAnchorY, e0.hyperEdgeTopYPos, e0.hyperEdgeBottomYPos)) c1++;
  }
  for (final p in e1.leftPorts) {
    if (_isBetween(p.absoluteAnchorY, e0.hyperEdgeTopYPos, e0.hyperEdgeBottomYPos)) c1--;
  }
  if (c0 < c1) {
    _Dependency(e0, e1, c1 - c0);
  } else if (c1 < c0) {
    _Dependency(e1, e0, c0 - c1);
  } else {
    _Dependency(e1, e0, 0);
    _Dependency(e0, e1, 0);
  }
}

void _breakCycles(List<_SplineSegment> edges, GwtRandom random) {
  final sources = Queue<_SplineSegment>(), sinks = Queue<_SplineSegment>();
  var nextMark = -1;
  for (final edge in edges) {
    edge.mark = nextMark--;
    var inweight = 0, outweight = 0;
    for (final d in edge.outgoing) {
      outweight += d.weight;
    }
    for (final d in edge.incoming) {
      inweight += d.weight;
    }
    edge.inweight = inweight;
    edge.outweight = outweight;
    if (outweight == 0) {
      sinks.add(edge);
    } else if (inweight == 0) {
      sources.add(edge);
    }
  }
  final unprocessed = LinkedHashSet<_SplineSegment>.of(edges);
  final markBase = edges.length;
  var nextLeft = markBase + 1, nextRight = markBase - 1;
  final maxEdges = <_SplineSegment>[];
  while (unprocessed.isNotEmpty) {
    while (sinks.isNotEmpty) {
      final sink = sinks.removeFirst();
      unprocessed.remove(sink);
      sink.mark = nextRight--;
      _updateNeighbors(sink, sources, sinks);
    }
    while (sources.isNotEmpty) {
      final source = sources.removeFirst();
      unprocessed.remove(source);
      source.mark = nextLeft++;
      _updateNeighbors(source, sources, sinks);
    }
    var maxOutflow = -2147483648;
    for (final edge in unprocessed) {
      final outflow = edge.outweight - edge.inweight;
      if (outflow >= maxOutflow) {
        if (outflow > maxOutflow) {
          maxEdges.clear();
          maxOutflow = outflow;
        }
        maxEdges.add(edge);
      }
    }
    if (maxEdges.isNotEmpty) {
      final maxEdge = maxEdges[random.nextInt(maxEdges.length)];
      unprocessed.remove(maxEdge);
      maxEdge.mark = nextLeft++;
      _updateNeighbors(maxEdge, sources, sinks);
      maxEdges.clear();
    }
  }
  final shiftBase = edges.length + 1;
  for (final edge in edges) {
    if (edge.mark < markBase) edge.mark += shiftBase;
  }
  for (final source in edges) {
    var i = 0;
    while (i < source.outgoing.length) {
      final dependency = source.outgoing[i];
      final target = dependency.target;
      if (source.mark > target.mark) {
        source.outgoing.removeAt(i);
        target.incoming.remove(dependency);
        if (dependency.weight > 0) {
          dependency.source = target;
          target.outgoing.add(dependency);
          dependency.target = source;
          source.incoming.add(dependency);
        }
      } else {
        i++;
      }
    }
  }
}

void _updateNeighbors(_SplineSegment edge, Queue<_SplineSegment> sources, Queue<_SplineSegment> sinks) {
  for (final dep in edge.outgoing) {
    if (dep.target.mark < 0 && dep.weight > 0) {
      dep.target.inweight -= dep.weight;
      if (dep.target.inweight <= 0 && dep.target.outweight > 0) sources.add(dep.target);
    }
  }
  for (final dep in edge.incoming) {
    if (dep.source.mark < 0 && dep.weight > 0) {
      dep.source.outweight -= dep.weight;
      if (dep.source.outweight <= 0 && dep.source.inweight > 0) sinks.add(dep.source);
    }
  }
}

void _topologicalNumbering(List<_SplineSegment> edges) {
  final sources = <_SplineSegment>[];
  final rightwardTargets = <_SplineSegment>[];
  for (final edge in edges) {
    edge.rank = 0;
    edge.inweight = edge.incoming.length;
    edge.outweight = edge.outgoing.length;
    if (edge.inweight == 0) sources.add(edge);
    if (edge.outweight == 0 && edge.leftPorts.isEmpty) rightwardTargets.add(edge);
  }
  var maxRank = -1;
  while (sources.isNotEmpty) {
    final edge = sources.removeAt(0);
    for (final dep in edge.outgoing) {
      final target = dep.target;
      target.rank = math.max(target.rank, edge.rank + 1);
      maxRank = math.max(maxRank, target.rank);
      target.inweight--;
      if (target.inweight == 0) sources.add(target);
    }
  }
  if (maxRank > -1) {
    for (final edge in rightwardTargets) {
      edge.rank = maxRank;
    }
    while (rightwardTargets.isNotEmpty) {
      final edge = rightwardTargets.removeAt(0);
      for (final dep in edge.incoming) {
        final source = dep.source;
        if (source.leftPorts.isNotEmpty) continue;
        source.rank = math.min(source.rank, edge.rank - 1);
        source.outweight--;
        if (source.outweight == 0) rightwardTargets.add(source);
      }
    }
  }
}

/// LGraphUtil.placeNodesHorizontally with alignment AUTOMATIC.
void _placeNodesHorizontally(Layer layer, double xoffset) {
  var maxLeftMargin = 0.0, maxRightMargin = 0.0;
  for (final node in layer.nodes) {
    maxLeftMargin = math.max(maxLeftMargin, node.margin.left);
    maxRightMargin = math.max(maxRightMargin, node.margin.right);
  }
  for (final node in layer.nodes) {
    var inports = 0, outports = 0;
    for (final port in node.ports) {
      if (port.incoming.isNotEmpty) inports++;
      if (port.outgoing.isNotEmpty) outports++;
    }
    final ratio = inports + outports == 0 ? 0.5 : outports / (inports + outports);
    final size = layer.size;
    final nodeSize = node.size.x;
    var xpos = (size.x - nodeSize) * ratio;
    if (ratio > 0.5) {
      xpos -= maxRightMargin * 2 * (ratio - 0.5);
    } else if (ratio < 0.5) {
      xpos += maxLeftMargin * 2 * (0.5 - ratio);
    }
    final leftMargin = node.margin.left;
    if (xpos < leftMargin) xpos = leftMargin;
    final rightMargin = node.margin.right;
    if (xpos > size.x - rightMargin - nodeSize) xpos = size.x - rightMargin - nodeSize;
    node.pos.x = xoffset + xpos;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// LongEdgeJoiner

void longEdgeJoiner(LGraph graph) {
  for (final layer in graph.layers) {
    layer.nodes.removeWhere((node) {
      if (node.type != NodeType.longEdge) return false;
      _joinAt(node);
      return true;
    });
  }
}

void _joinAt(LNode dummy) {
  final inputPortEdges = dummy.portsOnSide(PortSide.west).first.incoming;
  final outputPortEdges = dummy.portsOnSide(PortSide.east).first.outgoing;
  var edgeCount = inputPortEdges.length;
  while (edgeCount-- > 0) {
    final surviving = inputPortEdges[0];
    final dropped = outputPortEdges[0];
    final targetIncoming = dropped.target!.incoming;
    final index = targetIncoming.indexOf(dropped);
    surviving.setTargetAndInsertAtIndex(dropped.target!, index);
    dropped.setSource(null);
    dropped.setTarget(null);
  }
}

// ---------------------------------------------------------------------------------------------------------------
// HorizontalGraphCompactor

class _CNode {
  _CNode(this.origin, this.hitbox);
  final Object origin;
  ElkRectangle hitbox;
  late ElkRectangle hitboxPreCompaction;
  _CGroup? cGroup;
  final KVector cGroupOffset = KVector();
  List<_CNode> constraints = [];
  int id = 0;
}

class _CGroup {
  int id = 0;
  final Set<_CNode> cNodes = {};
  _CNode? reference;
  int outDegree = 0, outDegreeReal = 0;
  final Set<_CNode> incomingConstraints = {};

  void addCNode(_CNode n) {
    cNodes.add(n);
    n.cGroup = this;
    reference ??= n;
  }
}

class _VerticalSegment {
  _VerticalSegment(KVector bend1, KVector bend2, LEdge edge) {
    hitbox
      ..x = math.min(bend1.x, bend2.x)
      ..y = math.min(bend1.y, bend2.y)
      ..width = (bend1.x - bend2.x).abs()
      ..height = (bend1.y - bend2.y).abs();
    representedLEdges.add(edge);
  }

  final List<LEdge> representedLEdges = [];
  final ElkRectangle hitbox = ElkRectangle();
  final List<_VerticalSegment> constraints = [];
  final List<_VerticalSegment> joined = [];

  _VerticalSegment joinWith(_VerticalSegment other) {
    representedLEdges.addAll(other.representedLEdges);
    constraints.addAll(other.constraints);
    final newX = math.min(hitbox.x, other.hitbox.x);
    final newY = math.min(hitbox.y, other.hitbox.y);
    final maxX = math.max(hitbox.x + hitbox.width, other.hitbox.x + other.hitbox.width);
    final maxY = math.max(hitbox.y + hitbox.height, other.hitbox.y + other.hitbox.height);
    hitbox
      ..x = newX
      ..y = newY
      ..width = maxX - newX
      ..height = maxY - newY;
    joined.addAll(other.joined);
    joined.add(other);
    return this;
  }

  bool intersects(_VerticalSegment o) =>
      _fuzzyEq(hitbox.x, o.hitbox.x) &&
      !(_fuzzyLt(hitbox.y + hitbox.height, o.hitbox.y) || _fuzzyLt(o.hitbox.y + o.hitbox.height, hitbox.y));

  int compareTo(_VerticalSegment o) {
    final d = _fuzzyCompare(hitbox.x, o.hitbox.x);
    return d == 0 ? compareDouble(hitbox.y, o.hitbox.y) : d;
  }
}

const double _tolerance = 0.0001;

/// Guava DoubleMath.fuzzyEquals / fuzzyCompare.
bool _fuzzyEq(double a, double b) => (a - b).abs() <= _tolerance || a == b || (a.isNaN && b.isNaN);
int _fuzzyCompare(double a, double b) {
  if (_fuzzyEq(a, b)) return 0;
  if (a < b) return -1;
  if (a > b) return 1;
  return (a.isNaN ? 1 : 0) - (b.isNaN ? 1 : 0);
}

bool _fuzzyLt(double a, double b) => _fuzzyCompare(a, b) < 0;

void horizontalGraphCompactor(LGraph graph) {
  final cNodes = <_CNode>[];
  final cGroups = <_CGroup>[];
  final predefined = <(_CNode, _CNode)>[];
  final nodesMap = <LNode, _CNode>{};
  final vsMap = <_VerticalSegment, _CNode>{};

  // LGraphToCGraphTransformer.transform
  var index = 0;
  for (final l in graph.layers) {
    l.id = index++;
  }
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      final hitbox = ElkRectangle(
        node.pos.x - node.margin.left,
        node.pos.y - node.margin.top,
        node.size.x + node.margin.left + node.margin.right,
        node.size.y + node.margin.top + node.margin.bottom,
      );
      final cNode = _CNode(node, hitbox);
      cNodes.add(cNode);
      cGroups.add(_CGroup()..addCNode(cNode));
      nodesMap[node] = cNode;
    }
  }
  final verticalSegments = <_VerticalSegment>[];
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      for (final out in node.outgoingEdges) {
        final spline = out.splineRouteStart;
        if (spline == null) continue;
        _VerticalSegment? lastVs;
        for (final s in spline.cast<_SplineSegment>()) {
          if (s.isStraight) continue;
          final bb = s.boundingBox;
          final vs = _VerticalSegment(KVector(bb.x, bb.y), KVector(bb.x + bb.width, bb.y + bb.height), s.edges.first);
          verticalSegments.add(vs);
          lastVs?.constraints.add(vs);
          lastVs = vs;
        }
      }
    }
  }
  void toCNode(_VerticalSegment vs) {
    final cNode = _CNode(vs, ElkRectangle.from(vs.hitbox));
    cNodes.add(cNode);
    for (final other in vs.joined) {
      vsMap[other] = cNode;
    }
    vsMap[vs] = cNode;
  }

  if (verticalSegments.isNotEmpty) {
    gwtSort(verticalSegments, (a, b) => a.compareTo(b));
    var survivor = verticalSegments.first;
    for (final next in verticalSegments.skip(1)) {
      if (survivor.intersects(next)) {
        survivor = survivor.joinWith(next);
      } else {
        toCNode(survivor);
        survivor = next;
      }
    }
    toCNode(survivor);
  }
  for (final vs in vsMap.keys) {
    final vsNode = vsMap[vs]!;
    for (final other in vs.constraints) {
      predefined.add((vsNode, vsMap[other]!));
    }
  }

  // OneDimensionalCompactor
  for (final g in cGroups) {
    g.reference = null;
    for (final n in g.cNodes) {
      n.cGroupOffset
        ..x = 0
        ..y = 0;
      if (g.reference == null || n.hitbox.x < g.reference!.hitbox.x) g.reference = n;
    }
    for (final n in g.cNodes) {
      n.cGroupOffset.x = n.hitbox.x - g.reference!.hitbox.x;
      n.cGroupOffset.y = n.hitbox.y - g.reference!.hitbox.y;
    }
  }
  for (final n in cNodes) {
    if (n.cGroup == null) cGroups.add(_CGroup()..addCNode(n));
    n.hitboxPreCompaction = ElkRectangle.from(n.hitbox);
  }

  // changeDirection(LEFT) -> calculateConstraints
  for (final n in cNodes) {
    n.constraints.clear();
  }
  for (final (first, second) in predefined) {
    first.constraints.add(second);
  }
  _edgeAwareScanlineConstraints(graph, cNodes);
  for (final g in cGroups) {
    g.outDegree = 0;
    g.outDegreeReal = 0;
    g.incomingConstraints.clear();
  }
  for (final g in cGroups) {
    for (final n in g.cNodes) {
      for (final inc in n.constraints) {
        if (inc.cGroup != g) {
          g.incomingConstraints.add(inc);
          inc.cGroup!.outDegree++;
          inc.cGroup!.outDegreeReal++;
        }
      }
    }
  }

  // compact() with NetworkSimplexCompaction
  for (final g in cGroups) {
    g.outDegree = g.outDegreeReal;
  }
  _networkSimplexCompaction(graph, cNodes, cGroups);

  // LGraphToCGraphTransformer.applyLayout
  for (final cNode in cNodes) {
    final origin = cNode.origin;
    if (origin is LNode) origin.pos.x = cNode.hitbox.x + origin.margin.left;
  }
  var tlx = double.infinity, tly = double.infinity, brx = double.negativeInfinity, bry = double.negativeInfinity;
  for (final cNode in cNodes) {
    tlx = math.min(tlx, cNode.hitbox.x);
    tly = math.min(tly, cNode.hitbox.y);
    brx = math.max(brx, cNode.hitbox.x + cNode.hitbox.width);
    bry = math.max(bry, cNode.hitbox.y + cNode.hitbox.height);
  }
  graph.offset
    ..x = 0 + -tlx
    ..y = 0 + -tly;
  graph.size
    ..x = 0 + (brx - tlx)
    ..y = 0 + (bry - tly);
}

bool _isVerticalSegmentsOfSameEdge(_CNode a, _CNode b) {
  final v1 = a.origin, v2 = b.origin;
  if (v1 is! _VerticalSegment || v2 is! _VerticalSegment) return false;
  return v1.representedLEdges.any(v2.representedLEdges.contains);
}

double _horizontalSpacing(LGraph graph, _CNode a, _CNode b) {
  if (_isVerticalSegmentsOfSameEdge(a, b)) return 0;
  final n1 = a.origin is LNode ? a.origin as LNode : null;
  final n2 = b.origin is LNode ? b.origin as LNode : null;
  return graph.spacings.horizontal(n1?.type ?? NodeType.longEdge, n2?.type ?? NodeType.longEdge);
}

/// EdgeAwareScanlineConstraintCalculation.calculateForSpline.
void _edgeAwareScanlineConstraints(LGraph graph, List<_CNode> cNodes) {
  const epsilon = .5;
  _sweep(cNodes, (n) => n.origin is _VerticalSegment);
  var minSpacing = double.infinity;
  var any = false;
  for (final n in cNodes) {
    any = true;
    final double v;
    if (n.origin is _VerticalSegment) {
      v = math.max(0, graph.options.edgeEdge / 2 - epsilon);
    } else {
      v = math.max(0, graph.options.nodeNode / 2 - epsilon);
    }
    minSpacing = math.min(minSpacing, v);
  }
  if (!any) minSpacing = 0.0;
  void alter(_CNode n, double fac) {
    final delta = minSpacing * fac;
    n.hitbox.y -= delta;
    n.hitbox.height += 2 * delta;
  }

  final lNodes = [
    for (final n in cNodes)
      if (n.origin is LNode) n,
  ];
  for (final n in lNodes) {
    alter(n, 1);
  }
  _sweep(cNodes, (n) => true);
  for (final n in lNodes) {
    alter(n, -1);
  }
}

class _Timestamp {
  _Timestamp(this.node, this.low);
  final _CNode node;
  final bool low;
}

/// ScanlineConstraintCalculator.sweep.
void _sweep(List<_CNode> cNodes, bool Function(_CNode) filter) {
  final points = <_Timestamp>[];
  for (final n in cNodes) {
    if (filter(n)) {
      points.add(_Timestamp(n, true));
      points.add(_Timestamp(n, false));
    }
  }
  final intervals = SplayTreeMap<_CNode, bool>(
    (c1, c2) => compareDouble(c1.hitbox.x + (c1.hitbox.width / 2), c2.hitbox.x + (c2.hitbox.width / 2)),
  );
  final cand = List<_CNode?>.filled(cNodes.length, null);
  for (var i = 0; i < cNodes.length; i++) {
    cNodes[i].id = i;
  }
  gwtSort(points, (p1, p2) {
    var y1 = p1.node.hitbox.y;
    if (!p1.low) y1 += p1.node.hitbox.height;
    var y2 = p2.node.hitbox.y;
    if (!p2.low) y2 += p2.node.hitbox.height;
    final cmp = compareDouble(y1, y2);
    if (cmp == 0) {
      if (!p1.low && p2.low) return -1;
      if (!p2.low && p1.low) return 1;
    }
    return cmp;
  });
  for (final p in points) {
    if (p.low) {
      if (intervals.containsKey(p.node)) throw StateError('Invalid hitboxes for scanline constraint calculation.');
      intervals[p.node] = true;
      cand[p.node.id] = intervals.lastKeyBefore(p.node);
      final right = intervals.firstKeyAfter(p.node);
      if (right != null) cand[right.id] = p.node;
    } else {
      final left = intervals.lastKeyBefore(p.node);
      if (left != null && left == cand[p.node.id] && left.cGroup != null && left.cGroup != p.node.cGroup) {
        left.constraints.add(p.node);
      }
      final right = intervals.firstKeyAfter(p.node);
      if (right != null && cand[right.id] == p.node && right.cGroup != null && right.cGroup != p.node.cGroup) {
        p.node.constraints.add(right);
      }
      intervals.remove(p.node);
    }
  }
}

void _networkSimplexCompaction(LGraph graph, List<_CNode> cNodes, List<_CGroup> cGroups) {
  final nGraph = NGraph();
  final nNodes = <NNode>[];
  var index = 0;
  for (final g in cGroups) {
    g.id = index;
    nNodes.add(
      NNode(nGraph)
        ..id = index
        ..origin = g,
    );
    index++;
  }
  // addSeparationConstraints
  for (final cNode in cNodes) {
    for (final incNode in cNode.constraints) {
      if (cNode.cGroup == incNode.cGroup) continue;
      final spacing = _horizontalSpacing(graph, cNode, incNode);
      var delta = cNode.cGroupOffset.x + cNode.hitbox.width + spacing - incNode.cGroupOffset.x;
      delta = delta.ceilToDouble();
      delta = math.max(0, delta);
      if (!_isVerticalSegmentsOfSameEdge(cNode, incNode)) {
        var weight = 1.0;
        if ((cNode.origin is _VerticalSegment && incNode.origin is LNode) ||
            (incNode.origin is _VerticalSegment && cNode.origin is LNode)) {
          weight = 2;
        }
        NEdge.create(nNodes[cNode.cGroup!.id], nNodes[incNode.cGroup!.id], weight: weight, delta: delta.toInt());
      } else {
        final helper = NNode(nGraph);
        final offsetDelta = (incNode.cGroupOffset.x - cNode.cGroupOffset.x).ceil();
        NEdge.create(helper, nNodes[cNode.cGroup!.id], weight: 1, delta: math.max(0, offsetDelta));
        NEdge.create(helper, nNodes[incNode.cGroup!.id], weight: 1, delta: math.max(0, -offsetDelta));
      }
    }
  }
  // addEdgeConstraints
  final lNodeMap = <LNode, _CNode>{};
  final lEdgeMap = <LEdge, Set<_CNode>>{};
  for (final cNode in cNodes) {
    final origin = cNode.origin;
    if (origin is LNode) {
      lNodeMap[origin] = cNode;
    } else if (origin is _VerticalSegment) {
      for (final e in origin.representedLEdges) {
        lEdgeMap.putIfAbsent(e, () => <_CNode>{}).add(cNode);
      }
    }
  }
  for (final cNode in cNodes) {
    final lNode = cNode.origin;
    if (lNode is! LNode) continue;
    for (final lEdge in lNode.outgoingEdges) {
      if (lEdge.isSelfLoop) continue;
      final srcPort = lEdge.source!, tgtPort = lEdge.target!;
      final target = lNodeMap[tgtPort.node]!;
      NEdge.create(nNodes[cNode.cGroup!.id], nNodes[target.cGroup!.id], weight: 100, delta: 0);
      if (srcPort.side == PortSide.west && srcPort.outgoing.isNotEmpty) {
        for (final n in lEdgeMap[lEdge] ?? const <_CNode>{}) {
          if (n.hitbox.x < cNode.hitbox.x) {
            final src = nNodes[n.cGroup!.id], tgt = nNodes[cNode.cGroup!.id];
            if (src == tgt) continue;
            NEdge.create(src, tgt, weight: 100, delta: 1);
          }
        }
      }
      if (tgtPort.side == PortSide.east && tgtPort.incoming.isNotEmpty) {
        for (final n in lEdgeMap[lEdge] ?? const <_CNode>{}) {
          if (n.hitbox.x > cNode.hitbox.x) {
            final src = nNodes[cNode.cGroup!.id], tgt = nNodes[n.cGroup!.id];
            if (src == tgt) continue;
            NEdge.create(src, tgt, weight: 100, delta: 1);
          }
        }
      }
    }
  }
  // addArtificialSourceNode
  final sources = [
    for (final n in nGraph.nodes)
      if (n.incoming.isEmpty) n,
  ];
  if (sources.length > 1) {
    final dummySource = NNode(nGraph)..id = index++;
    for (final src in sources) {
      NEdge.create(dummySource, src, weight: 0, delta: 1);
    }
  }
  NetworkSimplex(nGraph).execute();
  for (final cNode in cNodes) {
    cNode.hitbox.x = nNodes[cNode.cGroup!.id].layer + cNode.cGroupOffset.x;
  }
}
