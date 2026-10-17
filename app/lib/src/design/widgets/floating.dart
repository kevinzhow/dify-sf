import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'placement.dart';
import 'text.dart';

/// Opens and closes a [DifyFloating] (its `open` state when uncontrolled; a request to `onOpenChange` otherwise).
class DifyFloatingController {
  _DifyFloatingState? _state;

  bool get isOpen => _state?._visible ?? false;

  /// Opens the popup; a context menu passes the pointer's global position as [at]. [instant] skips the transition.
  void open({Offset? at, bool instant = false}) => _state?._request(true, at: at, instant: instant);

  /// Closes it; [instant] skips the close transition (Base UI's `data-instant`, e.g. on Escape).
  void close({bool instant = false}) => _state?._request(false, instant: instant);

  void toggle() => isOpen ? close(instant: lastInputWasKeyboard) : open();
}

/// Whether the latest input was a key press rather than a pointer: Base UI opens and closes popups instantly when a
/// keyboard click toggles them (`instantType: 'click'`).
bool get lastInputWasKeyboard {
  _InputKind.ensure();
  return _InputKind.keyboard;
}

abstract final class _InputKind {
  static bool keyboard = false;
  static bool _installed = false;

  static void ensure() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute((e) {
      if (e is PointerDownEvent) keyboard = false;
    });
    HardwareKeyboard.instance.addHandler((e) {
      if (e is KeyDownEvent) keyboard = true;
      return false;
    });
  }
}

/// Builds a popup's trigger.
typedef DifyTriggerBuilder = Widget Function(BuildContext context, DifyFloatingController controller);

/// How a popup animates in and out (overlay-shared.ts `floatingPopupAnimationClassName`: scale 0.95 and opacity;
/// tooltips fade only), over Tailwind's default 150 ms transition.
enum DifyFloatingTransition { scaleFade, fade }

/// The anchored-popup engine behind popovers, menus and tooltips (Base UI Root + Portal + Positioner + Popup): the
/// popup is rendered in the root overlay, positioned against the trigger (or a point, for context menus) with Base UI's
/// collision rules, animated, dismissed on outside tap and Escape, and returns focus to the trigger on close.
class DifyFloating extends StatefulWidget {
  const DifyFloating({
    super.key,
    required this.builder,
    required this.popupBuilder,
    this.controller,
    this.open,
    this.onOpenChange,
    this.placement = DifyPlacement.bottom,
    this.sideOffset = 0,
    this.alignOffset = 0,
    this.collision = DifyCollision.popup,
    this.transition = DifyFloatingTransition.scaleFade,
    this.dismissible = true,
    this.triggerInsideTapRegion = true,
    this.tapRegionGroup,
    this.focusPopup = true,
    this.initialFocus,
    this.constrainHeight = false,
    this.instantTransition,
    this.pointAnchor = false,
  });

  /// Builds the trigger (the anchor), which opens the popup through the controller.
  final DifyTriggerBuilder builder;
  final WidgetBuilder popupBuilder;
  final DifyFloatingController? controller;

  /// Controlled open state; null leaves it to the controller.
  final bool? open;
  final ValueChanged<bool>? onOpenChange;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final DifyCollision collision;
  final DifyFloatingTransition transition;

  /// Closes on a tap outside the popup and on Escape.
  final bool dismissible;

  /// Taps on the trigger don't count as outside taps (it toggles the popup itself).
  final bool triggerInsideTapRegion;

  /// Shared by nested popups (submenus) so taps inside any of them aren't outside taps.
  final Object? tapRegionGroup;

  /// Moves focus into the popup on open ([initialFocus], else the popup itself). Focus inside the popup returns to
  /// the trigger on close either way.
  final bool focusPopup;
  final FocusNode? initialFocus;

  /// Limits the popup's height to the space on its side (`max-h-(--available-height)`).
  final bool constrainHeight;

  /// Asked on each transition whether it is instant (`data-instant`); defaults to never.
  final bool Function(bool opening)? instantTransition;

  /// Anchors to a point instead of the trigger: where [DifyFloatingController.open] was given `at`, else the overlay's
  /// origin (Base UI's initial context-menu anchor).
  final bool pointAnchor;

  @override
  State<DifyFloating> createState() => _DifyFloatingState();
}

class _DifyFloatingState extends State<DifyFloating> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _scope = FocusScopeNode(debugLabel: 'DifyFloating popup');
  final _triggerFocus = FocusNode(debugLabel: 'DifyFloating trigger', canRequestFocus: false, skipTraversal: true);
  late final _anim = AnimationController(vsync: this, duration: difyTransitionDuration);
  // A CSS transition runs its timing function forwards in both directions.
  late final _curved = CurvedAnimation(
    parent: _anim,
    curve: difyTransitionCurve,
    reverseCurve: difyTransitionCurve.flipped,
  );
  DifyFloatingController? _ownController;
  bool _visible = false;
  Offset? _point;

  DifyFloatingController get _controller => widget.controller ?? (_ownController ??= DifyFloatingController());

  Object get _group => widget.tapRegionGroup ?? _controller;

  @override
  void initState() {
    super.initState();
    _controller._state = this;
    _anim.addStatusListener((s) {
      if (s == AnimationStatus.dismissed && !_visible) _portal.hide();
    });
    if (widget.open ?? false) _show(instant: false, rebuild: false);
  }

  @override
  void didUpdateWidget(DifyFloating old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._state = null;
      _controller._state = this;
    }
    final open = widget.open;
    if (open != null && open != _visible) {
      // The overlay can't be shown or hidden during build.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.open != open || open == _visible) return;
        final instant = widget.instantTransition?.call(open) ?? false;
        open ? _show(instant: instant) : _hide(instant: instant);
      });
    }
  }

  @override
  void dispose() {
    if (_controller._state == this) _controller._state = null;
    _curved.dispose();
    _anim.dispose();
    _scope.dispose();
    _triggerFocus.dispose();
    super.dispose();
  }

  void _request(bool open, {Offset? at, bool instant = false}) {
    if (at != null) {
      final overlay = Overlay.of(context, rootOverlay: true).context.findRenderObject() as RenderBox?;
      setState(() => _point = overlay?.globalToLocal(at) ?? at);
    }
    if (open == _visible) return;
    widget.onOpenChange?.call(open);
    if (widget.open != null) return;
    final inst = instant || (widget.instantTransition?.call(open) ?? false) || (open && lastInputWasKeyboard);
    open ? _show(instant: inst) : _hide(instant: inst);
  }

  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
  }

  bool _instant(bool requested) => requested || _reduceMotion;

  void _show({required bool instant, bool rebuild = true}) {
    _visible = true;
    _portal.show();
    if (_instant(instant)) {
      _anim.value = 1;
    } else {
      _anim.forward(from: _anim.value);
    }
    if (widget.focusPopup) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_visible) return;
        (widget.initialFocus ?? _scope).requestFocus();
      });
    }
    if (rebuild) setState(() {});
  }

  void _hide({required bool instant, bool rebuild = true}) {
    final hadFocus = _scope.hasFocus;
    _visible = false;
    if (!_portal.isShowing) {
      _anim.value = 0;
    } else if (_instant(instant)) {
      _anim.value = 0;
      _portal.hide();
    } else {
      _anim.reverse();
    }
    if (hadFocus) {
      final target = _triggerFocus.descendants.where((n) => n.canRequestFocus && !n.skipTraversal).firstOrNull;
      target?.requestFocus();
    }
    if (rebuild) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    Widget trigger = Focus(
      focusNode: _triggerFocus,
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      child: Builder(builder: (context) => widget.builder(context, _controller)),
    );
    if (widget.triggerInsideTapRegion) trigger = TapRegion(groupId: _group, child: trigger);
    return OverlayPortal.overlayChildLayoutBuilder(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context, info) {
        final anchor = widget.pointAnchor
            ? (_point ?? Offset.zero) & Size.zero
            : MatrixUtils.transformRect(info.childPaintTransform, Offset.zero & info.childSize);
        Widget popup = FocusScope(
          node: _scope,
          skipTraversal: !widget.focusPopup,
          onKeyEvent: (node, e) {
            if (widget.dismissible && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
              _request(false, instant: true);
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: _FloatingGroup(
            group: _group,
            child: Builder(builder: widget.popupBuilder),
          ),
        );
        popup = TapRegion(
          groupId: _group,
          onTapOutside: widget.dismissible ? (_) => _request(false) : null,
          child: popup,
        );
        // A popup opened from inside another one (a select in a popover) is part of it, as in Base UI: taps in it
        // are not outside taps of the outer popup.
        final parent = _FloatingGroup.of(context);
        if (parent != null && parent != _group) popup = TapRegion(groupId: parent, child: popup);
        return DifyFloatingLayout(
          anchor: anchor,
          placement: widget.placement,
          sideOffset: widget.sideOffset,
          alignOffset: widget.alignOffset,
          collision: widget.collision,
          constrainHeight: widget.constrainHeight,
          animation: _curved,
          scale: widget.transition == DifyFloatingTransition.scaleFade,
          child: IgnorePointer(ignoring: !_visible, child: popup),
        );
      },
      child: trigger,
    );
  }
}

/// The tap region group of the popup [child] is in.
class _FloatingGroup extends InheritedWidget {
  const _FloatingGroup({required this.group, required super.child});
  final Object group;

  static Object? of(BuildContext context) => context.getInheritedWidgetOfExactType<_FloatingGroup>()?.group;

  @override
  bool updateShouldNotify(_FloatingGroup old) => group != old.group;
}

/// Lays a popup out against [anchor] in the overlay ([computeFloatingPosition]) and paints the open/close
/// transition around Base UI's transform origin.
class DifyFloatingLayout extends SingleChildRenderObjectWidget {
  const DifyFloatingLayout({
    super.key,
    required this.anchor,
    required this.placement,
    required this.animation,
    this.sideOffset = 0,
    this.alignOffset = 0,
    this.collision = DifyCollision.popup,
    this.constrainHeight = false,
    this.scale = true,
    super.child,
  });

  final Rect anchor;
  final DifyPlacement placement;
  final double sideOffset;
  final double alignOffset;
  final DifyCollision collision;
  final bool constrainHeight;
  final Animation<double> animation;
  final bool scale;

  @override
  RenderDifyFloatingLayout createRenderObject(BuildContext context) => RenderDifyFloatingLayout(this);

  @override
  void updateRenderObject(BuildContext context, RenderDifyFloatingLayout renderObject) => renderObject.config = this;
}

class RenderDifyFloatingLayout extends RenderShiftedBox {
  RenderDifyFloatingLayout(this._config) : super(null);

  DifyFloatingLayout _config;
  DifyFloatingPosition? _position;

  /// The side and alignment the popup ended up with (Base UI's `data-side` / `data-align`).
  DifySide get side => _position!.side;
  DifyAlign get align => _position!.align;

  set config(DifyFloatingLayout c) {
    final old = _config;
    _config = c;
    if (attached && old.animation != c.animation) {
      old.animation.removeListener(markNeedsPaint);
      c.animation.addListener(markNeedsPaint);
    }
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _config.animation.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _config.animation.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    final c = _config;
    DifyFloatingPosition place() => computeFloatingPosition(
      anchor: c.anchor,
      popup: child.size,
      bounds: size,
      placement: c.placement,
      sideOffset: c.sideOffset,
      alignOffset: c.alignOffset,
      collision: c.collision,
    );
    child.layout(BoxConstraints.loose(size), parentUsesSize: true);
    var p = place();
    if (c.constrainHeight && child.size.height > p.availableHeight) {
      child.layout(BoxConstraints.loose(Size(size.width, p.availableHeight)), parentUsesSize: true);
      p = place();
    }
    _position = p;
    (child.parentData! as BoxParentData).offset = p.offset;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    final t = _config.animation.value;
    if (t <= 0) return;
    final childOffset = (child.parentData! as BoxParentData).offset;
    void paintChild(PaintingContext ctx, Offset o) {
      if (!_config.scale || t >= 1) return ctx.paintChild(child, o + childOffset);
      final s = 0.95 + 0.05 * t;
      final origin = _position!.origin(child.size, _config.anchor).alongSize(child.size) + childOffset + o;
      final m = Matrix4.identity()
        ..translateByDouble(origin.dx, origin.dy, 0, 1)
        ..scaleByDouble(s, s, 1, 1)
        ..translateByDouble(-origin.dx, -origin.dy, 0, 1);
      ctx.pushTransform(needsCompositing, Offset.zero, m, (c2, _) => c2.paintChild(child, o + childOffset));
    }

    if (t >= 1) return paintChild(context, offset);
    context.pushOpacity(offset, (t * 255).round(), paintChild);
  }
}
