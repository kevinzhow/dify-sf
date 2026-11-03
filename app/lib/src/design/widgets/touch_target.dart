/// Touch-size hit areas for dify-sf's phone layout: a hit-area expander and the phone chrome's icon button.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'bottom_sheet.dart' show DifySheetRecipe;
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
  const DifyTouchTarget({
    super.key,
    this.minSize = DifyTouch.minTarget,
    this.accessible = false,
    required Widget super.child,
  });

  /// The smallest width and height of the hit area.
  final double minSize;

  /// The hit area is also the control's bounds for accessibility (raft-flutter's `RaftTouchTarget`): one node, the
  /// control's semantics merged into it, as large as the hit area, so TalkBack's focus and what the platform reports
  /// as the target's size match what a finger can hit. Only inside a box of the control's own that holds the whole hit
  /// area (the touch segmented control's 48 px box): hit testing stops at the parent's edge (the limitation above), so
  /// elsewhere the node would claim more than a finger can hit; give the control a [DifyTouchArea] box there.
  final bool accessible;

  @override
  RenderDifyTouchTarget createRenderObject(BuildContext context) =>
      RenderDifyTouchTarget(minSize: minSize, accessible: accessible);

  @override
  void updateRenderObject(BuildContext context, RenderDifyTouchTarget renderObject) => renderObject
    ..minSize = minSize
    ..accessible = accessible;
}

/// The render object of [DifyTouchTarget]: laid out like its child, hit-tested over [touchRect].
class RenderDifyTouchTarget extends RenderProxyBox {
  RenderDifyTouchTarget({this._minSize = DifyTouch.minTarget, this._accessible = false});

  /// The smallest width and height of the hit area (hit testing reads it, and the semantics when [accessible]).
  double get minSize => _minSize;
  double _minSize;
  set minSize(double value) {
    if (value == _minSize) return;
    _minSize = value;
    if (_accessible) markNeedsSemanticsUpdate();
  }

  /// See [DifyTouchTarget.accessible].
  bool get accessible => _accessible;
  bool _accessible;
  set accessible(bool value) {
    if (value == _accessible) return;
    _accessible = value;
    markNeedsSemanticsUpdate();
  }

  @override
  Rect get semanticBounds => _accessible ? touchRect : super.semanticBounds;

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (!_accessible) return;
    config
      ..isSemanticBoundary = true
      ..isMergingSemanticsOfDescendants = true;
  }

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

  /// A small control (a 24 px icon button, a field header's "+") in a sheet on a phone: in a touch box of
  /// [DifyTouch.controlHeight] that is also its accessible bounds, as a [DifyButton] there is touch-high; elsewhere
  /// the control as it is. The one rule of the controls' touch size in phone sheets ([DifyIconButton] uses it).
  ///
  /// The box sends a tap at its edges to the nearest point of [control], so that point must be the control's: padding
  /// or a border with no tap of its own at the control's edge leaves that edge of the reported box dead (keep such
  /// spacing outside the control, or leave it out in a phone sheet: [appliesIn]).
  static Widget inPhoneSheet(BuildContext context, Widget control) => appliesIn(context)
      ? DifyTouchArea(minSize: DifyTouch.controlHeight, accessibleBox: true, child: control)
      : control;

  /// Whether [inPhoneSheet] boxes a control in [context]: a sheet or a [DifyTouchSurface] in a compact window.
  static bool appliesIn(BuildContext context) =>
      DifyTouch.compactOf(context) && (DifySheetRecipe.contains(context) || DifyTouchSurface.of(context));

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

/// A surface of the phone layout whose controls are touch-sized as in a sheet ([DifyTouchArea.inPhoneSheet], a
/// [DifyButton] 44 px high): a pushed phone page and a drawer shown as a page. It has no effect in a window of 600 dp
/// and wider.
///
/// [enabled] false marks nothing (a surface that switches its form in place keeps this widget in its tree).
class DifyTouchSurface extends InheritedWidget {
  const DifyTouchSurface({super.key, this.enabled = true, required super.child});

  final bool enabled;

  /// Whether [context] is inside an enabled [DifyTouchSurface].
  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyTouchSurface>()?.enabled ?? false;

  @override
  bool updateShouldNotify(DifyTouchSurface oldWidget) => oldWidget.enabled != enabled;
}
