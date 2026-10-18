// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// Phases 1 and 2 of ELK Layered and the intermediate processors that run before crossing minimization, for the
/// option set of elk-layout.ts: PortSideProcessor, DepthFirstCycleBreaker, NetworkSimplexLayerer, LongEdgeSplitter,
/// InvertedPortProcessor, PortListSorter and SortByInputModelProcessor (with its model order comparators).
library;

import 'dart:math' as math;

import 'elk_graph.dart';
import 'network_simplex.dart';

// ---------------------------------------------------------------------------------------------------------------
// PortSideProcessor

void portSideProcessor(LGraph graph) {
  for (final node in graph.layerlessNodes) {
    if (node.portConstraints.isSideFixed) {
      for (final port in node.ports) {
        if (port.side == PortSide.undefined) _setPortSide(port);
      }
    } else {
      for (final port in node.ports) {
        _setPortSide(port);
      }
      node.portConstraints = PortConstraints.fixedSide;
    }
  }
}

void _setPortSide(LPort port) => port.setSide(port.netFlow < 0 ? PortSide.east : PortSide.west);

// ---------------------------------------------------------------------------------------------------------------
// DepthFirstCycleBreaker

void depthFirstCycleBreaker(LGraph graph) {
  final nodes = graph.layerlessNodes;
  final visited = List.filled(nodes.length, false);
  final active = List.filled(nodes.length, false);
  final sources = <LNode>[];
  final toReverse = <LEdge>[];
  for (var i = 0; i < nodes.length; i++) {
    nodes[i].id = i;
    if (nodes[i].incomingEdges.isEmpty) sources.add(nodes[i]);
  }
  void dfs(LNode n) {
    if (visited[n.id]) return;
    visited[n.id] = true;
    active[n.id] = true;
    for (final out in n.outgoingEdges) {
      if (out.isSelfLoop) continue;
      final target = out.target!.node!;
      if (active[target.id]) {
        toReverse.add(out);
      } else {
        dfs(target);
      }
    }
    active[n.id] = false;
  }

  sources.forEach(dfs);
  for (var i = 0; i < nodes.length; i++) {
    if (!visited[i]) dfs(nodes[i]);
  }
  for (final edge in toReverse) {
    edge.reverse();
    graph.cyclic = true;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// NetworkSimplexLayerer

void networkSimplexLayerer(LGraph graph) {
  final thoroughness = graph.options.thoroughness * 4;
  final theNodes = graph.layerlessNodes;
  if (theNodes.isEmpty) return;
  final components = _connectedComponents(theNodes);
  List<int>? previousLayeringNodeCounts;
  for (final comp in components) {
    final iterLimit = thoroughness * _sqrtInt(comp.length);
    final nGraph = NGraph();
    final nodeMap = <LNode, NNode>{};
    for (final lNode in comp) {
      nodeMap[lNode] = NNode(nGraph)..origin = lNode;
    }
    for (final lNode in comp) {
      for (final lEdge in lNode.outgoingEdges) {
        if (lEdge.isSelfLoop) continue;
        NEdge.create(nodeMap[lEdge.source!.node!]!, nodeMap[lEdge.target!.node!]!, weight: 1, delta: 1);
      }
    }
    NetworkSimplex(
      nGraph,
      iterationLimit: iterLimit,
      previousLayering: previousLayeringNodeCounts,
      balance: true,
    ).execute();
    final layers = graph.layers;
    for (final nNode in nGraph.nodes) {
      while (layers.length <= nNode.layer) {
        layers.add(Layer(graph));
      }
      (nNode.origin as LNode).setLayer(layers[nNode.layer]);
    }
    if (components.length > 1) {
      previousLayeringNodeCounts = [for (final l in graph.layers) l.nodes.length];
    }
  }
  theNodes.clear();
}

int _sqrtInt(int n) => math.sqrt(n).truncate();

List<List<LNode>> _connectedComponents(List<LNode> nodes) {
  final visited = List.filled(nodes.length, false);
  for (var i = 0; i < nodes.length; i++) {
    nodes[i].id = i;
  }
  final components = <List<LNode>>[];
  for (final node in nodes) {
    if (visited[node.id]) continue;
    final comp = <LNode>[];
    void dfs(LNode n) {
      visited[n.id] = true;
      comp.add(n);
      for (final port in n.ports) {
        for (final edge in port.connectedEdges) {
          final opposite = (edge.source == port ? edge.target! : edge.source!).node!;
          if (!visited[opposite.id]) dfs(opposite);
        }
      }
    }

    dfs(node);
    if (components.isEmpty || components.first.length < comp.length) {
      components.insert(0, comp);
    } else {
      components.add(comp);
    }
  }
  return components;
}

// ---------------------------------------------------------------------------------------------------------------
// LongEdgeSplitter

void longEdgeSplitter(LGraph graph) {
  final layers = graph.layers;
  if (layers.length <= 2) return;
  for (var li = 0; li < layers.length - 1; li++) {
    final layer = layers[li], nextLayer = layers[li + 1];
    for (final node in layer.nodes) {
      for (final port in node.ports) {
        for (final edge in port.outgoing) {
          final targetLayer = edge.target!.node!.layer;
          if (targetLayer != layer && targetLayer != nextLayer) {
            final dummy = LNode(graph)
              ..type = NodeType.longEdge
              ..originEdge = edge
              ..portConstraints = PortConstraints.fixedPos;
            dummy.setLayer(nextLayer);
            splitEdge(edge, dummy);
          }
        }
      }
    }
  }
}

/// LongEdgeSplitter.splitEdge (edge thickness is the default 1).
LEdge splitEdge(LEdge edge, LNode dummy) {
  final oldTarget = edge.target!;
  const thickness = 1.0;
  dummy.size.y = thickness;
  final portPos = (thickness / 2).floorToDouble();
  final input = LPort()
    ..setSide(PortSide.west)
    ..setNode(dummy);
  input.pos.y = portPos;
  final output = LPort()
    ..setSide(PortSide.east)
    ..setNode(dummy);
  output.pos.y = portPos;
  edge.setTarget(input);
  final dummyEdge = edge.copyProps();
  dummyEdge.setSource(output);
  dummyEdge.setTarget(oldTarget);
  final inSource = edge.source!.node!;
  if (inSource.type == NodeType.longEdge) {
    dummy.longEdgeSource = inSource.longEdgeSource;
    dummy.longEdgeTarget = inSource.longEdgeTarget;
  } else {
    dummy.longEdgeSource = edge.source;
    dummy.longEdgeTarget = dummyEdge.target;
  }
  return dummyEdge;
}

// ---------------------------------------------------------------------------------------------------------------
// InvertedPortProcessor

void invertedPortProcessor(LGraph graph) {
  Layer? currentLayer;
  final unassigned = <LNode>[];
  for (final layer in graph.layers) {
    final previousLayer = currentLayer;
    currentLayer = layer;
    for (final node in unassigned) {
      node.setLayer(previousLayer);
    }
    unassigned.clear();
    for (final node in layer.nodes) {
      if (node.type != NodeType.normal || !node.portConstraints.isSideFixed) continue;
      for (final port in node.ports.where((p) => p.incoming.isNotEmpty && p.side == PortSide.east).toList()) {
        for (final edge in List.of(port.incoming)) {
          _createEastPortSideDummies(graph, port, edge, unassigned);
        }
      }
      for (final port in node.ports.where((p) => p.outgoing.isNotEmpty && p.side == PortSide.west).toList()) {
        for (final edge in List.of(port.outgoing)) {
          _createWestPortSideDummies(graph, port, edge, unassigned);
        }
      }
    }
  }
  for (final node in unassigned) {
    node.setLayer(currentLayer);
  }
}

LNode _invertedDummy(LGraph graph, LEdge edge, List<LNode> list) {
  final dummy = LNode(graph)
    ..type = NodeType.longEdge
    ..originEdge = edge
    ..portConstraints = PortConstraints.fixedPos;
  list.add(dummy);
  return dummy;
}

void _createEastPortSideDummies(LGraph graph, LPort eastwardPort, LEdge edge, List<LNode> list) {
  if (edge.source!.node == eastwardPort.node) return;
  final dummy = _invertedDummy(graph, edge, list);
  final input = LPort()..setNode(dummy);
  input.setSide(PortSide.west);
  final output = LPort()..setNode(dummy);
  output.setSide(PortSide.east);
  edge.setTarget(input);
  final dummyEdge = edge.copyProps();
  dummyEdge.setSource(output);
  dummyEdge.setTarget(eastwardPort);
  _setLongEdgeSourceAndTarget(dummy, input, output);
}

void _createWestPortSideDummies(LGraph graph, LPort westwardPort, LEdge edge, List<LNode> list) {
  if (edge.target!.node == westwardPort.node) return;
  final dummy = _invertedDummy(graph, edge, list);
  final input = LPort()..setNode(dummy);
  input.setSide(PortSide.west);
  final output = LPort()..setNode(dummy);
  output.setSide(PortSide.east);
  final originalTarget = edge.target!;
  edge.setTarget(input);
  final dummyEdge = edge.copyProps();
  dummyEdge.setSource(output);
  dummyEdge.setTarget(originalTarget);
  _setLongEdgeSourceAndTarget(dummy, input, output);
}

void _setLongEdgeSourceAndTarget(LNode dummy, LPort input, LPort output) {
  final sourcePort = input.incoming[0].source!;
  final targetPort = output.outgoing[0].target!;
  dummy.longEdgeSource = sourcePort.node!.type == NodeType.longEdge ? sourcePort.node!.longEdgeSource : sourcePort;
  dummy.longEdgeTarget = targetPort.node!.type == NodeType.longEdge ? targetPort.node!.longEdgeTarget : targetPort;
}

// ---------------------------------------------------------------------------------------------------------------
// PortListSorter (port sorting strategy INPUT_ORDER)

void portListSorter(LGraph graph) {
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      final ports = node.ports;
      if (node.portConstraints.isOrderFixed) {
        gwtSort(ports, cmpCombined);
      } else if (node.portConstraints.isSideFixed) {
        gwtSort(ports, _cmpPortSide);
        _reverseWestAndSouthSide(ports);
      }
      node.cachePortSides();
    }
  }
}

int _cmpPortSide(LPort p1, LPort p2) => p1.side.index - p2.side.index;

int _cmpFixedOrderAndFixedPos(LPort p1, LPort p2) {
  final constraints = p1.node!.portConstraints;
  if (p1.side.index - p2.side.index != 0 || !constraints.isOrderFixed) return 0;
  if (constraints == PortConstraints.fixedOrder) {
    final i1 = p1.portIndex, i2 = p2.portIndex;
    if (i1 != null && i2 != null && i1 - i2 != 0) return i1 - i2;
  }
  return switch (p1.side) {
    PortSide.north => compareDouble(p1.pos.x, p2.pos.x),
    PortSide.east => compareDouble(p1.pos.y, p2.pos.y),
    PortSide.south => compareDouble(p2.pos.x, p1.pos.x),
    PortSide.west => compareDouble(p2.pos.y, p1.pos.y),
    PortSide.undefined => throw StateError('Port side is undefined'),
  };
}

/// PortListSorter.CMP_COMBINED.
int cmpCombined(LPort p1, LPort p2) {
  final c = _cmpPortSide(p1, p2);
  return c != 0 ? c : _cmpFixedOrderAndFixedPos(p1, p2);
}

void _reverseWestAndSouthSide(List<LPort> ports) {
  if (ports.length <= 1) return;
  final south = _findPortSideRange(ports, PortSide.south);
  _reverse(ports, south.$1, south.$2);
  final west = _findPortSideRange(ports, PortSide.west);
  _reverse(ports, west.$1, west.$2);
}

// Ported with its quirk: the second loop re-reads ports[lowIdx].
(int, int) _findPortSideRange(List<LPort> ports, PortSide side) {
  if (ports.isEmpty) return (0, 0);
  var currentSide = ports[0].side;
  var lowIdx = 0;
  final lb = side.index, hb = side.index + 1;
  while (lowIdx < ports.length - 1 && currentSide.index < lb) {
    lowIdx++;
    currentSide = ports[lowIdx].side;
  }
  var highIdx = lowIdx;
  while (highIdx < ports.length - 1 && currentSide.index < hb) {
    highIdx++;
    currentSide = ports[lowIdx].side;
  }
  return (lowIdx, highIdx);
}

void _reverse(List<LPort> ports, int lowIdx, int highIdx) {
  if (highIdx <= lowIdx + 2) return;
  final n = (highIdx - lowIdx) ~/ 2;
  for (var i = 0; i < n; ++i) {
    final tmp = ports[lowIdx + i];
    ports[lowIdx + i] = ports[highIdx - i - 1];
    ports[highIdx - i - 1] = tmp;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// SortByInputModelProcessor (strategy NODES_AND_EDGES, long edge strategy DUMMY_NODE_OVER, port model order off)

void sortByInputModelProcessor(LGraph graph) {
  var layerIndex = 0;
  for (final layer in graph.layers) {
    layer.id = layerIndex;
    final previousLayer = graph.layers[layerIndex == 0 ? 0 : layerIndex - 1];
    var comparator = ModelOrderNodeComparator(graph, List.of(previousLayer.nodes), beforePorts: true);
    modelOrderInsertionSort(layer.nodes, comparator.compare);
    comparator.clearTransitiveOrdering();
    for (final node in layer.nodes) {
      if (node.portConstraints != PortConstraints.fixedOrder && node.portConstraints != PortConstraints.fixedPos) {
        final c = ModelOrderPortComparator(graph, List.of(previousLayer.nodes), longEdgeTargetNodePreprocessing(node));
        gwtSort(node.ports, c.compare);
      }
    }
    comparator = ModelOrderNodeComparator(graph, List.of(previousLayer.nodes), beforePorts: false);
    modelOrderInsertionSort(layer.nodes, comparator.compare);
    comparator.clearTransitiveOrdering();
    layerIndex++;
  }
}

void modelOrderInsertionSort<T>(List<T> list, int Function(T, T) compare) {
  for (var i = 1; i < list.length; i++) {
    final temp = list[i];
    var j = i;
    while (j > 0 && compare(list[j - 1], temp) > 0) {
      list[j] = list[j - 1];
      j--;
    }
    list[j] = temp;
  }
}

Map<LNode, int> longEdgeTargetNodePreprocessing(LNode node) {
  final cached = node.targetNodeModelOrder;
  if (cached != null) return cached;
  final targetNodeModelOrder = <LNode, int>{};
  for (final p in node.ports.where((p) => p.outgoing.isNotEmpty)) {
    final targetNode = _getTargetNode(p);
    p.longEdgeTargetNode = targetNode;
    if (targetNode != null) {
      final previousOrder = targetNodeModelOrder[targetNode] ?? 2147483647;
      final edge = p.outgoing[0];
      if (!edge.reversed) {
        final mo = edge.modelOrder!;
        targetNodeModelOrder[targetNode] = mo < previousOrder ? mo : previousOrder;
      }
    }
  }
  node.targetNodeModelOrder = targetNodeModelOrder;
  return targetNodeModelOrder;
}

LNode? _getTargetNode(LPort port) {
  LNode? node;
  var edge = port.outgoing[0];
  do {
    node = edge.target!.node!;
    if (node.longEdgeTarget != null) return node.longEdgeTarget!.node;
    if (node.type != NodeType.normal && node.outgoingEdges.isNotEmpty) {
      edge = node.outgoingEdges.first;
    } else if (node.type != NodeType.normal) {
      return null;
    }
  } while (node.type != NodeType.normal);
  return node;
}

/// Transitive bookkeeping shared by the model order comparators (biggerThan / smallerThan maps).
class _Transitive<T> {
  Map<T, Set<T>> biggerThan = {};
  Map<T, Set<T>> smallerThan = {};

  /// The four early checks every comparator starts with; null when undecided. Ported with the quirk in the fourth
  /// check (it consults biggerThan of n2).
  int? check(T n1, T n2) {
    if (!biggerThan.containsKey(n1)) {
      biggerThan[n1] = {};
    } else if (biggerThan[n1]!.contains(n2)) {
      return 1;
    }
    if (!biggerThan.containsKey(n2)) {
      biggerThan[n2] = {};
    } else if (biggerThan[n2]!.contains(n1)) {
      return -1;
    }
    if (!smallerThan.containsKey(n1)) {
      smallerThan[n1] = {};
    } else if (smallerThan[n1]!.contains(n2)) {
      return -1;
    }
    if (!smallerThan.containsKey(n2)) {
      smallerThan[n2] = {};
    } else if (biggerThan[n2]!.contains(n1)) {
      return 1;
    }
    return null;
  }

  void update(T bigger, T smaller) {
    final biggerBiggerThan = biggerThan[bigger]!;
    final smallerBiggerThan = biggerThan[smaller]!;
    final biggerSmallerThan = smallerThan[bigger]!;
    final smallerSmallerThan = smallerThan[smaller]!;
    biggerBiggerThan.add(smaller);
    smallerSmallerThan.add(bigger);
    for (final verySmall in List.of(smallerBiggerThan)) {
      biggerBiggerThan.add(verySmall);
      smallerThan[verySmall]!.add(bigger);
      smallerThan[verySmall]!.addAll(List.of(biggerSmallerThan));
    }
    for (final veryBig in List.of(biggerSmallerThan)) {
      smallerSmallerThan.add(veryBig);
      biggerThan[veryBig]!.add(smaller);
      biggerThan[veryBig]!.addAll(List.of(smallerBiggerThan));
    }
  }

  void clear() {
    biggerThan = {};
    smallerThan = {};
  }
}

class ModelOrderNodeComparator {
  ModelOrderNodeComparator(
    this.graph,
    this.previousLayer, {
    required this.beforePorts,
    this.longEdgeOrderValue = 2147483647,
  });

  final LGraph graph;
  final List<LNode> previousLayer;
  final bool beforePorts;

  /// LongEdgeOrderingStrategy.returnValue (DUMMY_NODE_OVER: Integer.MAX_VALUE, EQUAL: 0).
  final int longEdgeOrderValue;
  final _Transitive<LNode> _t = _Transitive();

  void clearTransitiveOrdering() => _t.clear();

  int compare(LNode n1, LNode n2) {
    final early = _t.check(n1, n2);
    if (early != null) return early;
    if (n1.modelOrder == null || n2.modelOrder == null) {
      final p1SourcePort = _sourcePortFromPreviousLayer(n1);
      final p2SourcePort = _sourcePortFromPreviousLayer(n2);
      if (p1SourcePort != null && p2SourcePort != null) {
        final p1Node = p1SourcePort.node!, p2Node = p2SourcePort.node!;
        if (p1Node == p2Node) {
          for (final port in p1Node.ports) {
            if (port == p1SourcePort) {
              _t.update(n2, n1);
              return -1;
            } else if (port == p2SourcePort) {
              _t.update(n1, n2);
              return 1;
            }
          }
          final n1EdgeOrder = _modelOrderFromConnectedEdges(n1), n2EdgeOrder = _modelOrderFromConnectedEdges(n2);
          if (n1EdgeOrder > n2EdgeOrder) {
            _t.update(n1, n2);
            return 1;
          }
          _t.update(n2, n1);
          return -1;
        }
        for (final previousNode in previousLayer) {
          if (previousNode == p1Node) {
            _t.update(n2, n1);
            return -1;
          } else if (previousNode == p2Node) {
            _t.update(n1, n2);
            return 1;
          }
        }
      }
      if ((p1SourcePort != null) != (p2SourcePort != null)) {
        final c = _handleHelperDummyNodes(n1, n2);
        if (c != 0) {
          c > 0 ? _t.update(n1, n2) : _t.update(n2, n1);
          return c;
        }
        if (n1.modelOrder == null || n2.modelOrder == null) {
          final o1 = _modelOrderFromConnectedEdges(n1), o2 = _modelOrderFromConnectedEdges(n2);
          if (o1 > o2) {
            _t.update(n1, n2);
            return 1;
          }
          _t.update(n2, n1);
          return -1;
        }
      }
      if (p1SourcePort == null && p2SourcePort == null) {
        final c = _handleHelperDummyNodes(n1, n2);
        if (c != 0) {
          c > 0 ? _t.update(n1, n2) : _t.update(n2, n1);
          return c;
        }
      }
    }
    if (n1.modelOrder != null && n2.modelOrder != null) {
      if (n1.modelOrder! > n2.modelOrder!) {
        _t.update(n1, n2);
        return 1;
      }
      _t.update(n2, n1);
      return -1;
    }
    _t.update(n2, n1);
    return -1;
  }

  LPort? _sourcePortFromPreviousLayer(LNode n) {
    for (final p in n.ports) {
      if (p.incoming.isNotEmpty && p.incoming[0].source!.node!.layer!.id == n.layer!.id - 1) {
        return p.incoming[0].source;
      }
    }
    return null;
  }

  int _modelOrderFromConnectedEdges(LNode n) {
    for (final p in n.ports) {
      if (p.incoming.isNotEmpty) return p.incoming[0].modelOrder!;
    }
    return longEdgeOrderValue;
  }

  static LPort _firstIncomingSourcePort(LNode n) =>
      n.ports.firstWhere((p) => p.incoming.isNotEmpty).incoming[0].source!;
  static LPort _firstOutgoingTargetPort(LNode n) =>
      n.ports.firstWhere((p) => p.outgoing.isNotEmpty).outgoing[0].target!;

  int _handleHelperDummyNodes(LNode n1, LNode n2) {
    if (n1.type == NodeType.longEdge && n2.type == NodeType.normal) {
      final sourceNode = _firstIncomingSourcePort(n1).node!;
      final targetNode = _firstOutgoingTargetPort(n1).node!;
      final dummyLayerId = n1.layer!.id;
      if (sourceNode.layer!.id != dummyLayerId && targetNode.layer!.id != dummyLayerId) return 0;
      if (sourceNode == n2 || targetNode == n2) {
        _t.update(n1, n2);
        return 1;
      }
      return compare(sourceNode, n2);
    } else if (n1.type == NodeType.normal && n2.type == NodeType.longEdge) {
      final sourceNode = _firstIncomingSourcePort(n2).node!;
      final targetNode = _firstOutgoingTargetPort(n2).node!;
      final dummyLayerId = n1.layer!.id;
      if (sourceNode.layer!.id != dummyLayerId && targetNode.layer!.id != dummyLayerId) return 0;
      if (sourceNode == n1 || targetNode == n1) {
        _t.update(n2, n1);
        return -1;
      }
      return compare(n1, sourceNode);
    } else if (n1.type == NodeType.longEdge && n2.type == NodeType.longEdge) {
      final n1SourcePort = _firstIncomingSourcePort(n1), n1TargetPort = _firstOutgoingTargetPort(n1);
      final n1Source = n1SourcePort.node!, n1Target = n1TargetPort.node!;
      final n1LayerId = n1.layer!.id;
      var n1SourceFeedback = false, n1TargetFeedback = false;
      final n2SourcePort = _firstIncomingSourcePort(n2), n2TargetPort = _firstOutgoingTargetPort(n2);
      final n2Source = n2SourcePort.node!, n2Target = n2TargetPort.node!;
      final n2LayerId = n2.layer!.id;
      var n2SourceFeedback = false, n2TargetFeedback = false;
      var n1Ref = n1, n2Ref = n2;
      if (n1Source.layer!.id == n1LayerId) {
        n1SourceFeedback = true;
        n1Ref = n1Source;
      } else if (n1Target.layer!.id == n1LayerId) {
        n1TargetFeedback = true;
        n1Ref = n1Target;
      }
      if (n2Source.layer!.id == n2LayerId) {
        n2SourceFeedback = true;
        n2Ref = n2Source;
      } else if (n2Target.layer!.id == n2LayerId) {
        n2TargetFeedback = true;
        n2Ref = n2Target;
      }
      if (n1Ref == n2Ref) {
        if (beforePorts) {
          if (n1SourceFeedback && n2SourceFeedback) {
            final r = ModelOrderPortComparator(
              graph,
              previousLayer,
              null,
              portModelOrder: n2TargetFeedback,
            ).compare(n1SourcePort, n2SourcePort);
            if (r > 0) {
              _t.update(n2, n1);
              return 1;
            }
            _t.update(n1, n2);
            return -1;
          } else if (n1SourceFeedback && n2TargetFeedback) {
            _t.update(n2, n1);
            return 1;
          } else if (n1TargetFeedback && n2SourceFeedback) {
            _t.update(n1, n2);
            return -1;
          } else if (n1TargetFeedback && n2TargetFeedback) {
            return 0;
          }
        } else {
          for (final port in n1Ref.ports) {
            if (n1SourcePort == port) {
              _t.update(n2, n1);
              return -1;
            } else if (n2SourcePort == port) {
              _t.update(n1, n2);
              return 1;
            }
          }
        }
      }
      return compare(n1Ref, n2Ref);
    }
    return 0;
  }
}

/// ModelOrderPortComparator (strategy NODES_AND_EDGES).
class ModelOrderPortComparator {
  ModelOrderPortComparator(this.graph, this.previousLayer, this.targetNodeModelOrder, {this.portModelOrder = false});

  final LGraph graph;
  final List<LNode> previousLayer;
  final Map<LNode, int>? targetNodeModelOrder;
  final bool portModelOrder;
  final _Transitive<LPort> _t = _Transitive();

  void _update(LPort biggerOri, LPort smallerOri, int reverseOrder) =>
      reverseOrder < 0 ? _t.update(smallerOri, biggerOri) : _t.update(biggerOri, smallerOri);

  int compare(LPort p1, LPort p2) {
    final early = _t.check(p1, p2);
    if (early != null) return early;
    if (p1.side != p2.side) {
      final result = p1.side.index.compareTo(p2.side.index);
      result > 0 ? _update(p1, p2, 1) : _update(p2, p1, 1);
      return result;
    }
    var reverseOrder = 1;
    if (p1.incoming.isNotEmpty && p2.incoming.isNotEmpty) {
      if (p1.side == PortSide.west && p2.side == PortSide.west ||
          p1.side == PortSide.north && p2.side == PortSide.north ||
          p1.side == PortSide.south && p2.side == PortSide.south) {
        reverseOrder = -reverseOrder;
      }
      final p1SourcePort = p1.incoming[0].source!, p2SourcePort = p2.incoming[0].source!;
      final p1Node = p1SourcePort.node!, p2Node = p2SourcePort.node!;
      if (p1Node == p2Node) {
        for (final port in p1Node.ports) {
          if (p1SourcePort == port) {
            _update(p2, p1, reverseOrder);
            return -reverseOrder;
          } else if (p2SourcePort == port) {
            _update(p1, p2, reverseOrder);
            return reverseOrder;
          }
        }
      }
      if (p1Node.type == NodeType.longEdge &&
          p2Node.type == NodeType.longEdge &&
          p1Node.layer!.id == p2Node.layer!.id &&
          p1Node.layer!.id == p1.node!.layer!.id) {
        final inPrevious = _checkReferenceLayer(p1Node.layer!.nodes, p1Node, p2Node);
        if (inPrevious != 0) {
          if (p1.side == PortSide.east && p2.side == PortSide.east) reverseOrder = -reverseOrder;
          if (inPrevious > 0) {
            _update(p1, p2, reverseOrder);
            return reverseOrder;
          }
          _update(p2, p1, reverseOrder);
          return -reverseOrder;
        }
      }
      final inPrevious = _checkReferenceLayer(previousLayer, p1Node, p2Node);
      if (inPrevious != 0) {
        if (inPrevious > 0) {
          _update(p1, p2, reverseOrder);
          return reverseOrder;
        }
        _update(p2, p1, reverseOrder);
        return -reverseOrder;
      }
      if (portModelOrder) {
        final result = _checkPortModelOrder(p1, p2);
        if (result != 0) {
          if (result > 0) {
            _update(p1, p2, reverseOrder);
            return reverseOrder;
          }
          _update(p2, p1, reverseOrder);
          return -reverseOrder;
        }
      }
    }
    if (p1.outgoing.isNotEmpty && p2.outgoing.isNotEmpty) {
      if (p1.side == PortSide.west && p2.side == PortSide.west ||
          p1.side == PortSide.south && p2.side == PortSide.south) {
        reverseOrder = -reverseOrder;
      }
      final p1TargetNode = p1.longEdgeTargetNode, p2TargetNode = p2.longEdgeTargetNode;
      if (portModelOrder) {
        final result = _checkPortModelOrder(p1, p2);
        if (result != 0) {
          if (result > 0) {
            _update(p1, p2, reverseOrder);
            return reverseOrder;
          }
          _update(p2, p1, reverseOrder);
          return -reverseOrder;
        }
      }
      var p1Order = 0, p2Order = 0;
      if (p1.outgoing[0].modelOrder != null) p1Order = p1.outgoing[0].modelOrder!;
      if (p2.outgoing[0].modelOrder != null) p2Order = p2.outgoing[0].modelOrder!;
      if (p1TargetNode != null && p1TargetNode == p2TargetNode) {
        if (p1Order > p2Order) {
          _update(p1, p2, reverseOrder);
          return reverseOrder;
        }
        _update(p2, p1, reverseOrder);
        return -reverseOrder;
      }
      final tnmo = targetNodeModelOrder;
      if (tnmo != null) {
        if (tnmo.containsKey(p1TargetNode)) p1Order = tnmo[p1TargetNode]!;
        if (tnmo.containsKey(p2TargetNode)) p2Order = tnmo[p2TargetNode]!;
      }
      if (p1Order > p2Order) {
        _update(p1, p2, reverseOrder);
        return reverseOrder;
      }
      _update(p2, p1, reverseOrder);
      return -reverseOrder;
    }
    if (p1.incoming.isNotEmpty && p2.outgoing.isNotEmpty) {
      _update(p1, p2, reverseOrder);
      return 1;
    } else if (p1.outgoing.isNotEmpty && p2.incoming.isNotEmpty) {
      _update(p2, p1, reverseOrder);
      return -1;
    } else if (p1.modelOrder != null && p2.modelOrder != null) {
      final p1MO = p1.modelOrder!, p2MO = p2.modelOrder!;
      if (p1.side == PortSide.west && p2.side == PortSide.west ||
          p1.side == PortSide.south && p2.side == PortSide.south) {
        reverseOrder = -reverseOrder;
      }
      if (p1MO > p2MO) {
        _update(p1, p2, reverseOrder);
        return reverseOrder;
      }
      _update(p2, p1, reverseOrder);
      return -reverseOrder;
    }
    _update(p2, p1, reverseOrder);
    return -reverseOrder;
  }

  int _checkPortModelOrder(LPort p1, LPort p2) {
    if (p1.modelOrder != null && p2.modelOrder != null) return p1.modelOrder!.compareTo(p2.modelOrder!);
    return 0;
  }

  static int _checkReferenceLayer(List<LNode> layer, LNode p1Node, LNode p2Node) {
    for (final node in layer) {
      if (node == p1Node) return -1;
      if (node == p2Node) return 1;
    }
    return 0;
  }
}
