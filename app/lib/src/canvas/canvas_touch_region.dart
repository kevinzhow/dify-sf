import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'canvas_input.dart';

/// Finger input shares Flutter's gesture arena with live editors and the
/// workflow's long-press menu. Wait for a winning tap/drag before changing the
/// document: a second finger must be able to turn a press into a viewport pinch.
class CanvasTouchRegion extends StatefulWidget {
  const CanvasTouchRegion({
    super.key,
    required this.input,
    required this.onInteraction,
    this.onContact,
    required this.child,
  });

  final CanvasInput input;
  final VoidCallback onInteraction;
  final VoidCallback? onContact;
  final Widget child;

  @override
  State<CanvasTouchRegion> createState() => _CanvasTouchRegionState();
}

class _CanvasTouchRegionState extends State<CanvasTouchRegion> {
  final _pointers = <int, Offset>{};
  final _team = GestureArenaTeam();
  PointerDownEvent? _first;
  PointerMoveEvent? _move;
  PointerEvent? _last;
  bool _single = false, _pinched = false;
  int _epoch = 0;
  double _scale = 1;
  Offset _anchor = Offset.zero;
  Offset _doubleAt = Offset.zero;

  CanvasInput get input => widget.input;
  bool _allowed(PointerDownEvent e) => !input.claimed(e);
  bool _empty(PointerDownEvent e) => _allowed(e) && input.nodeAt(input.view.toCanvas(e.localPosition)) == null;

  void _down(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.touch || !_allowed(e)) return;
    // Freeze an in-flight organize/viewport transition before recording the
    // contact. This changes no selection and does not take an editor's focus.
    widget.onContact?.call();
    _epoch++;
    if (_pointers.isEmpty) {
      _first = e;
      _move = null;
      _last = null;
      _single = _pinched = false;
    }
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length > 1) {
      if (_single) input.cancel();
      _single = false;
      _pinched = true;
      _rebase();
    }
  }

  void _rebase() {
    final focal = _pointers.values.reduce((a, b) => a + b) / _pointers.length.toDouble();
    _scale = input.view.scale;
    _anchor = input.view.toCanvas(focal);
  }

  void _moving(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    _move = e;
  }

  void _up(PointerEvent e) {
    if (e.kind != PointerDeviceKind.touch) return;
    input.releaseClaim(e);
    if (_pointers.remove(e.pointer) == null) return;
    _last = e;
    if (_pointers.length >= 2) _rebase();
    if (e is PointerCancelEvent) {
      if (_single) input.cancel();
      _single = false;
    }
    if (_pointers.isNotEmpty) return;
    // Raw up precedes the recognizers' tap/end callbacks in this dispatch.
    final epoch = _epoch;
    scheduleMicrotask(() {
      if (!mounted || epoch != _epoch) return;
      if (_single) input.cancel();
      _move = null;
      // A single empty-canvas tap can still be awaiting the double-tap timeout.
      // Keep its down/up pair until the next sequence starts.
      _single = false;
    });
  }

  void _beginSingle() {
    if (_single || _pinched || _first == null) return;
    widget.onInteraction();
    input.down(_first!, touchPan: true, recognizeDoubleTap: false);
    _single = true;
  }

  void _start(ScaleStartDetails d) {
    if (d.pointerCount >= 2 && _pointers.length >= 2) {
      widget.onInteraction();
      _pinched = true;
    } else if (!_pinched) {
      _beginSingle();
      if (_move case final move?) input.move(move);
    }
  }

  void _update(ScaleUpdateDetails d) {
    if (_pinched) {
      if (d.pointerCount >= 2 && _pointers.length >= 2) {
        input.view.transformAt(d.localFocalPoint, _anchor, _scale * d.scale);
        input.onApplied?.call('zoom');
      }
    } else if (_single) {
      if (_move case final move?) input.move(move);
    }
  }

  void _end(ScaleEndDetails d) {
    if (_single) {
      if (_last case final end?) {
        input.up(end);
      } else {
        input.cancel();
      }
      _single = false;
    }
  }

  void _tap(TapUpDetails d) {
    if (_pinched || _first == null || _last == null) return;
    _beginSingle();
    input.up(_last!);
    _single = false;
  }

  @override
  Widget build(BuildContext context) => RawGestureDetector(
    behavior: HitTestBehavior.opaque,
    gestures: {
      _TouchScale: GestureRecognizerFactoryWithHandlers<_TouchScale>(
        () {
          final scale = _TouchScale(_allowed)..team = _team;
          _team.captain = scale;
          return scale;
        },
        (r) => r
          ..onStart = _start
          ..onUpdate = _update
          ..onEnd = _end,
      ),
      // Scale's one-finger pan threshold is twice the normal drag threshold.
      // A team pan claims at the usual distance before page text selection can
      // win, while the scale captain remains the sole viewport/document owner.
      _TouchPan: GestureRecognizerFactoryWithHandlers<_TouchPan>(
        () => _TouchPan(_allowed)..team = _team,
        (r) => r..onUpdate = ((_) {}),
      ),
      _TouchTap: GestureRecognizerFactoryWithHandlers<_TouchTap>(
        () => _TouchTap(_allowed),
        (r) => r..onTapUp = _tap,
      ),
      _TouchDoubleTap: GestureRecognizerFactoryWithHandlers<_TouchDoubleTap>(
        () => _TouchDoubleTap(_empty),
        (r) => r
          ..onDoubleTapDown = ((d) => _doubleAt = d.localPosition)
          ..onDoubleTap = (() {
            widget.onInteraction();
            input.view.zoomAt(_doubleAt, 2);
          }),
      ),
    },
    child: Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: _down,
      onPointerMove: _moving,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: widget.child,
    ),
  );
}

class _TouchScale extends ScaleGestureRecognizer {
  _TouchScale(this.allowed)
    : super(supportedDevices: const {PointerDeviceKind.touch}, dragStartBehavior: DragStartBehavior.down);
  final bool Function(PointerDownEvent) allowed;
  @override
  bool isPointerAllowed(PointerDownEvent e) => allowed(e) && super.isPointerAllowed(e);
  // ScaleGestureRecognizer accepts trackpad pan/zoom independently of
  // supportedDevices. The existing CanvasInput path already handles those.
  @override
  bool isPointerPanZoomAllowed(PointerPanZoomStartEvent e) => false;
}

class _TouchTap extends TapGestureRecognizer {
  _TouchTap(this.allowed) : super(supportedDevices: const {PointerDeviceKind.touch});
  final bool Function(PointerDownEvent) allowed;
  @override
  bool isPointerAllowed(PointerDownEvent e) => allowed(e) && super.isPointerAllowed(e);
}

class _TouchDoubleTap extends DoubleTapGestureRecognizer {
  _TouchDoubleTap(this.allowed) : super(supportedDevices: const {PointerDeviceKind.touch});
  final bool Function(PointerDownEvent) allowed;
  @override
  bool isPointerAllowed(PointerDownEvent e) => allowed(e) && super.isPointerAllowed(e);
}

class _TouchPan extends PanGestureRecognizer {
  _TouchPan(this.allowed) : super(supportedDevices: const {PointerDeviceKind.touch});
  final bool Function(PointerDownEvent) allowed;
  @override
  bool isPointerAllowed(PointerEvent e) => e is PointerDownEvent && allowed(e) && super.isPointerAllowed(e);
  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind kind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > computeHitSlop(kind, gestureSettings);
}
