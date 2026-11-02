import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'back_dismiss.dart';
import 'bottom_sheet.dart';
import 'page.dart' show DifyWindowInsets;
import 'placement.dart';
import 'responsive.dart';
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
/// collision rules, animated, dismissed on outside tap and Escape, and returns focus to the trigger on close. A
/// [dismissible] popup also closes on Android back before the page under it does (a [DifyBackStep] on the trigger's
/// route while it is open).
///
/// A picker ([sheetOnCompact]: selects, the variable and model pickers, popovers) opens as a bottom sheet in a compact
/// window instead (dify-sf's phones; raft-flutter's picker policy: a sheet below the breakpoint, a popover above). This
/// is the one switch every picker goes through ([presentsAsSheet]): the same popup content, in the same overlay (it
/// keeps the trigger's inherited state), over a window-wide scrim, under an optional [sheetTitle] header, full width
/// and without its own surface ([inSheet] tells the content so: menus and lists grow their rows to 48 px). Its focus
/// stays on the sheet itself, so a search field in it does not open the keyboard until it is tapped. The scrim, a
/// drag down, Escape and Android back close it.
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
    this.sheetOnCompact = false,
    this.sheetTitle,
    this.sheetDetents = const [DifySheetDetent.full],
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

  /// A picker: in a compact window it opens as a bottom sheet ([presentsAsSheet]).
  final bool sheetOnCompact;

  /// The sheet's header title (a [DifySheetHeader] with a close button); none: the sheet starts with its grab handle.
  final String? sheetTitle;

  /// Where the sheet rests: its content's height by default (up to the top safe area).
  final List<DifySheetDetent> sheetDetents;

  /// Whether a popup that opens as a sheet on compact windows ([sheetOnCompact]) does so in [context]'s window: below
  /// 600 dp ([DifyWindowClass.compact]). The single compact switch of the pickers.
  static bool presentsAsSheet(BuildContext context, {bool sheetOnCompact = true}) =>
      sheetOnCompact && DifyWindowClass.of(context) == DifyWindowClass.compact;

  /// Whether [context] is inside a popup shown as a bottom sheet: its content drops its own surface and fixed width,
  /// and its rows take touch height (48 px).
  static bool inSheet(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<DifyPopupSheetScope>() != null;

  @override
  State<DifyFloating> createState() => _DifyFloatingState();
}

/// Marks the content of a popup shown as a bottom sheet ([DifyFloating.inSheet]): [DifyFloating] puts it there, and
/// so does a popup host of its own that presents its content in a sheet on a phone (the prompt editor's `{` / `/`
/// picker, through [DifyPortalSheetFrame]).
class DifyPopupSheetScope extends InheritedWidget {
  const DifyPopupSheetScope({super.key, required super.child});

  @override
  bool updateShouldNotify(DifyPopupSheetScope oldWidget) => false;
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

  /// Android back closes the open popup first.
  late final _back = DifyBackStep(onDismiss: () => _request(false, instant: true));

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
    _back.detach();
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
    // A close request takes the back step away at once, also when the owner closes a controlled popup later.
    if (!open) _back.detach();
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

  /// Whether the popup shows as a sheet (read live: the window's class).
  bool get _sheet => mounted && DifyFloating.presentsAsSheet(context, sheetOnCompact: widget.sheetOnCompact);

  void _show({required bool instant, bool rebuild = true}) {
    _visible = true;
    // Opened from initState the window cannot be read yet; the duration follows from the next opening.
    if (rebuild) _anim.duration = _sheet ? DifySheetRecipe.openDuration : difyTransitionDuration;
    _portal.show();
    if (widget.dismissible) {
      // Opened from initState (no inherited lookups yet): after the first frame.
      if (rebuild) {
        _back.attach(context);
      } else {
        SchedulerBinding.instance.addPostFrameCallback((_) {
          if (mounted && _visible) _back.attach(context);
        });
      }
    }
    if (_instant(instant)) {
      _anim.value = 1;
    } else {
      _anim.forward(from: _anim.value);
    }
    if (widget.focusPopup) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_visible) return;
        // A sheet keeps the focus on itself: a search field in it would open the keyboard over the list.
        (_sheet ? _scope : widget.initialFocus ?? _scope).requestFocus();
      });
    }
    if (rebuild) setState(() {});
  }

  void _hide({required bool instant, bool rebuild = true}) {
    final hadFocus = _scope.hasFocus;
    _visible = false;
    _back.detach();
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
        // Portal descendants are inside every ancestor popup, not only the
        // immediate parent. Keep the complete tree in the same tap regions.
        final groups = <Object>{...?_FloatingGroup.of(context), _group};
        if (_sheet) return _sheetPopup(groups);
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
            groups: groups,
            child: Builder(builder: widget.popupBuilder),
          ),
        );
        for (final group in groups) {
          popup = TapRegion(
            groupId: group,
            onTapOutside: group == _group && widget.dismissible ? (_) => _request(false) : null,
            child: popup,
          );
        }
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

extension on _DifyFloatingState {
  /// The popup as a bottom sheet: the scrim closes it (not an outside tap: the sheet's own handle is outside the
  /// content), and the whole frame is inside the popup's tap regions, so a popup it opens keeps it open.
  Widget _sheetPopup(Set<Object> groups) {
    final w = widget;
    Widget content = FocusScope(
      node: _scope,
      skipTraversal: !w.focusPopup,
      onKeyEvent: (node, e) {
        if (w.dismissible && e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          _request(false, instant: true);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: _FloatingGroup(
        groups: groups,
        child: DifyPopupSheetScope(child: Builder(builder: w.popupBuilder)),
      ),
    );
    if (w.sheetTitle case final title?) {
      content = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          DifySheetHeader(title: title),
          Flexible(child: content),
        ],
      );
    }
    Widget sheet = DifyPortalSheetFrame(
      animation: _curved,
      detents: w.sheetDetents,
      onDismiss: w.dismissible ? () => _request(false) : null,
      isOpen: () => mounted && _visible,
      child: IgnorePointer(ignoring: !_visible, child: content),
    );
    for (final group in groups) {
      sheet = TapRegion(groupId: group, child: sheet);
    }
    return sheet;
  }
}

/// The tap region group of the popup [child] is in.
class _FloatingGroup extends InheritedWidget {
  const _FloatingGroup({required this.groups, required super.child});
  final Set<Object> groups;

  static Set<Object>? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_FloatingGroup>()?.groups;

  @override
  bool updateShouldNotify(_FloatingGroup old) => groups.length != old.groups.length || !groups.containsAll(old.groups);
}

/// Lays a popup out against [anchor] in the overlay ([computeFloatingPosition]) and paints the open/close
/// transition around Base UI's transform origin. The collision bounds are the overlay less the window's system insets
/// ([DifyWindowInsets]): the root overlay fills the window, popups stay clear of the status and navigation bars.
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
  RenderDifyFloatingLayout createRenderObject(BuildContext context) =>
      RenderDifyFloatingLayout(this, insets: DifyWindowInsets.of(context));

  @override
  void updateRenderObject(BuildContext context, RenderDifyFloatingLayout renderObject) => renderObject
    ..config = this
    ..insets = DifyWindowInsets.of(context);
}

class RenderDifyFloatingLayout extends RenderShiftedBox {
  RenderDifyFloatingLayout(this._config, {this._insets = EdgeInsets.zero}) : super(null);

  DifyFloatingLayout _config;
  DifyFloatingPosition? _position;

  /// The overlay's edges the popup keeps clear of (the window's system insets).
  EdgeInsets get insets => _insets;
  EdgeInsets _insets;
  set insets(EdgeInsets value) {
    if (value == _insets) return;
    _insets = value;
    markNeedsLayout();
  }

  /// The side and alignment the popup ended up with (Base UI's `data-side` / `data-align`).
  DifySide get side => _position!.side;
  DifyAlign get align => _position!.align;

  set config(DifyFloatingLayout c) {
    final old = _config;
    _config = c;
    if (attached && old.animation != c.animation) {
      old.animation.removeListener(_animationChanged);
      c.animation.addListener(_animationChanged);
    }
    markNeedsLayout();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _config.animation.addListener(_animationChanged);
  }

  @override
  void detach() {
    _config.animation.removeListener(_animationChanged);
    super.detach();
  }

  void _animationChanged() {
    markNeedsPaint();
    markNeedsSemanticsUpdate();
  }

  // The full viewport is only a positioning surface. Exposing it as a leaf
  // semantics rectangle lets an otherwise empty Web overlay swallow clicks.
  @override
  Rect get semanticBounds {
    final child = this.child;
    if (child == null || !child.hasSize || _config.animation.value <= 0) return Rect.zero;
    return MatrixUtils.transformRect(_childTransform, Offset.zero & child.size);
  }

  // Like RenderTransform, all consumers use the same child-to-parent matrix.
  // A paint-only scale leaves pointer/hover and Web accessibility at stale
  // coordinates throughout the transition, including the submenu corridor.
  Matrix4 get _childTransform {
    final child = this.child!;
    final offset = (child.parentData! as BoxParentData).offset;
    final transform = Matrix4.translationValues(offset.dx, offset.dy, 0);
    if (_config.scale && _config.animation.value < 1) {
      final scale = 0.95 + 0.05 * _config.animation.value;
      final origin = _position!.origin(child.size, _config.anchor).alongSize(child.size);
      transform
        ..translateByDouble(origin.dx, origin.dy, 0, 1)
        ..scaleByDouble(scale, scale, 1, 1)
        ..translateByDouble(-origin.dx, -origin.dy, 0, 1);
    }
    return transform;
  }

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) => transform.multiply(_childTransform);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    final child = this.child;
    if (child == null || _config.animation.value <= 0) return false;
    return result.addWithPaintTransform(
      transform: _childTransform,
      position: position,
      hitTest: (result, transformed) => child.hitTest(result, position: transformed),
    );
  }

  @override
  void performLayout() {
    size = constraints.biggest;
    final child = this.child;
    if (child == null) return;
    final c = _config;
    // Positions are computed in the safe area (origin at its top-left) and moved back into the overlay.
    final origin = Offset(math.min(_insets.left, size.width), math.min(_insets.top, size.height));
    final bounds = Size(
      math.max(0, size.width - _insets.horizontal),
      math.max(0, size.height - _insets.vertical),
    );
    DifyFloatingPosition place() {
      final p = computeFloatingPosition(
        anchor: c.anchor.shift(-origin),
        popup: child.size,
        bounds: bounds,
        placement: c.placement,
        sideOffset: c.sideOffset,
        alignOffset: c.alignOffset,
        collision: c.collision,
      );
      return DifyFloatingPosition(p.offset + origin, p.side, p.align, p.availableHeight);
    }

    final popupBounds = Size(
      math.max(0, bounds.width - 2 * difyFloatingCollisionPadding),
      math.max(0, bounds.height - 2 * difyFloatingCollisionPadding),
    );
    child.layout(BoxConstraints.loose(popupBounds), parentUsesSize: true);
    var p = place();
    if (c.constrainHeight && child.size.height > p.availableHeight) {
      child.layout(BoxConstraints.loose(Size(popupBounds.width, p.availableHeight)), parentUsesSize: true);
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
    void paintChild(PaintingContext ctx, Offset o) {
      ctx.pushTransform(needsCompositing, o, _childTransform, (context, offset) => context.paintChild(child, offset));
    }

    if (t >= 1) return paintChild(context, offset);
    context.pushOpacity(offset, (t * 255).round(), paintChild);
  }
}
