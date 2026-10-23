// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// Phase 3 of ELK Layered: LayerSweepCrossingMinimizer with the ModelOrderBarycenterHeuristic (forceNodeModelOrder)
/// and, as the hierarchical TWO_SIDED greedy switch, the same sweep with the _GreedySwitchHeuristic. Only the root
/// graph exists (Dify feeds flat graphs), so the hierarchical sweeping into nested graphs is not needed.
library;

import 'dart:math' as math;

import 'elk_graph.dart';
import 'elk_layering.dart' show modelOrderInsertionSort;

enum CrossMinType { barycenter, twoSidedGreedySwitch }

void layerSweepCrossingMinimizer(LGraph graph, CrossMinType type) {
  final emptyGraph = graph.layers.isEmpty || graph.layers.every((l) => l.nodes.isEmpty);
  if (emptyGraph) return;
  _LayerSweep(graph, type).run();
}

class _LayerSweep {
  _LayerSweep(this.graph, this.type);

  final LGraph graph;
  final CrossMinType type;
  late final GwtRandom random;
  late (int, int) randomSeed;
  late final _GraphInfo gData;
  bool _changed = false;

  void run() {
    random = graph.random;
    randomSeed = random.nextLong();
    graph.id = 0;
    gData = _GraphInfo(graph, type, random);
    if (gData.currentNodeOrder.isNotEmpty) {
      if (type == CrossMinType.barycenter) {
        _compareDifferentRandomizedLayouts();
      } else {
        _minimizeCrossingsNoCounter();
      }
    }
    final best = type == CrossMinType.barycenter ? gData.bestNodeAndPortOrder : gData.currentlyBestNodeAndPortOrder;
    best?.transferNodeAndPortOrdersToGraph(graph);
  }

  void _minimizeCrossingsNoCounter() {
    var isForwardSweep = random.nextBoolean();
    var improved = true;
    while (improved) {
      improved = gData.crossMinimizer.setFirstLayerOrder(gData.currentNodeOrder, isForwardSweep);
      improved |= _sweepReducingCrossings(isForwardSweep, false);
      isForwardSweep = !isForwardSweep;
    }
    _setCurrentlyBestNodeOrders();
  }

  void _compareDifferentRandomizedLayouts() {
    random.setSeed(randomSeed);
    _changed = false;
    var bestCrossings = 2147483647;
    graph.firstTryWithInitialOrder = true;
    for (var i = 0; i < graph.options.thoroughness; i++) {
      final crossings = _minimizeCrossingsWithCounter();
      if (crossings < bestCrossings) {
        bestCrossings = crossings;
        if (_changed) gData.bestNodeAndPortOrder = SweepCopy.copy(gData.currentlyBestNodeAndPortOrder!);
        if (bestCrossings == 0) break;
      }
    }
  }

  int _minimizeCrossingsWithCounter() {
    var isForwardSweep = random.nextBoolean();
    final initialCrossings = gData.crossCounter.countAllCrossings(gData.currentNodeOrder);
    if (initialCrossings == 0 && graph.firstTryWithInitialOrder) return 0;
    if (!graph.firstTryWithInitialOrder && !graph.secondTryWithInitialOrder) {
      gData.crossMinimizer.setFirstLayerOrder(gData.currentNodeOrder, isForwardSweep);
    } else {
      isForwardSweep = graph.firstTryWithInitialOrder;
    }
    _sweepReducingCrossings(isForwardSweep, true);
    if (graph.secondTryWithInitialOrder) graph.secondTryWithInitialOrder = false;
    if (graph.firstTryWithInitialOrder) {
      graph.firstTryWithInitialOrder = false;
      graph.secondTryWithInitialOrder = true;
    }
    var crossingsInGraph = gData.crossCounter.countAllCrossings(gData.currentNodeOrder);
    int oldNumberOfCrossings;
    do {
      _setCurrentlyBestNodeOrders();
      if (crossingsInGraph == 0) return 0;
      isForwardSweep = !isForwardSweep;
      oldNumberOfCrossings = crossingsInGraph;
      _sweepReducingCrossings(isForwardSweep, false);
      crossingsInGraph = gData.crossCounter.countAllCrossings(gData.currentNodeOrder);
    } while (oldNumberOfCrossings > crossingsInGraph);
    return oldNumberOfCrossings;
  }

  bool _sweepReducingCrossings(bool forward, bool firstSweep) {
    final nodes = gData.currentNodeOrder;
    final length = nodes.length;
    var improved = gData.portDistributor.distributePortsWhileSweeping(nodes, forward ? 0 : length - 1, forward);
    for (var i = forward ? 1 : length - 2; forward ? i < length : i >= 0; i += forward ? 1 : -1) {
      improved |= gData.crossMinimizer.minimizeCrossings(
        nodes,
        i,
        forward,
        firstSweep && !graph.firstTryWithInitialOrder && !graph.secondTryWithInitialOrder,
      );
      improved |= gData.portDistributor.distributePortsWhileSweeping(nodes, i, forward);
    }
    _changed = true;
    return improved;
  }

  void _setCurrentlyBestNodeOrders() {
    if (_changed) gData.currentlyBestNodeAndPortOrder = SweepCopy(gData.currentNodeOrder);
  }
}

/// GraphInfoHolder for the root graph, including the IInitializable traversal and its side effects on ids.
class _GraphInfo {
  _GraphInfo(this.lGraph, CrossMinType type, GwtRandom random) : currentNodeOrder = lGraph.toNodeArray() {
    final order = currentNodeOrder;
    portDistributor = type == CrossMinType.twoSidedGreedySwitch
        ? GreedyPortDistributor()
        : (random.nextBoolean() ? NodeRelativePortDistributor(order.length) : LayerTotalPortDistributor(order.length));
    if (type == CrossMinType.barycenter) {
      final states = <List<BarycenterState>>[];
      // Every initializable assigns layer.id = l, node.id = n and port.id = running port index; ForsterConstraintResolver
      // contributes the barycenter states.
      _initIds(order, (l, n, node) {
        if (n == 0) states.add([]);
        states[l].add(BarycenterState(node));
      });
      crossMinimizer = ModelOrderBarycenterHeuristic(
        random,
        portDistributor as AbstractBarycenterPortDistributor,
        states,
      );
    } else {
      _initIds(order, null);
      crossMinimizer = _GreedySwitchHeuristic(this);
    }
    portDistributor.initAfterTraversal(order, _nPorts);
    crossCounter = AllCrossingsCounter(order, _nPorts);
    portPositions = List.filled(_nPorts, 0);
  }

  final LGraph lGraph;
  final List<List<LNode>> currentNodeOrder;
  late final ISweepPortDistributor portDistributor;
  late final ICrossingMinimizationHeuristic crossMinimizer;
  late final AllCrossingsCounter crossCounter;
  late final List<int> portPositions;
  SweepCopy? currentlyBestNodeAndPortOrder;
  SweepCopy? bestNodeAndPortOrder;
  int _nPorts = 0;

  void _initIds(List<List<LNode>> order, void Function(int l, int n, LNode node)? onNode) {
    for (var l = 0; l < order.length; l++) {
      order[l][0].layer!.id = l;
      for (var n = 0; n < order[l].length; n++) {
        final node = order[l][n];
        node.id = n;
        onNode?.call(l, n, node);
        for (final port in node.ports) {
          port.id = _nPorts++;
        }
      }
    }
  }
}

class SweepCopy {
  SweepCopy(List<List<LNode>> order)
    : nodeOrder = [for (final l in order) List.of(l)],
      portOrders = [
        for (final l in order) [for (final n in l) List.of(n.ports)],
      ];

  SweepCopy.copy(SweepCopy sc)
    : nodeOrder = [for (final l in sc.nodeOrder) List.of(l)],
      portOrders = List.of(sc.portOrders);

  final List<List<LNode>> nodeOrder;
  final List<List<List<LPort>>> portOrders;

  void transferNodeAndPortOrdersToGraph(LGraph graph) {
    for (var i = 0; i < graph.layers.length; i++) {
      final nodes = graph.layers[i].nodes;
      for (var j = 0; j < nodes.length; j++) {
        final node = nodeOrder[i][j];
        node.id = j;
        nodes[j] = node;
        node.ports
          ..clear()
          ..addAll(portOrders[i][j]);
        if (!node.portConstraints.isOrderFixed) node.portConstraints = PortConstraints.fixedOrder;
      }
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Heuristics

abstract class ICrossingMinimizationHeuristic {
  bool setFirstLayerOrder(List<List<LNode>> order, bool forwardSweep);
  bool minimizeCrossings(List<List<LNode>> order, int freeLayerIndex, bool forwardSweep, bool isFirstSweep);
}

class BarycenterState {
  BarycenterState(this.node);
  final LNode node;
  double summedWeight = 0;
  int degree = 0;
  double? barycenter;
  bool visited = false;
}

/// BarycenterHeuristic as overridden by ModelOrderBarycenterHeuristic (forceNodeModelOrder is set, so constraint
/// resolution is skipped and layers are insertion-sorted with the transitive model order comparator).
class ModelOrderBarycenterHeuristic implements ICrossingMinimizationHeuristic {
  ModelOrderBarycenterHeuristic(this.random, this.portDistributor, this.barycenterState);

  final GwtRandom random;
  final AbstractBarycenterPortDistributor portDistributor;
  final List<List<BarycenterState>> barycenterState;
  Map<LNode, Set<LNode>> _biggerThan = {};
  Map<LNode, Set<LNode>> _smallerThan = {};

  static const double _randomAmount = 0.07000000029802322;
  static const double _halfRandomAmount = 0.03500000014901161;

  BarycenterState stateOf(LNode node) => barycenterState[node.layer!.id][node.id];

  void _minimizeLayer(List<LNode> layer, bool preOrdered, bool randomize, bool forward) {
    if (randomize) {
      for (final node in layer) {
        final s = stateOf(node);
        s.barycenter = random.nextDouble();
        s.summedWeight = s.barycenter!;
        s.degree = 1;
      }
    } else {
      for (final node in layer) {
        stateOf(node).visited = false;
      }
      for (final node in layer) {
        _calculateBarycenter(node, forward);
      }
      _fillInUnknownBarycenters(layer, preOrdered);
    }
    if (layer.length > 1) {
      modelOrderInsertionSort(layer, _compare);
      _biggerThan = {};
      _smallerThan = {};
    }
  }

  void _fillInUnknownBarycenters(List<LNode> nodes, bool preOrdered) {
    if (preOrdered) {
      var lastValue = -1.0;
      for (var i = 0; i < nodes.length; i++) {
        final state = stateOf(nodes[i]);
        var value = state.barycenter;
        if (value == null) {
          var nextValue = lastValue + 1;
          for (var j = i + 1; j < nodes.length; j++) {
            final x = stateOf(nodes[j]).barycenter;
            if (x != null) {
              nextValue = x;
              break;
            }
          }
          value = (lastValue + nextValue) / 2;
          state.barycenter = value;
          state.summedWeight = value;
          state.degree = 1;
        }
        lastValue = value;
      }
    } else {
      var maxBary = 0.0;
      for (final node in nodes) {
        final b = stateOf(node).barycenter;
        if (b != null) maxBary = math.max(maxBary, b);
      }
      maxBary += 2;
      for (final node in nodes) {
        final s = stateOf(node);
        if (s.barycenter == null) {
          final value = random.nextFloat() * maxBary - 1;
          s.barycenter = value;
          s.summedWeight = value;
          s.degree = 1;
        }
      }
    }
  }

  void _calculateBarycenter(LNode node, bool forward) {
    final state = stateOf(node);
    if (state.visited) return;
    state.visited = true;
    state.degree = 0;
    state.summedWeight = 0.0;
    state.barycenter = null;
    final portRanks = portDistributor.portRanks;
    for (final freePort in node.ports) {
      for (final fixedPort in forward ? freePort.predecessorPorts : freePort.successorPorts) {
        final fixedNode = fixedPort.node!;
        if (fixedNode.layer == node.layer) {
          if (fixedNode != node) {
            _calculateBarycenter(fixedNode, forward);
            state.degree += stateOf(fixedNode).degree;
            state.summedWeight += stateOf(fixedNode).summedWeight;
          }
        } else {
          state.summedWeight += portRanks[fixedPort.id];
          state.degree++;
        }
      }
    }
    if (state.degree > 0) {
      state.summedWeight += random.nextFloat() * _randomAmount - _halfRandomAmount;
      state.barycenter = state.summedWeight / state.degree;
    }
  }

  int _compare(LNode n1, LNode n2) {
    final transitive = _compareBasedOnTransitiveDependencies(n1, n2);
    if (transitive != 0) return transitive;
    if (n1.modelOrder != null && n2.modelOrder != null) {
      final value = n1.modelOrder!.compareTo(n2.modelOrder!);
      if (value < 0) {
        _update(n1, n2);
        return value;
      } else if (value > 0) {
        _update(n2, n1);
        return value;
      }
    }
    final s1 = stateOf(n1), s2 = stateOf(n2);
    if (s1.barycenter != null && s2.barycenter != null) {
      final value = s1.barycenter!.compareTo(s2.barycenter!);
      if (value < 0) {
        _update(n1, n2);
      } else if (value > 0) {
        _update(n2, n1);
      }
      return value;
    } else if (s1.barycenter != null) {
      _update(n1, n2);
      return -1;
    } else if (s2.barycenter != null) {
      _update(n2, n1);
      return 1;
    }
    return 0;
  }

  int _compareBasedOnTransitiveDependencies(LNode n1, LNode n2) {
    if (!_biggerThan.containsKey(n1)) {
      _biggerThan[n1] = {};
    } else if (_biggerThan[n1]!.contains(n2)) {
      return 1;
    }
    if (!_biggerThan.containsKey(n2)) {
      _biggerThan[n2] = {};
    } else if (_biggerThan[n2]!.contains(n1)) {
      return -1;
    }
    if (!_smallerThan.containsKey(n1)) {
      _smallerThan[n1] = {};
    } else if (_smallerThan[n1]!.contains(n2)) {
      return -1;
    }
    if (!_smallerThan.containsKey(n2)) {
      _smallerThan[n2] = {};
    } else if (_smallerThan[n2]!.contains(n1)) {
      return 1;
    }
    return 0;
  }

  // Note the argument order of ELK's calls: update(n1, n2) when n1 < n2, i.e. "bigger" is the smaller node here.
  void _update(LNode bigger, LNode smaller) {
    final biggerBiggerThan = _biggerThan[bigger]!;
    final smallerBiggerThan = _biggerThan[smaller]!;
    final biggerSmallerThan = _smallerThan[bigger]!;
    final smallerSmallerThan = _smallerThan[smaller]!;
    biggerBiggerThan.add(smaller);
    smallerSmallerThan.add(bigger);
    for (final verySmall in List.of(smallerBiggerThan)) {
      biggerBiggerThan.add(verySmall);
      _smallerThan[verySmall]!.add(bigger);
      _smallerThan[verySmall]!.addAll(List.of(biggerSmallerThan));
    }
    for (final veryBig in List.of(biggerSmallerThan)) {
      smallerSmallerThan.add(veryBig);
      _biggerThan[veryBig]!.add(smaller);
      _biggerThan[veryBig]!.addAll(List.of(smallerBiggerThan));
    }
  }

  @override
  bool minimizeCrossings(List<List<LNode>> order, int freeLayerIndex, bool forwardSweep, bool isFirstSweep) {
    final startIndex = forwardSweep ? 0 : (order.length - 1 > 0 ? order.length - 1 : 0);
    if (freeLayerIndex != startIndex) {
      final fixedLayer = order[freeLayerIndex - (forwardSweep ? 1 : -1)];
      portDistributor.calculatePortRanksOfLayer(fixedLayer, forwardSweep ? PortType.output : PortType.input);
    }
    final preOrdered = !isFirstSweep || order[freeLayerIndex][0].type == NodeType.externalPort;
    final nodes = List.of(order[freeLayerIndex]);
    _minimizeLayer(nodes, preOrdered, false, forwardSweep);
    for (var i = 0; i < nodes.length; i++) {
      order[freeLayerIndex][i] = nodes[i];
    }
    return false;
  }

  @override
  bool setFirstLayerOrder(List<List<LNode>> order, bool forwardSweep) {
    final startIndex = forwardSweep ? 0 : (order.length - 1 > 0 ? order.length - 1 : 0);
    final nodes = List.of(order[startIndex]);
    _minimizeLayer(nodes, false, true, forwardSweep);
    for (var i = 0; i < nodes.length; i++) {
      order[startIndex][i] = nodes[i];
    }
    return false;
  }
}

/// _GreedySwitchHeuristic of type TWO_SIDED.
class _GreedySwitchHeuristic implements ICrossingMinimizationHeuristic {
  _GreedySwitchHeuristic(this.graphData);
  final _GraphInfo graphData;
  late List<List<LNode>> _order;
  late _SwitchDecider _decider;

  void _setUp(List<List<LNode>> order, int freeLayerIndex) {
    _order = order;
    _decider = _SwitchDecider(freeLayerIndex, order, graphData.portPositions);
  }

  @override
  bool minimizeCrossings(List<List<LNode>> order, int freeLayerIndex, bool forwardSweep, bool isFirstSweep) {
    _setUp(order, freeLayerIndex);
    var improved = false;
    bool continueSwitching;
    do {
      continueSwitching = _sweepDownwardInLayer(freeLayerIndex);
      improved |= continueSwitching;
    } while (continueSwitching);
    return improved;
  }

  @override
  bool setFirstLayerOrder(List<List<LNode>> order, bool forwardSweep) {
    final startIndex = forwardSweep ? 0 : order.length - 1;
    _setUp(order, startIndex);
    return _sweepDownwardInLayer(startIndex);
  }

  bool _sweepDownwardInLayer(int layerIndex) {
    var continueSwitching = false;
    final length = _order[layerIndex].length;
    for (var upper = 0; upper < length - 1; upper++) {
      final lower = upper + 1;
      if (_decider.doesSwitchReduceCrossings(upper, lower)) {
        final layer = _order[layerIndex];
        _decider.notifyOfSwitch(layer[upper], layer[lower]);
        final temp = layer[lower];
        layer[lower] = layer[upper];
        layer[upper] = temp;
        continueSwitching = true;
      }
    }
    return continueSwitching;
  }
}

class _SwitchDecider {
  _SwitchDecider(int freeLayerIndex, List<List<LNode>> graph, List<int> portPositions)
    : freeLayer = graph[freeLayerIndex],
      leftInLayerCounter = CrossingsCounter(portPositions),
      rightInLayerCounter = CrossingsCounter(portPositions),
      _matrix = _CrossingMatrixFiller(graph, freeLayerIndex) {
    leftInLayerCounter.initPortPositionsForInLayerCrossings(freeLayer, PortSide.west);
    rightInLayerCounter.initPortPositionsForInLayerCrossings(freeLayer, PortSide.east);
  }

  final List<LNode> freeLayer;
  final CrossingsCounter leftInLayerCounter;
  final CrossingsCounter rightInLayerCounter;
  final _CrossingMatrixFiller _matrix;

  void notifyOfSwitch(LNode upper, LNode lower) {
    leftInLayerCounter.switchNodes(upper, lower, PortSide.west);
    rightInLayerCounter.switchNodes(upper, lower, PortSide.east);
  }

  // Successor constraints, layout units and north/south port dummies never occur, so no switch is prevented.
  bool doesSwitchReduceCrossings(int upperIndex, int lowerIndex) {
    final upper = freeLayer[upperIndex], lower = freeLayer[lowerIndex];
    final left = leftInLayerCounter.countInLayerCrossingsBetweenNodesInBothOrders(upper, lower, PortSide.west);
    final right = rightInLayerCounter.countInLayerCrossingsBetweenNodesInBothOrders(upper, lower, PortSide.east);
    final upperLower = _matrix.entry(upper, lower) + left.$1 + right.$1;
    final lowerUpper = _matrix.entry(lower, upper) + left.$2 + right.$2;
    return upperLower > lowerUpper;
  }
}

class _CrossingMatrixFiller {
  _CrossingMatrixFiller(List<List<LNode>> graph, int freeLayerIndex)
    : _filled = List.generate(graph[freeLayerIndex].length, (_) => List.filled(graph[freeLayerIndex].length, false)),
      _matrix = List.generate(graph[freeLayerIndex].length, (_) => List.filled(graph[freeLayerIndex].length, 0)),
      _counter = BetweenLayerEdgeTwoNodeCrossingsCounter(graph, freeLayerIndex);

  final List<List<bool>> _filled;
  final List<List<int>> _matrix;
  final BetweenLayerEdgeTwoNodeCrossingsCounter _counter;

  int entry(LNode upper, LNode lower) {
    if (!_filled[upper.id][lower.id]) {
      _counter.countBothSideCrossings(upper, lower);
      _matrix[upper.id][lower.id] = _counter.upperLowerCrossings;
      _matrix[lower.id][upper.id] = _counter.lowerUpperCrossings;
      _filled[upper.id][lower.id] = true;
      _filled[lower.id][upper.id] = true;
    }
    return _matrix[upper.id][lower.id];
  }
}

Iterable<LPort> inNorthSouthEastWestOrder(LNode node, PortSide side) => switch (side) {
  PortSide.east || PortSide.north => node.portSideView(side),
  PortSide.south || PortSide.west => node.portSideView(side).reversed,
  PortSide.undefined => const [],
};

class BetweenLayerEdgeTwoNodeCrossingsCounter {
  BetweenLayerEdgeTwoNodeCrossingsCounter(this.currentNodeOrder, this.freeLayerIndex) {
    if (freeLayerIndex > 0) _setPortPositionsForLayer(freeLayerIndex - 1, PortSide.east);
    if (freeLayerIndex < currentNodeOrder.length - 1) _setPortPositionsForLayer(freeLayerIndex + 1, PortSide.west);
  }

  final List<List<LNode>> currentNodeOrder;
  final int freeLayerIndex;
  final Map<LPort, int> _portPositions = {};
  final Map<LNode, _AdjacencyList> _east = {};
  final Map<LNode, _AdjacencyList> _west = {};
  int upperLowerCrossings = 0;
  int lowerUpperCrossings = 0;
  late _AdjacencyList _upper, _lower;

  void _setPortPositionsForLayer(int layerIndex, PortSide side) {
    var portId = 0;
    for (final node in currentNodeOrder[layerIndex]) {
      for (final port in inNorthSouthEastWestOrder(node, side)) {
        _portPositions[port] = portId++;
      }
    }
  }

  void countBothSideCrossings(LNode upper, LNode lower) {
    upperLowerCrossings = 0;
    lowerUpperCrossings = 0;
    if (upper == lower) return;
    _addCrossings(upper, lower, PortSide.west, _west);
    _addCrossings(upper, lower, PortSide.east, _east);
  }

  _AdjacencyList _adjacencyFor(LNode node, PortSide side, Map<LNode, _AdjacencyList> map) {
    if (map.isEmpty) {
      for (final n in currentNodeOrder[freeLayerIndex]) {
        map[n] = _AdjacencyList(n, side, _portPositions);
      }
    }
    return map[node]!..reset();
  }

  void _addCrossings(LNode upper, LNode lower, PortSide side, Map<LNode, _AdjacencyList> map) {
    _upper = _adjacencyFor(upper, side, map);
    _lower = _adjacencyFor(lower, side, map);
    if (_upper.currentSize == 0 || _lower.currentSize == 0) return;
    while (!_upper.isEmpty && !_lower.isEmpty) {
      if (_upper.first > _lower.first) {
        upperLowerCrossings += _upper.currentSize;
        _lower.removeFirst();
      } else if (_lower.first > _upper.first) {
        lowerUpperCrossings += _lower.currentSize;
        _upper.removeFirst();
      } else {
        upperLowerCrossings += _upper.countAdjacenciesBelowNodeOfFirstPort();
        lowerUpperCrossings += _lower.countAdjacenciesBelowNodeOfFirstPort();
        _upper.removeFirst();
        _lower.removeFirst();
      }
    }
  }
}

class _Adjacency {
  _Adjacency(this.position);
  final int position;
  int cardinality = 1;
  int currentCardinality = 1;
}

class _AdjacencyList {
  _AdjacencyList(LNode node, PortSide side, Map<LPort, int> portPositions) {
    for (final port in inNorthSouthEastWestOrder(node, side)) {
      for (final edge in side == PortSide.west ? port.incoming : port.outgoing) {
        if (!edge.isSelfLoop && edge.source!.node!.layer != edge.target!.node!.layer) {
          final adjacentPort = side == PortSide.west ? edge.source! : edge.target!;
          final position = portPositions[adjacentPort]!;
          if (_list.isNotEmpty && _list.last.position == position) {
            _list.last.cardinality++;
            _list.last.currentCardinality++;
          } else {
            _list.add(_Adjacency(position));
          }
          size++;
          currentSize++;
        }
      }
    }
    gwtSort(_list, (a, b) => a.position < b.position ? -1 : (a.position == b.position ? 0 : 1));
  }

  final List<_Adjacency> _list = [];
  int size = 0;
  int currentSize = 0;
  int _currentIndex = 0;

  void reset() {
    _currentIndex = 0;
    currentSize = size;
    if (!isEmpty) _list[_currentIndex].currentCardinality = _list[_currentIndex].cardinality;
  }

  int countAdjacenciesBelowNodeOfFirstPort() => currentSize - _list[_currentIndex].currentCardinality;

  void removeFirst() {
    if (isEmpty) return;
    final current = _list[_currentIndex];
    if (current.currentCardinality == 1) {
      _currentIndex++;
      if (_currentIndex < _list.length) _list[_currentIndex].currentCardinality = _list[_currentIndex].cardinality;
    } else {
      current.currentCardinality--;
    }
    currentSize--;
  }

  bool get isEmpty => currentSize == 0;
  int get first => _list[_currentIndex].position;
}

// ---------------------------------------------------------------------------------------------------------------
// Port distributors

enum PortType { input, output }

abstract class ISweepPortDistributor {
  bool distributePortsWhileSweeping(List<List<LNode>> order, int freeLayerIndex, bool isForwardSweep);
  void initAfterTraversal(List<List<LNode>> order, int nPorts);
}

abstract class AbstractBarycenterPortDistributor implements ISweepPortDistributor {
  AbstractBarycenterPortDistributor(int numLayers) : _nodePositions = List.filled(numLayers, const []);

  late List<double> portRanks;
  late List<double> _portBarycenter;
  final List<List<int>> _nodePositions;
  double _minBarycenter = 0, _maxBarycenter = 0;
  final List<LPort> _inLayerPorts = [];

  @override
  void initAfterTraversal(List<List<LNode>> order, int nPorts) {
    for (var l = 0; l < order.length; l++) {
      _nodePositions[l] = List.generate(order[l].length, (n) => n);
    }
    portRanks = List.filled(nPorts, 0);
    _portBarycenter = List.filled(nPorts, 0);
  }

  @override
  bool distributePortsWhileSweeping(List<List<LNode>> nodeOrder, int currentIndex, bool isForwardSweep) {
    final layer = nodeOrder[currentIndex];
    for (var i = 0; i < layer.length; i++) {
      _nodePositions[layer[i].layer!.id][layer[i].id] = i;
    }
    final freeLayer = layer;
    final side = isForwardSweep ? PortSide.west : PortSide.east;
    final notFirst = isForwardSweep ? currentIndex != 0 : currentIndex != nodeOrder.length - 1;
    if (notFirst) {
      final fixedLayer = nodeOrder[isForwardSweep ? currentIndex - 1 : currentIndex + 1];
      calculatePortRanksOfLayer(fixedLayer, isForwardSweep ? PortType.output : PortType.input);
      for (final node in freeLayer) {
        _distributePorts(node, side);
      }
      calculatePortRanksOfLayer(freeLayer, isForwardSweep ? PortType.input : PortType.output);
      final opposed = side == PortSide.west ? PortSide.east : PortSide.west;
      for (final node in fixedLayer) {
        _distributePorts(node, opposed);
      }
    } else {
      for (final node in freeLayer) {
        _distributePorts(node, side);
      }
    }
    return false;
  }

  void calculatePortRanksOfLayer(List<LNode> layer, PortType type) {
    var consumedRank = 0.0;
    for (final node in layer) {
      consumedRank += calculatePortRanks(node, consumedRank, type);
    }
  }

  double calculatePortRanks(LNode node, double rankSum, PortType type);

  void _distributePorts(LNode node, PortSide side) {
    if (node.portConstraints.isOrderFixed) return;
    _distributePortsOf(node, node.portsOnSide(side));
    _distributePortsOf(node, node.portsOnSide(PortSide.south));
    _distributePortsOf(node, node.portsOnSide(PortSide.north));
    gwtSort(node.ports, (p1, p2) {
      if (p1.side != p2.side) return p1.side.index - p2.side.index;
      final b1 = _portBarycenter[p1.id], b2 = _portBarycenter[p2.id];
      if (b1 == 0 && b2 == 0) return 0;
      if (b1 == 0) return -1;
      if (b2 == 0) return 1;
      return compareDouble(b1, b2);
    });
  }

  void _distributePortsOf(LNode node, Iterable<LPort> ports) {
    _inLayerPorts.clear();
    _minBarycenter = 0.0;
    _maxBarycenter = 0.0;
    portLoop:
    for (final port in ports) {
      var sum = 0.0;
      // North/south ports never occur.
      for (final outgoing in port.outgoing) {
        final connected = outgoing.target!;
        if (connected.node!.layer == node.layer) {
          _inLayerPorts.add(port);
          continue portLoop;
        }
        sum += portRanks[connected.id];
      }
      for (final incoming in port.incoming) {
        final connected = incoming.source!;
        if (connected.node!.layer == node.layer) {
          _inLayerPorts.add(port);
          continue portLoop;
        }
        sum -= portRanks[connected.id];
      }
      if (port.degree > 0) {
        final b = sum / port.degree;
        _portBarycenter[port.id] = b;
        _minBarycenter = math.min(_minBarycenter, b);
        _maxBarycenter = math.max(_maxBarycenter, b);
      }
    }
    if (_inLayerPorts.isNotEmpty) _calculateInLayerPortsBarycenterValues(node);
  }

  int _positionOf(LNode node) => _nodePositions[node.layer!.id][node.id];

  void _calculateInLayerPortsBarycenterValues(LNode node) {
    final nodeIndexInLayer = _positionOf(node) + 1;
    final layerSize = node.layer!.nodes.length + 1;
    for (final port in _inLayerPorts) {
      var sum = 0, inLayerConnections = 0;
      for (final connected in port.connectedPorts) {
        if (connected.node!.layer == node.layer) {
          sum += _positionOf(connected.node!) + 1;
          inLayerConnections++;
        }
      }
      final barycenter = sum / inLayerConnections;
      if (port.side == PortSide.east) {
        _portBarycenter[port.id] = barycenter < nodeIndexInLayer
            ? _minBarycenter - barycenter
            : _maxBarycenter + (layerSize - barycenter);
      } else if (port.side == PortSide.west) {
        _portBarycenter[port.id] = barycenter < nodeIndexInLayer
            ? _maxBarycenter + barycenter
            : _minBarycenter - (layerSize - barycenter);
      }
    }
  }
}

class NodeRelativePortDistributor extends AbstractBarycenterPortDistributor {
  NodeRelativePortDistributor(super.numLayers);

  @override
  double calculatePortRanks(LNode node, double rankSum, PortType type) {
    if (type == PortType.input) {
      var inputCount = 0, northInputCount = 0;
      for (final port in node.ports) {
        if (port.incoming.isNotEmpty) {
          inputCount++;
          if (port.side == PortSide.north) northInputCount++;
        }
      }
      final incr = 1.0 / (inputCount + 1);
      var northPos = rankSum + northInputCount * incr;
      var restPos = rankSum + 1 - incr;
      for (final port in node.inputPorts) {
        if (port.side == PortSide.north) {
          portRanks[port.id] = northPos;
          northPos -= incr;
        } else {
          portRanks[port.id] = restPos;
          restPos -= incr;
        }
      }
    } else {
      var outputCount = 0;
      for (final port in node.ports) {
        if (port.outgoing.isNotEmpty) outputCount++;
      }
      final incr = 1.0 / (outputCount + 1);
      var pos = rankSum + incr;
      for (final port in node.outputPorts) {
        portRanks[port.id] = pos;
        pos += incr;
      }
    }
    return 1;
  }
}

class LayerTotalPortDistributor extends AbstractBarycenterPortDistributor {
  LayerTotalPortDistributor(super.numLayers);

  @override
  double calculatePortRanks(LNode node, double rankSum, PortType type) {
    if (type == PortType.input) {
      var inputCount = 0, northInputCount = 0;
      for (final port in node.ports) {
        if (port.incoming.isNotEmpty) {
          inputCount++;
          if (port.side == PortSide.north) northInputCount++;
        }
      }
      var northPos = rankSum + northInputCount;
      var restPos = rankSum + inputCount;
      for (final port in node.inputPorts) {
        if (port.side == PortSide.north) {
          portRanks[port.id] = northPos;
          northPos--;
        } else {
          portRanks[port.id] = restPos;
          restPos--;
        }
      }
      return inputCount.toDouble();
    }
    var pos = 0;
    for (final port in node.outputPorts) {
      pos++;
      portRanks[port.id] = rankSum + pos;
    }
    return pos.toDouble();
  }
}

class GreedyPortDistributor implements ISweepPortDistributor {
  late CrossingsCounter _counter;

  @override
  void initAfterTraversal(List<List<LNode>> order, int nPorts) {
    _counter = CrossingsCounter(List.filled(nPorts, 0));
  }

  @override
  bool distributePortsWhileSweeping(List<List<LNode>> nodeOrder, int currentIndex, bool isForwardSweep) {
    if (isForwardSweep && currentIndex > 0) {
      _counter.initForCountingBetween(nodeOrder[currentIndex - 1], nodeOrder[currentIndex]);
    } else if (!isForwardSweep && currentIndex < nodeOrder.length - 1) {
      _counter.initForCountingBetween(nodeOrder[currentIndex], nodeOrder[currentIndex + 1]);
    } else {
      _counter.initPortPositionsForInLayerCrossings(
        nodeOrder[currentIndex],
        isForwardSweep ? PortSide.west : PortSide.east,
      );
    }
    final side = isForwardSweep ? PortSide.west : PortSide.east;
    var improved = false;
    for (final node in nodeOrder[currentIndex]) {
      if (node.portConstraints.isOrderFixed) continue;
      improved |= _distributePortsOnNode(node, side);
    }
    return improved;
  }

  /// Works on node.ports through the (reversed for west) port side view, as ELK's live sublist views do.
  bool _distributePortsOnNode(LNode node, PortSide side) {
    final view = node.portSideView(side);
    if (view.isEmpty) return false;
    final start = node.ports.indexOf(view.first);
    final count = view.length;
    final reversed = side == PortSide.south || side == PortSide.west;
    int index(int i) => reversed ? start + count - 1 - i : start + i;
    var improved = false;
    bool continueSwitching;
    do {
      continueSwitching = false;
      for (var i = 0; i < count - 1; i++) {
        final upper = node.ports[index(i)], lower = node.ports[index(i + 1)];
        final crossings = _counter.countCrossingsBetweenPortsInBothOrders(upper, lower);
        if (crossings.$1 > crossings.$2) {
          improved = true;
          _counter.switchPorts(upper, lower);
          node.ports[index(i + 1)] = upper;
          node.ports[index(i)] = lower;
          continueSwitching = true;
        }
      }
    } while (continueSwitching);
    return improved;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// Crossing counters

class AllCrossingsCounter {
  AllCrossingsCounter(List<List<LNode>> order, int nPorts) : _counter = CrossingsCounter(List.filled(nPorts, 0));

  final CrossingsCounter _counter;

  // Hyperedges (ports with several edges) and north/south ports never occur, so the between-layer counter suffices.
  int countAllCrossings(List<List<LNode>> currentOrder) {
    if (currentOrder.isEmpty) return 0;
    var crossings = _counter.countInLayerCrossingsOnSide(currentOrder[0], PortSide.west);
    crossings += _counter.countInLayerCrossingsOnSide(currentOrder[currentOrder.length - 1], PortSide.east);
    for (var i = 0; i < currentOrder.length - 1; i++) {
      crossings += _counter.countCrossingsBetweenLayers(currentOrder[i], currentOrder[i + 1]);
    }
    return crossings;
  }
}

class _BinaryIndexedTree {
  _BinaryIndexedTree(this._maxNum) : _binarySums = List.filled(_maxNum + 1, 0), _numsPerIndex = List.filled(_maxNum, 0);

  final int _maxNum;
  List<int> _binarySums;
  List<int> _numsPerIndex;
  int size = 0;

  void add(int index) {
    size++;
    _numsPerIndex[index]++;
    var i = index + 1;
    while (i < _binarySums.length) {
      _binarySums[i]++;
      i += i & -i;
    }
  }

  int rank(int index) {
    var i = index, sum = 0;
    while (i > 0) {
      sum += _binarySums[i];
      i -= i & -i;
    }
    return sum;
  }

  void removeAll(int index) {
    final n = _numsPerIndex[index];
    if (n == 0) return;
    _numsPerIndex[index] = 0;
    size -= n;
    var i = index + 1;
    while (i < _binarySums.length) {
      _binarySums[i] -= n;
      i += i & -i;
    }
  }

  void clear() {
    _binarySums = List.filled(_maxNum + 1, 0);
    _numsPerIndex = List.filled(_maxNum, 0);
    size = 0;
  }
}

class CrossingsCounter {
  CrossingsCounter(this.portPositions);

  final List<int> portPositions;
  late _BinaryIndexedTree _indexTree;
  final List<int> _ends = [];
  List<int> _nodeCardinalities = const [];

  int _positionOf(LPort p) => portPositions[p.id];
  static LPort _otherEnd(LEdge e, LPort from) => from == e.source ? e.target! : e.source!;
  static bool _isInLayer(LEdge e) => e.source!.node!.layer == e.target!.node!.layer;

  int countCrossingsBetweenLayers(List<LNode> left, List<LNode> right) {
    final ports = _initPortPositionsCounterClockwise(left, right);
    _indexTree = _BinaryIndexedTree(ports.length);
    return _countCrossingsOnPorts(ports);
  }

  int countInLayerCrossingsOnSide(List<LNode> nodes, PortSide side) =>
      _countInLayerCrossingsOnPorts(initPortPositionsForInLayerCrossings(nodes, side));

  (int, int) countCrossingsBetweenPortsInBothOrders(LPort upper, LPort lower) {
    final ports = _connectedPortsSortedByPosition(upper, lower);
    final upperLower = _countCrossingsOnPorts(ports);
    _indexTree.clear();
    switchPorts(upper, lower);
    gwtSort(ports, (a, b) => _positionOf(a).compareTo(_positionOf(b)));
    final lowerUpper = _countCrossingsOnPorts(ports);
    _indexTree.clear();
    switchPorts(lower, upper);
    return (upperLower, lowerUpper);
  }

  (int, int) countInLayerCrossingsBetweenNodesInBothOrders(LNode upper, LNode lower, PortSide side) {
    final ports = _connectedInLayerPortsSortedByPosition(upper, lower, side);
    final upperLower = _countInLayerCrossingsOnPorts(ports);
    switchNodes(upper, lower, side);
    _indexTree.clear();
    gwtSort(ports, (a, b) => _positionOf(a).compareTo(_positionOf(b)));
    final lowerUpper = _countInLayerCrossingsOnPorts(ports);
    switchNodes(lower, upper, side);
    _indexTree.clear();
    return (upperLower, lowerUpper);
  }

  void initForCountingBetween(List<LNode> left, List<LNode> right) {
    final ports = _initPortPositionsCounterClockwise(left, right);
    _indexTree = _BinaryIndexedTree(ports.length);
  }

  List<LPort> initPortPositionsForInLayerCrossings(List<LNode> nodes, PortSide side) {
    final ports = <LPort>[];
    _initPositions(nodes, ports, side, true, true);
    _indexTree = _BinaryIndexedTree(ports.length);
    return ports;
  }

  void switchPorts(LPort top, LPort bottom) {
    final topPos = portPositions[top.id];
    portPositions[top.id] = portPositions[bottom.id];
    portPositions[bottom.id] = topPos;
  }

  void switchNodes(LNode wasUpper, LNode wasLower, PortSide side) {
    for (final port in inNorthSouthEastWestOrder(wasUpper, side)) {
      portPositions[port.id] = _positionOf(port) + _nodeCardinalities[wasLower.id];
    }
    for (final port in inNorthSouthEastWestOrder(wasLower, side)) {
      portPositions[port.id] = _positionOf(port) - _nodeCardinalities[wasUpper.id];
    }
  }

  /// A TreeSet ordered by position: de-duplicated by position and sorted.
  List<LPort> _sortedByPosition(Iterable<LPort> candidates) {
    final byPosition = <int, LPort>{};
    for (final p in candidates) {
      byPosition.putIfAbsent(_positionOf(p), () => p);
    }
    final keys = byPosition.keys.toList()..sort();
    return [for (final k in keys) byPosition[k]!];
  }

  List<LPort> _connectedInLayerPortsSortedByPosition(LNode upper, LNode lower, PortSide side) {
    final candidates = <LPort>[];
    for (final node in [upper, lower]) {
      for (final port in inNorthSouthEastWestOrder(node, side)) {
        for (final edge in port.connectedEdges) {
          if (!edge.isSelfLoop) {
            candidates.add(port);
            if (_isInLayer(edge)) candidates.add(_otherEnd(edge, port));
          }
        }
      }
    }
    return _sortedByPosition(candidates);
  }

  List<LPort> _connectedPortsSortedByPosition(LPort upper, LPort lower) {
    final candidates = <LPort>[];
    for (final port in [upper, lower]) {
      candidates.add(port);
      for (final edge in port.connectedEdges) {
        if (edge.source != edge.target) candidates.add(_otherEnd(edge, port));
      }
    }
    return _sortedByPosition(candidates);
  }

  int _countCrossingsOnPorts(List<LPort> ports) {
    var crossings = 0;
    for (final port in ports) {
      _indexTree.removeAll(_positionOf(port));
      for (final edge in port.connectedEdges) {
        final endPosition = _positionOf(_otherEnd(edge, port));
        if (endPosition > _positionOf(port)) {
          crossings += _indexTree.rank(endPosition);
          _ends.add(endPosition);
        }
      }
      while (_ends.isNotEmpty) {
        _indexTree.add(_ends.removeLast());
      }
    }
    return crossings;
  }

  int _countInLayerCrossingsOnPorts(List<LPort> ports) {
    var crossings = 0;
    for (final port in ports) {
      _indexTree.removeAll(_positionOf(port));
      var numBetweenLayerEdges = 0;
      for (final edge in port.connectedEdges) {
        if (_isInLayer(edge)) {
          final endPosition = _positionOf(_otherEnd(edge, port));
          if (endPosition > _positionOf(port)) {
            crossings += _indexTree.rank(endPosition);
            _ends.add(endPosition);
          }
        } else {
          numBetweenLayerEdges++;
        }
      }
      crossings += _indexTree.size * numBetweenLayerEdges;
      while (_ends.isNotEmpty) {
        _indexTree.add(_ends.removeLast());
      }
    }
    return crossings;
  }

  void _initPositions(List<LNode> nodes, List<LPort> ports, PortSide side, bool topDown, bool getCardinalities) {
    var numPorts = ports.length;
    if (getCardinalities) _nodeCardinalities = List.filled(nodes.length, 0);
    for (var i = topDown ? 0 : nodes.length - 1; topDown ? i < nodes.length : i >= 0; i += topDown ? 1 : -1) {
      final node = nodes[i];
      final view = node.portSideView(side);
      final nodePorts = side == PortSide.east
          ? (topDown ? view : view.reversed.toList())
          : (topDown ? view.reversed.toList() : view);
      if (getCardinalities) _nodeCardinalities[node.id] = nodePorts.length;
      for (final port in nodePorts) {
        portPositions[port.id] = numPorts++;
      }
      ports.addAll(nodePorts);
    }
  }

  List<LPort> _initPortPositionsCounterClockwise(List<LNode> left, List<LNode> right) {
    final ports = <LPort>[];
    _initPositions(left, ports, PortSide.east, true, false);
    _initPositions(right, ports, PortSide.west, false, false);
    return ports;
  }
}
