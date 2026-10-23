// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// org.eclipse.elk.alg.common.networksimplex: the network simplex algorithm ELK uses for layering and for the
/// horizontal compaction of the EDGE_LENGTH post-compaction strategy.
library;

class NGraph {
  final List<NNode> nodes = [];
}

class NNode {
  NNode(NGraph graph) {
    graph.nodes.add(this);
  }

  int id = 0;
  int _internalId = 0;
  Object? origin;
  int layer = 0;
  final List<NEdge> outgoing = [];
  final List<NEdge> incoming = [];
  bool _treeNode = false;
  final List<NEdge> _unknownCutvalues = [];

  List<NEdge> get connected => [...incoming, ...outgoing];
}

class NEdge {
  NEdge._(this.source, this.target, this.weight, this.delta);

  factory NEdge.create(NNode source, NNode target, {required double weight, required int delta}) {
    if (source == target) throw StateError('Network simplex does not support self-loops');
    final e = NEdge._(source, target, weight, delta);
    source.outgoing.add(e);
    target.incoming.add(e);
    return e;
  }

  NNode source;
  NNode target;
  double weight;
  int delta;
  int _internalId = 0;
  bool _treeEdge = false;

  NNode other(NNode n) => n == source ? target : source;
}

const int _intMax = 2147483647;
const int _intMin = -2147483648;

class NetworkSimplex {
  NetworkSimplex(this.graph, {this.iterationLimit = _intMax, this.previousLayering, this.balance = false});

  final NGraph graph;
  final int iterationLimit;
  final List<int>? previousLayering;
  final bool balance;

  static const int _removeSubtreesThresh = 40;
  static const double _fuzzyStZero = -1e-10;

  late List<NEdge> _edges;
  late Set<NEdge> _treeEdges;
  late List<NNode> _sources;
  late List<bool> _edgeVisited;
  late List<int> _poID;
  late List<int> _lowestPoID;
  late List<double> _cutvalue;
  int _postOrder = 1;
  final List<(NNode, NEdge)> _subtreeNodesStack = [];

  // getConnectedEdges() is cached in ELK and recomputed when the edge lists change; the order is the same.
  List<NEdge> _conn(NNode n) => n.connected;

  void execute() {
    if (graph.nodes.isEmpty) return;
    for (final node in graph.nodes) {
      node.layer = 0;
    }
    final removeSubtrees = graph.nodes.length >= _removeSubtreesThresh;
    if (removeSubtrees) _removeSubtrees();
    _initialize();
    _feasibleTree();
    var e = _leaveEdge();
    var iter = 0;
    while (e != null && iter < iterationLimit) {
      _exchange(e, _enterEdge(e)!);
      e = _leaveEdge();
      iter++;
    }
    if (removeSubtrees) _reattachSubtrees();
    if (balance) {
      _balance(_normalize());
    } else {
      _normalize();
    }
  }

  void _initialize() {
    final numNodes = graph.nodes.length;
    for (final n in graph.nodes) {
      n._treeNode = false;
    }
    _poID = List.filled(numNodes, 0);
    _lowestPoID = List.filled(numNodes, 0);
    _sources = [];
    var index = 0;
    final theEdges = <NEdge>[];
    for (final node in graph.nodes) {
      node._internalId = index++;
      if (node.incoming.isEmpty) _sources.add(node);
      theEdges.addAll(node.outgoing);
    }
    var counter = 0;
    for (final edge in theEdges) {
      edge._internalId = counter++;
      edge._treeEdge = false;
    }
    _cutvalue = List.filled(theEdges.length, 0);
    _edgeVisited = List.filled(theEdges.length, false);
    _edges = theEdges;
    _treeEdges = <NEdge>{};
    _postOrder = 1;
  }

  void _removeSubtrees() {
    final leafs = <NNode>[
      for (final node in graph.nodes)
        if (_conn(node).length == 1) node,
    ];
    var head = 0;
    while (head < leafs.length) {
      final node = leafs[head++];
      final conn = _conn(node);
      if (conn.isEmpty) continue;
      final edge = conn[0];
      final isOutEdge = node.outgoing.isNotEmpty;
      final other = edge.other(node);
      if (isOutEdge) {
        other.incoming.remove(edge);
      } else {
        other.outgoing.remove(edge);
      }
      if (_conn(other).length == 1) leafs.add(other);
      _subtreeNodesStack.add((node, edge));
      graph.nodes.remove(node);
    }
  }

  void _reattachSubtrees() {
    while (_subtreeNodesStack.isNotEmpty) {
      final (node, edge) = _subtreeNodesStack.removeLast();
      final placed = edge.other(node);
      if (edge.target == node) {
        placed.outgoing.add(edge);
        node.layer = placed.layer + edge.delta;
      } else {
        placed.incoming.add(edge);
        node.layer = placed.layer - edge.delta;
      }
      graph.nodes.add(node);
    }
  }

  void _feasibleTree() {
    _layeringTopologicalNumbering(_sources);
    if (_edges.isEmpty) return;
    _edgeVisited.fillRange(0, _edgeVisited.length, false);
    while (_tightTreeDFS(graph.nodes.first) < graph.nodes.length) {
      final e = _minimalSlack()!;
      var slack = e.target.layer - e.source.layer - e.delta;
      if (e.target._treeNode) slack = -slack;
      for (final node in graph.nodes) {
        if (node._treeNode) node.layer += slack;
      }
      _edgeVisited.fillRange(0, _edgeVisited.length, false);
    }
    _edgeVisited.fillRange(0, _edgeVisited.length, false);
    _postorderTraversal(graph.nodes.first);
    _cutvalues();
  }

  void _layeringTopologicalNumbering(List<NNode> initialRoots) {
    final incident = List.filled(graph.nodes.length, 0);
    for (final node in graph.nodes) {
      incident[node._internalId] += node.incoming.length;
    }
    final roots = List.of(initialRoots);
    var head = 0;
    while (head < roots.length) {
      final node = roots[head++];
      for (final edge in node.outgoing) {
        final target = edge.target;
        final candidate = node.layer + edge.delta;
        if (candidate > target.layer) target.layer = candidate;
        incident[target._internalId]--;
        if (incident[target._internalId] == 0) roots.add(target);
      }
    }
  }

  (int, int) _minimalSpan(NNode node) {
    var minSpanOut = _intMax, minSpanIn = _intMax;
    for (final edge in _conn(node)) {
      final currentSpan = edge.target.layer - edge.source.layer;
      if (edge.target == node && currentSpan < minSpanIn) {
        minSpanIn = currentSpan;
      } else if (currentSpan < minSpanOut) {
        minSpanOut = currentSpan;
      }
    }
    if (minSpanIn == _intMax) minSpanIn = -1;
    if (minSpanOut == _intMax) minSpanOut = -1;
    return (minSpanIn, minSpanOut);
  }

  int _tightTreeDFS(NNode node) {
    var nodeCount = 1;
    node._treeNode = true;
    for (final edge in _conn(node)) {
      if (_edgeVisited[edge._internalId]) continue;
      _edgeVisited[edge._internalId] = true;
      final opposite = edge.other(node);
      if (edge._treeEdge) {
        nodeCount += _tightTreeDFS(opposite);
      } else if (!opposite._treeNode && edge.delta == edge.target.layer - edge.source.layer) {
        edge._treeEdge = true;
        _treeEdges.add(edge);
        nodeCount += _tightTreeDFS(opposite);
      }
    }
    return nodeCount;
  }

  NEdge? _minimalSlack() {
    var minSlack = _intMax;
    NEdge? minSlackEdge;
    for (final edge in _edges) {
      if (edge.source._treeNode != edge.target._treeNode) {
        final curSlack = edge.target.layer - edge.source.layer - edge.delta;
        if (curSlack < minSlack) {
          minSlack = curSlack;
          minSlackEdge = edge;
        }
      }
    }
    return minSlackEdge;
  }

  int _postorderTraversal(NNode node) {
    var lowest = _intMax;
    for (final edge in _conn(node)) {
      if (edge._treeEdge && !_edgeVisited[edge._internalId]) {
        _edgeVisited[edge._internalId] = true;
        final l = _postorderTraversal(edge.other(node));
        if (l < lowest) lowest = l;
      }
    }
    _poID[node._internalId] = _postOrder;
    _lowestPoID[node._internalId] = lowest < _postOrder ? lowest : _postOrder;
    _postOrder++;
    return _lowestPoID[node._internalId];
  }

  bool _isInHead(NNode node, NEdge edge) {
    final s = edge.source._internalId, t = edge.target._internalId, n = _poID[node._internalId];
    if (_lowestPoID[s] <= n && n <= _poID[s] && _lowestPoID[t] <= n && n <= _poID[t]) {
      return !(_poID[s] < _poID[t]);
    }
    return _poID[s] < _poID[t];
  }

  void _cutvalues() {
    final leafs = <NNode>[];
    for (final node in graph.nodes) {
      var treeEdgeCount = 0;
      node._unknownCutvalues.clear();
      for (final edge in _conn(node)) {
        if (edge._treeEdge) {
          node._unknownCutvalues.add(edge);
          treeEdgeCount++;
        }
      }
      if (treeEdgeCount == 1) leafs.add(node);
    }
    for (var node in leafs) {
      while (node._unknownCutvalues.length == 1) {
        final toDetermine = node._unknownCutvalues.first;
        final id = toDetermine._internalId;
        _cutvalue[id] = toDetermine.weight;
        final source = toDetermine.source, target = toDetermine.target;
        for (final edge in _conn(node)) {
          if (edge == toDetermine) continue;
          if (edge._treeEdge) {
            if (source == edge.source || target == edge.target) {
              _cutvalue[id] -= _cutvalue[edge._internalId] - edge.weight;
            } else {
              _cutvalue[id] += _cutvalue[edge._internalId] - edge.weight;
            }
          } else if (node == source) {
            if (edge.source == node) {
              _cutvalue[id] += edge.weight;
            } else {
              _cutvalue[id] -= edge.weight;
            }
          } else {
            if (edge.source == node) {
              _cutvalue[id] -= edge.weight;
            } else {
              _cutvalue[id] += edge.weight;
            }
          }
        }
        source._unknownCutvalues.remove(toDetermine);
        target._unknownCutvalues.remove(toDetermine);
        node = source == node ? toDetermine.target : toDetermine.source;
      }
    }
  }

  NEdge? _leaveEdge() {
    for (final edge in _treeEdges) {
      if (edge._treeEdge && _cutvalue[edge._internalId] < _fuzzyStZero) return edge;
    }
    return null;
  }

  NEdge? _enterEdge(NEdge leave) {
    NEdge? replace;
    var repSlack = _intMax;
    for (final edge in _edges) {
      if (_isInHead(edge.source, leave) && !_isInHead(edge.target, leave)) {
        final slack = edge.target.layer - edge.source.layer - edge.delta;
        if (slack < repSlack) {
          repSlack = slack;
          replace = edge;
        }
      }
    }
    return replace;
  }

  void _exchange(NEdge leave, NEdge enter) {
    leave._treeEdge = false;
    _treeEdges.remove(leave);
    enter._treeEdge = true;
    _treeEdges.add(enter);
    var delta = enter.target.layer - enter.source.layer - enter.delta;
    if (!_isInHead(enter.target, leave)) delta = -delta;
    for (final node in graph.nodes) {
      if (!_isInHead(node, leave)) node.layer += delta;
    }
    _postOrder = 1;
    _edgeVisited.fillRange(0, _edgeVisited.length, false);
    _postorderTraversal(graph.nodes.first);
    _cutvalues();
  }

  List<int> _normalize() {
    var highest = _intMin, lowest = _intMax;
    for (final node in graph.nodes) {
      if (node.layer < lowest) lowest = node.layer;
      if (node.layer > highest) highest = node.layer;
    }
    final filling = List.filled(highest - lowest + 1, 0);
    for (final node in graph.nodes) {
      node.layer -= lowest;
      filling[node.layer]++;
    }
    final previous = previousLayering;
    if (previous != null) {
      var layerID = 0;
      for (final count in previous) {
        filling[layerID++] += count;
        if (filling.length == layerID) break;
      }
    }
    return filling;
  }

  void _balance(List<int> filling) {
    for (final node in graph.nodes) {
      if (node.incoming.length == node.outgoing.length) {
        var newLayer = node.layer;
        final (spanIn, spanOut) = _minimalSpan(node);
        for (var i = node.layer - spanIn + 1; i < node.layer + spanOut; i++) {
          if (filling[i] < filling[newLayer]) newLayer = i;
        }
        if (filling[newLayer] < filling[node.layer]) {
          filling[node.layer]--;
          filling[newLayer]++;
          node.layer = newLayer;
        }
      }
    }
  }
}
