import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Material;
import 'package:flutter/scheduler.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

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
  static const edgeWidthPx = 1.5;
  static const statusPad = 3.0;
  static const highlightPad = 5.0;
}

const _statusColors = {
  'running': Color(0xFF2F6FED),
  'succeeded': Color(0xFF1E9E5A),
  'failed': Color(0xFFD93A3A),
  'exception': Color(0xFFF79009),
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

  late final InstancedMesh _statusMesh;
  late final InstancedMesh _highlightMesh;
  late final UnlitMaterial _edgeMaterial;
  late final UnlitMaterial _selectedEdgeMaterial;
  late final UnlitMaterial _previewMaterial;
  final _edgeGeometries = <LineSegmentsGeometry>[];
  Node? _staticEdges;
  Node? _liveEdges;
  Node? _selectedEdge;
  Node? _preview;
  double _edgeWidthScale = 0;

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
    _edgeMaterial = UnlitMaterial()..baseColorFactor = srgb(const Color(0xFF94A3B8));
    _selectedEdgeMaterial = UnlitMaterial()..baseColorFactor = srgb(const Color(0xFF296DFF));
    _previewMaterial = UnlitMaterial()..baseColorFactor = srgb(const Color(0xFF296DFF));
    // Opaque scene geometry, all in one plane: no per-frame depth sort of instances. (Display-referred surfaces are
    // composited without depth order among themselves, which would draw the frames over the cards.)
    _statusMesh = InstancedMesh(geometry: _unitQuad, material: UnlitMaterial(), sortTransparentInstances: false);
    _highlightMesh = InstancedMesh(geometry: _unitQuad, material: UnlitMaterial(), sortTransparentInstances: false);
    scene
      ..add(Node()..addComponent(InstancedMeshComponent(_highlightMesh)))
      ..add(Node()..addComponent(InstancedMeshComponent(_statusMesh)))
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
      _statusMesh.addInstance(vm.Matrix4.zero());
      _highlightMesh.addInstance(vm.Matrix4.zero());
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
    _statusMesh.setInstanceTransform(slot, vm.Matrix4.zero());
    _highlightMesh.setInstanceTransform(slot, vm.Matrix4.zero());
    _overviewQueue.remove(slot);
    _dirty.remove(slot);
    _liveStale.remove(slot);
  }

  /// Distance in front of the canvas: moving nodes above all, then selected nodes, then later nodes above earlier
  /// ones (tiny steps, so overlapping cards stack like the widget renderer and hit testing).
  double _lift(int slot) {
    final n = graph.slots[slot];
    if (n == null) return 0;
    if (_moving.contains(slot)) return 0.5;
    return (selection.nodes.contains(slot) ? 0.2 : 0) + (n.order % 100000) * 1e-6;
  }

  /// Puts every visual of [slot] where its node is; a moving node is lifted towards the camera.
  void _place(int slot) {
    final n = graph.slots[slot];
    final card = _cardNodes[slot];
    if (n == null || card == null) return;
    final lift = _lift(slot);
    card
      ..position = toWorld(n.center, lift)
      ..scale = vm.Vector3(n.size.width, n.size.height, 1);
    _placeholderNodes[slot]
      ?..position = toWorld(n.center, lift - 0.05)
      ..scale = vm.Vector3(n.size.width, n.size.height, 1);
    final sk = _skeleton[slot];
    if (sk != null) _skeletonMeshes[sk.$1]!.setInstanceTransform(sk.$2, _box(n.center, n.size, lift - 0.05));
    _statusChanged(slot);
    _highlight(slot);
  }

  // ----- status and selection frames -----

  void _statusChanged(int slot) {
    final n = graph.slots[slot];
    final color = n == null ? null : _statusColors[n.status.value];
    if (n == null || color == null) {
      _statusMesh.setInstanceTransform(slot, vm.Matrix4.zero());
      return;
    }
    const pad = SceneTuning.statusPad * 2;
    _statusMesh
      ..setInstanceTransform(
        slot,
        _box(n.center, n.size + const Offset(pad, pad), _lift(slot) - 0.1),
      )
      ..setInstanceColor(slot, srgb(color));
  }

  void _highlight(int slot) {
    final n = graph.slots[slot];
    final selected = selection.nodes.contains(slot), hovered = selection.hovered == slot;
    if (n == null || (!selected && !hovered)) {
      _highlightMesh.setInstanceTransform(slot, vm.Matrix4.zero());
      return;
    }
    const pad = SceneTuning.highlightPad * 2;
    _highlightMesh
      ..setInstanceTransform(
        slot,
        _box(n.center, n.size + const Offset(pad, pad), _lift(slot) - 0.15),
      )
      ..setInstanceColor(slot, srgb(selected ? const Color(0xFF296DFF) : const Color(0xFFA6C2FF)));
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

  Iterable<CanvasEdge> _edgesWhere({required bool live}) => graph.edges.where(
    (e) => (_moving.contains(e.source) || _moving.contains(e.target)) == live,
  );

  Node? _edgeNode(
    Iterable<CanvasEdge> edges,
    UnlitMaterial material, {
    double lift = -1,
    double widthPx = SceneTuning.edgeWidthPx,
  }) {
    final out = <double>[];
    for (final e in edges) {
      final a = graph.slots[e.source], b = graph.slots[e.target];
      if (a == null || b == null) continue;
      final pts = edgeCurve(a.outPort, b.inPort);
      for (var k = 0; k + 1 < pts.length; k++) {
        final p = toWorld(pts[k]), q = toWorld(pts[k + 1]);
        out.addAll([p.x, p.y, p.z, q.x, q.y, q.z]);
      }
    }
    if (out.isEmpty) return null;
    final geometry = LineSegmentsGeometry(
      LineSegmentData(positions: Float32List.fromList(out)),
      width: widthPx / view.scale,
    );
    _edgeGeometries.add(geometry);
    return Node(mesh: Mesh(geometry, material))..position = toWorld(Offset.zero, lift);
  }

  void _replaceEdgeNode(
    Node? old,
    void Function(Node?) set,
    Iterable<CanvasEdge> edges,
    UnlitMaterial material, {
    double lift = -1,
    double widthPx = SceneTuning.edgeWidthPx,
  }) {
    if (old != null) {
      scene.remove(old);
      _edgeGeometries.remove(old.mesh?.primitives.first.geometry);
    }
    final n = _edgeNode(edges, material, lift: lift, widthPx: widthPx);
    if (n != null) scene.add(n);
    set(n);
  }

  void _rebuildEdges() {
    _replaceEdgeNode(_staticEdges, (n) => _staticEdges = n, _edgesWhere(live: false), _edgeMaterial);
    _replaceEdgeNode(_liveEdges, (n) => _liveEdges = n, _edgesWhere(live: true), _edgeMaterial);
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
      widthPx: 3,
    );
  }

  @override
  void connectPreview(Offset? from, Offset? to) {
    if (!_ready.value) return;
    if (_preview != null) {
      scene.remove(_preview!);
      _edgeGeometries.remove(_preview!.mesh?.primitives.first.geometry);
      _preview = null;
    }
    if (from == null || to == null) return;
    final pts = edgeCurve(from, to);
    final out = <double>[];
    for (var k = 0; k + 1 < pts.length; k++) {
      final p = toWorld(pts[k], 0.6), q = toWorld(pts[k + 1], 0.6);
      out.addAll([p.x, p.y, p.z, q.x, q.y, q.z]);
    }
    final geometry = LineSegmentsGeometry(LineSegmentData(positions: Float32List.fromList(out)), width: 2 / view.scale);
    _edgeGeometries.add(geometry);
    _preview = Node(mesh: Mesh(geometry, _previewMaterial));
    scene.add(_preview!);
  }

  void _edgeWidths() {
    if (view.scale == _edgeWidthScale) return;
    final ratio = _edgeWidthScale == 0 ? 1.0 : _edgeWidthScale / view.scale;
    _edgeWidthScale = view.scale;
    for (final g in _edgeGeometries) {
      g.width = g.width * ratio;
    }
  }

  // ----- cards: live components -----

  WidgetComponent _component(int slot, double density) {
    final n = graph.slots[slot]!;
    late final WidgetComponent c;
    c = WidgetComponent(
      // Cards stay out of the semantics tree; the canvas exposes its own summary (CanvasA11y).
      child: ExcludeSemantics(
        child: Builder(
          builder: (context) => cards.build(context, n, live: true, onPainted: () => _livePainted(slot, c)),
        ),
      ),
      size: n.size,
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
              cards.build(context, sample, live: false, onPainted: () => c.controller.requestCapture()),
        ),
      ),
      size: sample.size,
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
            builder: (context) => cards.build(context, n, live: false, onPainted: () => c.controller.requestCapture()),
          ),
        ),
        size: n.size,
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
    _edgeWidths();
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
