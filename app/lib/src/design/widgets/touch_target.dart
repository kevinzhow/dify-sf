/// Touch-size hit areas for dify-sf's phone layout: a hit-area expander and the phone chrome's icon button.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'responsive.dart';

/// Gives a small control (a 24 px icon button, a 20 px close glyph, a 36 px segmented control) a hit area of at least
/// [minSize] in each direction, centred on it, without changing its layout size: a tap that lands outside the control
/// but inside that area is sent to the nearest point of the control (so a segmented control keeps the segment under
/// the finger).
///
/// Limitation: Flutter only hit-tests a widget when the point is inside its parent, so the extra area works only
/// where the parent is large enough to contain it (a 56 px bar around a 24 px button, a padded row). Where the
/// parent is exactly the control's size, give the control a real 48 px box instead. Between siblings, the one
/// hit-tested first (the later one in a Stack, the first one in a Row or Column) wins an overlapping area.
class DifyTouchTarget extends SingleChildRenderObjectWidget {
  const DifyTouchTarget({super.key, this.minSize = DifyTouch.minTarget, required Widget super.child});

  /// The smallest width and height of the hit area.
  final double minSize;

  @override
  RenderDifyTouchTarget createRenderObject(BuildContext context) => RenderDifyTouchTarget(minSize: minSize);

  @override
  void updateRenderObject(BuildContext context, RenderDifyTouchTarget renderObject) => renderObject.minSize = minSize;
}

/// The render object of [DifyTouchTarget]: laid out like its child, hit-tested over [touchRect].
class RenderDifyTouchTarget extends RenderProxyBox {
  RenderDifyTouchTarget({this.minSize = DifyTouch.minTarget});

  /// The smallest width and height of the hit area (only hit testing reads it, so changing it needs no layout).
  double minSize;

  static const _edge = 1e-6;

  /// The hit area, in local coordinates: the box grown to [minSize] around its centre (edges included).
  Rect get touchRect => Rect.fromCenter(
    center: size.center(Offset.zero),
    width: math.max(size.width, minSize),
    height: math.max(size.height, minSize),
  );

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position)) return super.hitTest(result, position: position);
    final child = this.child;
    final r = touchRect;
    if (child == null ||
        position.dx < r.left ||
        position.dx > r.right ||
        position.dy < r.top ||
        position.dy > r.bottom) {
      return false;
    }
    // The child sees the pointer moved onto its nearest point (inside: the right and bottom edges are exclusive), and
    // later events of the same pointer moved by the same amount.
    final nearest = Offset(
      position.dx.clamp(0.0, math.max(0.0, size.width - _edge)),
      position.dy.clamp(0.0, math.max(0.0, size.height - _edge)),
    );
    final hit = result.addWithPaintOffset(
      offset: position - nearest,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
    if (hit) result.add(BoxHitTestEntry(this, position));
    return hit;
  }
}

/// A small control in a box of at least [minSize] square, centred, with the hit area of a [DifyTouchTarget]: where the
/// row around the control is only as tall as the control (a 24 px field header), this is the "real 48 px box" the
/// target needs. The control keeps its own size and look; only the slot around it grows.
///
/// With [accessibleBox] (one control in the box) the box is also the control's bounds for accessibility: TalkBack's
/// focus and what the platform reports as the target's size are the box, not the 24 px glyph.
class DifyTouchArea extends StatelessWidget {
  const DifyTouchArea({super.key, this.minSize = DifyTouch.minTarget, this.accessibleBox = false, required this.child});

  final double minSize;
  final bool accessibleBox;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final box = ConstrainedBox(
      constraints: BoxConstraints(minWidth: minSize, minHeight: minSize),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: DifyTouchTarget(minSize: minSize, child: child),
      ),
    );
    return accessibleBox ? MergeSemantics(child: box) : box;
  }
}

/// The phone chrome's icon button (the mockups' `.ibtn`): a [size] square (44 px) with `rounded-[10px]`, an icon
/// (22 px by convention) in text-secondary, state-base-hover while pressed or hovered, and at least a 48 px hit area.
/// [label] is its accessible name (there are no tooltips on touch). [destructive] tints it text-destructive. A toggle
/// passes [selected]: on, it shows state-accent-active with a text-accent icon (Dify's toggled icon buttons) and reports
/// `toggled` to assistive technology.
class DifyTouchIconButton extends StatelessWidget {
  const DifyTouchIconButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.disabled = false,
    this.destructive = false,
    this.size = 44,
    this.selected,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool destructive;
  final double size;

  /// On / off for a toggle; null for a plain action.
  final bool? selected;

  @override
  Widget build(BuildContext context) {
    final on = selected ?? false;
    Widget button = DifyPressable(
      onPressed: onPressed,
      disabled: disabled,
      semanticLabel: label,
      builder: (context, hovered, focused) => DifyButtonSurface(
        look: DifyButtonLook(
          foreground: disabled
              ? DifyColors.textDisabled
              : destructive
              ? DifyColors.textDestructive
              : on
              ? DifyColors.textAccent
              : DifyColors.textSecondary,
          background: on
              ? (hovered && !disabled ? DifyColors.stateAccentActiveAlt : DifyColors.stateAccentActive)
              : hovered && !disabled
              ? DifyColors.stateBaseHover
              : null,
        ),
        radius: DifyRadius.container,
        focused: focused,
        child: SizedBox.square(
          dimension: size,
          child: Center(child: ExcludeSemantics(child: icon)),
        ),
      ),
    );
    // One node: the button with its name and, for a toggle, its state.
    if (selected != null) {
      button = MergeSemantics(
        child: Semantics(toggled: selected, child: button),
      );
    }
    return DifyTouchTarget(child: button);
  }
}
