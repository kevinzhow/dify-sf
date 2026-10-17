// Canvas spike: the same workflow graph drawn two ways, measured with the same script.
//   MODE=scene    Flutter Scene: each node card is a WidgetComponent (captured only when it changes), edges are one
//                 GPU-expanded line batch, pan/zoom moves an orthographic camera.
//   MODE=widgets  Plain widgets, optimized: one layer transform for pan/zoom, a RepaintBoundary per card, only cards
//                 inside the viewport are built, edges in one cached picture.
// Run (profile, Flutter GPU on):
//   MODE=scene NODES=500 build/linux/x64/profile/bundle/scene_canvas   (after flutter build linux --profile)
// With BENCH=true (default) it runs pan / zoom / edits / drag / sharpen phases, prints one `PERF {json}` line per
// phase plus a summary, saves screenshots to $SHOTS (default /tmp/scene_canvas), and exits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:vector_math/vector_math.dart' as vm;

const kNodeW = 220.0;
const kNodeH = 78.0;
// Environment variables override the dart-defines, so one build covers every configuration.
final kMode = Platform.environment['MODE'] ?? const String.fromEnvironment('MODE', defaultValue: 'scene');
final kNodes = int.parse(Platform.environment['NODES'] ?? const String.fromEnvironment('NODES', defaultValue: '500'));
String env(String k, String d) => Platform.environment[k] ?? d;
// Isolation switches (scene mode): EDGES=0 / CARDS=0 drop that layer, AA=none|fxaa|msaa, PHASES=pan,zoom,...
final kEdges = env('EDGES', '1') == '1';
final kCards = env('CARDS', '1') == '1';
final kAA = env('AA', '');
// SEM=0 keeps the hosted cards out of the semantics tree (a canvas would expose its own summary instead).
final kSem = env('SEM', '1') == '1';
// Debug switches for card rendering: POLICY=manual|every, DREF=0 (lit material), RECAP=<ms> (capture all again later).
final kPolicy = env('POLICY', 'manual');
final kDref = env('DREF', '1') == '1';
final kRecap = int.parse(env('RECAP', '0'));
// CULL=1 (default): only cards near the view hold a WidgetComponent (and its texture); the rest show a plain
// placeholder quad. CULL=0: every card holds one for the whole run.
final kCull = env('CULL', '1') == '1';
// Zoom-back tuning: CAP_BUDGET captures started per frame; DENSITY=zoom captures at the zoom's density (below 1x
// too, cheaper when zoomed out); KEEP=<n> keeps captures beyond the drop margin while fewer than n are held;
// PREDICT=1 widens the capture margin to where a zoom-out is heading.
final kCapBudget = int.parse(env('CAP_BUDGET', '24'));
final kDensityZoom = env('DENSITY', 'fixed') == 'zoom';
final kKeep = int.parse(env('KEEP', '0'));
final kPredict = env('PREDICT', '0') == '1';
// OVERVIEW=1: every card also gets a half-density capture, made in the background a few per frame (nearest first)
// and kept as its placeholder's texture; at or below 0.5x zoom no full-density captures are started.
final kOverview = env('OVERVIEW', '0') == '1';
final kOverviewBudget = int.parse(env('OV_BUDGET', '6'));
final kPhases = env('PHASES', 'pan,zoom,edits,drag,sharpen').split(',').toSet();
final kBench = (Platform.environment['BENCH'] ?? const String.fromEnvironment('BENCH', defaultValue: 'true')) == 'true';

// ---------------------------------------------------------------------------------------------------------------
// Graph: the same generator as app/integration_test/canvas_perf_test.dart (25-wide grid, chain + fan-out every 7).

class GNode {
  GNode(this.id, this.type, String title, this.x, this.y) : title = ValueNotifier(title);
  final String id;
  final String type;
  final ValueNotifier<String> title;
  double x;
  double y;
  Offset get outPort => Offset(x + kNodeW, y + kNodeH / 2);
  Offset get inPort => Offset(x, y + kNodeH / 2);
}

class GEdge {
  const GEdge(this.source, this.target);
  final int source;
  final int target;
}

class Graph {
  Graph(this.nodes, this.edges);
  final List<GNode> nodes;
  final List<GEdge> edges;

  factory Graph.generate(int n) {
    const types = ['llm', 'code', 'answer', 'llm', 'code'];
    final nodes = <GNode>[];
    final edges = <GEdge>[];
    for (var i = 0; i < n; i++) {
      final type = i == 0 ? 'start' : types[i % types.length];
      nodes.add(GNode('n$i', type, '$type $i', (i % 25) * 300.0, (i ~/ 25) * 180.0));
      if (i > 0) edges.add(GEdge(i - 1, i));
      if (i % 7 == 0 && i + 25 < n) edges.add(GEdge(i, i + 25));
    }
    return Graph(nodes, edges);
  }

  /// Points along the edge's curve (cubic, horizontal tangents at both ports), in canvas coordinates.
  List<Offset> curve(GEdge e, {int segments = 12}) {
    final a = nodes[e.source].outPort, b = nodes[e.target].inPort;
    final dx = max(40.0, (b.dx - a.dx).abs() / 2);
    final c1 = a + Offset(dx, 0), c2 = b - Offset(dx, 0);
    return [
      for (var i = 0; i <= segments; i++)
        () {
          final t = i / segments, u = 1 - t;
          return a * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + b * (t * t * t);
        }(),
    ];
  }
}

/// The view: canvas point at the viewport center, and screen pixels per canvas pixel.
class View2D {
  View2D(this.center, this.scale);
  Offset center;
  double scale;
}

abstract mixin class CanvasHandle {
  void editTitle(int i, String title);
  void beginDrag(int i);
  void dragTo(int i, Offset topLeft);
  void endDrag(int i);

  /// Make text crisp at the current zoom (scene: recapture visible cards at a higher pixel ratio).
  Future<void> sharpen();
  int get liveWidgets;
  Map<String, Object> get stats => const {};
  int get pendingVisible => 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Node card: the look of the editor's _NodeCard (no gestures; the spike measures rendering).

Color typeColor(String type) => switch (type) {
  'start' => Colors.green.shade600,
  'llm' => Colors.indigo.shade500,
  'code' => Colors.orange.shade700,
  'answer' => Colors.teal.shade600,
  _ => Colors.blueGrey,
};

class NodeCard extends StatelessWidget {
  const NodeCard({super.key, required this.node, this.onPainted});
  final GNode node;

  /// Called after a frame in which the card repainted with a new title (scene mode recaptures then).
  final VoidCallback? onPainted;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = typeColor(node.type);
    return SizedBox(
      width: kNodeW,
      height: kNodeH,
      child: Material(
        color: scheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: scheme.outlineVariant),
        ),
        clipBehavior: Clip.antiAlias,
        child: Row(
          children: [
            Container(width: 6, color: accent),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ValueListenableBuilder<String>(
                      valueListenable: node.title,
                      builder: (context, title, _) {
                        if (onPainted != null) SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
                        return Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        );
                      },
                    ),
                    const SizedBox(height: 4),
                    Text(
                      node.type,
                      style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------------------------------------------
// MODE=scene

/// Canvas (x right, y down) to world: the camera sits on -Z looking along +Z (world +X is screen-right, +Y up), and
/// [z] is the distance in front of the canvas plane (toward the camera).
vm.Vector3 toWorld(Offset p, [double z = 0]) => vm.Vector3(p.dx, -p.dy, -z);

/// The card quad. WidgetComponent's own quad is front-facing toward -Z but maps the texture as seen from +Z, so from
/// a -Z camera it shows the card mirrored; this one flips u. One geometry is shared by every card.
Geometry? _cardQuad;
Geometry cardQuad() => _cardQuad ??= MeshGeometry.fromArrays(
  positions: Float32List.fromList([
    kNodeW / 2,
    -kNodeH / 2,
    0,
    -kNodeW / 2,
    -kNodeH / 2,
    0,
    -kNodeW / 2,
    kNodeH / 2,
    0,
    kNodeW / 2,
    kNodeH / 2,
    0,
  ]),
  texCoords: Float32List.fromList([1, 1, 0, 1, 0, 0, 1, 0]),
  indices: [0, 1, 3, 3, 1, 2],
);

class SceneCanvas extends StatefulWidget {
  const SceneCanvas({super.key, required this.graph, required this.view, required this.onReady, this.withCards = true});
  final Graph graph;
  final bool withCards;
  final View2D view;
  final VoidCallback onReady;
  @override
  State<SceneCanvas> createState() => SceneCanvasState();
}

class SceneCanvasState extends State<SceneCanvas> with CanvasHandle {
  final scene = Scene();
  final cards = <Node>[];
  final comps = <WidgetComponent?>[];
  final pixelRatios = <double>[];
  int attached = 0;
  int maxAttached = 0;
  int attachedTotal = 0;
  late final UnlitMaterial placeholderMaterial;
  final placeholders = <UnlitMaterial>[];
  final hasOverview = <bool>[];
  final overviewQueue = <int>[];
  final overviewInFlight = <int, WidgetComponent>{};
  int overviewsDone = 0;
  Node? staticEdges;
  Node? liveEdges;
  Set<int> liveEdgeIds = {};
  bool ready = false;
  Size viewport = Size.zero;
  late final UnlitMaterial edgeMaterial;
  int captured = 0;

  Graph get g => widget.graph;

  @override
  void initState() {
    super.initState();
    Scene.initializeStaticResources().then((_) {
      if (!mounted) return;
      edgeMaterial = UnlitMaterial()..baseColorFactor = vm.Vector4(0.58, 0.62, 0.68, 1);
      if (kAA.isNotEmpty) scene.antiAliasingMode = AntiAliasingMode.values.byName(kAA);
      placeholderMaterial = UnlitMaterial()..baseColorFactor = vm.Vector4(0.97, 0.96, 1.0, 1);
      final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      for (var i = 0; i < g.nodes.length; i++) {
        final n = Node(name: g.nodes[i].id);
        n.position = toWorld(g.nodes[i].center);
        cards.add(n);
        pixelRatios.add(dpr);
        comps.add(null);
        if (widget.withCards) {
          // Stands in for the card until (and while not) it has a capture; just behind where the capture draws.
          final m = kOverview
              ? (UnlitMaterial()
                  ..baseColorFactor = vm.Vector4(0.97, 0.96, 1.0, 1)
                  ..alphaMode = AlphaMode.blend
                  ..displayReferred = true)
              : placeholderMaterial;
          placeholders.add(m);
          hasOverview.add(false);
          n.add(Node(mesh: Mesh(cardQuad(), m))..position = vm.Vector3(0, 0, 0.05));
          if (!kCull) _attach(i, dpr);
        }
        if (kCards && widget.withCards) scene.add(n);
      }
      if (kOverview && widget.withCards) {
        final c = widget.view.center;
        overviewQueue
          ..addAll(List.generate(g.nodes.length, (i) => i))
          ..sort((a, b) => (g.nodes[a].center - c).distanceSquared.compareTo((g.nodes[b].center - c).distanceSquared));
      }
      _rebuildEdges();
      setState(() => ready = true);
      if (!kCards || !widget.withCards) SchedulerBinding.instance.addPostFrameCallback((_) => widget.onReady());
      if (kRecap > 0) {
        Timer(Duration(milliseconds: kRecap), () {
          for (final c in comps) {
            c?.controller.requestCapture();
          }
        });
      }
    });
  }

  WidgetComponent _component(int i, double pixelRatio) {
    late final WidgetComponent c;
    c = WidgetComponent(
      child: kSem
          ? NodeCard(node: g.nodes[i], onPainted: () => c.controller.requestCapture())
          : ExcludeSemantics(
              child: NodeCard(node: g.nodes[i], onPainted: () => c.controller.requestCapture()),
            ),
      size: const Size(kNodeW, kNodeH),
      pixelRatio: pixelRatio,
      worldHeight: kNodeH,
      geometry: cardQuad(),
      update: kPolicy == 'every' ? WidgetUpdatePolicy.everyFrame : WidgetUpdatePolicy.manual,
      input: WidgetInput.manual,
      displayReferred: kDref,
    );
    void counted() {
      if (c.controller.texture == null) return;
      c.controller.removeListener(counted);
      if (!reported && ++captured == initialTarget) {
        reported = true;
        widget.onReady();
      }
    }

    c.controller.addListener(counted);
    return c;
  }

  // Readiness: every card attached in the first residency pass has its first capture.
  int initialTarget = -1;
  bool reported = false;

  /// The capture density for the current zoom: the screen's pixel density, times the zoom rounded up to a power of 2
  /// (small zoom steps do not recapture).
  double densityForZoom() {
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final scale = kDensityZoom ? max(0.25, widget.view.scale) : max(1.0, widget.view.scale);
    return dpr * pow(2, (log(scale) / ln2).ceil()).toDouble();
  }

  // The card captures itself after its first paint (NodeCard's post-frame callback).
  void _attach(int i, double pixelRatio) {
    final c = _component(i, pixelRatio);
    cards[i].addComponent(c);
    comps[i] = c;
    pixelRatios[i] = pixelRatio;
    attachedTotal++;
    maxAttached = max(maxAttached, ++attached);
  }

  void _detach(int i) {
    cards[i].removeComponent(comps[i]!);
    comps[i] = null;
    attached--;
  }

  // Below this zoom cards are too small to read: placeholders only, no new captures.
  static const lodScale = 0.3;
  // The overview capture is exact up to this zoom.
  static const overviewMaxScale = 0.5;

  void _overviewStep() {
    if (!kOverview) return;
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    while (overviewInFlight.length < kOverviewBudget && overviewQueue.isNotEmpty) {
      final i = overviewQueue.removeAt(0);
      late final WidgetComponent c;
      c = WidgetComponent.bindOnly(
        child: ExcludeSemantics(
          child: NodeCard(node: g.nodes[i], onPainted: () => c.controller.requestCapture()),
        ),
        size: const Size(kNodeW, kNodeH),
        pixelRatio: dpr * overviewMaxScale,
        update: WidgetUpdatePolicy.manual,
        input: WidgetInput.manual,
        bind: (texture) {
          // The wrapped texture keeps its image alive after the component (and its host) is gone.
          placeholders[i]
            ..baseColorTexture = GpuTextureSource(texture)
            ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
          if (!hasOverview[i]) overviewsDone++;
          hasOverview[i] = true;
          SchedulerBinding.instance.addPostFrameCallback((_) {
            cards[i].removeComponent(c);
            overviewInFlight.remove(i);
          });
        },
      );
      overviewInFlight[i] = c;
      cards[i].addComponent(c);
    }
  }

  // Captures started per frame, so a fast pan spreads its work.
  static final attachBudget = kCapBudget;
  Offset? lastCenter;
  double lastViewScale = 0;
  int lastMove = 0;
  double lastScale = 0;

  /// Cards on screen that still show their placeholder (for the zoom-back measurement).
  @override
  int get pendingVisible {
    if (widget.view.scale < lodScale || viewport.isEmpty) return 0;
    final view = visibleRect(widget.view, viewport);
    var n = 0;
    for (var i = 0; i < cards.length; i++) {
      if (view.overlaps(g.nodes[i].rect) && comps[i]?.controller.texture == null && !(kOverview && hasOverview[i])) {
        n++;
      }
    }
    return n;
  }

  /// Keeps a WidgetComponent on the cards within half a viewport of the view and drops those beyond a whole one.
  void _residency() {
    if (!kCull || !widget.withCards || viewport.isEmpty) return;
    final v = widget.view;
    // With overviews every card already shows real content, so capture work waits until the view rests.
    final now = DateTime.now().microsecondsSinceEpoch;
    if (v.center != lastCenter || v.scale != lastViewScale) lastMove = now;
    lastCenter = v.center;
    lastViewScale = v.scale;
    final moving = now - lastMove < 150000;
    if (kOverview && moving && initialTarget >= 0) return;
    _overviewStep();
    final view = visibleRect(v, viewport);
    var keep = view.inflate(max(view.width, view.height) / 2);
    if (kPredict && lastScale > 0 && v.scale < lastScale) {
      // Zooming out: also cover where the view will be in about 15 frames at this rate.
      final ahead = max(lodScale, v.scale * pow(v.scale / lastScale, 15));
      keep = keep.expandToInclude(visibleRect(View2D(v.center, ahead.toDouble()), viewport));
    }
    lastScale = v.scale;
    final drop = view.inflate(max(view.width, view.height));
    final density = densityForZoom();
    var budget = initialTarget < 0 ? 1 << 30 : attachBudget;
    // Releases are spread too: each one unmounts a hosted card.
    var releases = initialTarget < 0 ? 1 << 30 : max(8, attachBudget);
    var first = 0;
    for (var i = 0; i < cards.length; i++) {
      final r = g.nodes[i].rect;
      if (comps[i] != null) {
        if (!drop.overlaps(r) && !liveDrag(i) && attached > kKeep && releases > 0) {
          _detach(i);
          releases--;
        }
      } else if (keep.overlaps(r) && v.scale >= (kOverview ? overviewMaxScale : lodScale) && budget > 0) {
        _attach(i, density);
        budget--;
        first++;
      }
    }
    if (initialTarget < 0) {
      initialTarget = first;
      if (first == 0) {
        reported = true;
        SchedulerBinding.instance.addPostFrameCallback((_) => widget.onReady());
      }
    }
  }

  int? dragging;
  bool liveDrag(int i) => dragging == i;

  Float32List _segments(Iterable<GEdge> edges) {
    final out = <double>[];
    for (final e in edges) {
      final pts = g.curve(e);
      for (var k = 0; k + 1 < pts.length; k++) {
        final a = toWorld(pts[k]), b = toWorld(pts[k + 1]);
        out.addAll([a.x, a.y, a.z, b.x, b.y, b.z]);
      }
    }
    return Float32List.fromList(out);
  }

  Node? _edgeNode(Iterable<GEdge> edges) {
    final data = _segments(edges);
    if (data.isEmpty || !kEdges) return null;
    // Edges sit behind the cards.
    return Node(mesh: Mesh(LineSegmentsGeometry(LineSegmentData(positions: data), width: 2), edgeMaterial))
      ..position = toWorld(Offset.zero, -1);
  }

  void _rebuildEdges() {
    for (final n in [staticEdges, liveEdges]) {
      if (n != null) scene.remove(n);
    }
    staticEdges = _edgeNode([
      for (var k = 0; k < g.edges.length; k++)
        if (!liveEdgeIds.contains(k)) g.edges[k],
    ]);
    liveEdges = _edgeNode([for (final k in liveEdgeIds) g.edges[k]]);
    for (final n in [staticEdges, liveEdges]) {
      if (n != null) scene.add(n);
    }
  }

  @override
  void editTitle(int i, String title) {
    g.nodes[i].title.value = title;
    if (kOverview && !overviewInFlight.containsKey(i)) {
      overviewQueue
        ..remove(i)
        ..insert(0, i);
    }
  }

  @override
  void beginDrag(int i) {
    dragging = i;
    liveEdgeIds = {
      for (var k = 0; k < g.edges.length; k++)
        if (g.edges[k].source == i || g.edges[k].target == i) k,
    };
    _rebuildEdges();
  }

  @override
  void dragTo(int i, Offset topLeft) {
    g.nodes[i]
      ..x = topLeft.dx
      ..y = topLeft.dy;
    cards[i].position = toWorld(g.nodes[i].center, 0.5); // lifted above its neighbours while dragged
    // Only the dragged node's edges are rebuilt per frame.
    if (liveEdges != null) scene.remove(liveEdges!);
    liveEdges = _edgeNode([for (final k in liveEdgeIds) g.edges[k]]);
    if (liveEdges != null) scene.add(liveEdges!);
  }

  @override
  void endDrag(int i) {
    dragging = null;
    cards[i].position = toWorld(g.nodes[i].center);
    liveEdgeIds = {};
    _rebuildEdges();
  }

  /// Visible cards get a capture at the screen's pixel density for the current zoom (rounded up to a power of 2,
  /// so small zoom steps do not recapture). Off-screen cards keep theirs.
  @override
  Future<void> sharpen() async {
    final want = densityForZoom();
    final visible = visibleRect(widget.view, viewport);
    final pending = <Future<void>>[];
    for (var i = 0; i < cards.length; i++) {
      if (comps[i] == null || pixelRatios[i] == want || !visible.overlaps(g.nodes[i].rect)) continue;
      _detach(i);
      _attach(i, want);
      final c = comps[i]!, done = Completer<void>();
      void l() {
        if (c.controller.texture != null && !done.isCompleted) done.complete();
      }

      c.controller.addListener(l);
      pending.add(done.future);
    }
    await Future.wait(pending);
  }

  @override
  int get liveWidgets => attached;

  @override
  Map<String, Object> get stats => {
    'maxAttached': maxAttached,
    'attachedTotal': attachedTotal,
    if (kOverview) 'overviewsDone': overviewsDone,
  };

  Camera camera() {
    final v = widget.view;
    final eye = toWorld(v.center, 50);
    return OrthographicCamera(
      position: eye,
      target: toWorld(v.center),
      projection: OrthographicProjection(size: OrthographicSize.height(max(1, viewport.height) / v.scale), far: 100),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!ready) return const SizedBox.expand();
    return LayoutBuilder(
      builder: (context, c) {
        viewport = c.biggest;
        return SceneView(scene, cameraBuilder: (_) => camera(), onTick: (_, _) => _residency());
      },
    );
  }
}

extension on GNode {
  Offset get center => Offset(x + kNodeW / 2, y + kNodeH / 2);
  Rect get rect => Rect.fromLTWH(x, y, kNodeW, kNodeH);
}

Rect visibleRect(View2D v, Size viewport) =>
    Rect.fromCenter(center: v.center, width: viewport.width / v.scale, height: viewport.height / v.scale);

// ---------------------------------------------------------------------------------------------------------------
// MODE=widgets

class WidgetCanvas extends StatefulWidget {
  const WidgetCanvas({super.key, required this.graph, required this.view, required this.onReady, this.edgesKey});
  final Graph graph;

  /// MODE=hybrid: the edges are drawn by the scene under this canvas; drags are forwarded to it.
  final GlobalKey? edgesKey;
  final View2D view;
  final VoidCallback onReady;
  @override
  State<WidgetCanvas> createState() => WidgetCanvasState();
}

class WidgetCanvasState extends State<WidgetCanvas> with SingleTickerProviderStateMixin, CanvasHandle {
  late final Ticker ticker;
  final cards = <int, Widget>{};
  int edgesVersion = 0;
  Set<int> liveEdgeIds = {};
  int built = 0;

  Graph get g => widget.graph;

  @override
  void initState() {
    super.initState();
    // The view object is mutated by the driver; follow it every frame (the scene mode's camera does the same).
    ticker = createTicker((_) => setState(() {}))..start();
    SchedulerBinding.instance.addPostFrameCallback((_) => widget.onReady());
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  Widget card(int i) => cards[i] ??= RepaintBoundary(
    key: ValueKey(i),
    child: NodeCard(node: g.nodes[i]),
  );

  @override
  void editTitle(int i, String title) => g.nodes[i].title.value = title;

  CanvasHandle? get edges => widget.edgesKey?.currentState as CanvasHandle?;

  @override
  void beginDrag(int i) => setState(() {
    edges?.beginDrag(i);
    liveEdgeIds = {
      for (var k = 0; k < g.edges.length; k++)
        if (g.edges[k].source == i || g.edges[k].target == i) k,
    };
    edgesVersion++;
  });

  @override
  void dragTo(int i, Offset topLeft) {
    edges?.dragTo(i, topLeft);
    g.nodes[i]
      ..x = topLeft.dx
      ..y = topLeft.dy;
  }

  @override
  void endDrag(int i) => setState(() {
    edges?.endDrag(i);
    liveEdgeIds = {};
    edgesVersion++;
  });

  @override
  Future<void> sharpen() async {} // widgets render at screen resolution at every zoom

  @override
  int get liveWidgets => built;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final v = widget.view;
        final visible = visibleRect(v, c.biggest).inflate(40);
        final transform = Matrix4.identity()
          ..translateByDouble(c.maxWidth / 2, c.maxHeight / 2, 0, 1)
          ..scaleByDouble(v.scale, v.scale, 1, 1)
          ..translateByDouble(-v.center.dx, -v.center.dy, 0, 1);
        final children = <Widget>[
          if (widget.edgesKey == null)
            RepaintBoundary(child: CustomPaint(painter: EdgePainter(g, liveEdgeIds, edgesVersion, live: false))),
          if (widget.edgesKey == null && liveEdgeIds.isNotEmpty)
            CustomPaint(painter: EdgePainter(g, liveEdgeIds, edgesVersion, live: true)),
          for (var i = 0; i < g.nodes.length; i++)
            if (visible.overlaps(g.nodes[i].rect)) Positioned(left: g.nodes[i].x, top: g.nodes[i].y, child: card(i)),
        ];
        built = children.length - 1;
        return ClipRect(
          child: Transform(
            transform: transform,
            child: Stack(clipBehavior: Clip.none, children: children),
          ),
        );
      },
    );
  }
}

class EdgePainter extends CustomPainter {
  EdgePainter(this.g, this.liveEdgeIds, this.version, {required this.live});
  final Graph g;
  final Set<int> liveEdgeIds;
  final int version;
  final bool live;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF949EAD)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    final path = Path();
    for (var k = 0; k < g.edges.length; k++) {
      if (liveEdgeIds.contains(k) != live) continue;
      final a = g.nodes[g.edges[k].source].outPort, b = g.nodes[g.edges[k].target].inPort;
      final dx = max(40.0, (b.dx - a.dx).abs() / 2);
      path
        ..moveTo(a.dx, a.dy)
        ..cubicTo(a.dx + dx, a.dy, b.dx - dx, b.dy, b.dx, b.dy);
    }
    canvas.drawPath(path, paint);
  }

  // The static layer repaints only when the live set changes; the live layer every frame.
  @override
  bool shouldRepaint(EdgePainter old) => live || old.version != version;
}

// ---------------------------------------------------------------------------------------------------------------
// Benchmark driver

class Phase {
  Phase(this.name, this.seconds);
  final String name;
  final double seconds;
  final timings = <ui.FrameTiming>[];
}

double pct(List<double> xs, double p) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  return s[min(s.length - 1, (p * s.length).floor())];
}

double r1(double x) => (x * 10).roundToDouble() / 10;

Map<String, Object> summarize(Phase p) {
  final t = p.timings;
  final intervals = <double>[
    for (var i = 1; i < t.length; i++)
      (t[i].timestampInMicroseconds(ui.FramePhase.rasterFinish) -
              t[i - 1].timestampInMicroseconds(ui.FramePhase.rasterFinish)) /
          1000,
  ];
  final build = [for (final f in t) f.buildDuration.inMicroseconds / 1000];
  final raster = [for (final f in t) f.rasterDuration.inMicroseconds / 1000];
  return {
    'phase': p.name,
    'frames': t.length,
    'fps': r1(t.length / p.seconds),
    'interval_p50': r1(pct(intervals, .5)),
    'interval_p90': r1(pct(intervals, .9)),
    'interval_p99': r1(pct(intervals, .99)),
    'interval_max': r1(intervals.isEmpty ? 0 : intervals.reduce(max)),
    'over_9_6ms': intervals.where((x) => x > 9.6).length,
    'over_16_7ms': intervals.where((x) => x > 16.7).length,
    'build_p50': r1(pct(build, .5)),
    'build_p99': r1(pct(build, .99)),
    'raster_p50': r1(pct(raster, .5)),
    'raster_p99': r1(pct(raster, .99)),
  };
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SpikeApp());
}

class SpikeApp extends StatefulWidget {
  const SpikeApp({super.key});
  @override
  State<SpikeApp> createState() => _SpikeAppState();
}

class _SpikeAppState extends State<SpikeApp> with SingleTickerProviderStateMixin {
  final graph = Graph.generate(kNodes);
  // HOME=x,y,scale sets the starting view (canvas point at the center).
  final view = () {
    final h = env('HOME_VIEW', '800,500,1').split(',').map(double.parse).toList();
    return View2D(Offset(h[0], h[1]), h[2]);
  }();
  final canvasKey = GlobalKey();
  final shotKey = GlobalKey();
  final edgesKey = GlobalKey();
  final sw = Stopwatch()..start();
  late final Ticker ticker;
  Phase? current;
  final results = <Map<String, Object>>[];
  final rng = Random(7);
  int loadMs = 0;

  CanvasHandle get canvas => canvasKey.currentState! as CanvasHandle;

  @override
  void initState() {
    super.initState();
    ticker = createTicker(_tick);
    SchedulerBinding.instance.addTimingsCallback((ts) => current?.timings.addAll(ts));
  }

  void _ready() {
    loadMs = sw.elapsedMilliseconds;
    final v = WidgetsBinding.instance.platformDispatcher.views.first;
    stdout.writeln(
      'READY mode=$kMode nodes=$kNodes edges=${graph.edges.length} loadMs=$loadMs window=${v.physicalSize.width}x${v.physicalSize.height}@${v.devicePixelRatio} canvas=${canvasKey.currentContext?.size?.width}x${canvasKey.currentContext?.size?.height} shot=${shotKey.currentContext?.size?.width}x${shotKey.currentContext?.size?.height}',
    );
    if (kBench) unawaited(_run());
  }

  // Per-phase motion, driven from the ticker with the time since the phase started.
  void Function(double t)? _motion;
  double _now = 0;
  double _phaseStart = 0;

  void _tick(Duration elapsed) {
    _now = elapsed.inMicroseconds / 1e6;
    _motion?.call(_now - _phaseStart);
  }

  Future<void> _phase(String name, double seconds, void Function(double t)? motion) async {
    if (!kPhases.contains(name)) return;
    final p = Phase(name, seconds);
    _phaseStart = _now;
    _motion = motion;
    if (!ticker.isActive) ticker.start();
    // Let the motion settle in before recording.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    current = p;
    await Future<void>.delayed(Duration(milliseconds: (seconds * 1000).round()));
    current = null;
    await Future<void>.delayed(const Duration(milliseconds: 200)); // timings arrive in batches
    final s = summarize(p);
    results.add(s);
    stdout.writeln('PERF ${jsonEncode(s)}');
  }

  /// Zoomed in to 2x on the middle of the graph (text made crisp), then a 1 s zoom out to 0.35x and hold: how many
  /// on-screen cards show a placeholder, and for how long.
  Future<void> _zoomBack() async {
    if (kOverview) {
      // Background overview captures: record the frames while they run, and how long they take.
      final sw0 = Stopwatch()..start();
      final p = Phase('warmup', 0);
      current = p;
      while ((canvas.stats['overviewsDone'] as int? ?? 0) < kNodes && sw0.elapsed.inSeconds < 20) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      current = null;
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final w = Phase('warmup', sw0.elapsedMilliseconds / 1000)..timings.addAll(p.timings);
      final sum = summarize(w)..['overviewMs'] = sw0.elapsedMilliseconds;
      results.add(sum);
      stdout.writeln('PERF ${jsonEncode(sum)}');
    }
    final saved = (view.center, view.scale);
    view
      ..center = const Offset(3700, 3000)
      ..scale = 2;
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await canvas.sharpen();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    // ZB_SEC: how long the zoom out takes (0 = a jump, like a zoom-to-fit button).
    const start = 0.3;
    final end = start + double.parse(env('ZB_SEC', '1'));
    stdout.writeln('ZB_START');
    final samples = <(double, int)>[];
    // Screenshots during the zoom, just after it ends, and later.
    const shotsAt = [0.8, 1.35, 1.6, 2.2];
    final taken = <double>{};
    await _phase('zoomback', 2.5, (t) {
      final u = end <= start ? (t >= start ? 1.0 : 0.0) : ((t - start) / (end - start)).clamp(0.0, 1.0);
      view.scale = 2 * pow(0.35 / 2, u).toDouble();
      if (t >= start) samples.add((t, canvas.pendingVisible));
      for (final at in shotsAt) {
        if (t >= at && !taken.contains(at)) {
          taken.add(at);
          unawaited(_shot('zoomback-${(at * 1000).round()}ms'));
        }
      }
    });
    final pending = samples.where((x) => x.$2 > 0).toList();
    final extra = <String, Object>{
      'maxPending': pending.isEmpty ? 0 : pending.map((x) => x.$2).reduce(max),
      'framesWithPending': pending.length,
      'framesSampled': samples.length,
      'pendingAfterZoomMs': pending.isEmpty ? 0 : max(0, ((pending.last.$1 - end) * 1000).round()),
      'pendingCardFrames': pending.fold<int>(0, (a, x) => a + x.$2),
    };
    results.last.addAll(extra);
    stdout.writeln('ZOOMBACK ${jsonEncode(extra)}');
    view
      ..center = saved.$1
      ..scale = saved.$2;
    await _shot('after-zoomback');
  }

  Future<void> _shot(String name) async {
    await SchedulerBinding.instance.endOfFrame;
    final dir = Platform.environment['SHOTS'] ?? '/tmp/scene_canvas';
    Directory(dir).createSync(recursive: true);
    final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    try {
      final image = await boundary.toImage();
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$kMode-$kNodes-$name.png').writeAsBytesSync(png!.buffer.asUint8List());
    } catch (e) {
      stdout.writeln(
        'SHOT $name failed (${boundary.size.width}x${boundary.size.height}, dpr ${View.of(context).devicePixelRatio}): $e',
      );
    }
  }

  Future<void> _run() async {
    await Future<void>.delayed(const Duration(seconds: 1));
    await _shot('start');
    final home = view.center;
    if (kPhases.contains('zoomback')) await _zoomBack();
    // Pan: a 600 px/s diagonal sweep and back.
    await _phase('pan', 4, (t) {
      final s = sin(t * pi / 2);
      view.center = home + Offset(1600 * s, 900 * s);
    });
    view.center = home;
    // Zoom around the center between 0.4x and 1.6x.
    await _phase('zoom', 4, (t) => view.scale = 1 + 0.6 * sin(t * pi / 2));
    view.scale = 1;
    // Another user renames visible nodes, 20 per second.
    var edits = 0;
    final visible = [
      for (var i = 0; i < graph.nodes.length; i++)
        if (visibleRect(view, const Size(1600, 1000)).overlaps(graph.nodes[i].rect)) i,
    ];
    var last = 0.0;
    await _phase('edits', 4, (t) {
      while (last < t) {
        last += 0.05;
        final i = visible[rng.nextInt(visible.length)];
        canvas.editTitle(i, '${graph.nodes[i].type} $i · edit ${++edits}');
      }
    });
    // Drag one node in a circle.
    const k = 52;
    final origin = Offset(graph.nodes[k].x, graph.nodes[k].y);
    canvas.beginDrag(k);
    await _phase('drag', 4, (t) => canvas.dragTo(k, origin + Offset(120 * sin(t * 2), 80 * (1 - cos(t * 2)))));
    canvas.dragTo(k, origin);
    canvas.endDrag(k);
    // Zoom in to 2x and make text crisp; measure the frames while that happens and how long it takes.
    _motion = null;
    view.scale = 2;
    await _shot('zoom2-before-sharpen');
    final s0 = sw.elapsedMilliseconds;
    final p = Phase('sharpen', 1);
    current = p;
    await canvas.sharpen();
    final sharpenMs = sw.elapsedMilliseconds - s0;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    current = null;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await _shot('zoom2');
    final summary = {
      'mode': kMode,
      'nodes': kNodes,
      'edges': graph.edges.length,
      'loadMs': loadMs,
      'sharpenMs': sharpenMs,
      'sharpenFrames': p.timings.length,
      'sharpenWorstBuildMs': r1(
        p.timings.isEmpty ? 0 : p.timings.map((f) => f.buildDuration.inMicroseconds / 1000).reduce(max),
      ),
      'rssMb': ProcessInfo.currentRss ~/ (1 << 20),
      'maxRssMb': ProcessInfo.maxRss ~/ (1 << 20),
      'liveWidgets': canvas.liveWidgets,
      ...canvas.stats,
      'phases': results,
    };
    stdout.writeln('SUMMARY ${jsonEncode(summary)}');
    await stdout.flush();
    exit(0);
  }

  @override
  void dispose() {
    ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        backgroundColor: const Color(0xFFF2F4F7),
        // Scaffold gives its body loose constraints; the canvas must fill the window.
        body: SizedBox.expand(
          child: RepaintBoundary(
            key: shotKey,
            child: ColoredBox(
              color: const Color(0xFFF2F4F7),
              child: switch (kMode) {
                'scene' => SceneCanvas(key: canvasKey, graph: graph, view: view, onReady: _ready),
                // Widget cards over a scene that draws the edges (and, later, background and effects).
                'hybrid' => Stack(
                  children: [
                    Positioned.fill(
                      child: SceneCanvas(key: edgesKey, graph: graph, view: view, onReady: () {}, withCards: false),
                    ),
                    Positioned.fill(
                      child: WidgetCanvas(
                        key: canvasKey,
                        graph: graph,
                        view: view,
                        onReady: _ready,
                        edgesKey: edgesKey,
                      ),
                    ),
                  ],
                ),
                _ => WidgetCanvas(key: canvasKey, graph: graph, view: view, onReady: _ready),
              },
            ),
          ),
        ),
      ),
    );
  }
}
