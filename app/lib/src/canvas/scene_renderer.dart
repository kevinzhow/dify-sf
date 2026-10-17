import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../design/dify_tokens.g.dart';
import 'canvas_graph.dart';
import 'canvas_renderer.dart';
import 'canvas_selection.dart';
import 'canvas_view_state.dart';
import 'edge_curve.dart';
import 'node_card.dart';

/// Canvas (x right, y down) to world: the camera sits on -Z looking along +Z (world +X is screen-right, +Y up);
/// [lift] is the distance in front of the canvas plane (towards the camera).
vm.Vector3 toWorld(Offset p, [double lift = 0]) => vm.Vector3(p.dx, -p.dy, -lift);

/// A screen colour (sRGB) as the scene's linear colour, so it reaches the screen unchanged (linear tone mapping).
vm.Vector4 srgb(Color c) {
  double lin(double v) => v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4).toDouble();
  return vm.Vector4(lin(c.r), lin(c.g), lin(c.b), 1);
}

/// A 1 x 1 quad facing the camera, scaled per card. WidgetComponent's own quad maps the texture as seen from +Z,
/// so from our -Z camera it would show cards mirrored; this one flips u.
final Geometry _unitQuad = MeshGeometry.fromArrays(
  positions: Float32List.fromList([0.5, -0.5, 0, -0.5, -0.5, 0, -0.5, 0.5, 0, 0.5, 0.5, 0]),
  texCoords: Float32List.fromList([1, 1, 0, 1, 0, 0, 1, 0]),
  indices: [0, 1, 3, 3, 1, 2],
);

vm.Matrix4 _box(Offset center, Size size, double lift) =>
    vm.Matrix4.translation(toWorld(center, lift))..scaleByVector3(vm.Vector3(size.width, size.height, 1));

/// Tuning (the web reads every capture back, so it does fewer per frame).
class SceneTuning {
  static final captureBudget = kIsWeb ? 8 : 24;
  static final overviewBudget = kIsWeb ? 2 : 6;
  static const sharpenBudget = 8;
  static const releaseBudget = 24;

  /// Overview captures are exact up to this zoom; below it no live captures are started.
  static const overviewMaxScale = 0.5;

  /// Below this zoom cards come from one capture per node type.
  static const skeletonScale = 0.2;

  /// A card's overview is refreshed at most this often (bursts of changes coalesce).
  static const overviewIntervalUs = 300000;

  /// Edges are 2 canvas units wide (React Flow draws them in canvas space, so they scale with the zoom).
  static const edgeWidth = 2.0;

  /// Captures include this much around the card, for its shadow (shadow-lg reaches about 24 px below).
  static const capturePad = 24.0;
}

/// The card border by run status (getNodeStatusBorders) and the selected frame (option-card selected border).
const _statusColors = {
  'running': DifyColors.stateAccentSolid,
  'paused': DifyColors.stateAccentSolid,
  'succeeded': DifyColors.stateSuccessSolid,
  'failed': DifyColors.stateDestructiveSolid,
  'exception': DifyColors.stateWarningSolid,
};

/// Draws the canvas with Flutter Scene.
///
/// * Live tier: cards at 0.5x or more near the view hold a live `WidgetComponent`, recaptured when they repaint
///   (off-screen ones a few per frame), and at rest recaptured at the density the zoom needs.
/// * Delayed tier: every card has an overview capture (half density), made in the background while the view rests
///   and refreshed when its content changes (on-screen cards first, coalesced); it is the card below 0.5x.
/// * Below 0.2x cards come from one capture per node type, one instanced draw per type.
/// * Status, selection and hover are instanced frames behind the cards, never in a capture.
/// * No capture or release work runs while the view moves.
class SceneRenderer extends CanvasRenderer {
  SceneRenderer({
    required this.graph,
    required this.view,
    required this.selection,
    required this.cards,
    required this.onUnavailable,
  }) {
    Scene.initializeStaticResources().then((_) => _start(), onError: (Object e) => onUnavailable(e));
  }

  final CanvasGraph graph;
  final CanvasViewState view;
  final CanvasSelection selection;
  final CardSpec cards;
  final void Function(Object error) onUnavailable;

  final scene = Scene();
  final _ready = ValueNotifier(false);
  bool _disposed = false;

  // Per slot.
  final _cardNodes = <Node?>[];
  final _live = <WidgetComponent?>[];
  final _density = <double>[];
  final _placeholderNodes = <Node?>[];
  final _placeholders = <UnlitMaterial?>[];
  final _hasOverview = <bool>[];
  final _dirtySince = <int?>[];
  final _captureStartedAt = <int>[];
  final _lastOverviewAt = <int>[];
  final _skeleton = <(String, int)?>[];

  final _attached = <int>{};
  final _replaced = <int, WidgetComponent>{};
  final _liveStale = <int>{};
  final _overviewQueue = <int>[];
  final _overviewInFlight = <int, WidgetComponent>{};
  final _dirty = <int>{};

  final _overviewLayer = Node();
  final _skeletonLayer = Node()..visible = false;
  final _skeletonMeshes = <String, InstancedMesh>{};
  final _skeletonTextures = <String, GpuTextureSource>{};
  final _skeletonRequested = <String>{};
  bool _skeletonOn = false;

  late final _RoundedFrames _statusFrames;
  late final _RoundedFrames _selectedFrames;
  late final InstancedMesh _markers;
  // One marker instance per connected handle: (slot, handle id or '' for the target handle) -> instance.
  final _markerAt = <(int, String), int>{};
  final _markerFree = <int>[];
  late final UnlitMaterial _edgeMaterial;
  late final UnlitMaterial _selectedEdgeMaterial;
  late final UnlitMaterial _previewMaterial;
  Node? _staticEdges;
  Node? _liveEdges;
  Node? _selectedEdge;
  Node? _preview;

  Set<int> _moving = {};
  Offset? _lastCenter;
  double _lastScale = 0;
  int _lastMove = 0;
  bool _settled = false;
  int _settledAt = 0;

  int _nowUs() => DateTime.now().microsecondsSinceEpoch;
  double get _dpr => WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  void _start() {
    if (_disposed) return;
    scene.toneMapping = ToneMappingMode.linear; // a flat 2D canvas: colours pass through unchanged
    // Dify's edge colours (custom-edge.tsx, custom-connection-line.tsx).
    _edgeMaterial = UnlitMaterial()..baseColorFactor = srgb(DifyColors.workflowLinkLineNormal);
    _selectedEdgeMaterial = UnlitMaterial()..baseColorFactor = srgb(DifyColors.workflowLinkLineHandle);
    _previewMaterial = UnlitMaterial()..baseColorFactor = srgb(const Color(0xFFD0D5DD));
    // Opaque scene geometry behind the cards. (Display-referred surfaces are composited without depth order among
    // themselves, which would draw the frames over the cards.)
    _statusFrames = _RoundedFrames(scene);
    _selectedFrames = _RoundedFrames(scene);
    _markers = InstancedMesh(geometry: _unitQuad, material: UnlitMaterial(), sortTransparentInstances: false);
    scene
      ..add(Node()..addComponent(InstancedMeshComponent(_markers)))
      ..add(_overviewLayer)
      ..add(_skeletonLayer);
    _ready.value = true;
    final everything = CanvasChange()..edgesChanged = true;
    everything.added.addAll(graph.nodes);
    apply(everything);
  }

  // ----- document changes -----

  @override
  void apply(CanvasChange change) {
    if (!_ready.value) return; // _start applies everything
    for (final n in change.removed) {
      _removeSlot(n.slot);
    }
    for (final n in change.added) {
      _addSlot(n);
    }
    for (final n in [...change.moved, ...change.resized]) {
      if (change.resized.contains(n) && _live[n.slot] != null) {
        _detach(n.slot); // recaptured at the new size by residency
      }
      _place(n.slot);
    }
    for (final n in change.changed) {
      _markDirty(n.slot);
    }
    if (change.edgesChanged) _rebuildEdges();
    _settled = false;
  }

  void _grow(int slot) {
    while (_cardNodes.length <= slot) {
      _cardNodes.add(null);
      _live.add(null);
      _density.add(0);
      _placeholderNodes.add(null);
      _placeholders.add(null);
      _hasOverview.add(false);
      _dirtySince.add(null);
      _captureStartedAt.add(0);
      _lastOverviewAt.add(0);
      _skeleton.add(null);
    }
  }

  void _addSlot(CanvasNode n) {
    final slot = n.slot;
    _grow(slot);
    final card = Node(name: n.id);
    _cardNodes[slot] = card;
    scene.add(card);
    final m = UnlitMaterial()
      ..baseColorFactor = srgb(const Color(0xFFF8F7FF))
      ..alphaMode = AlphaMode.blend
      ..displayReferred = true;
    final type = _skeletonTextures[n.type];
    if (type != null) {
      m
        ..baseColorTexture = type
        ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
    }
    _placeholders[slot] = m;
    final pn = Node(mesh: Mesh(_unitQuad, m));
    _placeholderNodes[slot] = pn;
    _overviewLayer.add(pn);
    _hasOverview[slot] = false;
    _dirtySince[slot] = null;
    _ensureSkeleton(n.type);
    final mesh = _skeletonMeshes[n.type]!;
    _skeleton[slot] = (n.type, mesh.addInstance(vm.Matrix4.zero()));
    _overviewQueue.add(slot);
    _place(slot);
    _statusChanged(slot);
  }

  void _removeSlot(int slot) {
    if (slot >= _cardNodes.length) return;
    if (_live[slot] != null) _detach(slot);
    final inflight = _overviewInFlight.remove(slot);
    if (inflight != null && inflight.isAttached) _cardNodes[slot]?.removeComponent(inflight);
    final card = _cardNodes[slot];
    if (card != null) scene.remove(card);
    final pn = _placeholderNodes[slot];
    if (pn != null) _overviewLayer.remove(pn);
    _cardNodes[slot] = null;
    _placeholderNodes[slot] = null;
    _placeholders[slot] = null;
    final sk = _skeleton[slot];
    if (sk != null) _skeletonMeshes[sk.$1]?.setInstanceTransform(sk.$2, vm.Matrix4.zero());
    _skeleton[slot] = null;
    _statusFrames.clear(slot);
    _selectedFrames.clear(slot);
    for (final k in [..._markerAt.keys.where((k) => k.$1 == slot)]) {
      _dropMarker(k);
    }
    _overviewQueue.remove(slot);
    _dirty.remove(slot);
    _liveStale.remove(slot);
  }

  /// Distance in front of the canvas: moving nodes above all, then selected nodes, then later nodes above earlier
  /// ones (tiny steps, so overlapping cards stack like the widget renderer and hit testing).
  double _lift(int slot) {
    final n = graph.slots[slot];
    if (n == null) return 0;
    if (_moving.contains(slot)) return 0.5 + n.depth * 0.3;
    // Nested nodes above their container (even a selected one), then selected nodes, then later above earlier.
    return n.depth * 0.3 + (selection.nodes.contains(slot) ? 0.2 : 0) + (n.order % 100000) * 1e-6;
  }

  /// Puts every visual of [slot] where its node is; a moving node is lifted towards the camera.
  void _place(int slot) {
    final n = graph.slots[slot];
    final card = _cardNodes[slot];
    if (n == null || card == null) return;
    final lift = _lift(slot);
    // Captures cover everything drawn for the node (the visual rectangle) plus room for the shadow.
    final padded = n.visual.size + const Offset(2 * SceneTuning.capturePad, 2 * SceneTuning.capturePad);
    final center = n.visual.center;
    card
      ..position = toWorld(center, lift)
      ..scale = vm.Vector3(padded.width, padded.height, 1);
    _placeholderNodes[slot]
      ?..position = toWorld(center, lift - 0.05)
      ..scale = vm.Vector3(padded.width, padded.height, 1);
    final sk = _skeleton[slot];
    if (sk != null) _skeletonMeshes[sk.$1]!.setInstanceTransform(sk.$2, _box(center, padded, lift - 0.05));
    _statusChanged(slot);
    _highlight(slot);
    _placeMarkers(slot);
  }

  /// The handles' visible markers (node-handle.tsx `after:`): 2 x 8 bars, 6 px inside the handle box's outer side and
  /// 4 px below its top, only on handles that have an edge.
  void _placeMarkers(int slot) {
    final n = graph.slots[slot];
    if (n == null) return;
    final lift = _lift(slot) + 0.02;
    for (final MapEntry(key: k, value: at) in _markerAt.entries) {
      if (k.$1 != slot) continue;
      final Rect bar;
      if (k.$2.isEmpty) {
        bar = Rect.fromLTWH(n.inHandle.left + 6, n.inHandle.top + 4, 2, 8);
      } else {
        final port = n.outPortFor(k.$2);
        bar = Rect.fromLTWH(port.dx - 8, port.dy - 4, 2, 8);
      }
      _markers.setInstanceTransform(at, _box(bar.center, bar.size, lift));
    }
  }

  void _dropMarker((int, String) k) {
    final at = _markerAt.remove(k);
    if (at == null) return;
    _markers.setInstanceTransform(at, vm.Matrix4.zero());
    _markerFree.add(at);
  }

  /// Markers for exactly the handles that have edges.
  void _syncMarkers() {
    final want = <(int, String)>{
      for (final e in graph.edges) ...[(e.target, ''), (e.source, _handleKey(e))],
    };
    for (final k in [..._markerAt.keys]) {
      if (!want.contains(k)) _dropMarker(k);
    }
    for (final k in want) {
      _markerAt.putIfAbsent(
        k,
        () => _markerFree.isNotEmpty
            ? _markerFree.removeLast()
            : _markers.addInstance(vm.Matrix4.zero(), color: srgb(DifyColors.workflowLinkLineHandle)),
      );
    }
    for (final slot in {for (final k in want) k.$1}) {
      if (slot < _cardNodes.length) _placeMarkers(slot);
    }
  }

  /// The source handle an edge leaves from, as the layout knows it.
  String _handleKey(CanvasEdge e) {
    final n = graph.slots[e.source];
    if (n == null || n.layout.sources.containsKey(e.sourceHandle)) return e.sourceHandle;
    return n.layout.sources.keys.firstOrNull ?? 'source';
  }

  // ----- status and selection frames -----

  /// The card's own 1 px border in the run status colour: a rounded rectangle the size of the card (radius 15)
  /// behind it, seen through the card's transparent border.
  void _statusChanged(int slot) {
    final n = graph.slots[slot];
    final color = n == null ? null : _statusColors[n.status.value];
    if (n == null || color == null) {
      _statusFrames.clear(slot);
      return;
    }
    _statusFrames.set(slot, n.rect, DifyRadius.nodeCard, srgb(color), _lift(slot) - 0.1);
  }

  /// The selected frame: 1 px outside the card (radius 16), option-card selected border.
  void _highlight(int slot) {
    final n = graph.slots[slot];
    if (n == null || !selection.nodes.contains(slot)) {
      _selectedFrames.clear(slot);
      return;
    }
    _selectedFrames.set(
      slot,
      n.rect.inflate(1),
      DifyRadius.xxl,
      srgb(DifyColors.componentsOptionCardOptionSelectedBorder),
      _lift(slot) - 0.15,
    );
  }

  @override
  void statusChanged(int slot) {
    if (_ready.value && slot < _cardNodes.length) _statusChanged(slot);
  }

  @override
  void selectionChanged(Set<int> slots) {
    if (!_ready.value) return;
    for (final s in slots) {
      if (s < _cardNodes.length) _place(s);
    }
    _showSelectedEdge();
  }

  // ----- moving -----

  @override
  void beginMove(Set<int> slots) {
    _moving = {...slots};
    if (!_ready.value) return;
    _rebuildEdges();
    for (final s in _moving) {
      _place(s);
    }
  }

  @override
  void moved(Iterable<int> slots) {
    if (!_ready.value) return;
    for (final s in slots) {
      _place(s);
    }
    _replaceEdgeNode(_liveEdges, (n) => _liveEdges = n, _edgesWhere(live: true), _edgeMaterial);
    _replaceEdgeNode(
      _nestedLiveEdges,
      (n) => _nestedLiveEdges = n,
      _edgesWhere(live: true, nested: true),
      _edgeMaterial,
      lift: 0.75,
    );
  }

  @override
  void endMove(Set<int> slots) {
    _moving = {};
    if (!_ready.value) return;
    for (final s in slots) {
      _place(s);
    }
    _rebuildEdges();
  }

  // ----- edges -----

  Iterable<CanvasEdge> _edgesWhere({required bool live, bool nested = false}) => graph.edges.where(
    (e) =>
        (_moving.contains(e.source) || _moving.contains(e.target)) == live &&
        ((graph.slots[e.source]?.depth ?? 0) > 0) == nested,
  );

  Node? _edgeNode(
    Iterable<CanvasEdge> edges,
    UnlitMaterial material, {
    double lift = -1,
  }) {
    final out = <double>[];
    for (final e in edges) {
      final a = graph.slots[e.source], b = graph.slots[e.target];
      if (a == null || b == null) continue;
      final pts = edgeCurve(a.outPortFor(e.sourceHandle), b.inPort);
      for (var k = 0; k + 1 < pts.length; k++) {
        final p = toWorld(pts[k]), q = toWorld(pts[k + 1]);
        out.addAll([p.x, p.y, p.z, q.x, q.y, q.z]);
      }
    }
    if (out.isEmpty) return null;
    final geometry = LineSegmentsGeometry(
      LineSegmentData(positions: Float32List.fromList(out)),
      width: SceneTuning.edgeWidth,
    );
    return Node(mesh: Mesh(geometry, material))..position = toWorld(Offset.zero, lift);
  }

  void _replaceEdgeNode(
    Node? old,
    void Function(Node?) set,
    Iterable<CanvasEdge> edges,
    UnlitMaterial material, {
    double lift = -1,
  }) {
    if (old != null) scene.remove(old);
    final n = _edgeNode(edges, material, lift: lift);
    if (n != null) scene.add(n);
    set(n);
  }

  // Edges inside containers lie above the container's body and below its children.
  Node? _nestedEdges;
  Node? _nestedLiveEdges;

  void _rebuildEdges() {
    _syncMarkers();
    _replaceEdgeNode(_staticEdges, (n) => _staticEdges = n, _edgesWhere(live: false), _edgeMaterial);
    _replaceEdgeNode(_liveEdges, (n) => _liveEdges = n, _edgesWhere(live: true), _edgeMaterial);
    _replaceEdgeNode(
      _nestedEdges,
      (n) => _nestedEdges = n,
      _edgesWhere(live: false, nested: true),
      _edgeMaterial,
      lift: 0.25,
    );
    _replaceEdgeNode(
      _nestedLiveEdges,
      (n) => _nestedLiveEdges = n,
      _edgesWhere(live: true, nested: true),
      _edgeMaterial,
      lift: 0.75,
    );
    _showSelectedEdge();
  }

  void _showSelectedEdge() {
    final id = selection.edge;
    _replaceEdgeNode(
      _selectedEdge,
      (n) => _selectedEdge = n,
      [if (id != null) ...graph.edges.where((e) => e.id == id)],
      _selectedEdgeMaterial,
      lift: -0.9,
    );
  }

  @override
  void connectPreview(Offset? from, Offset? to) {
    if (!_ready.value) return;
    if (_preview != null) {
      scene.remove(_preview!);
      _preview = null;
    }
    if (from == null || to == null) return;
    final pts = edgeCurve(from, to, inset: 0);
    final out = <double>[];
    for (var k = 0; k + 1 < pts.length; k++) {
      final p = toWorld(pts[k], 0.6), q = toWorld(pts[k + 1], 0.6);
      out.addAll([p.x, p.y, p.z, q.x, q.y, q.z]);
    }
    final geometry = LineSegmentsGeometry(
      LineSegmentData(positions: Float32List.fromList(out)),
      width: SceneTuning.edgeWidth,
    );
    _preview = Node(mesh: Mesh(geometry, _previewMaterial));
    scene.add(_preview!);
  }

  // ----- cards: live components -----

  WidgetComponent _component(int slot, double density) {
    final n = graph.slots[slot]!;
    late final WidgetComponent c;
    c = WidgetComponent(
      // Cards stay out of the semantics tree; the canvas exposes its own summary (CanvasA11y).
      child: ExcludeSemantics(
        child: Builder(
          builder: (context) =>
              _padded(cards.build(context, n, graph, live: true, onPainted: () => _livePainted(slot, c))),
        ),
      ),
      size: n.visual.size + const Offset(2 * SceneTuning.capturePad, 2 * SceneTuning.capturePad),
      pixelRatio: density,
      worldHeight: 1,
      geometry: _unitQuad,
      update: WidgetUpdatePolicy.manual,
      input: WidgetInput.manual,
    );
    return c;
  }

  void _attach(int slot, double density) {
    final c = _component(slot, density);
    // Once the live capture shows, the overview behind it is hidden (its softer edges would show around the card).
    void landed() {
      if (c.controller.texture == null) return;
      c.controller.removeListener(landed);
      if (identical(_live[slot], c) || _replaced[slot] == c) _placeholderNodes[slot]?.visible = false;
    }

    c.controller.addListener(landed);
    _cardNodes[slot]!.addComponent(c);
    _live[slot] = c;
    _density[slot] = density;
    _attached.add(slot);
  }

  /// Replaces [slot]'s capture with one at [density]; the old one stays until the new one lands (no flash).
  void _upgrade(int slot, double density) {
    final old = _live[slot]!, c = _component(slot, density);
    _replaced[slot] = old;
    void landed() {
      if (c.controller.texture == null) return;
      c.controller.removeListener(landed);
      if (identical(_replaced[slot], old)) _replaced.remove(slot);
      if (old.isAttached) _cardNodes[slot]?.removeComponent(old);
    }

    c.controller.addListener(landed);
    _cardNodes[slot]!.addComponent(c);
    _live[slot] = c;
    _density[slot] = density;
  }

  void _detach(int slot) {
    final old = _replaced.remove(slot);
    if (old != null && old.isAttached) _cardNodes[slot]?.removeComponent(old);
    final c = _live[slot];
    if (c != null && c.isAttached) _cardNodes[slot]?.removeComponent(c);
    _live[slot] = null;
    _attached.remove(slot);
    _placeholderNodes[slot]?.visible = true;
  }

  bool _onScreen(int slot) {
    final n = graph.slots[slot];
    return n != null && view.visible.overlaps(n.rect);
  }

  void _livePainted(int slot, WidgetComponent c) {
    _markDirty(slot);
    if (c.controller.texture == null || _onScreen(slot)) {
      c.controller.requestCapture();
    } else {
      _liveStale.add(slot);
    }
  }

  void _liveStep() {
    var offscreen = 4;
    for (final slot in [..._liveStale]) {
      final c = _live[slot];
      if (c == null) {
        _liveStale.remove(slot);
      } else if (_onScreen(slot) || offscreen-- > 0) {
        c.controller.requestCapture();
        _liveStale.remove(slot);
      }
    }
  }

  /// The capture density for the current zoom: the screen's pixel density times the zoom, rounded up to a power of
  /// 2 (small zoom steps do not recapture).
  double _densityForZoom() => _dpr * pow(2, (log(max(1.0, view.scale)) / ln2).ceil()).toDouble();

  // ----- cards: overviews and type cards -----

  void _ensureSkeleton(String type) {
    if (_skeletonMeshes.containsKey(type)) return;
    final material = UnlitMaterial()
      ..alphaMode = AlphaMode.blend
      ..displayReferred = true
      ..baseColorFactor = srgb(const Color(0xFFF8F7FF));
    final mesh = InstancedMesh(geometry: _unitQuad, material: material, sortTransparentInstances: false);
    _skeletonMeshes[type] = mesh;
    _skeletonLayer.addComponent(InstancedMeshComponent(mesh));
    if (!_skeletonRequested.add(type)) return;
    // One capture of a typical card of this type: the look of every card of the type below 0.2x, and of a card
    // until its own overview arrives.
    final sample = graph.nodes.where((n) => n.type == type).firstOrNull;
    if (sample == null) return;
    final host = Node();
    late final WidgetComponent c;
    c = WidgetComponent.bindOnly(
      child: ExcludeSemantics(
        child: Builder(
          builder: (context) =>
              _padded(cards.build(context, sample, graph, live: false, onPainted: () => c.controller.requestCapture())),
        ),
      ),
      size: sample.visual.size + const Offset(2 * SceneTuning.capturePad, 2 * SceneTuning.capturePad),
      pixelRatio: _dpr * SceneTuning.skeletonScale * 2,
      update: WidgetUpdatePolicy.manual,
      input: WidgetInput.manual,
      bind: (texture) {
        final source = GpuTextureSource(texture);
        _skeletonTextures[type] = source;
        material
          ..baseColorTexture = source
          ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
        for (final n in graph.nodes) {
          if (n.type == type && !_hasOverview[n.slot]) {
            _placeholders[n.slot]
              ?..baseColorTexture = source
              ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
          }
        }
        SchedulerBinding.instance.addPostFrameCallback((_) => scene.remove(host));
      },
    );
    host.addComponent(c);
    scene.add(host);
  }

  void _skeletonSwitch() {
    final s = view.scale;
    final want = _skeletonOn ? s < SceneTuning.skeletonScale * 1.05 : s < SceneTuning.skeletonScale * 0.95;
    if (want == _skeletonOn) return;
    _skeletonOn = want;
    _skeletonLayer.visible = want;
    _overviewLayer.visible = !want;
  }

  void _markDirty(int slot) {
    if (slot >= _dirtySince.length || _cardNodes[slot] == null) return;
    _dirtySince[slot] ??= _nowUs();
    _dirty.add(slot);
  }

  int? _nextDirty() {
    if (_dirty.isEmpty) return null;
    final now = _nowUs();
    int? best;
    var bestKey = (2, 0);
    for (final slot in _dirty) {
      if (_overviewInFlight.containsKey(slot) || now - _lastOverviewAt[slot] < SceneTuning.overviewIntervalUs) continue;
      final key = (_onScreen(slot) ? 0 : 1, _dirtySince[slot]!);
      if (best == null || key.$1 < bestKey.$1 || (key.$1 == bestKey.$1 && key.$2 < bestKey.$2)) {
        best = slot;
        bestKey = key;
      }
    }
    return best;
  }

  int? _nextOverview() {
    // New cards nearest the view first.
    if (_overviewQueue.isNotEmpty) {
      final c = view.center;
      var bi = 0;
      var bd = double.infinity;
      for (var i = 0; i < _overviewQueue.length; i++) {
        final n = graph.slots[_overviewQueue[i]];
        final d = n == null ? double.infinity : (n.center - c).distanceSquared;
        if (d < bd) {
          bd = d;
          bi = i;
        }
      }
      return _overviewQueue.removeAt(bi);
    }
    return _nextDirty();
  }

  void _overviewStep() {
    while (_overviewInFlight.length < SceneTuning.overviewBudget) {
      final slot = _nextOverview();
      if (slot == null) break;
      final n = graph.slots[slot], card = _cardNodes[slot];
      if (n == null || card == null) continue;
      _captureStartedAt[slot] = _nowUs();
      late final WidgetComponent c;
      c = WidgetComponent.bindOnly(
        child: ExcludeSemantics(
          child: Builder(
            builder: (context) =>
                _padded(cards.build(context, n, graph, live: false, onPainted: () => c.controller.requestCapture())),
          ),
        ),
        size: n.visual.size + const Offset(2 * SceneTuning.capturePad, 2 * SceneTuning.capturePad),
        pixelRatio: _dpr * SceneTuning.overviewMaxScale,
        update: WidgetUpdatePolicy.manual,
        input: WidgetInput.manual,
        bind: (texture) {
          // The wrapped texture keeps its image alive after the component (and its host) is gone.
          _placeholders[slot]
            ?..baseColorTexture = GpuTextureSource(texture)
            ..baseColorFactor = vm.Vector4(1, 1, 1, 1);
          _hasOverview[slot] = true;
          final now = _nowUs(), since = _dirtySince[slot];
          _lastOverviewAt[slot] = now;
          if (since != null && since <= _captureStartedAt[slot]) {
            _dirtySince[slot] = null;
            _dirty.remove(slot);
          }
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (c.isAttached) _cardNodes[slot]?.removeComponent(c);
            _overviewInFlight.remove(slot);
          });
        },
      );
      _overviewInFlight[slot] = c;
      card.addComponent(c);
    }
  }

  // ----- per frame -----

  /// Keeps live components on the cards near the view, releases far ones, sharpens at rest, refreshes overviews.
  void _tick() {
    if (view.viewport.isEmpty) return;
    _skeletonSwitch();
    final now = _nowUs();
    if (view.center != _lastCenter || view.scale != _lastScale) _lastMove = now;
    _lastCenter = view.center;
    _lastScale = view.scale;
    // Every card already shows real content (live or overview), so capture work waits until the view rests.
    if (now - _lastMove < 150000) return;
    _liveStep();
    _overviewStep();
    if (_settled && _lastMove <= _settledAt && _moving.isEmpty) return;
    final visible = view.visible;
    final keep = visible.inflate(max(visible.width, visible.height) / 2);
    final drop = visible.inflate(max(visible.width, visible.height));
    final density = _densityForZoom();
    var attach = SceneTuning.captureBudget, release = SceneTuning.releaseBudget, sharpen = SceneTuning.sharpenBudget;
    for (final slot in [..._attached]) {
      if (release <= 0) break;
      final n = graph.slots[slot];
      if ((n == null || !drop.overlaps(n.rect)) && !_moving.contains(slot)) {
        _detach(slot);
        release--;
      }
    }
    if (view.scale >= SceneTuning.overviewMaxScale) {
      for (final slot in graph.grid.near(keep)) {
        if (attach <= 0) break;
        final n = graph.slots[slot];
        if (n != null && _live[slot] == null && _cardNodes[slot] != null && keep.overlaps(n.rect)) {
          _attach(slot, density);
          attach--;
        }
      }
    }
    for (final slot in [..._attached]) {
      if (sharpen <= 0) break;
      if (_density[slot] < density && _onScreen(slot)) {
        _upgrade(slot, density);
        sharpen--;
      }
    }
    _settled = attach > 0 && release > 0 && sharpen > 0;
    _settledAt = now;
  }

  /// The card with room around it for its shadow (the capture covers [SceneTuning.capturePad] on every side).
  Widget _padded(Widget card) => Padding(padding: const EdgeInsets.all(SceneTuning.capturePad), child: card);

  Camera _camera() => OrthographicCamera(
    position: toWorld(view.center, 50),
    target: toWorld(view.center),
    projection: OrthographicProjection(
      size: OrthographicSize.height(max(1, view.viewport.height) / view.scale),
      far: 100,
    ),
  );

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: _ready,
    builder: (context, ready, _) =>
        ready ? SceneView(scene, cameraBuilder: (_) => _camera(), onTick: (_, _) => _tick()) : const SizedBox.expand(),
  );

  @override
  void dispose() {
    _disposed = true;
    _ready.dispose();
  }
}

/// Rounded rectangles behind the cards (status border, selected frame), one instance per slot. Instances share a
/// geometry only when they have the same size, so corners keep their radius; one instanced mesh per size.
class _RoundedFrames {
  _RoundedFrames(this.scene);

  final Scene scene;
  final _meshes = <(int, int, int), InstancedMesh>{};
  final _free = <(int, int, int), List<int>>{};
  final _of = <int, ((int, int, int), int)>{};

  void set(int slot, Rect rect, double radius, vm.Vector4 color, double lift) {
    final key = ((rect.width * 2).round(), (rect.height * 2).round(), (radius * 2).round());
    final have = _of[slot];
    if (have != null && have.$1 != key) clear(slot);
    final at = _of[slot]?.$2 ?? _alloc(key, rect.size, radius);
    _of[slot] = (key, at);
    _meshes[key]!
      ..setInstanceTransform(at, vm.Matrix4.translation(toWorld(rect.center, lift)))
      ..setInstanceColor(at, color);
  }

  void clear(int slot) {
    final have = _of.remove(slot);
    if (have == null) return;
    _meshes[have.$1]!.setInstanceTransform(have.$2, vm.Matrix4.zero());
    _free.putIfAbsent(have.$1, () => []).add(have.$2);
  }

  int _alloc((int, int, int) key, Size size, double radius) {
    final free = _free[key];
    if (free != null && free.isNotEmpty) return free.removeLast();
    final mesh = _meshes.putIfAbsent(key, () {
      final m = InstancedMesh(
        geometry: _roundedRect(size, radius),
        material: UnlitMaterial(),
        sortTransparentInstances: false,
      );
      scene.add(Node()..addComponent(InstancedMeshComponent(m)));
      return m;
    });
    return mesh.addInstance(vm.Matrix4.zero());
  }
}

/// A filled rounded rectangle centred on the origin, as a triangle fan, facing the -Z camera.
Geometry _roundedRect(Size size, double radius, {int segments = 8}) {
  final w = size.width / 2, h = size.height / 2, r = min(radius, min(w, h));
  final pts = <Offset>[];
  for (final (cx, cy, a0) in [
    (w - r, h - r, 0.0),
    (-w + r, h - r, pi / 2),
    (-w + r, -h + r, pi),
    (w - r, -h + r, 1.5 * pi),
  ]) {
    for (var i = 0; i <= segments; i++) {
      final a = a0 + i / segments * pi / 2;
      pts.add(Offset(cx + r * cos(a), cy + r * sin(a)));
    }
  }
  final positions = <double>[0, 0, 0];
  for (final p in pts) {
    // Canvas y grows downwards and world y upwards; the shape is symmetric, so only the winding matters.
    positions.addAll([p.dx, -p.dy, 0]);
  }
  final indices = <int>[];
  for (var i = 1; i <= pts.length; i++) {
    final j = i == pts.length ? 1 : i + 1;
    indices.addAll([0, i, j]); // same winding as the card quad (front-facing for the -Z camera)
  }
  return MeshGeometry.fromArrays(
    positions: Float32List.fromList(positions),
    texCoords: Float32List(positions.length ~/ 3 * 2),
    indices: indices,
  );
}
