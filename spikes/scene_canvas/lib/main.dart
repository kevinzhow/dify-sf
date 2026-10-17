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
import 'dart:developer' show Timeline;
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
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
// A11Y=1 (default): the canvas exposes its own compact semantics (one node per on-screen card, or one summary node
// when more than 200 are on screen), rebuilt when the view rests.
final kA11y = env('A11Y', '1') == '1';
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

  /// Run state: idle, running, succeeded, failed.
  final status = ValueNotifier('idle');
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
  const NodeCard({super.key, required this.node, this.onPainted, this.showStatus = true});
  final GNode node;

  /// Overview captures leave the status out: the scene's status frame shows it without delay.
  final bool showStatus;

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
                    ValueListenableBuilder<String>(
                      valueListenable: node.status,
                      builder: (context, status, _) {
                        if (showStatus && status != 'idle' && onPainted != null) {
                          SchedulerBinding.instance.addPostFrameCallback((_) => onPainted!());
                        }
                        return Text(
                          showStatus && status != 'idle' ? '${node.type} · $status' : node.type,
                          style: TextStyle(color: accent, fontSize: 12, fontWeight: FontWeight.w500),
                        );
                      },
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

/// The status frame: a quad a few pixels larger than the card, drawn behind it, so its colour shows as a border.
Geometry? _statusQuad;
Geometry statusQuad() => _statusQuad ??= () {
  const w = kNodeW / 2 + 3, h = kNodeH / 2 + 3;
  return MeshGeometry.fromArrays(
    positions: Float32List.fromList([w, -h, 0, -w, -h, 0, -w, h, 0, w, h, 0]),
    texCoords: Float32List.fromList([1, 1, 0, 1, 0, 0, 1, 0]),
    indices: [0, 1, 3, 3, 1, 2],
  );
}();

/// The selection/hover frame: larger than the status frame, so both show when a running node is selected.
Geometry? _highlightQuad;
Geometry highlightQuad() => _highlightQuad ??= () {
  const w = kNodeW / 2 + 5, h = kNodeH / 2 + 5;
  return MeshGeometry.fromArrays(
    positions: Float32List.fromList([w, -h, 0, -w, -h, 0, -w, h, 0, w, h, 0]),
    texCoords: Float32List.fromList([1, 1, 0, 1, 0, 0, 1, 0]),
    indices: [0, 1, 3, 3, 1, 2],
  );
}();

/// A screen colour (sRGB) as the scene's linear colour, so it reaches the screen unchanged (linear tone mapping).
vm.Vector4 srgb(double r, double g, double b) {
  double lin(double c) => c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4).toDouble();
  return vm.Vector4(lin(r), lin(g), lin(b), 1);
}

const statusColors = {'running': Color(0xFF2F6FED), 'succeeded': Color(0xFF1E9E5A), 'failed': Color(0xFFD93A3A)};

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
  // Overviews (or plain placeholders) in one layer, so the skeleton tier can switch it off in one step.
  final overviewLayer = Node();
  final placeholderNodes = <Node>[];
  // Skeleton tier, below 0.2x: one capture per node type (title text blurred to a line at that size anyway),
  // drawn as one instanced mesh per type.
  final skeletonLayer = Node()..visible = false;
  final skeletonMeshes = <String, InstancedMesh>{};
  final skeletonIndex = <int>[];
  bool skeletonOn = false;
  static const skeletonScale = 0.2;

  void _skeletonSwitch(double scale) {
    final want = skeletonOn ? scale < skeletonScale * 1.05 : scale < skeletonScale * 0.95;
    if (want == skeletonOn || skeletonMeshes.isEmpty) return;
    skeletonOn = want;
    skeletonLayer.visible = want;
    overviewLayer.visible = !want;
  }

  void _buildSkeletons() {
    final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
    final types = {for (final n in g.nodes) n.type};
    final meshes = <String, InstancedMesh>{};
    for (final t in types) {
      final material = UnlitMaterial()
        ..alphaMode = AlphaMode.blend
        ..displayReferred = true
        ..baseColorFactor = srgb(0.97, 0.96, 1.0);
      meshes[t] = InstancedMesh(geometry: cardQuad(), material: material, sortTransparentInstances: false);
      final host = Node();
      late final WidgetComponent c;
      c = WidgetComponent.bindOnly(
        child: ExcludeSemantics(
          child: NodeCard(
            node: GNode('skeleton', t, '$t 0000', 0, 0),
            onPainted: () => c.controller.requestCapture(),
            showStatus: false,
          ),
        ),
        size: const Size(kNodeW, kNodeH),
        pixelRatio: dpr * skeletonScale,
        update: WidgetUpdatePolicy.manual,
        input: WidgetInput.manual,
        bind: (texture) {
          material
            ..baseColorTexture = GpuTextureSource(texture)
            ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
          // Until a card has its own overview, its placeholder shows its type's card.
          for (var i = 0; i < g.nodes.length; i++) {
            if (g.nodes[i].type == t && !hasOverview[i]) {
              placeholders[i]
                ..baseColorTexture = GpuTextureSource(texture)
                ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
            }
          }
          SchedulerBinding.instance.addPostFrameCallback((_) => scene.remove(host));
        },
      );
      host.addComponent(c);
      scene.add(host);
    }
    for (var i = 0; i < g.nodes.length; i++) {
      skeletonIndex.add(
        meshes[g.nodes[i].type]!.addInstance(vm.Matrix4.translation(toWorld(g.nodes[i].center, -0.05))),
      );
    }
    for (final m in meshes.values) {
      skeletonLayer.addComponent(InstancedMeshComponent(m));
    }
    skeletonMeshes.addAll(meshes);
  }

  // Status frames: one instanced mesh, one instance per card, coloured per instance (idle = scaled to nothing).
  late final InstancedMesh statusMesh;
  late final Map<String, vm.Vector4> statusColorValues;
  int statusChanges = 0;
  // Delayed tier: cards whose overview is older than their content (first unrendered change, microseconds).
  final dirtySince = <int?>[];
  final captureStartedAt = <int>[];
  final lastOverviewAt = <int>[];
  final dirty = <int>{};
  // Staleness of overviews on screen: from the first unrendered change to the new overview.
  final stalenessMs = <double>[];
  static const minOverviewIntervalUs = 300000; // a card's overview is refreshed at most every 300 ms

  int nowUs() => DateTime.now().microsecondsSinceEpoch;
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
      edgeMaterial = UnlitMaterial()..baseColorFactor = srgb(0.58, 0.62, 0.68);
      if (kAA.isNotEmpty) scene.antiAliasingMode = AntiAliasingMode.values.byName(kAA);
      // A flat 2D canvas: colours pass through unchanged (no filmic curve on status and selection colours).
      scene.toneMapping = ToneMappingMode.linear;
      placeholderMaterial = UnlitMaterial()..baseColorFactor = srgb(0.97, 0.96, 1.0);
      statusColorValues = {for (final e in statusColors.entries) e.key: srgb(e.value.r, e.value.g, e.value.b)};
      // All cards lie in one plane: no per-frame depth sort of the instances.
      statusMesh = InstancedMesh(
        geometry: statusQuad(),
        // Opaque scene geometry (not display-referred): display-referred surfaces are composited without depth
        // order among themselves, which drew the frames over the overview captures.
        material: UnlitMaterial(),
        sortTransparentInstances: false,
      );
      highlightMesh = InstancedMesh(
        geometry: highlightQuad(),
        material: UnlitMaterial(),
        sortTransparentInstances: false,
      );
      highlightEdgeMaterial = UnlitMaterial()..baseColorFactor = selectedColor;
      if (widget.withCards) {
        scene
          ..add(Node()..addComponent(InstancedMeshComponent(highlightMesh)))
          ..add(Node()..addComponent(InstancedMeshComponent(statusMesh)))
          ..add(overviewLayer)
          ..add(skeletonLayer);
      }
      final dpr = WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      for (var i = 0; i < g.nodes.length; i++) {
        final n = Node(name: g.nodes[i].id);
        n.position = toWorld(g.nodes[i].center);
        cards.add(n);
        cellOf.add(_cellFor(i));
        grid.putIfAbsent(cellOf[i], () => []).add(i);
        pixelRatios.add(dpr);
        comps.add(null);
        if (widget.withCards) {
          // Stands in for the card until (and while not) it has a capture; just behind where the capture draws.
          final m = kOverview
              ? (UnlitMaterial()
                  ..baseColorFactor = srgb(0.97, 0.96, 1.0)
                  ..alphaMode = AlphaMode.blend
                  ..displayReferred = true)
              : placeholderMaterial;
          placeholders.add(m);
          hasOverview.add(false);
          dirtySince.add(null);
          captureStartedAt.add(0);
          lastOverviewAt.add(0);
          final pn = Node(mesh: Mesh(cardQuad(), m))..position = toWorld(g.nodes[i].center, -0.05);
          placeholderNodes.add(pn);
          overviewLayer.add(pn);
          statusMesh.addInstance(vm.Matrix4.zero());
          highlightMesh.addInstance(vm.Matrix4.zero());
          final node = g.nodes[i], si = i;
          node.status.addListener(() => _showStatus(si, node.status.value));
          node.title.addListener(() => _markDirty(si));
          if (!kCull) _attach(i, dpr);
        }
        if (kCards && widget.withCards) scene.add(n);
      }
      if (kOverview && widget.withCards) {
        _buildSkeletons();
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
          ? NodeCard(node: g.nodes[i], onPainted: () => _livePainted(i, c))
          : ExcludeSemantics(
              child: NodeCard(node: g.nodes[i], onPainted: () => _livePainted(i, c)),
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
  // Grid index of the cards (by top-left corner), so residency looks only near the view.
  static const gridCell = 1000.0;
  final grid = <(int, int), List<int>>{};
  final attachedSet = <int>{};

  Iterable<int> nodesIn(Rect r) sync* {
    final q = r.inflate(max(kNodeW, kNodeH));
    for (var cx = (q.left / gridCell).floor(); cx <= (q.right / gridCell).floor(); cx++) {
      for (var cy = (q.top / gridCell).floor(); cy <= (q.bottom / gridCell).floor(); cy++) {
        final cellNodes = grid[(cx, cy)];
        if (cellNodes != null) yield* cellNodes;
      }
    }
  }

  void _attach(int i, double pixelRatio) {
    attachedSet.add(i);
    final c = _component(i, pixelRatio);
    cards[i].addComponent(c);
    comps[i] = c;
    pixelRatios[i] = pixelRatio;
    attachedTotal++;
    maxAttached = max(maxAttached, ++attached);
  }

  /// Replaces card [i]'s capture with one at [pixelRatio]; the old one stays until the new one has landed.
  Future<void> _upgrade(int i, double pixelRatio) {
    final old = comps[i]!, c = _component(i, pixelRatio), done = Completer<void>();
    replaced[i] = old;
    void landed() {
      if (c.controller.texture == null) return;
      c.controller.removeListener(landed);
      if (identical(replaced[i], old)) replaced.remove(i);
      if (old.isAttached) cards[i].removeComponent(old);
      if (!done.isCompleted) done.complete();
    }

    c.controller.addListener(landed);
    cards[i].addComponent(c);
    comps[i] = c;
    pixelRatios[i] = pixelRatio;
    attachedTotal++;
    return done.future;
  }

  /// Captures being replaced by [_upgrade], kept until the new one lands.
  final replaced = <int, WidgetComponent>{};

  void _detach(int i) {
    final old = replaced.remove(i);
    if (old != null && old.isAttached) cards[i].removeComponent(old);
    attachedSet.remove(i);
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
    while (overviewInFlight.length < kOverviewBudget) {
      final i = overviewQueue.isNotEmpty ? overviewQueue.removeAt(0) : _nextDirty();
      if (i == null) break;
      captureStartedAt[i] = nowUs();
      late final WidgetComponent c;
      c = WidgetComponent.bindOnly(
        child: ExcludeSemantics(
          child: NodeCard(node: g.nodes[i], onPainted: () => c.controller.requestCapture(), showStatus: false),
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
          final now = nowUs(), since = dirtySince[i];
          lastOverviewAt[i] = now;
          if (since != null && since <= captureStartedAt[i]) {
            // This capture includes every change so far.
            if (comps[i] == null && visibleRect(widget.view, viewport).overlaps(g.nodes[i].rect)) {
              stalenessMs.add((now - since) / 1000);
            }
            dirtySince[i] = null;
            dirty.remove(i);
          }
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

  // Live cards off screen that changed: recaptured a few per frame, or at once when they come on screen.
  final liveStale = <int>{};
  bool onScreen(int i) => visibleRect(widget.view, viewport).overlaps(g.nodes[i].rect);

  void _livePainted(int i, WidgetComponent c) {
    if (!kOverview || c.controller.texture == null || onScreen(i)) {
      c.controller.requestCapture();
    } else {
      liveStale.add(i);
    }
  }

  void _liveStep() {
    if (liveStale.isEmpty) return;
    var offscreen = 4;
    for (final i in [...liveStale]) {
      final c = comps[i];
      if (c == null) {
        liveStale.remove(i);
      } else if (onScreen(i) || offscreen-- > 0) {
        c.controller.requestCapture();
        liveStale.remove(i);
      }
    }
  }

  void _markDirty(int i) {
    if (!kOverview) return;
    dirtySince[i] ??= nowUs();
    dirty.add(i);
  }

  /// The dirty card to refresh next: on-screen cards first, then the longest-stale; none refreshed again within
  /// [minOverviewIntervalUs] of its last overview (bursts of changes coalesce into one capture).
  int? _nextDirty() {
    if (dirty.isEmpty) return null;
    final now = nowUs();
    final view = visibleRect(widget.view, viewport);
    int? best;
    var bestKey = (2, 0);
    for (final i in dirty) {
      if (overviewInFlight.containsKey(i) || now - lastOverviewAt[i] < minOverviewIntervalUs) continue;
      final key = (view.overlaps(g.nodes[i].rect) ? 0 : 1, dirtySince[i]!);
      if (best == null || key.$1 < bestKey.$1 || (key.$1 == bestKey.$1 && key.$2 < bestKey.$2)) {
        best = i;
        bestKey = key;
      }
    }
    return best;
  }

  void _showStatus(int i, String status) {
    statusChanges++;
    a11yDirty = true;
    if (status == 'idle') {
      statusMesh.setInstanceTransform(i, vm.Matrix4.zero());
      return;
    }
    statusMesh
      ..setInstanceTransform(i, vm.Matrix4.translation(toWorld(g.nodes[i].center, -0.1)))
      ..setInstanceColor(i, statusColorValues[status]!);
  }

  // Captures started per frame, so a fast pan spreads its work.
  static final attachBudget = kCapBudget;
  Offset? lastCenter;
  bool settled = false;
  bool a11yDirty = false;
  int settledAt = 0;
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
    _edgeWidths();
    if (!kCull || !widget.withCards || viewport.isEmpty) return;
    final v = widget.view;
    // With overviews every card already shows real content, so capture work waits until the view rests.
    final now = DateTime.now().microsecondsSinceEpoch;
    if (v.center != lastCenter || v.scale != lastViewScale) lastMove = now;
    lastCenter = v.center;
    lastViewScale = v.scale;
    final viewMoving = now - lastMove < 150000;
    if (kOverview) _skeletonSwitch(v.scale);
    // Semantics follow the view at rest, and other changes at most every 250 ms.
    if (!viewMoving && (a11yBuiltAt < lastMove || (a11yDirty && now - a11yBuiltAt > 250000))) {
      a11yBuiltAt = now;
      a11yDirty = false;
      _updateA11y();
    }
    if (kOverview && viewMoving && initialTarget >= 0) return;
    _liveStep();
    _overviewStep();
    // Nothing to attach or release until the view moves again (or a pass ran out of budget).
    if (settled && lastMove <= settledAt && initialTarget >= 0 && moving.isEmpty) return;
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
    // Only attached cards can be released, and only cards in grid cells near the view can be attached.
    if (attached > kKeep) {
      for (final i in [...attachedSet]) {
        if (releases <= 0) break;
        if (!drop.overlaps(g.nodes[i].rect) && !liveDrag(i)) {
          _detach(i);
          releases--;
        }
      }
    }
    if (v.scale >= (kOverview ? overviewMaxScale : lodScale)) {
      for (final i in nodesIn(keep)) {
        if (budget <= 0) break;
        if (comps[i] == null && keep.overlaps(g.nodes[i].rect)) {
          _attach(i, density);
          budget--;
          first++;
        }
      }
    }
    // At rest, on-screen cards captured below the zoom's density are recaptured (a few per frame, no flash).
    var sharpens = 8;
    if (!viewMoving) {
      for (final i in [...attachedSet]) {
        if (sharpens <= 0) break;
        if (pixelRatios[i] < density && view.overlaps(g.nodes[i].rect)) {
          _upgrade(i, density);
          sharpens--;
        }
      }
    }
    settled = budget > 0 && releases > 0 && sharpens > 0;
    settledAt = now;
    if (initialTarget < 0) {
      initialTarget = first;
      if (first == 0) {
        reported = true;
        SchedulerBinding.instance.addPostFrameCallback((_) => widget.onReady());
      }
    }
  }

  bool liveDrag(int i) => moving.contains(i);

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
    final geometry = LineSegmentsGeometry(LineSegmentData(positions: data), width: edgeWidthPx / widget.view.scale);
    edgeGeometries.add(geometry);
    return Node(mesh: Mesh(geometry, edgeMaterial))..position = toWorld(Offset.zero, -1);
  }

  // Edges keep a constant width on screen: their world width follows the zoom.
  static const edgeWidthPx = 1.5;
  final edgeGeometries = <LineSegmentsGeometry>[];
  double edgeWidthScale = 0;

  void _edgeWidths() {
    final scale = widget.view.scale;
    if (scale == edgeWidthScale) return;
    edgeWidthScale = scale;
    for (final geometry in edgeGeometries) {
      geometry.width = edgeWidthPx / scale;
    }
  }

  void _rebuildEdges() {
    edgeGeometries.clear();
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
  void editTitle(int i, String title) => g.nodes[i].title.value = title;

  @override
  void beginDrag(int i) => _beginMove({i});

  @override
  void dragTo(int i, Offset topLeft) => _moveBy(topLeft - Offset(g.nodes[i].x, g.nodes[i].y));

  @override
  void endDrag(int i) => _endMove();

  // ----- moving nodes -----

  final moving = <int>{};

  /// Puts every visual of node [i] where the node is; a moving node is lifted towards the camera.
  void _placeNode(int i) {
    final lift = moving.contains(i) ? 0.5 : 0.0, c = g.nodes[i].center;
    cards[i].position = toWorld(c, lift);
    if (placeholderNodes.isNotEmpty) placeholderNodes[i].position = toWorld(c, lift - 0.05);
    if (g.nodes[i].status.value != 'idle') {
      statusMesh.setInstanceTransform(i, vm.Matrix4.translation(toWorld(c, lift - 0.1)));
    }
    if (skeletonIndex.isNotEmpty) {
      skeletonMeshes[g.nodes[i].type]!.setInstanceTransform(
        skeletonIndex[i],
        vm.Matrix4.translation(toWorld(c, lift - 0.05)),
      );
    }
    _updateHighlight(i);
  }

  void _beginMove(Set<int> nodes) {
    moving
      ..clear()
      ..addAll(nodes);
    liveEdgeIds = {
      for (var k = 0; k < g.edges.length; k++)
        if (moving.contains(g.edges[k].source) || moving.contains(g.edges[k].target)) k,
    };
    _rebuildEdges();
    for (final i in moving) {
      _placeNode(i);
    }
  }

  void _moveBy(Offset d) {
    for (final i in moving) {
      g.nodes[i]
        ..x += d.dx
        ..y += d.dy;
      _placeNode(i);
    }
    // Only the moving nodes' edges are rebuilt per frame.
    if (liveEdges != null) {
      scene.remove(liveEdges!);
      edgeGeometries.remove((liveEdges!.mesh!.primitives.first.geometry));
    }
    liveEdges = _edgeNode([for (final k in liveEdgeIds) g.edges[k]]);
    if (liveEdges != null) scene.add(liveEdges!);
  }

  void _endMove() {
    final done = [...moving];
    moving.clear();
    for (final i in done) {
      _placeNode(i);
      _regrid(i);
    }
    liveEdgeIds = {};
    _rebuildEdges();
  }

  final cellOf = <(int, int)>[];
  (int, int) _cellFor(int i) => ((g.nodes[i].x / gridCell).floor(), (g.nodes[i].y / gridCell).floor());

  void _regrid(int i) {
    final now = _cellFor(i);
    if (now == cellOf[i]) return;
    grid[cellOf[i]]?.remove(i);
    grid.putIfAbsent(now, () => []).add(i);
    cellOf[i] = now;
  }

  // ----- selection and hover: one instanced frame per card, never in a capture -----

  final selected = <int>{};
  int? hovered;
  late final InstancedMesh highlightMesh;
  static final selectedColor = srgb(0.16, 0.42, 0.95);
  static final hoverColor = srgb(0.62, 0.74, 0.98);

  void _updateHighlight(int i) {
    final on = selected.contains(i) || hovered == i;
    if (!on) {
      highlightMesh.setInstanceTransform(i, vm.Matrix4.zero());
      return;
    }
    final lift = moving.contains(i) ? 0.5 : 0.0;
    highlightMesh
      ..setInstanceTransform(i, vm.Matrix4.translation(toWorld(g.nodes[i].center, lift - 0.15)))
      ..setInstanceColor(i, selected.contains(i) ? selectedColor : hoverColor);
  }

  void _select(Iterable<int> nodes, {bool toggle = false}) {
    final before = {...selected};
    if (!toggle) selected.clear();
    for (final i in nodes) {
      if (toggle && before.contains(i)) {
        selected.remove(i);
      } else {
        selected.add(i);
      }
    }
    for (final i in {...before, ...selected}) {
      _updateHighlight(i);
    }
    a11yDirty = true;
  }

  void _hover(int? i) {
    if (i == hovered) return;
    final old = hovered;
    hovered = i;
    if (old != null) _updateHighlight(old);
    if (i != null) _updateHighlight(i);
  }

  // ----- pointer input: hit testing in canvas coordinates -----

  Offset toCanvas(Offset local) =>
      widget.view.center + (local - Offset(viewport.width / 2, viewport.height / 2)) / widget.view.scale;

  int? hitNode(Offset c) {
    int? hit;
    for (final i in nodesIn(Rect.fromCenter(center: c, width: 1, height: 1))) {
      if (g.nodes[i].rect.contains(c)) hit = i;
    }
    return hit;
  }

  /// The node whose output port is under [c] (within 10 screen pixels).
  int? hitOutPort(Offset c) {
    final r = max(10 / widget.view.scale, 4.0);
    for (final i in nodesIn(Rect.fromCenter(center: c, width: 2 * r, height: 2 * r))) {
      if ((g.nodes[i].outPort - c).distance <= r) return i;
    }
    return null;
  }

  String gesture = 'none'; // none, pan, move, connect, marquee
  Offset downLocal = Offset.zero;
  Offset lastCanvas = Offset.zero;
  Offset panCenter = Offset.zero;
  bool movedSinceDown = false;
  int? connectFrom;
  Node? connectPreview;
  final marquee = ValueNotifier<Rect?>(null);

  /// Box selection needs Shift (forced by the benchmark, which cannot hold a key).
  bool forceMarquee = false;
  bool get marqueeModifier => forceMarquee || HardwareKeyboard.instance.isShiftPressed;

  /// Called when an input has changed what is drawn (the benchmark times event to frame).
  void Function(String kind)? onInputApplied;

  void _onDown(PointerDownEvent e) {
    if (e.buttons & kPrimaryButton == 0) return;
    downLocal = e.localPosition;
    final c = toCanvas(e.localPosition);
    lastCanvas = c;
    movedSinceDown = false;
    final port = hitOutPort(c);
    final hit = hitNode(c);
    if (port != null) {
      gesture = 'connect';
      connectFrom = port;
    } else if (hit != null) {
      gesture = 'move';
      if (!selected.contains(hit)) _select([hit], toggle: HardwareKeyboard.instance.isShiftPressed);
      onInputApplied?.call('select');
    } else if (marqueeModifier) {
      gesture = 'marquee';
    } else {
      gesture = 'pan';
      panCenter = widget.view.center;
    }
  }

  void _onMove(PointerMoveEvent e) {
    final c = toCanvas(e.localPosition);
    if (!movedSinceDown && (e.localPosition - downLocal).distance < 3) return;
    switch (gesture) {
      case 'pan':
        widget.view.center = panCenter - (e.localPosition - downLocal) / widget.view.scale;
        onInputApplied?.call('pan');
      case 'move':
        if (!movedSinceDown) _beginMove({...selected});
        _moveBy(c - lastCanvas);
        onInputApplied?.call('move');
      case 'connect':
        _showConnectPreview(g.nodes[connectFrom!].outPort, c);
        onInputApplied?.call('connect');
      case 'marquee':
        marquee.value = Rect.fromPoints(downLocal, e.localPosition);
        onInputApplied?.call('marquee');
    }
    movedSinceDown = true;
    lastCanvas = c;
  }

  void _onUp(PointerUpEvent e) {
    final c = toCanvas(e.localPosition);
    switch (gesture) {
      case 'move':
        if (movedSinceDown) _endMove();
      case 'pan':
        if (!movedSinceDown) {
          _select(const []); // a click on empty canvas clears the selection
          onInputApplied?.call('select');
        }
      case 'connect':
        _showConnectPreview(null, null);
        final target = hitNode(c);
        if (target != null && target != connectFrom) {
          g.edges.add(GEdge(connectFrom!, target));
          _rebuildEdges();
          onInputApplied?.call('connected');
        }
        connectFrom = null;
      case 'marquee':
        final r = marquee.value;
        marquee.value = null;
        if (r != null) {
          final cr = Rect.fromPoints(toCanvas(r.topLeft), toCanvas(r.bottomRight));
          _select([
            for (final i in nodesIn(cr))
              if (cr.overlaps(g.nodes[i].rect)) i,
          ]);
          onInputApplied?.call('select');
        }
    }
    gesture = 'none';
  }

  void _onHover(PointerHoverEvent e) {
    final h = hitNode(toCanvas(e.localPosition));
    if (h != hovered) {
      _hover(h);
      onInputApplied?.call('hover');
    }
  }

  void _onSignal(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    // Zoom around the pointer: the canvas point under it stays put.
    final v = widget.view, c = toCanvas(e.localPosition);
    v.scale = (v.scale * exp(-e.scrollDelta.dy / 400)).clamp(0.05, 4.0);
    v.center = c - (e.localPosition - Offset(viewport.width / 2, viewport.height / 2)) / v.scale;
    onInputApplied?.call('zoom');
  }

  void _showConnectPreview(Offset? from, Offset? to) {
    if (connectPreview != null) scene.remove(connectPreview!);
    connectPreview = null;
    if (from == null || to == null || !kEdges) return;
    final dx = max(40.0, (to.dx - from.dx).abs() / 2);
    final c1 = from + Offset(dx, 0), c2 = to - Offset(dx, 0);
    final out = <double>[];
    vm.Vector3? prev;
    for (var k = 0; k <= 16; k++) {
      final t = k / 16, u = 1 - t;
      final p = toWorld(from * (u * u * u) + c1 * (3 * u * u * t) + c2 * (3 * u * t * t) + to * (t * t * t), 0.6);
      if (prev != null) out.addAll([prev.x, prev.y, prev.z, p.x, p.y, p.z]);
      prev = p;
    }
    connectPreview = Node(
      mesh: Mesh(
        LineSegmentsGeometry(LineSegmentData(positions: Float32List.fromList(out)), width: 2.5),
        highlightEdgeMaterial,
      ),
    );
    scene.add(connectPreview!);
  }

  late final UnlitMaterial highlightEdgeMaterial;

  // ----- accessibility: the canvas's own compact semantics -----

  /// What the semantics layer shows: per-card entries (screen rect, label) or one summary; rebuilt at rest.
  final a11y = ValueNotifier<(List<(Rect, int)>, String?)>((const [], null));
  int a11yBuiltAt = -1;
  int a11yBuilds = 0;
  static const a11yMaxCards = 200;

  void _updateA11y() {
    if (!kA11y || viewport.isEmpty) return;
    final v = widget.view, view = visibleRect(v, viewport);
    final on = [
      for (final i in nodesIn(view))
        if (view.overlaps(g.nodes[i].rect)) i,
    ];
    Rect screenRect(int i) {
      final r = g.nodes[i].rect;
      final o = Offset(viewport.width / 2, viewport.height / 2);
      return Rect.fromPoints((r.topLeft - v.center) * v.scale + o, (r.bottomRight - v.center) * v.scale + o);
    }

    a11yBuilds++;
    if (on.length <= a11yMaxCards) {
      a11y.value = ([for (final i in on) (screenRect(i), i)], null);
      return;
    }
    final byStatus = <String, int>{};
    for (final i in on) {
      byStatus.update(g.nodes[i].status.value, (n) => n + 1, ifAbsent: () => 1);
    }
    final parts = [
      for (final e in byStatus.entries)
        if (e.key != 'idle') '${e.value} ${e.key}',
    ];
    a11y.value = (
      [
        for (final i in selected)
          if (on.contains(i)) (screenRect(i), i),
      ],
      '${on.length} nodes in view${parts.isEmpty ? '' : ', ${parts.join(', ')}'}. Zoom in to read them.',
    );
  }

  String a11yLabel(int i) {
    final n = g.nodes[i];
    return [
      n.title.value,
      '${n.type} node',
      if (n.status.value != 'idle') n.status.value,
      if (selected.contains(i)) 'selected',
    ].join(', ');
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
      pending.add(_upgrade(i, want));
    }
    await Future.wait(pending);
  }

  @override
  int get liveWidgets => attached;

  @override
  /// On-screen cards with a capture below the density the zoom needs (blurry).
  int get unsharpOnScreen {
    final view = visibleRect(widget.view, viewport), want = densityForZoom();
    return [
      for (final i in attachedSet)
        if (view.overlaps(g.nodes[i].rect) && pixelRatios[i] < want) i,
    ].length;
  }

  @override
  Map<String, Object> get stats => {
    'unsharpOnScreen': unsharpOnScreen,
    'a11yBuilds': a11yBuilds,
    'a11yNodes': a11y.value.$1.length + (a11y.value.$2 == null ? 0 : 1),
    'maxAttached': maxAttached,
    'attachedTotal': attachedTotal,
    if (kOverview) 'overviewsDone': overviewsDone,
    if (kOverview) 'statusChanges': statusChanges,
    if (kOverview) 'staleness': stalenessMs,
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
        return Listener(
          onPointerDown: _onDown,
          onPointerMove: _onMove,
          onPointerUp: _onUp,
          onPointerHover: _onHover,
          onPointerSignal: _onSignal,
          child: Stack(
            fit: StackFit.expand,
            children: [
              SceneView(scene, cameraBuilder: (_) => camera(), onTick: (_, _) => _residency()),
              if (kA11y)
                ValueListenableBuilder<(List<(Rect, int)>, String?)>(
                  valueListenable: a11y,
                  builder: (context, a, _) => Stack(
                    children: [
                      if (a.$2 != null) Positioned.fill(child: Semantics(container: true, label: a.$2)),
                      for (final (r, i) in a.$1)
                        Positioned.fromRect(
                          rect: r,
                          child: Semantics(
                            container: true,
                            button: true,
                            selected: selected.contains(i),
                            label: a11yLabel(i),
                            onTap: () => _select([i]),
                          ),
                        ),
                    ],
                  ),
                ),
              IgnorePointer(
                child: ValueListenableBuilder<Rect?>(
                  valueListenable: marquee,
                  builder: (context, r, _) => CustomPaint(painter: MarqueePainter(r)),
                ),
              ),
            ],
          ),
        );
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

class MarqueePainter extends CustomPainter {
  MarqueePainter(this.rect);
  final Rect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final r = rect;
    if (r == null) return;
    canvas
      ..drawRect(r, Paint()..color = const Color(0x1F2A6BF2))
      ..drawRect(
        r,
        Paint()
          ..color = const Color(0xFF2A6BF2)
          ..style = PaintingStyle.stroke,
      );
  }

  @override
  bool shouldRepaint(MarqueePainter old) => old.rect != rect;
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
  Future<void> _waitOverviews() async {
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
  }

  Future<void> _zoomBack() async {
    await _waitOverviews();
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

  /// Zoomed out over the graph (RUN_SCALE, default 0.15): a workflow run sweeps through every node (running, then
  /// succeeded or failed 0.4 s later, 400 nodes/s) while another user renames 20 on-screen nodes per second.
  Future<void> _runWorkflow() async {
    await _waitOverviews();
    final saved = (view.center, view.scale);
    view
      ..center = const Offset(3700, 3300)
      ..scale = double.parse(env('RUN_SCALE', '0.15'));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final visible = [
      for (var i = 0; i < graph.nodes.length; i++)
        if (visibleRect(view, const Size(1600, 1000)).overlaps(graph.nodes[i].rect)) i,
    ];
    stdout.writeln('RUN_START');
    var started = 0, finished = 0, edits = 0;
    var lastEdit = 0.0;
    var midShot = false;
    final c0 = canvas.stats['statusChanges'] as int? ?? 0;
    await _phase('run', 6, (t) {
      final run = t - 0.3; // recording starts at 0.3
      if (run < 0) return;
      if (run >= 2.5 && !midShot) {
        midShot = true;
        unawaited(_shot('run-mid'));
      }
      while (started < graph.nodes.length && started / 400 <= run) {
        graph.nodes[started++].status.value = 'running';
      }
      while (finished < started && finished / 400 + 0.4 <= run) {
        graph.nodes[finished].status.value = finished % 37 == 0 ? 'failed' : 'succeeded';
        finished++;
      }
      while (lastEdit < run) {
        lastEdit += 0.05;
        final i = visible[rng.nextInt(visible.length)];
        canvas.editTitle(i, '${graph.nodes[i].type} $i · edit ${++edits}');
      }
    });
    // Let the last overviews land, then read their staleness.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    await _shot('run-end');
    final st = [...(canvas.stats['staleness'] as List<double>? ?? const <double>[])]..sort();
    double q(double p) => st.isEmpty ? 0 : st[min(st.length - 1, (p * st.length).floor())];
    final extra = <String, Object>{
      'visibleCards': visible.length,
      'statusChanges': (canvas.stats['statusChanges'] as int? ?? 0) - c0,
      'edits': edits,
      'overviewRefreshes': st.length,
      'staleP50Ms': r1(q(.5)),
      'staleP99Ms': r1(q(.99)),
      'staleMaxMs': r1(st.isEmpty ? 0 : st.last),
    };
    results.last.addAll(extra);
    stdout.writeln('RUN ${jsonEncode(extra)}');
    view
      ..center = saved.$1
      ..scale = saved.$2;
  }

  /// Synthetic mouse input on the scene canvas: hover, click-select, drag a node, connect two nodes, pan, wheel zoom,
  /// box select. For each input that changed what is drawn: time from that change to the end of rasterizing the next
  /// frame (FrameTiming and Timeline.now share the monotonic clock). Each gesture's outcome is checked.
  Future<void> _inputTest() async {
    final sc = canvasKey.currentState;
    if (sc is! SceneCanvasState) return;
    view
      ..center = const Offset(3700, 3000)
      ..scale = 1;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final box = canvasKey.currentContext!.findRenderObject()! as RenderBox;
    final vp = box.size;
    Offset screen(Offset c) => box.localToGlobal((c - view.center) * view.scale + Offset(vp.width / 2, vp.height / 2));
    final applied = <(String, int)>[];
    sc.onInputApplied = (kind) => applied.add((kind, Timeline.now));
    var pointer = 10;
    final checks = <String, bool>{};
    Future<void> step([int ms = 8]) => Future<void>.delayed(Duration(milliseconds: ms));
    void send(PointerEvent e) => GestureBinding.instance.handlePointerEvent(e);
    Future<void> drag(Offset from, Offset to, int steps) async {
      final id = ++pointer;
      send(PointerDownEvent(pointer: id, position: from, buttons: kPrimaryButton));
      await step();
      for (var k = 1; k <= steps; k++) {
        send(PointerMoveEvent(pointer: id, position: Offset.lerp(from, to, k / steps)!, buttons: kPrimaryButton));
        await step();
      }
      send(PointerUpEvent(pointer: id, position: to));
      await step(60);
    }

    final onScreen = [
      for (var i = 0; i < graph.nodes.length; i++)
        if (visibleRect(view, vp).deflate(60).contains(graph.nodes[i].rect.center)) i,
    ];
    final p = Phase('input', 0);
    final sw0 = Stopwatch()..start();
    current = p;
    // Hover across 30 cards.
    for (var k = 0; k < 30; k++) {
      send(PointerHoverEvent(position: screen(graph.nodes[onScreen[k % onScreen.length]].center)));
      await step(40);
    }
    // Click to select 20 cards.
    var clicksOk = true;
    for (var k = 0; k < 20; k++) {
      final i = onScreen[(k * 3) % onScreen.length], id = ++pointer;
      send(PointerDownEvent(pointer: id, position: screen(graph.nodes[i].center), buttons: kPrimaryButton));
      send(PointerUpEvent(pointer: id, position: screen(graph.nodes[i].center)));
      await step(60);
      clicksOk &= sc.selected.length == 1 && sc.selected.contains(i);
    }
    checks['click selects the card'] = clicksOk;
    // Drag the selected card by (360, 180) screen pixels.
    final k0 = onScreen[5];
    final before = Offset(graph.nodes[k0].x, graph.nodes[k0].y);
    final from = screen(graph.nodes[k0].center);
    await drag(from, from + const Offset(360, 180), 90);
    final moved = Offset(graph.nodes[k0].x, graph.nodes[k0].y) - before;
    checks['drag moves the card by the pointer distance'] = (moved - const Offset(360, 180)).distance < 4;
    // Connect: from a card's output port to another card.
    final a = onScreen[1], b = onScreen[onScreen.length - 2], edges0 = graph.edges.length;
    await drag(screen(graph.nodes[a].outPort), screen(graph.nodes[b].center), 40);
    checks['dragging from a port connects'] =
        graph.edges.length == edges0 + 1 && graph.edges.last.source == a && graph.edges.last.target == b;
    // Pan from an empty spot between rows.
    final empty = Offset(graph.nodes[onScreen[0]].x + 150, graph.nodes[onScreen[0]].y + 130);
    final c0 = view.center;
    await drag(screen(empty), screen(empty) + const Offset(-360, -180), 90);
    checks['dragging empty canvas pans'] = ((view.center - c0) - const Offset(360, 180)).distance < 4;
    // Wheel zoom, in and out.
    final s0 = view.scale;
    for (var k = 0; k < 20; k++) {
      send(PointerScrollEvent(position: screen(view.center), scrollDelta: Offset(0, k < 10 ? -40 : 40)));
      await step(16);
    }
    checks['wheel zoom returns to the same zoom'] = (view.scale - s0).abs() < 1e-6;
    // Box select a 3 x 2 block of cards (Shift is forced: a benchmark cannot hold a key).
    sc.forceMarquee = true;
    // A card near the middle of the (now panned) view, with two cards to its right and one row below.
    final n0 = graph.nodes.firstWhere(
      (n) => visibleRect(view, vp).deflate(300).contains(n.rect.center) && n.x < 22 * 300,
    );
    final boxFrom = screen(Offset(n0.x - 20, n0.y - 20));
    await drag(boxFrom, screen(Offset(n0.x + 2 * 300 + 100, n0.y + 180 + 60)), 40);
    sc.forceMarquee = false;
    checks['box select picks the 3 x 2 block'] = sc.selected.length == 6;
    if (kA11y) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final cardsInView = [
        for (final n in graph.nodes)
          if (visibleRect(view, vp).overlaps(n.rect)) n,
      ].length;
      final labels = semanticsLabels();
      checks['semantics: one node per card in view'] = labels.where((l) => l.contains(' node')).length == cardsInView;
      checks['semantics: selected cards say so'] = labels.where((l) => l.endsWith('selected')).length == 6;
      view.scale = 0.2;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      checks['semantics: one summary when zoomed out'] = semanticsLabels().any((l) => l.contains('nodes in view'));
      view.scale = 1;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    current = null;
    sc.onInputApplied = null;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final frames = [...p.timings]
      ..sort(
        (x, y) => x
            .timestampInMicroseconds(ui.FramePhase.buildStart)
            .compareTo(y.timestampInMicroseconds(ui.FramePhase.buildStart)),
      );
    final lat = <String, List<double>>{};
    for (final (kind, t) in applied) {
      for (final f in frames) {
        if (f.timestampInMicroseconds(ui.FramePhase.buildStart) >= t) {
          (lat[kind] ??= []).add((f.timestampInMicroseconds(ui.FramePhase.rasterFinish) - t) / 1000);
          break;
        }
      }
    }
    final summary = summarize(Phase('input', sw0.elapsedMilliseconds / 1000)..timings.addAll(p.timings));
    final extra = <String, Object>{
      'latencyMs': {
        for (final e in lat.entries)
          e.key: {
            'n': e.value.length,
            'p50': r1(pct(e.value, .5)),
            'p99': r1(pct(e.value, .99)),
            'max': r1(e.value.reduce(max)),
          },
      },
      'checks': checks,
    };
    summary.addAll(extra);
    results.add(summary);
    stdout.writeln('PERF ${jsonEncode(summary)}');
    stdout.writeln('INPUT ${jsonEncode(extra)}');
    await _shot('after-input');
  }

  List<String> semanticsLabels() {
    final out = <String>[];
    void visit(SemanticsNode n) {
      if (n.label.isNotEmpty) out.add(n.label);
      n.visitChildren((c) {
        visit(c);
        return true;
      });
    }

    final root = RendererBinding.instance.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
    if (root != null) visit(root);
    return out;
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
    if (kPhases.contains('run')) await _runWorkflow();
    if (kPhases.contains('input')) await _inputTest();
    if (kPhases.contains('autosharp')) {
      // Zoom in by a jump and let the view rest: on-screen cards must end up captured at the new density.
      view
        ..center = const Offset(3700, 3000)
        ..scale = 1;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      view.scale = 2;
      final sw1 = Stopwatch()..start();
      var unsharp = -1;
      while (sw1.elapsedMilliseconds < 3000) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        unsharp = canvas.stats['unsharpOnScreen'] as int? ?? -1;
        if (unsharp == 0) break;
      }
      stdout.writeln('AUTOSHARP ${jsonEncode({'unsharpOnScreen': unsharp, 'ms': sw1.elapsedMilliseconds})}');
      await _shot('autosharp');
    }
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
