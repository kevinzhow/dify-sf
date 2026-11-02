/// The other people's pointers on the canvas (collaboration/components/user-cursors.tsx) and their avatars on the nodes
/// whose panel they have open (nodes/_base/node.tsx's UserAvatarList), from [EditorPresence].
library;

import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart' show PresenceDrag;
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../canvas/canvas_controller.dart';
import '../../canvas/canvas_view_state.dart';
import '../../design/dify_fonts.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';
import '../../editor/editor_controller.dart';
import '../header/online_users.dart' show getUserColor;
import '../store/workflow_store_scope.dart';
import 'editor_presence.dart';

/// user-cursors.tsx: each collaborator's pointer, a 20 px arrow in their colour with a white outline, and their name
/// in a pill 16 px right and down, at the same size at any zoom. Hidden with the zoom menu's "Collaborator cursors" off
/// (`showUserCursors`); never this user's own.
///
/// Deviation: Dify eases each pointer to its new *screen* position over 150 ms (`transition-all duration-150`), so every
/// pointer lags behind the canvas while it pans or zooms, and behind the nodes its owner drags. Here a pointer is pinned
/// to the canvas (it moves with it at once), only the collaborator's own movement is eased, in canvas coordinates, over
/// the time between their reports, and while they drag nodes it sits where they hold the node (presence `drag`), so it
/// moves exactly with it; all pointers are painted in one pass.
class UserCursors extends StatefulWidget {
  const UserCursors({super.key, required this.presence, required this.canvas});
  final EditorPresence presence;
  final CanvasController canvas;

  @override
  State<UserCursors> createState() => _UserCursorsState();
}

/// One collaborator's pointer on its way from [from] to [to] (canvas coordinates), or held on the node it drags.
class _Track {
  _Track(this.name, this.color, Offset at, this.reported) : from = at, to = at;
  String name;
  Color color;
  Offset from, to;
  Duration start = Duration.zero, length = Duration.zero;
  Duration reported;

  /// The node they drag, and since when (the pointer eases from [heldFrom] onto it over [_hold]).
  PresenceDrag? drag;
  Duration heldAt = Duration.zero;
  Offset heldFrom = Offset.zero;

  static const _hold = Duration(milliseconds: 150);

  /// Where the pointer is drawn; [node] is a node's top-left as drawn now.
  Offset at(Duration now, Offset? Function(String id) node) {
    final d = drag;
    final n = d == null ? null : node(d.node);
    if (n != null) {
      final held = n + Offset(d!.x, d.y);
      final u = (now - heldAt).inMicroseconds / _hold.inMicroseconds;
      return u >= 1 ? held : Offset.lerp(heldFrom, held, Curves.easeOut.transform(u.clamp(0.0, 1.0)))!;
    }
    if (length == Duration.zero || now >= start + length) return to;
    final t = Curves.easeOut.transform(((now - start).inMicroseconds / length.inMicroseconds).clamp(0.0, 1.0));
    return Offset.lerp(from, to, t)!;
  }

  bool settled(Duration now) => now >= start + length && (drag == null || now >= heldAt + _hold);
}

class _UserCursorsState extends State<UserCursors> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_onTick);
  final _frame = ValueNotifier<Duration>(Duration.zero);
  final _tracks = <String, _Track>{};

  @override
  void initState() {
    super.initState();
    widget.presence.addListener(_presenceChanged);
    _presenceChanged();
  }

  @override
  void didUpdateWidget(UserCursors old) {
    super.didUpdateWidget(old);
    if (old.presence != widget.presence) {
      old.presence.removeListener(_presenceChanged);
      widget.presence.addListener(_presenceChanged);
      _presenceChanged();
    }
  }

  @override
  void dispose() {
    widget.presence.removeListener(_presenceChanged);
    _ticker.dispose();
    _frame.dispose();
    super.dispose();
  }

  Duration get _now => _ticker.isActive ? _frame.value : _clock.elapsed;
  final _clock = Stopwatch()..start();

  void _onTick(Duration _) {
    _frame.value = _clock.elapsed;
    if (_tracks.values.every((t) => t.settled(_frame.value))) _ticker.stop();
  }

  Offset? _nodeAt(String id) {
    final n = widget.canvas.graph?[id];
    return n == null ? null : Offset(n.x, n.y);
  }

  void _presenceChanged() {
    final now = _clock.elapsed;
    final seen = <String>{};
    for (final u in widget.presence.others) {
      final c = u.cursor;
      if (c == null) continue;
      seen.add(u.account);
      final to = Offset(c.x, c.y);
      final t = _tracks[u.account];
      if (t == null) {
        _tracks[u.account] = _Track(u.name, getUserColor(u.account), to, now)
          ..drag = u.drag
          ..heldFrom = to
          ..heldAt = now;
        continue;
      }
      t
        ..name = u.name
        ..color = getUserColor(u.account);
      final drag = u.drag;
      if (drag?.node != t.drag?.node || (drag != null && drag != t.drag)) {
        // Onto the node they began dragging (from where the pointer is drawn now), or off it when they let go.
        final here = t.at(now, _nodeAt);
        if (drag != null && drag.node != t.drag?.node) {
          t
            ..heldFrom = here
            ..heldAt = now;
        }
        t.drag = drag;
        if (drag == null) {
          t
            ..from = here
            ..to = to
            ..start = now
            ..length = const Duration(milliseconds: 160)
            ..reported = now;
          continue;
        }
      }
      if (to == t.to) continue;
      // Ease over the time since their previous report (Dify's 300 ms throttle), so a moving pointer glides
      // continuously instead of jumping and waiting.
      final since = now - t.reported;
      t
        ..from = t.at(now, _nodeAt)
        ..to = to
        ..start = now
        ..length = Duration(milliseconds: since.inMilliseconds.clamp(80, 320))
        ..reported = now;
    }
    _tracks.removeWhere((k, _) => !seen.contains(k));
    _frame.value = now;
    if (!_ticker.isActive && _tracks.isNotEmpty) _ticker.start();
  }

  @override
  Widget build(BuildContext context) {
    final store = WorkflowStoreScope.of(context);
    return IgnorePointer(
      child: ValueListenableBuilder<bool>(
        valueListenable: store.showUserCursors,
        builder: (context, show, _) => !show
            ? const SizedBox.shrink()
            : RepaintBoundary(
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _CursorsPainter(
                    tracks: _tracks,
                    now: () => _now,
                    node: _nodeAt,
                    view: widget.canvas.view,
                    dpr: MediaQuery.devicePixelRatioOf(context),
                    // The canvas moves, a pointer eases, or a node someone holds moves.
                    repaint: Listenable.merge([widget.canvas.view, _frame, widget.canvas.visualChanges]),
                  ),
                ),
              ),
      ),
    );
  }
}

class _CursorsPainter extends CustomPainter {
  _CursorsPainter({
    required this.tracks,
    required this.now,
    required this.node,
    required this.view,
    required this.dpr,
    required Listenable repaint,
  }) : super(repaint: repaint);
  final Map<String, _Track> tracks;
  final Duration Function() now;
  final Offset? Function(String id) node;
  final CanvasViewState view;
  final double dpr;

  static final _labels = <String, TextPainter>{};

  /// The arrow of user-cursors.tsx: `M5 3L5 15L8 11.5L11 16L13 15L10 10.5L14 10.5L5 3Z` in a 20 px box, filled with the
  /// user's colour, `stroke="white" strokeWidth="1.5" strokeLinejoin="round"`, with `drop-shadow-md`.
  static final _arrow = Path()
    ..moveTo(5, 3)
    ..lineTo(5, 15)
    ..lineTo(8, 11.5)
    ..lineTo(11, 16)
    ..lineTo(13, 15)
    ..lineTo(10, 10.5)
    ..lineTo(14, 10.5)
    ..close();
  static final _shadow1 = _arrow.shift(const Offset(0, 4));
  static final _shadow2 = _arrow.shift(const Offset(0, 2));
  static final _shadowPaint1 = Paint()
    ..color = DifyTailwind.black.withValues(alpha: .07) // drop-shadow-md, first layer
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
  static final _shadowPaint2 = Paint()
    ..color = DifyTailwind.black.withValues(alpha: .06) // drop-shadow-md, second layer
    ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1);
  static final _stroke = Paint()
    ..color = DifyTailwind.white
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeJoin = StrokeJoin.round;

  static TextPainter _label(String name) {
    return _labels[name] ??= TextPainter(
      text: TextSpan(
        text: name,
        style: DifyFonts.resolveStyle(difyTextStyle(DifyTw.text11Medium, DifyTailwind.white)),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 120 - 12); // `max-w-30` minus `px-1.5`
  }

  /// One collaborator's pointer and name pill, the pointer's tip box at the origin.
  static void _draw(Canvas canvas, Color color, TextPainter label) {
    canvas
      ..drawPath(_shadow1, _shadowPaint1)
      ..drawPath(_shadow2, _shadowPaint2)
      ..drawPath(_arrow, Paint()..color = color)
      ..drawPath(_arrow, _stroke);
    // `absolute top-4 left-4 rounded px-1.5 py-0.5 shadow-sm`, the user's colour.
    final pill = Rect.fromLTWH(16, 16, label.width + 12, label.height + 4);
    canvas
      ..drawRRect(
        RRect.fromRectAndRadius(pill.shift(const Offset(0, 1)), const Radius.circular(4)),
        Paint()
          ..color = DifyTailwind.black.withValues(alpha: .05) // shadow-sm
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1),
      )
      ..drawRRect(RRect.fromRectAndRadius(pill, const Radius.circular(4)), Paint()..color = color);
    label.paint(canvas, const Offset(22, 18));
  }

  /// Room around [_draw] for the shadows.
  static const _margin = 4.0;

  /// Each pointer drawn once into an image at the screen's pixel ratio: a hundred pointers with blurred shadows and text
  /// every frame cost more than the rest of the canvas.
  static final _sprites = <(String, int, double), ui.Image>{};

  static ui.Image _sprite(String name, Color color, double dpr) {
    final key = (name, color.toARGB32(), dpr);
    final cached = _sprites[key];
    if (cached != null) return cached;
    if (_sprites.length >= 256) {
      for (final i in _sprites.values) {
        i.dispose();
      }
      _sprites.clear();
    }
    final label = _label(name);
    final w = 16 + label.width + 12 + 2 * _margin, h = 16 + label.height + 4 + 2 * _margin + 1;
    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder)
      ..scale(dpr)
      ..translate(_margin, _margin);
    _draw(c, color, label);
    final picture = recorder.endRecording();
    final image = picture.toImageSync((w * dpr).ceil(), (h * dpr).ceil());
    picture.dispose();
    return _sprites[key] = image;
  }

  static final _imagePaint = Paint()..filterQuality = FilterQuality.low;

  @override
  void paint(Canvas canvas, Size size) {
    final t = now();
    for (final track in tracks.values) {
      final p = view.toScreen(track.at(t, node));
      if (p.dx < -160 || p.dy < -60 || p.dx > size.width + 20 || p.dy > size.height + 20) continue;
      final image = _sprite(track.name, track.color, dpr);
      // On whole device pixels, so the image is drawn 1:1 and stays sharp.
      final at = Offset(((p.dx - _margin) * dpr).roundToDouble() / dpr, ((p.dy - _margin) * dpr).roundToDouble() / dpr);
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
        at & Size(image.width / dpr, image.height / dpr),
        _imagePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_CursorsPainter old) => true;
}

/// node.tsx: on a node whose configuration panel others have open, their avatars (base/user-avatar-list, `maxVisible=3`,
/// `size="sm"`: 24 px circles in their user colour with the initial, overlapping by 4 px, a 2 px ring in the panel
/// background; past three, two and a gray "+N") at the right end of the node's title row, scaled with the zoom like the
/// card. Painted above the cards in one pass (cards, captured images on native builds, never change).
class NodeViewers extends StatelessWidget {
  const NodeViewers({super.key, required this.presence, required this.controller, required this.canvas});
  final EditorPresence presence;
  final EditorController controller;
  final CanvasController canvas;

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _ViewersPainter(
          presence: presence,
          canvas: canvas,
          repaint: Listenable.merge([presence, canvas.view, canvas.visualChanges, controller]),
        ),
      ),
    ),
  );
}

class _ViewersPainter extends CustomPainter {
  _ViewersPainter({required this.presence, required this.canvas, required Listenable repaint})
    : super(repaint: repaint);
  final EditorPresence presence;
  final CanvasController canvas;

  static final _initials = <String, TextPainter>{};
  static TextPainter _text(String s) => _initials[s] ??= TextPainter(
    text: TextSpan(text: s, style: DifyFonts.resolveStyle(difyTextStyle(DifyTw.text10Medium, DifyTailwind.white))),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();

  @override
  void paint(Canvas c, Size size) {
    final graph = canvas.graph;
    final byNode = presence.viewersByNode;
    if (graph == null || byNode.isEmpty) return;
    final view = canvas.view;
    final zoom = view.scale;
    final ring = Paint()..color = DifyColors.componentsPanelBg;
    for (final MapEntry(key: id, value: users) in byNode.entries) {
      final node = graph[id];
      if (node == null) continue;
      final r = view.rectToScreen(node.rect);
      if (!r.overlaps(Offset.zero & size)) continue;
      final showCount = users.length > 3;
      final visible = users.take(showCount ? 2 : 3).toList();
      final items = visible.length + (showCount ? 1 : 0);
      final width = 24.0 + (items - 1) * 20.0;
      c
        ..save()
        ..translate(r.right - (12 + width) * zoom, r.top + 8 * zoom)
        ..scale(zoom);
      // The earlier ones on top: paint from the last.
      for (var i = items - 1; i >= 0; i--) {
        final center = Offset(12 + i * 20.0, 12);
        c.drawCircle(center, 14, ring);
        if (i < visible.length) {
          final u = visible[i];
          c.drawCircle(center, 12, Paint()..color = getUserColor(u.account));
          final t = _text(u.name.isEmpty ? '' : u.name.characters.first.toUpperCase());
          t.paint(c, center - Offset(t.width / 2, t.height / 2));
        } else {
          c.drawCircle(center, 12, Paint()..color = DifyColors.gray500);
          final t = _text('+${users.length - visible.length}');
          t.paint(c, center - Offset(t.width / 2, t.height / 2));
        }
      }
      c.restore();
    }
  }

  @override
  bool shouldRepaint(_ViewersPainter old) => old.presence != presence || old.canvas != canvas;
}
