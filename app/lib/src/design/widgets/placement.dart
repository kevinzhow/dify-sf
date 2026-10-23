import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// The side of the anchor a popup sits on (`data-side`).
enum DifySide { top, right, bottom, left }

/// How a popup lines up with the anchor along that side (`data-align`).
enum DifyAlign { start, center, end }

/// dify-ui's `Placement` (placement.ts, Floating UI's 12 placements).
enum DifyPlacement {
  top(DifySide.top, DifyAlign.center),
  topStart(DifySide.top, DifyAlign.start),
  topEnd(DifySide.top, DifyAlign.end),
  right(DifySide.right, DifyAlign.center),
  rightStart(DifySide.right, DifyAlign.start),
  rightEnd(DifySide.right, DifyAlign.end),
  bottom(DifySide.bottom, DifyAlign.center),
  bottomStart(DifySide.bottom, DifyAlign.start),
  bottomEnd(DifySide.bottom, DifyAlign.end),
  left(DifySide.left, DifyAlign.center),
  leftStart(DifySide.left, DifyAlign.start),
  leftEnd(DifySide.left, DifyAlign.end);

  const DifyPlacement(this.side, this.align);
  final DifySide side;
  final DifyAlign align;
}

/// Base UI's collision avoidance for a positioner (internals/useAnchorPositioning.mjs).
class DifyCollision {
  const DifyCollision({this.flipSide = true, this.perpendicularFallback = false, this.shiftSideAxis = false});

  /// Base UI `DROPDOWN_COLLISION_AVOIDANCE` (menus): flips to the opposite side only.
  static const dropdown = DifyCollision();

  /// Base UI `POPUP_COLLISION_AVOIDANCE` (popover, tooltip, submenus): may also flip to the perpendicular axis.
  static const popup = DifyCollision(perpendicularFallback: true);

  /// A context menu at the pointer: never changes side, shifts on both axes instead.
  static const contextMenu = DifyCollision(flipSide: false, shiftSideAxis: true);

  final bool flipSide;
  final bool perpendicularFallback;
  final bool shiftSideAxis;
}

/// Where a popup goes: its top-left in the bounds, the side and alignment it ended up with, and the height left for
/// it on that side (`--available-height`).
class DifyFloatingPosition {
  const DifyFloatingPosition(this.offset, this.side, this.align, this.availableHeight);
  final Offset offset;
  final DifySide side;
  final DifyAlign align;
  final double availableHeight;

  /// The transform origin of the open/close scale (Base UI's `--transform-origin` for arrowless popups): the
  /// anchor-facing edge, at the aligned edge, or at the anchor's centre for centred popups.
  Alignment origin(Size popup, Rect anchor) {
    final vertical = side == DifySide.top || side == DifySide.bottom;
    double cross() {
      if (align == DifyAlign.start) return -1;
      if (align == DifyAlign.end) return 1;
      final c = vertical ? anchor.center.dx - offset.dx : anchor.center.dy - offset.dy;
      final len = vertical ? popup.width : popup.height;
      return len == 0 ? 0 : (c / len * 2 - 1).clamp(-1.0, 1.0);
    }

    return switch (side) {
      DifySide.top => Alignment(cross(), 1),
      DifySide.bottom => Alignment(cross(), -1),
      DifySide.left => Alignment(1, cross()),
      DifySide.right => Alignment(-1, cross()),
    };
  }
}

DifySide _opposite(DifySide s) => switch (s) {
  DifySide.top => DifySide.bottom,
  DifySide.bottom => DifySide.top,
  DifySide.left => DifySide.right,
  DifySide.right => DifySide.left,
};

DifyAlign _flip(DifyAlign a) => switch (a) {
  DifyAlign.start => DifyAlign.end,
  DifyAlign.end => DifyAlign.start,
  DifyAlign.center => DifyAlign.center,
};

bool _vertical(DifySide s) => s == DifySide.top || s == DifySide.bottom;

/// Base UI's shared collision padding, used for both sizing and placement.
const difyFloatingCollisionPadding = 5.0;

/// Positions a [popup] of this size against [anchor] within [bounds] the way Base UI's positioner (Floating UI's
/// offset, flip, shift and size middleware, collision padding 5) does. LTR only.
DifyFloatingPosition computeFloatingPosition({
  required Rect anchor,
  required Size popup,
  required Size bounds,
  required DifyPlacement placement,
  double sideOffset = 0,
  double alignOffset = 0,
  DifyCollision collision = DifyCollision.dropdown,
  double padding = difyFloatingCollisionPadding,
}) {
  Offset at(DifySide side, DifyAlign align) {
    final cross = align == DifyAlign.end ? -alignOffset : alignOffset;
    if (_vertical(side)) {
      final x = switch (align) {
        DifyAlign.start => anchor.left,
        DifyAlign.center => anchor.center.dx - popup.width / 2,
        DifyAlign.end => anchor.right - popup.width,
      };
      final y = side == DifySide.top ? anchor.top - popup.height - sideOffset : anchor.bottom + sideOffset;
      return Offset(x + cross, y);
    }
    final y = switch (align) {
      DifyAlign.start => anchor.top,
      DifyAlign.center => anchor.center.dy - popup.height / 2,
      DifyAlign.end => anchor.bottom - popup.height,
    };
    final x = side == DifySide.left ? anchor.left - popup.width - sideOffset : anchor.right + sideOffset;
    return Offset(x, y + cross);
  }

  // Overflow past each edge (positive = outside), with the flip padding: padding + 1, plus 1 on the side opposite
  // the preferred one (Base UI's bias).
  final want = placement.side;
  double over(Rect r, DifySide edge) {
    final p = padding + 1 + (edge == _opposite(want) ? 1 : 0);
    return switch (edge) {
      DifySide.top => p - r.top,
      DifySide.bottom => r.bottom - (bounds.height - p),
      DifySide.left => p - r.left,
      DifySide.right => r.right - (bounds.width - p),
    };
  }

  final candidates = <(DifySide, DifyAlign)>[(want, placement.align)];
  void add(DifySide s, DifyAlign a) {
    candidates.add((s, a));
    if (a != DifyAlign.center) candidates.add((s, _flip(a)));
  }

  if (placement.align != DifyAlign.center) candidates.add((want, _flip(placement.align)));
  if (collision.flipSide) {
    add(_opposite(want), placement.align);
    if (collision.perpendicularFallback) {
      for (final s in _vertical(want) ? [DifySide.right, DifySide.left] : [DifySide.bottom, DifySide.top]) {
        add(s, placement.align);
      }
    }
  }

  (DifySide, DifyAlign)? chosen;
  final tried = <((DifySide, DifyAlign), double, double)>[];
  for (final c in candidates) {
    final r = at(c.$1, c.$2) & popup;
    final main = collision.flipSide ? over(r, c.$1) : 0.0;
    final crossSides = _vertical(c.$1) ? [DifySide.left, DifySide.right] : [DifySide.top, DifySide.bottom];
    // Cross-axis overflow counts only for alignments on the preferred axis (Floating UI's `crossAxis: 'alignment'`);
    // centred popups are shifted instead.
    final cross = c.$2 != DifyAlign.center && _vertical(c.$1) == _vertical(want)
        ? crossSides.map((e) => over(r, e)).reduce(math.max)
        : 0.0;
    if (main <= 0 && cross <= 0) {
      chosen = c;
      break;
    }
    tried.add((c, main, cross));
  }
  if (chosen == null) {
    final fits = tried.where((t) => t.$2 <= 0).toList()..sort((a, b) => a.$3.compareTo(b.$3));
    chosen = fits.isNotEmpty ? fits.first.$1 : candidates.first;
  }
  final (side, align) = chosen;
  var o = at(side, align);

  // shift(): keep the popup inside the bounds along its alignment axis, but never detached from the anchor
  // (limitShift) unless the side axis shifts too (context menus).
  double clamp(double v, double lo, double hi) => math.max(lo, math.min(v, hi));
  final detach = collision.shiftSideAxis;
  if (_vertical(side)) {
    var x = clamp(o.dx, padding, bounds.width - padding - popup.width);
    if (!detach) x = clamp(x, anchor.left - popup.width, anchor.right);
    var y = o.dy;
    if (detach) y = clamp(y, padding, bounds.height - padding - popup.height);
    o = Offset(x, y);
  } else {
    var y = clamp(o.dy, padding, bounds.height - padding - popup.height);
    if (!detach) y = clamp(y, anchor.top - popup.height, anchor.bottom);
    var x = o.dx;
    if (detach) x = clamp(x, padding, bounds.width - padding - popup.width);
    o = Offset(x, y);
  }

  // If neither side can fit (for example a third menu in a narrow viewport),
  // flipping alone leaves actions unreachable. Keep the chosen side and clamp
  // its main axis too; normal placements retain their anchor relationship.
  if (_vertical(side)) {
    o = Offset(o.dx, clamp(o.dy, padding, bounds.height - padding - popup.height));
  } else {
    o = Offset(clamp(o.dx, padding, bounds.width - padding - popup.width), o.dy);
  }

  final available = switch (side) {
    DifySide.top => anchor.top - sideOffset - padding,
    DifySide.bottom => bounds.height - padding - anchor.bottom - sideOffset,
    _ => bounds.height - 2 * padding,
  };
  return DifyFloatingPosition(o, side, align, math.max(0, available));
}
