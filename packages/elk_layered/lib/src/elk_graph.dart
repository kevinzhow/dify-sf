// SPDX-License-Identifier: EPL-2.0
// Dart adaptation of Eclipse Layout Kernel 0.11 (Kiel University and contributors).
// See LICENSE and NOTICE at the package root.

/// The layered graph of ELK Layered (org.eclipse.elk.alg.layered.graph), reduced to what the option set of Dify's
/// elk-layout.ts exercises, plus the pieces of the GWT runtime that elkjs results depend on (java.util.Random and
/// the merge sort behind Collections.sort).
library;

enum PortSide { undefined, north, east, south, west }

enum NodeType {
  normal,
  longEdge,
  externalPort,
  northSouthPort,
  label,
  breakingPoint,
  placeholder,
  nonshiftingPlaceholder,
}

enum PortConstraints {
  undefined,
  free,
  fixedSide,
  fixedOrder,
  fixedRatio,
  fixedPos;

  bool get isSideFixed => this == fixedSide || this == fixedOrder || this == fixedRatio || this == fixedPos;
  bool get isOrderFixed => this == fixedOrder || this == fixedRatio || this == fixedPos;
}

class KVector {
  KVector([this.x = 0, this.y = 0]);
  double x;
  double y;
}

class ElkRectangle {
  ElkRectangle([this.x = 0, this.y = 0, this.width = 0, this.height = 0]);
  ElkRectangle.from(ElkRectangle r) : x = r.x, y = r.y, width = r.width, height = r.height;
  double x;
  double y;
  double width;
  double height;
}

/// Margins around a node (LMargin).
class LMargin {
  double top = 0, right = 0, bottom = 0, left = 0;
}

abstract class LGraphElement {
  int id = 0;
}

class LGraph extends LGraphElement {
  final KVector size = KVector();
  final KVector offset = KVector();
  final List<LNode> layerlessNodes = [];
  final List<Layer> layers = [];

  /// The graph padding (default 12 on every side).
  double paddingLeft = 12, paddingTop = 12;

  late final ElkOptions options;
  late final GwtRandom random;
  late final Spacings spacings;
  int maxModelOrderNodes = 0;
  bool cyclic = false;
  // Both upstream properties have the same identifier, so ELK's property map aliases them.
  bool firstTryWithInitialOrder = false;
  // Keep both upstream names: this alias is required for identical sweep state transitions.
  // ignore: unnecessary_getters_setters
  bool get secondTryWithInitialOrder => firstTryWithInitialOrder;
  set secondTryWithInitialOrder(bool value) => firstTryWithInitialOrder = value;

  List<List<LNode>> toNodeArray() => [for (final l in layers) List.of(l.nodes)];
}

class Layer extends LGraphElement {
  Layer(this.graph);
  final LGraph graph;
  final KVector size = KVector();
  final List<LNode> nodes = [];
}

class LNode extends LGraphElement {
  LNode(this.graph);
  final LGraph graph;
  Layer? layer;
  NodeType type = NodeType.normal;
  final List<LPort> ports = [];
  final KVector pos = KVector();
  final KVector size = KVector();
  final LMargin margin = LMargin();
  PortConstraints portConstraints = PortConstraints.undefined;

  /// Index of the input node this node was imported from (normal nodes only).
  int? origin;

  /// The edge a dummy node was created for.
  LEdge? originEdge;
  int? modelOrder;
  LPort? longEdgeSource;
  LPort? longEdgeTarget;
  Map<LNode, int>? targetNodeModelOrder;

  Map<PortSide, (int, int)>? _portSideIndices;
  bool _portSidesCached = false;

  void setLayer(Layer? l) {
    layer?.nodes.remove(this);
    layer = l;
    l?.nodes.add(this);
  }

  void setLayerAt(int index, Layer? l) {
    layer?.nodes.remove(this);
    layer = l;
    l?.nodes.insert(index, this);
  }

  Iterable<LPort> portsOnSide(PortSide side) => ports.where((p) => p.side == side);
  Iterable<LPort> get inputPorts => ports.where((p) => p.incoming.isNotEmpty);
  Iterable<LPort> get outputPorts => ports.where((p) => p.outgoing.isNotEmpty);
  Iterable<LEdge> get incomingEdges => ports.expand((p) => p.incoming);
  Iterable<LEdge> get outgoingEdges => ports.expand((p) => p.outgoing);
  Iterable<LEdge> get connectedEdges => ports.expand((p) => p.connectedEdges);

  /// LNode.getPortSideView: the ports of one side as cached by [cachePortSides].
  List<LPort> portSideView(PortSide side) {
    if (!_portSidesCached) _findPortIndices();
    final indices = _portSideIndices![side];
    return indices == null ? const [] : ports.sublist(indices.$1, indices.$2);
  }

  void cachePortSides() {
    _portSidesCached = true;
    _findPortIndices();
  }

  void _findPortIndices() {
    final map = <PortSide, (int, int)>{};
    var first = 0;
    var currentSide = PortSide.north;
    var i = 0;
    for (; i < ports.length; i++) {
      final side = ports[i].side;
      if (side != currentSide) {
        if (first != i) map[currentSide] = (first, i);
        currentSide = side;
        first = i;
      }
    }
    map[currentSide] = (first, i);
    _portSideIndices = map;
  }

  @override
  String toString() => 'n${type == NodeType.normal ? '' : '(${type.name})'}_${origin ?? id}';
}

class LPort extends LGraphElement {
  LNode? node;
  PortSide side = PortSide.undefined;
  final KVector pos = KVector();
  final KVector size = KVector();
  final KVector anchor = KVector();
  final List<LEdge> incoming = [];
  final List<LEdge> outgoing = [];
  int? portIndex;
  int? modelOrder;
  LNode? longEdgeTargetNode;

  Iterable<LEdge> get connectedEdges => incoming.followedBy(outgoing);
  int get degree => incoming.length + outgoing.length;
  int get netFlow => incoming.length - outgoing.length;
  Iterable<LPort> get predecessorPorts => incoming.map((e) => e.source!);
  Iterable<LPort> get successorPorts => outgoing.map((e) => e.target!);
  Iterable<LPort> get connectedPorts => predecessorPorts.followedBy(successorPorts);

  void setNode(LNode? n) {
    node?.ports.remove(this);
    node = n;
    n?.ports.add(this);
  }

  void setSide(PortSide s) {
    side = s;
    switch (s) {
      case PortSide.north:
        anchor.x = size.x / 2;
        anchor.y = 0;
      case PortSide.east:
        anchor.x = size.x;
        anchor.y = size.y / 2;
      case PortSide.south:
        anchor.x = size.x / 2;
        anchor.y = size.y;
      case PortSide.west:
        anchor.x = 0;
        anchor.y = size.y / 2;
      case PortSide.undefined:
    }
  }

  double get absoluteAnchorY => node!.pos.y + pos.y + anchor.y;
}

class LEdge extends LGraphElement {
  LPort? source;
  LPort? target;
  bool reversed = false;
  int? modelOrder;

  /// SPLINE_ROUTE_START: the spline segments of the edge chain starting at this edge.
  List<Object>? splineRouteStart;

  LEdge copyProps() => LEdge()
    ..reversed = reversed
    ..modelOrder = modelOrder;

  void setSource(LPort? p) {
    source?.outgoing.remove(this);
    source = p;
    p?.outgoing.add(this);
  }

  void setTarget(LPort? p) {
    target?.incoming.remove(this);
    target = p;
    p?.incoming.add(this);
  }

  void setTargetAndInsertAtIndex(LPort p, int index) {
    target?.incoming.remove(this);
    target = p;
    p.incoming.insert(index, this);
  }

  bool get isSelfLoop => source != null && target != null && source!.node != null && source!.node == target!.node;
  bool get isInLayerEdge => !isSelfLoop && source!.node!.layer == target!.node!.layer;

  /// LEdge.reverse with adaptPorts (collector ports never occur here).
  void reverse() {
    final oldSource = source, oldTarget = target;
    setSource(null);
    setTarget(null);
    setSource(oldTarget);
    setTarget(oldSource);
    reversed = !reversed;
  }

  LNode otherNode(LNode n) => n == source!.node ? target!.node! : source!.node!;
}

/// The effective values of the layout options elk-layout.ts sets (and the defaults it relies on).
class ElkOptions {
  const ElkOptions({
    required this.nodeNodeBetweenLayers,
    required this.nodeNode,
    required this.edgeNode,
    required this.edgeEdge,
    required this.portPort,
    required this.greedySwitchHierarchical,
    this.edgeNodeBetweenLayers = 10,
    this.edgeEdgeBetweenLayers = 10,
    this.thoroughness = 10,
  });

  final double nodeNodeBetweenLayers;
  final double nodeNode;
  final double edgeNode;
  final double edgeEdge;
  final double portPort;
  final double edgeNodeBetweenLayers;
  final double edgeEdgeBetweenLayers;
  final int thoroughness;

  /// crossingMinimization.greedySwitchHierarchical.type is TWO_SIDED (root) or OFF (default, child layouts).
  final bool greedySwitchHierarchical;
}

/// options/Spacings.java for the node types that occur (normal and long-edge dummies).
class Spacings {
  Spacings(this.options);
  final ElkOptions options;

  double vertical(NodeType a, NodeType b) {
    final dummyA = a == NodeType.longEdge, dummyB = b == NodeType.longEdge;
    if (dummyA && dummyB) return options.edgeEdge;
    if (dummyA || dummyB) return options.edgeNode;
    return options.nodeNode;
  }

  double horizontal(NodeType a, NodeType b) {
    final dummyA = a == NodeType.longEdge, dummyB = b == NodeType.longEdge;
    if (dummyA && dummyB) return options.edgeEdgeBetweenLayers;
    if (dummyA || dummyB) return options.edgeNodeBetweenLayers;
    return options.nodeNodeBetweenLayers;
  }
}

/// java.util.Random exactly as GWT emulates it (48-bit LCG split into two 24-bit halves held in doubles).
class GwtRandom {
  GwtRandom(int seed) {
    _setSeedParts((seed ~/ 16777216) % 16777216, seed % 16777216);
  }

  static const double _two24 = 16777216;
  static const double _twoM24 = 5.9604644775390625E-8;
  double _hi = 0, _lo = 0;

  void _setSeedParts(int hi, int lo) {
    _hi = (hi ^ 1502).toDouble();
    _lo = (lo ^ 15525485).toDouble();
  }

  /// setSeed(long) for a seed given as its high and low 32-bit words (as produced by [nextLong]).
  void setSeed((int, int) seed) {
    final (high, low) = seed;
    _setSeedParts(((low ~/ 16777216) | ((high % 65536) << 8)) % 16777216, low % 16777216);
  }

  double _next(int bits) {
    var hi = _hi * 15525485 + _lo * 1502;
    var lo = _lo * 15525485 + 11;
    final carry = (lo * _twoM24).floorToDouble();
    hi += carry;
    lo -= carry * _two24;
    hi %= _two24;
    _hi = hi;
    _lo = lo;
    if (bits <= 24) return (_hi * _pow2(bits - 24)).floorToDouble();
    final h = _hi * (1 << (bits - 24));
    final l = (_lo * _pow2(bits - 48)).floorToDouble();
    var d = h + l;
    if (d >= 2147483648) d -= 4294967296;
    return d;
  }

  static double _pow2(int e) {
    var r = 1.0;
    if (e < 0) {
      for (var i = 0; i < -e; i++) {
        r *= 0.5;
      }
    } else {
      for (var i = 0; i < e; i++) {
        r *= 2;
      }
    }
    return r;
  }

  bool nextBoolean() => _next(1) != 0;
  double nextFloat() => _next(24) * _twoM24;
  double nextDouble() => _next(26) * 1.4901161193847656E-8 + _next(27) * 1.1102230246251565E-16;

  int nextInt(int n) {
    if ((n & -n) == n) return (n * _next(31) * 4.6566128730773926E-10).truncate();
    return (_next(31) % n).truncate();
  }

  /// nextLong as (high word, low word as unsigned 32-bit), enough for [setSeed].
  (int, int) nextLong() {
    final a = _next(32).toInt(), b = _next(32).toInt();
    final low = b < 0 ? b + 4294967296 : b;
    final high = (b < 0 ? a - 1 : a) % 4294967296;
    return (high, low);
  }
}

/// Collections.sort as compiled by GWT: a stable merge sort with insertion sort below 7 elements. Some ELK
/// comparators are not total orders, so the exact algorithm matters.
void gwtSort<T>(List<T> list, int Function(T a, T b) compare) {
  if (list.length < 2) return;
  final temp = List<T>.of(list);
  _mergeSort(temp, list, 0, list.length, 0, compare);
}

void _mergeSort<T>(List<T> temp, List<T> array, int low, int high, int ofs, int Function(T, T) comp) {
  final length = high - low;
  if (length < 7) {
    for (var i = low + 1; i < high; ++i) {
      for (var j = i; j > low && comp(array[j - 1], array[j]) > 0; --j) {
        final t = array[j];
        array[j] = array[j - 1];
        array[j - 1] = t;
      }
    }
    return;
  }
  var tempLow = low + ofs;
  final tempHigh = high + ofs;
  final tempMid = tempLow + ((tempHigh - tempLow) >> 1);
  _mergeSort(array, temp, tempLow, tempMid, -ofs, comp);
  _mergeSort(array, temp, tempMid, tempHigh, -ofs, comp);
  if (comp(temp[tempMid - 1], temp[tempMid]) <= 0) {
    while (low < high) {
      array[low++] = temp[tempLow++];
    }
    return;
  }
  var srcLow = tempLow, topIdx = tempMid;
  var destLow = low;
  while (destLow < high) {
    if (topIdx >= tempHigh || srcLow < tempMid && comp(temp[srcLow], temp[topIdx]) <= 0) {
      array[destLow++] = temp[srcLow++];
    } else {
      array[destLow++] = temp[topIdx++];
    }
  }
}

/// Double.compare semantics (-0.0 < 0.0, NaN largest).
int compareDouble(double a, double b) => a.compareTo(b);
