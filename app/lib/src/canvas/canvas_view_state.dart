import 'dart:math';

import 'package:flutter/widgets.dart';

/// What the canvas shows: the canvas point at the middle of the viewport, and screen pixels per canvas pixel.
/// Canvas coordinates are the document's (x right, y down, in Dify's units).
class CanvasViewState extends ChangeNotifier {
  // ignore: prefer_initializing_formals
  CanvasViewState({Offset center = Offset.zero, double scale = 1}) : _center = center, _scale = scale;

  static const minScale = 0.05;
  static const maxScale = 4.0;

  Offset _center;
  double _scale;
  Size viewport = Size.zero;

  Offset get center => _center;
  double get scale => _scale;

  set center(Offset value) {
    if (value == _center) return;
    _center = value;
    notifyListeners();
  }

  set scale(double value) {
    final s = value.clamp(minScale, maxScale);
    if (s == _scale) return;
    _scale = s;
    notifyListeners();
  }

  /// The canvas rectangle on screen.
  Rect get visible =>
      Rect.fromCenter(center: _center, width: viewport.width / _scale, height: viewport.height / _scale);

  Offset get _mid => Offset(viewport.width / 2, viewport.height / 2);

  Offset toCanvas(Offset local) => _center + (local - _mid) / _scale;
  Offset toScreen(Offset canvas) => (canvas - _center) * _scale + _mid;
  Rect rectToScreen(Rect r) => Rect.fromPoints(toScreen(r.topLeft), toScreen(r.bottomRight));

  /// Zooms by [factor] keeping the canvas point under [local] where it is.
  void zoomAt(Offset local, double factor) {
    final c = toCanvas(local);
    _scale = (_scale * factor).clamp(minScale, maxScale);
    _center = c - (local - _mid) / _scale;
    notifyListeners();
  }

  /// Fits [bounds] (canvas) into the viewport with [padding] screen pixels around it.
  void fit(Rect bounds, {double padding = 48}) {
    if (viewport.isEmpty || bounds.isEmpty) return;
    final sx = (viewport.width - 2 * padding) / bounds.width, sy = (viewport.height - 2 * padding) / bounds.height;
    _scale = min(sx, sy).clamp(minScale, 1.0);
    _center = bounds.center;
    notifyListeners();
  }
}
