// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// Port placement (LabelAndNodeSizeProcessor with fixed node sizes, no labels), node margins
/// (InnermostNodeMarginCalculator) and phase 4 of ELK Layered, the Brandes-Köpf node placer (BALANCED,
/// favorStraightEdges, edge straightening IMPROVE_STRAIGHTNESS).
library;

import 'dart:math' as math;

import 'elk_graph.dart';

// ---------------------------------------------------------------------------------------------------------------
// LabelAndNodeSizeProcessor: NodeLabelAndSizeCalculator for normal nodes. Node sizes are fixed (empty size
// constraints), there are no labels, ports have size 0 and only east/west sides, port alignment is DISTRIBUTED and
// the surrounding port margins are 0, so the inside port label cells span the full node height.

void labelAndNodeSizeProcessor(LGraph graph) {
  final spacing = graph.options.portPort;
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      if (node.type != NodeType.normal) continue;
      for (var i = 0; i < node.ports.length; i++) {
        node.ports[i].id = i;
      }
      if (node.portConstraints == PortConstraints.fixedPos || node.portConstraints == PortConstraints.fixedRatio) {
        throw UnsupportedError('Fixed port positions are not supported');
      }
      final east = node.ports.where((p) => p.side == PortSide.east).toList();
      final west = node.ports.where((p) => p.side == PortSide.west).toList().reversed.toList();
      _placeVerticalFreePorts(node, east, spacing);
      _placeVerticalFreePorts(node, west, spacing);
    }
  }
}

void _placeVerticalFreePorts(LNode node, List<LPort> ports, double portPortSpacing) {
  if (ports.isEmpty) return;
  // VerticalPortPlacementSizeCalculator.calculateVerticalNodeSizeRequiredByFreePorts
  var calculated = 0.0;
  for (var i = 0; i < ports.length; i++) {
    calculated += 0.0 + ports[i].size.y + 0.0;
    if (i < ports.length - 1) calculated += portPortSpacing;
  }
  calculated += 2 * portPortSpacing;

  final availableSpace = node.size.y - 0.0 - 0.0;
  var currentYPos = 0.0 + 0.0;
  var spaceBetweenPorts = portPortSpacing;
  final nodeWidth = node.size.x;
  var distributed = true;
  if (ports.length == 1) {
    calculated = calculated - 2 * portPortSpacing;
    distributed = false;
  }
  if (availableSpace < calculated) {
    if (distributed) {
      spaceBetweenPorts += (availableSpace - calculated) / (ports.length + 1);
      currentYPos += spaceBetweenPorts;
    } else {
      spaceBetweenPorts += (availableSpace - calculated) / (ports.length - 1);
    }
  } else if (!distributed) {
    currentYPos += (availableSpace - calculated) / 2;
  } else {
    final additional = (availableSpace - calculated) / (ports.length + 1);
    spaceBetweenPorts += math.max(0, additional);
    currentYPos += spaceBetweenPorts;
  }
  for (final port in ports) {
    port.pos.x = port.side == PortSide.west ? -port.size.x : nodeWidth;
    port.pos.y = currentYPos + 0.0;
    currentYPos += 0.0 + port.size.y + 0.0 + spaceBetweenPorts;
  }
}

// ---------------------------------------------------------------------------------------------------------------
// InnermostNodeMarginCalculator (ports only; there are no labels)

void innermostNodeMarginCalculator(LGraph graph) {
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      var bx = node.pos.x, by = node.pos.y, bw = node.size.x, bh = node.size.y;
      for (final port in node.ports) {
        final ex = port.pos.x + node.pos.x, ey = port.pos.y + node.pos.y;
        var x1 = math.min(bx, ex), y1 = math.min(by, ey);
        var x2 = math.max(bx + bw, ex + port.size.x), y2 = math.max(by + bh, ey + port.size.y);
        if (x2 < x1) (x1, x2) = (x2, x1);
        if (y2 < y1) (y1, y2) = (y2, y1);
        bx = x1;
        by = y1;
        bw = x2 - x1;
        bh = y2 - y1;
      }
      node.margin
        ..top = math.max(0, node.pos.y - by)
        ..bottom = math.max(0, by + bh - (node.pos.y + node.size.y))
        ..left = math.max(0, node.pos.x - bx)
        ..right = math.max(0, bx + bw - (node.pos.x + node.size.x));
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------
// BKNodePlacer

enum _VDir { down, up }

enum _HDir { right, left }

class _Neighborhood {
  _Neighborhood(LGraph graph) {
    for (final layer in graph.layers) {
      nodeCount += layer.nodes.length;
    }
    layerIndex = List.filled(graph.layers.length, 0);
    nodeIndex = List.filled(nodeCount, 0);
    var lId = 0, lIndex = 0, nId = 0;
    for (final l in graph.layers) {
      l.id = lId++;
      layerIndex[l.id] = lIndex++;
      var nIndex = 0;
      for (final n in l.nodes) {
        n.id = nId++;
        nodeIndex[n.id] = nIndex++;
      }
    }
    int cmp((LNode, LEdge) a, (LNode, LEdge) b) => (nodeIndex[a.$1.id] - nodeIndex[b.$1.id]).sign;
    for (final l in graph.layers) {
      for (final n in l.nodes) {
        final result = <(LNode, LEdge)>[
          for (final edge in n.incomingEdges)
            if (!edge.isSelfLoop && !edge.isInLayerEdge) (edge.source!.node!, edge),
        ];
        gwtSort(result, cmp);
        leftNeighbors.add(result);
      }
    }
    for (final l in graph.layers) {
      for (final n in l.nodes) {
        final result = <(LNode, LEdge)>[
          for (final edge in n.outgoingEdges)
            if (!edge.isSelfLoop && !edge.isInLayerEdge) (edge.target!.node!, edge),
        ];
        gwtSort(result, cmp);
        rightNeighbors.add(result);
      }
    }
  }

  int nodeCount = 0;
  late final List<int> layerIndex;
  late final List<int> nodeIndex;
  final List<List<(LNode, LEdge)>> leftNeighbors = [];
  final List<List<(LNode, LEdge)>> rightNeighbors = [];
}

class _AlignedLayout {
  _AlignedLayout(this.graph, int n, this.vdir, this.hdir)
    : root = List.filled(n, null),
      blockSize = List.filled(n, null),
      align = List.filled(n, null),
      innerShift = List.filled(n, null),
      sink = List.filled(n, null),
      shift = List.filled(n, null),
      y = List.filled(n, null),
      su = List.filled(n, false),
      od = List.filled(n, true);

  final LGraph graph;
  final _VDir? vdir;
  final _HDir? hdir;
  final List<LNode?> root;
  final List<double?> blockSize;
  final List<LNode?> align;
  final List<double?> innerShift;
  final List<LNode?> sink;
  final List<double?> shift;
  final List<double?> y;
  final List<bool> su;
  final List<bool> od;

  double layoutSize() {
    var min = double.infinity, max = double.negativeInfinity;
    for (final layer in graph.layers) {
      for (final n in layer.nodes) {
        final yMin = y[n.id]!;
        final yMax = yMin + blockSize[root[n.id]!.id]!;
        min = math.min(min, yMin);
        max = math.max(max, yMax);
      }
    }
    return max - min;
  }

  double calculateDelta(LPort src, LPort tgt) {
    final srcPos = y[src.node!.id]! + innerShift[src.node!.id]! + src.pos.y + src.anchor.y;
    final tgtPos = y[tgt.node!.id]! + innerShift[tgt.node!.id]! + tgt.pos.y + tgt.anchor.y;
    return tgtPos - srcPos;
  }

  void shiftBlock(LNode rootNode, double delta) {
    var current = rootNode;
    do {
      y[current.id] = y[current.id]! + delta;
      current = align[current.id]!;
    } while (current != rootNode);
  }

  double checkSpaceAbove(LNode blockRoot, double delta, _Neighborhood ni) {
    var available = delta;
    var current = blockRoot;
    do {
      current = align[current.id]!;
      final minYCurrent = getMinY(current);
      final idx = ni.nodeIndex[current.id];
      if (idx > 0) {
        final neighbor = current.layer!.nodes[idx - 1];
        final maxYNeighbor = getMaxY(neighbor);
        available = math.min(
          available,
          minYCurrent - (maxYNeighbor + graph.spacings.vertical(current.type, neighbor.type)),
        );
      }
    } while (blockRoot != current);
    return available;
  }

  double checkSpaceBelow(LNode blockRoot, double delta, _Neighborhood ni) {
    var available = delta;
    var current = blockRoot;
    do {
      current = align[current.id]!;
      final maxYCurrent = getMaxY(current);
      final idx = ni.nodeIndex[current.id];
      if (idx < current.layer!.nodes.length - 1) {
        final neighbor = current.layer!.nodes[idx + 1];
        final minYNeighbor = getMinY(neighbor);
        available = math.min(
          available,
          minYNeighbor - (maxYCurrent + graph.spacings.vertical(current.type, neighbor.type)),
        );
      }
    } while (blockRoot != current);
    return available;
  }

  double getMinY(LNode n) => y[root[n.id]!.id]! + innerShift[n.id]! - n.margin.top;
  double getMaxY(LNode n) => y[root[n.id]!.id]! + innerShift[n.id]! + n.size.y + n.margin.bottom;
}

void bkNodePlacer(LGraph graph) {
  final ni = _Neighborhood(graph);
  final markedEdges = <LEdge>{};
  _markConflicts(graph, ni, markedEdges);
  final layouts = [
    _AlignedLayout(graph, ni.nodeCount, _VDir.down, _HDir.right),
    _AlignedLayout(graph, ni.nodeCount, _VDir.up, _HDir.right),
    _AlignedLayout(graph, ni.nodeCount, _VDir.down, _HDir.left),
    _AlignedLayout(graph, ni.nodeCount, _VDir.up, _HDir.left),
  ];
  for (final bal in layouts) {
    _verticalAlignment(graph, ni, bal, markedEdges);
    _insideBlockShift(graph, bal);
  }
  final compactor = _BKCompactor(graph, ni);
  for (final bal in layouts) {
    compactor.horizontalCompaction(bal);
  }
  _AlignedLayout? chosen;
  final balanced = _createBalancedLayout(graph, layouts, ni.nodeCount);
  if (_checkOrderConstraint(graph, balanced)) chosen = balanced;
  if (chosen == null) {
    for (final bal in layouts) {
      if (_checkOrderConstraint(graph, bal)) {
        if (chosen == null || chosen.layoutSize() > bal.layoutSize()) chosen = bal;
      }
    }
  }
  chosen ??= layouts[0];
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      node.pos.y = chosen.y[node.id]! + chosen.innerShift[node.id]!;
    }
  }
}

bool _incidentToInnerSegment(LNode node, int layer1, int layer2, _Neighborhood ni) {
  if (node.type == NodeType.longEdge) {
    for (final edge in node.incomingEdges) {
      final source = edge.source!.node!;
      if (source.type == NodeType.longEdge &&
          ni.layerIndex[source.layer!.id] == layer2 &&
          ni.layerIndex[node.layer!.id] == layer1) {
        return true;
      }
    }
  }
  return false;
}

void _markConflicts(LGraph graph, _Neighborhood ni, Set<LEdge> markedEdges) {
  final numberOfLayers = graph.layers.length;
  if (numberOfLayers < 3) return;
  final layerSize = [for (final l in graph.layers) l.nodes.length];
  for (var i = 1; i < numberOfLayers - 1; i++) {
    final currentLayer = graph.layers[i + 1];
    var k0 = 0, l = 0;
    for (var l1 = 0; l1 < layerSize[i + 1]; l1++) {
      final vli = currentLayer.nodes[l1];
      if (l1 == layerSize[i + 1] - 1 || _incidentToInnerSegment(vli, i + 1, i, ni)) {
        var k1 = layerSize[i] - 1;
        if (_incidentToInnerSegment(vli, i + 1, i, ni)) k1 = ni.nodeIndex[ni.leftNeighbors[vli.id][0].$1.id];
        while (l <= l1) {
          final vl = currentLayer.nodes[l];
          if (!_incidentToInnerSegment(vl, i + 1, i, ni)) {
            for (final upper in ni.leftNeighbors[vl.id]) {
              final k = ni.nodeIndex[upper.$1.id];
              if (k < k0 || k > k1) markedEdges.add(upper.$2);
            }
          }
          l++;
        }
        k0 = k1;
      }
    }
  }
}

void _verticalAlignment(LGraph graph, _Neighborhood ni, _AlignedLayout bal, Set<LEdge> markedEdges) {
  for (final layer in graph.layers) {
    for (final v in layer.nodes) {
      bal.root[v.id] = v;
      bal.align[v.id] = v;
      bal.innerShift[v.id] = 0.0;
    }
  }
  final layers = bal.hdir == _HDir.left ? graph.layers.reversed : graph.layers;
  for (final layer in layers) {
    var r = -1;
    var nodes = layer.nodes as Iterable<LNode>;
    if (bal.vdir == _VDir.up) {
      r = 2147483647;
      nodes = layer.nodes.reversed;
    }
    for (final v in nodes) {
      final neighbors = bal.hdir == _HDir.left ? ni.rightNeighbors[v.id] : ni.leftNeighbors[v.id];
      if (neighbors.isEmpty) continue;
      final d = neighbors.length;
      final low = ((d + 1.0) / 2.0).floor() - 1;
      final high = ((d + 1.0) / 2.0).ceil() - 1;
      void tryAlign(int m) {
        if (bal.align[v.id] != v) return;
        final (u, edge) = neighbors[m];
        final ok = bal.vdir == _VDir.up ? r > ni.nodeIndex[u.id] : r < ni.nodeIndex[u.id];
        if (!markedEdges.contains(edge) && ok) {
          bal.align[u.id] = v;
          bal.root[v.id] = bal.root[u.id];
          bal.align[v.id] = bal.root[v.id];
          bal.od[bal.root[v.id]!.id] &= v.type == NodeType.longEdge;
          r = ni.nodeIndex[u.id];
        }
      }

      if (bal.vdir == _VDir.up) {
        for (var m = high; m >= low; m--) {
          tryAlign(m);
        }
      } else {
        for (var m = low; m <= high; m++) {
          tryAlign(m);
        }
      }
    }
  }
}

LEdge? _getEdge(LNode source, LNode target) {
  for (final edge in source.connectedEdges) {
    if (edge.target!.node == target || edge.source!.node == target) return edge;
  }
  return null;
}

void _insideBlockShift(LGraph graph, _AlignedLayout bal) {
  final blocks = <LNode, List<LNode>>{};
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      blocks.putIfAbsent(bal.root[node.id]!, () => []).add(node);
    }
  }
  for (final root in blocks.keys) {
    var spaceAbove = root.margin.top;
    var spaceBelow = root.size.y + root.margin.bottom;
    bal.innerShift[root.id] = 0.0;
    var current = root;
    LNode next;
    while ((next = bal.align[current.id]!) != root) {
      final edge = _getEdge(current, next)!;
      final double portPosDiff;
      if (bal.hdir == _HDir.left) {
        portPosDiff = edge.target!.pos.y + edge.target!.anchor.y - edge.source!.pos.y - edge.source!.anchor.y;
      } else {
        portPosDiff = edge.source!.pos.y + edge.source!.anchor.y - edge.target!.pos.y - edge.target!.anchor.y;
      }
      final nextInnerShift = bal.innerShift[current.id]! + portPosDiff;
      bal.innerShift[next.id] = nextInnerShift;
      spaceAbove = math.max(spaceAbove, next.margin.top - nextInnerShift);
      spaceBelow = math.max(spaceBelow, nextInnerShift + next.size.y + next.margin.bottom);
      current = next;
    }
    current = root;
    do {
      bal.innerShift[current.id] = bal.innerShift[current.id]! + spaceAbove;
      current = bal.align[current.id]!;
    } while (current != root);
    bal.blockSize[root.id] = spaceAbove + spaceBelow;
  }
}

class _ClassNode {
  double? classShift;
  late LNode node;
  final List<(_ClassNode, double)> outgoing = [];
  int indegree = 0;

  void addEdge(_ClassNode target, double separation) {
    target.indegree++;
    outgoing.add((target, separation));
  }
}

class _BKCompactor {
  _BKCompactor(this.graph, this.ni);
  final LGraph graph;
  final _Neighborhood ni;
  final Map<LNode, _ClassNode> _sinkNodes = {};
  late _AlignedLayout _bal;

  // SimpleThresholdStrategy state
  final Set<LNode> _blockFinished = {};
  final List<_Postprocessable> _queue = [];
  final List<_Postprocessable> _stack = [];

  void horizontalCompaction(_AlignedLayout bal) {
    _bal = bal;
    for (final layer in graph.layers) {
      for (final node in layer.nodes) {
        bal.sink[node.id] = node;
        bal.shift[node.id] = bal.vdir == _VDir.up ? double.negativeInfinity : double.infinity;
      }
    }
    _sinkNodes.clear();
    final layers = bal.hdir == _HDir.left ? graph.layers.reversed.toList() : graph.layers;
    _blockFinished.clear();
    _queue.clear();
    _stack.clear();
    bal.y.fillRange(0, bal.y.length, null);
    for (final layer in layers) {
      final nodes = bal.vdir == _VDir.up ? layer.nodes.reversed : layer.nodes;
      for (final v in nodes) {
        if (bal.root[v.id] == v) _placeBlock(v);
      }
    }
    _placeClasses();
    for (final layer in layers) {
      for (final v in layer.nodes) {
        bal.y[v.id] = bal.y[bal.root[v.id]!.id];
        if (v == bal.root[v.id]) {
          final sinkShift = bal.shift[bal.sink[v.id]!.id]!;
          if ((bal.vdir == _VDir.up && sinkShift > double.negativeInfinity) ||
              (bal.vdir == _VDir.down && sinkShift < double.infinity)) {
            bal.y[v.id] = bal.y[v.id]! + sinkShift;
          }
        }
      }
    }
    _postProcess();
  }

  void _placeBlock(LNode root) {
    final bal = _bal;
    if (bal.y[root.id] != null) return;
    var isInitialAssignment = true;
    bal.y[root.id] = 0.0;
    var currentNode = root;
    var thresh = bal.vdir == _VDir.down ? double.negativeInfinity : double.infinity;
    do {
      final currentIndexInLayer = ni.nodeIndex[currentNode.id];
      final currentLayerSize = currentNode.layer!.nodes.length;
      if ((bal.vdir == _VDir.down && currentIndexInLayer > 0) ||
          (bal.vdir == _VDir.up && currentIndexInLayer < currentLayerSize - 1)) {
        final neighbor = bal.vdir == _VDir.up
            ? currentNode.layer!.nodes[currentIndexInLayer + 1]
            : currentNode.layer!.nodes[currentIndexInLayer - 1];
        final neighborRoot = bal.root[neighbor.id]!;
        _placeBlock(neighborRoot);
        thresh = _calculateThreshold(thresh, root, currentNode);
        if (bal.sink[root.id] == root) bal.sink[root.id] = bal.sink[neighborRoot.id];
        if (bal.sink[root.id] == bal.sink[neighborRoot.id]) {
          final spacing = graph.spacings.vertical(currentNode.type, neighbor.type);
          if (bal.vdir == _VDir.up) {
            final currentBlockPosition = bal.y[root.id]!;
            final newPosition =
                bal.y[neighborRoot.id]! +
                bal.innerShift[neighbor.id]! -
                neighbor.margin.top -
                spacing -
                currentNode.margin.bottom -
                currentNode.size.y -
                bal.innerShift[currentNode.id]!;
            if (isInitialAssignment) {
              isInitialAssignment = false;
              bal.y[root.id] = math.min(newPosition, thresh);
            } else {
              bal.y[root.id] = math.min(currentBlockPosition, math.min(newPosition, thresh));
            }
          } else {
            final currentBlockPosition = bal.y[root.id]!;
            final newPosition =
                bal.y[neighborRoot.id]! +
                bal.innerShift[neighbor.id]! +
                neighbor.size.y +
                neighbor.margin.bottom +
                spacing +
                currentNode.margin.top -
                bal.innerShift[currentNode.id]!;
            if (isInitialAssignment) {
              isInitialAssignment = false;
              bal.y[root.id] = math.max(newPosition, thresh);
            } else {
              bal.y[root.id] = math.max(currentBlockPosition, math.max(newPosition, thresh));
            }
          }
        } else {
          final spacing = graph.options.nodeNode;
          final sinkNode = _classNode(bal.sink[root.id]!);
          final neighborSink = _classNode(bal.sink[neighborRoot.id]!);
          if (bal.vdir == _VDir.up) {
            final requiredSpace =
                bal.y[root.id]! +
                bal.innerShift[currentNode.id]! +
                currentNode.size.y +
                currentNode.margin.bottom +
                spacing -
                (bal.y[neighborRoot.id]! + bal.innerShift[neighbor.id]! - neighbor.margin.top);
            sinkNode.addEdge(neighborSink, requiredSpace);
          } else {
            final requiredSpace =
                bal.y[root.id]! +
                bal.innerShift[currentNode.id]! -
                currentNode.margin.top -
                bal.y[neighborRoot.id]! -
                bal.innerShift[neighbor.id]! -
                neighbor.size.y -
                neighbor.margin.bottom -
                spacing;
            sinkNode.addEdge(neighborSink, requiredSpace);
          }
        }
      } else {
        thresh = _calculateThreshold(thresh, root, currentNode);
      }
      currentNode = bal.align[currentNode.id]!;
    } while (currentNode != root);
    _blockFinished.add(root);
  }

  _ClassNode _classNode(LNode sinkNode) => _sinkNodes.putIfAbsent(sinkNode, () => _ClassNode()..node = sinkNode);

  void _placeClasses() {
    final bal = _bal;
    final sinks = <_ClassNode>[
      for (final n in _sinkNodes.values)
        if (n.indegree == 0) n,
    ];
    var head = 0;
    while (head < sinks.length) {
      final n = sinks[head++];
      n.classShift ??= 0.0;
      for (final (target, separation) in n.outgoing) {
        if (target.classShift == null) {
          target.classShift = n.classShift! + separation;
        } else if (bal.vdir == _VDir.down) {
          target.classShift = math.min(target.classShift!, n.classShift! + separation);
        } else {
          target.classShift = math.max(target.classShift!, n.classShift! + separation);
        }
        target.indegree--;
        if (target.indegree == 0) sinks.add(target);
      }
    }
    for (final n in _sinkNodes.values) {
      bal.shift[n.node.id] = n.classShift;
    }
  }

  // --- SimpleThresholdStrategy

  double _calculateThreshold(double oldThresh, LNode blockRoot, LNode currentNode) {
    final isRoot = blockRoot == currentNode;
    final isLast = _bal.align[currentNode.id] == blockRoot;
    if (!(isRoot || isLast)) return oldThresh;
    var t = oldThresh;
    if (isRoot) t = _getBound(blockRoot, true);
    if (t.isInfinite && isLast) t = _getBound(currentNode, false);
    return t;
  }

  _Postprocessable _pickEdge(_Postprocessable pp) {
    final bal = _bal;
    final Iterable<LEdge> edges;
    if (pp.isRoot) {
      edges = bal.hdir == _HDir.right ? pp.free.incomingEdges : pp.free.outgoingEdges;
    } else {
      edges = bal.hdir == _HDir.left ? pp.free.incomingEdges : pp.free.outgoingEdges;
    }
    var hasEdges = false;
    for (final e in edges) {
      final onlyDummies = bal.od[bal.root[pp.free.id]!.id];
      if (!onlyDummies && e.isInLayerEdge) continue;
      if (bal.su[bal.root[pp.free.id]!.id]) continue;
      hasEdges = true;
      if (_blockFinished.contains(bal.root[e.otherNode(pp.free).id])) {
        pp.hasEdges = true;
        pp.edge = e;
        return pp;
      }
    }
    pp.hasEdges = hasEdges;
    pp.edge = null;
    return pp;
  }

  double _getBound(LNode blockNode, bool isRoot) {
    final bal = _bal;
    final invalid = bal.vdir == _VDir.up ? double.infinity : double.negativeInfinity;
    final pick = _pickEdge(_Postprocessable(blockNode, isRoot));
    if (pick.edge == null && pick.hasEdges) {
      _queue.add(pick);
      return invalid;
    } else if (pick.edge != null) {
      final left = pick.edge!.source!, right = pick.edge!.target!;
      final double threshold;
      if (isRoot) {
        final rootPort = bal.hdir == _HDir.right ? right : left;
        final otherPort = bal.hdir == _HDir.right ? left : right;
        final otherRoot = bal.root[otherPort.node!.id]!;
        threshold =
            bal.y[otherRoot.id]! +
            bal.innerShift[otherPort.node!.id]! +
            otherPort.pos.y +
            otherPort.anchor.y -
            bal.innerShift[rootPort.node!.id]! -
            rootPort.pos.y -
            rootPort.anchor.y;
      } else {
        final rootPort = bal.hdir == _HDir.left ? right : left;
        final otherPort = bal.hdir == _HDir.left ? left : right;
        threshold =
            bal.y[bal.root[otherPort.node!.id]!.id]! +
            bal.innerShift[otherPort.node!.id]! +
            otherPort.pos.y +
            otherPort.anchor.y -
            bal.innerShift[rootPort.node!.id]! -
            rootPort.pos.y -
            rootPort.anchor.y;
      }
      bal.su[bal.root[left.node!.id]!.id] = true;
      bal.su[bal.root[right.node!.id]!.id] = true;
      return threshold;
    }
    return invalid;
  }

  void _postProcess() {
    final bal = _bal;
    var head = 0;
    while (head < _queue.length) {
      final pp = _queue[head++];
      final pick = _pickEdge(pp);
      if (pick.edge == null) continue;
      final onlyDummies = bal.od[bal.root[pp.free.id]!.id];
      if (!onlyDummies && pick.edge!.isInLayerEdge) continue;
      if (!_process(pp)) _stack.add(pp);
    }
    _queue.clear();
    while (_stack.isNotEmpty) {
      _process(_stack.removeLast());
    }
  }

  bool _process(_Postprocessable pp) {
    final bal = _bal;
    final edge = pp.edge!;
    final fix = edge.source!.node == pp.free ? edge.target! : edge.source!;
    final block = edge.source!.node == pp.free ? edge.source! : edge.target!;
    final delta = bal.calculateDelta(fix, block);
    if (delta > 0 && delta < double.maxFinite) {
      final available = bal.checkSpaceAbove(block.node!, delta, ni);
      bal.shiftBlock(block.node!, -available);
      return available > 0;
    } else if (delta < 0 && -delta < double.maxFinite) {
      final available = bal.checkSpaceBelow(block.node!, -delta, ni);
      bal.shiftBlock(block.node!, available);
      return available > 0;
    }
    return false;
  }
}

class _Postprocessable {
  _Postprocessable(this.free, this.isRoot);
  final LNode free;
  final bool isRoot;
  bool hasEdges = false;
  LEdge? edge;
}

_AlignedLayout _createBalancedLayout(LGraph graph, List<_AlignedLayout> layouts, int nodeCount) {
  final n = layouts.length;
  final balanced = _AlignedLayout(graph, nodeCount, null, null);
  final width = List.filled(n, 0.0);
  final min = List.filled(n, 2147483647.0);
  final max = List.filled(n, -2147483648.0);
  var minWidthLayout = 0;
  for (var i = 0; i < n; i++) {
    final bal = layouts[i];
    width[i] = bal.layoutSize();
    if (width[minWidthLayout] > width[i]) minWidthLayout = i;
    for (final l in graph.layers) {
      for (final node in l.nodes) {
        final nodePosY = bal.y[node.id]! + bal.innerShift[node.id]!;
        min[i] = math.min(min[i], nodePosY);
        max[i] = math.max(max[i], nodePosY + node.size.y);
      }
    }
  }
  final shift = List.filled(n, 0.0);
  for (var i = 0; i < n; i++) {
    shift[i] = layouts[i].vdir == _VDir.down ? min[minWidthLayout] - min[i] : max[minWidthLayout] - max[i];
  }
  final calculatedYs = List.filled(n, 0.0);
  for (final layer in graph.layers) {
    for (final node in layer.nodes) {
      for (var i = 0; i < n; i++) {
        calculatedYs[i] = layouts[i].y[node.id]! + layouts[i].innerShift[node.id]! + shift[i];
      }
      calculatedYs.sort();
      balanced.y[node.id] = (calculatedYs[1] + calculatedYs[2]) / 2.0;
      balanced.innerShift[node.id] = 0.0;
    }
  }
  return balanced;
}

bool _checkOrderConstraint(LGraph graph, _AlignedLayout bal) {
  for (final layer in graph.layers) {
    var pos = double.negativeInfinity;
    for (final node in layer.nodes) {
      final top = bal.y[node.id]! + bal.innerShift[node.id]! - node.margin.top;
      final bottom = bal.y[node.id]! + bal.innerShift[node.id]! + node.size.y + node.margin.bottom;
      if (top > pos && bottom > pos) {
        pos = bal.y[node.id]! + bal.innerShift[node.id]! + node.size.y + node.margin.bottom;
      } else {
        return false;
      }
    }
  }
  return true;
}
