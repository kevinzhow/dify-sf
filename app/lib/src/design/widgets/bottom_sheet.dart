/// dify-sf's phone bottom sheets (a dify-sf divergence: Dify's console uses centred dialogs and side panels).
///
/// Built the way raft-flutter's raft_ui builds RaftSheet: our own look (panel colour, 16 px top corners, our grab
/// handle, the shared scrim) over the framework's behaviour. A modal sheet is the framework's modal bottom sheet route
/// (scrim, Back, the slide in and out); its detents, snapping and the hand-over between a scrolling body and the sheet
/// come from [DraggableScrollableSheet]. A drag down to the bottom asks the route to close with [Navigator.maybePop],
/// as Back and Escape do, so a PopScope can veto it and the sheet slides back. A persistent sheet is the same
/// [DraggableScrollableSheet] without a route. Nothing outside design/ opens a framework sheet (design check
/// `raw-sheet`).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, listEquals;
import 'package:flutter/material.dart' show MaterialLocalizations, ModalBottomSheetRoute;
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'back_dismiss.dart';
import 'page.dart' show DifySurface, DifyWindowInsets;
import 'responsive.dart';
import 'selection.dart';
import 'text.dart';
import 'touch_target.dart';

/// The bottom sheets' look (gen.py `.sheet`, `.grab`, `.scrim`).
abstract final class DifySheetRecipe {
  /// `rounded-t-2xl`.
  static const radius = DifyRadius.xxl;

  /// The grab handle's row (`h-5`) and bar (36x4, `rounded-xs`).
  static const grabHeight = 20.0;
  static const grabSize = Size(36, 4);

  /// The scrim behind a modal sheet: the mockups' `rgba(16,24,40,.28)`, which is background-overlay's colour at 28 %
  /// in the light theme; the dark theme uses background-overlay-alt, which still separates a dark sheet.
  static Color get scrim =>
      DifyColors.isDark ? DifyColors.backgroundOverlayAlt : DifyColors.backgroundOverlay.withValues(alpha: 0.28);

  /// shadow-lg cast upwards (gen.py's sheet shadow is `0 -8px 24px`): only a persistent sheet needs it to stand off
  /// the page.
  static List<BoxShadow> get shadow => [
    for (final s in DifyShadows.lg) s.copyWith(offset: Offset(s.offset.dx, -s.offset.dy)),
  ];

  /// A flick faster than this (logical pixels a second) moves the sheet to the next detent, or closes it from below
  /// the lowest one (raft-flutter's threshold).
  static const flingVelocity = 700.0;

  /// The settle animation after a drag (raft-flutter: 200 ms, ease-out).
  static const settleDuration = Duration(milliseconds: 200);

  /// A sheet shown from a page's tree ([DifySheetPortal]) slides in and out over this (the framework sheet route's
  /// 250 ms).
  static const openDuration = Duration(milliseconds: 250);

  /// Whether [context] is inside a bottom sheet's content (a sheet route, a [DifySheetPortal], a
  /// [DifyPersistentSheet], a picker sheet).
  static bool contains(BuildContext context) => _SheetDragScope.of(context) != null;
}

enum _DetentKind { peek, half, full }

/// A height a bottom sheet rests at. Released, the sheet settles on the nearest detent, or flicked, on the next one in
/// the flick's direction. Heights are measured from the top of the keyboard when it is open (so the sheet grows by the
/// keyboard's height and what was visible stays visible) and above the bottom system inset otherwise; none exceeds
/// [full].
@immutable
class DifySheetDetent {
  /// [height] logical pixels of the sheet showing (the grab handle included).
  const DifySheetDetent.peek(double this.height) : _kind = _DetentKind.peek;

  const DifySheetDetent._(this._kind) : height = null;

  /// Half the window's height (the sheet's whole height if that is shorter).
  static const half = DifySheetDetent._(_DetentKind.half);

  /// The whole sheet: its content's height, at most up to the top safe area (a scrolling body fills it).
  static const full = DifySheetDetent._(_DetentKind.full);

  final double? height;
  final _DetentKind _kind;

  @override
  bool operator ==(Object other) => other is DifySheetDetent && other._kind == _kind && other.height == height;

  @override
  int get hashCode => Object.hash(_kind, height);

  @override
  String toString() => switch (_kind) {
    _DetentKind.peek => 'DifySheetDetent.peek($height)',
    _DetentKind.half => 'DifySheetDetent.half',
    _DetentKind.full => 'DifySheetDetent.full',
  };
}

/// Moves a sheet between its detents and reports its position. Give it to [showDifyBottomSheet] or
/// [DifyPersistentSheet]; dispose it with its owner.
class DifySheetController extends ChangeNotifier {
  _DifySheetState? _sheet;

  /// Whether a sheet is attached.
  bool get isAttached => _sheet?._ready ?? false;

  /// The sheet's visible height above the bottom of its viewport, the keyboard under it included (null before it is
  /// laid out).
  double? get offset => _sheet?._offset;

  /// The detent the attached sheet rests at, or is settling on (null when none is attached).
  DifySheetDetent? get detent => _sheet?._resting;

  /// Animates the attached sheet to [detent]; completes at once when none is attached.
  Future<void> animateTo(
    DifySheetDetent detent, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
  }) => _sheet?._animateTo(detent, duration: duration, curve: curve) ?? Future.value();

  /// Slides a dismissible [DifyPersistentSheet] away and then calls its `onDismiss` (what Back does for such a
  /// sheet); completes at once when none is attached or it cannot be dismissed.
  Future<void> dismiss() => _sheet?._dismiss() ?? Future.value();

  void _attach(_DifySheetState sheet) => _sheet = sheet;

  void _detach(_DifySheetState sheet) {
    if (_sheet == sheet) _sheet = null;
  }

  /// The sheet moved. Listeners may rebuild, so a move during a build or layout is reported after the frame.
  void _moved() {
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => notifyListeners());
    } else {
      notifyListeners();
    }
  }
}

/// Marks the content of a modal sheet (a route, or a [DifySheetPortal]), so [DifySheetHeader]'s close button closes
/// it by default: [close] (a portal's dismissal), or the route's [Navigator.maybePop] when null.
class _ModalSheetScope extends InheritedWidget {
  const _ModalSheetScope({this.close, required super.child});

  final VoidCallback? close;

  static _ModalSheetScope? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ModalSheetScope>();

  @override
  bool updateShouldNotify(_ModalSheetScope oldWidget) => close != oldWidget.close;
}

/// Pushes a bottom sheet route showing [builder]'s content (usually a [DifySheetHeader] over a body; a scrolling body
/// fills the sheet, other content keeps its own height) and resolves with what it pops.
///
/// The sheet starts at [initialDetent] (the first of [detents] by default) and snaps between [detents]. When
/// [modal], a scrim (`DifySheetRecipe.scrim`) covers the window and blocks the page; otherwise the page stays
/// interactive around the sheet. When [dismissible], dragging it down below its lowest detent, a tap on the scrim, the
/// system back button and Escape close it (each through [Navigator.maybePop], so a PopScope in the content can veto
/// it); otherwise only the content can close it (`Navigator.pop`), unless [backDismissible]: then the system back
/// button and Escape still close it (a dialog whose outside clicks do not close it, Dify's `disablePointerDismissal`).
/// With [closeOnEscape] false the content handles Escape itself.
///
/// The sheet paints to the window's bottom and side edges and keeps its content clear of the system insets and the
/// keyboard: the keyboard's height replaces the bottom inset (never added to it) and the sheet rises with it, so a
/// focused field stays visible. Dragging the sheet down hides the keyboard; while the keyboard is open a drag does not
/// close the sheet. A scroll view in the body is the sheet's scrollable: scrolled to its top, a drag down moves the
/// sheet, and a drag up grows the sheet before it scrolls (on Android and iOS; elsewhere give it `primary: true`).
Future<T?> showDifyBottomSheet<T>(
  BuildContext context,
  WidgetBuilder builder, {
  List<DifySheetDetent> detents = const [DifySheetDetent.full],
  DifySheetDetent? initialDetent,
  bool modal = true,
  bool dismissible = true,
  DifySheetController? controller,
  String? barrierLabel,
  bool useRootNavigator = true,
  bool? backDismissible,
  bool closeOnEscape = true,
}) {
  assert(detents.isNotEmpty, 'A sheet needs at least one detent');
  final back = backDismissible ?? dismissible;
  assert(initialDetent == null || detents.contains(initialDetent), 'initialDetent must be one of detents');
  final navigator = Navigator.of(context, rootNavigator: useRootNavigator);
  late final _DifySheetRoute<T> route;
  route = _DifySheetRoute<T>(
    modal: modal,
    isDismissible: dismissible,
    barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
    capturedThemes: InheritedTheme.capture(from: context, to: navigator.context),
    builder: (context) {
      Widget sheet = _ModalSheetScope(
        child: _DifySheet(
          detents: detents,
          initialDetent: initialDetent,
          controller: controller,
          requestClose: dismissible
              ? () async {
                  await Navigator.of(context).maybePop();
                  return route.isActive;
                }
              : null,
          modalRoute: true,
          shadow: !modal,
          child: DifySelectionRegion(child: Builder(builder: builder)),
        ),
      );
      if (!back) sheet = PopScope<T>(canPop: false, child: sheet);
      if (!closeOnEscape) return sheet;
      return Shortcuts(
        shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
        child: Actions(
          actions: {
            DismissIntent: CallbackAction<DismissIntent>(
              onInvoke: (_) {
                Navigator.of(context).maybePop();
                return null;
              },
            ),
          },
          child: sheet,
        ),
      );
    },
  );
  return navigator.push(route);
}

/// The framework's modal bottom sheet route with nothing of its own look: the sheet paints itself ([_DifySheet]),
/// the framework drag is off (the detents drag it), the width is not capped and the route reaches under the status
/// bar (the sheet stops at the top safe area itself). When not [modal], the barrier lets pointers through to the page.
class _DifySheetRoute<T> extends ModalBottomSheetRoute<T> {
  _DifySheetRoute({
    required this.modal,
    required super.builder,
    required super.isDismissible,
    required super.barrierLabel,
    super.capturedThemes,
  }) : super(
         isScrollControlled: true,
         useSafeArea: false,
         enableDrag: false,
         showDragHandle: false,
         backgroundColor: const Color(0x00000000),
         elevation: 0,
         constraints: const BoxConstraints(),
         modalBarrierColor: DifySheetRecipe.scrim,
       );

  final bool modal;

  @override
  Widget buildModalBarrier() => modal ? super.buildModalBarrier() : const IgnorePointer(child: SizedBox.expand());

  // The framework removes the top padding from the sheet's MediaQuery (useSafeArea: false); the sheet still needs it
  // to stop below the status bar.
  @override
  Widget buildPage(BuildContext context, Animation<double> animation, Animation<double> secondaryAnimation) =>
      _SheetTopInset(
        top: MediaQuery.paddingOf(context).top,
        child: super.buildPage(context, animation, secondaryAnimation),
      );
}

class _SheetTopInset extends InheritedWidget {
  const _SheetTopInset({required this.top, required super.child});
  final double top;

  static double? of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_SheetTopInset>()?.top;

  @override
  bool updateShouldNotify(_SheetTopInset oldWidget) => top != oldWidget.top;
}

/// A sheet that lives in a page instead of a route (mockup 7's run panel): the page behind stays interactive. Put
/// it last in a Stack that fills the page; it fills the Stack and only its sheet takes pointers. It rests at
/// [initialDetent] (the first of [detents]) and snaps between [detents]; without [onDismiss] it cannot be dragged
/// away. (A modal sheet shown from a page's tree is a [DifySheetPortal].)
///
/// Because it is part of the page, its content sees the page's inherited scopes, and the page decides when it shows:
/// an owner that shows it while some state says so (a list is open) passes [onDismiss] to clear that state. Then a
/// drag or flick below the lowest detent and [DifySheetController.dismiss] (Back, through the owner) slide it away and
/// call [onDismiss]; should the owner keep it, it slides back. [slideIn] makes it rise from the bottom edge when it
/// first shows.
///
/// Edge to edge like [showDifyBottomSheet]: in an edge-to-edge page it paints to the window's edges and pads its
/// content by the system insets and the keyboard; its full height stops at the top safe area.
class DifyPersistentSheet extends StatelessWidget {
  const DifyPersistentSheet({
    super.key,
    required this.child,
    this.detents = const [DifySheetDetent.peek(120), DifySheetDetent.half, DifySheetDetent.full],
    this.initialDetent,
    this.controller,
    this.onDismiss,
    this.slideIn = false,
  });

  final Widget child;
  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;

  /// Called once the sheet has slid away (dragged below its lowest detent, or dismissed through [controller]); null:
  /// the sheet cannot be dismissed.
  final VoidCallback? onDismiss;

  /// The sheet rises from the bottom edge to [initialDetent] when it first shows.
  final bool slideIn;

  @override
  Widget build(BuildContext context) => _DifySheet(
    detents: detents,
    initialDetent: initialDetent,
    controller: controller,
    requestClose: null,
    modalRoute: false,
    shadow: true,
    onDismiss: onDismiss,
    slideIn: slideIn,
    child: child,
  );
}

/// A drag of the sheet by the handle, the header or any part that is not a scroll view, in logical pixels down the
/// screen. The scroll view drags the sheet through the [DraggableScrollableSheet]'s controller.
abstract interface class _SheetPointerDrag {
  void update(double dy);
  void end(double velocityDy);
}

class _SheetDragScope extends InheritedWidget {
  const _SheetDragScope({required this.drag, required super.child});
  final _SheetPointerDrag drag;

  static _SheetPointerDrag? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SheetDragScope>()?.drag;

  @override
  bool updateShouldNotify(_SheetDragScope oldWidget) => drag != oldWidget.drag;
}

/// The grab handle and the header move the sheet with any pointer, a mouse included (raft-flutter's pointer drag
/// area); the rest of the sheet takes the scroll configuration's drag devices.
class _SheetPointerDragArea extends StatelessWidget {
  const _SheetPointerDragArea({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final drag = _SheetDragScope.of(context);
    if (drag == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onVerticalDragUpdate: (d) => drag.update(d.delta.dy),
      onVerticalDragEnd: (d) => drag.end(d.velocity.pixelsPerSecond.dy),
      onVerticalDragCancel: () => drag.end(0),
      child: MouseRegion(cursor: SystemMouseCursors.grab, child: child),
    );
  }
}

/// The sheet: a [DraggableScrollableSheet] whose sizes are the detents (fractions of the room between the top safe
/// area and the keyboard), `rounded-t-2xl bg-components-panel-bg` from the sheet's top to the viewport's bottom edge
/// (behind the keyboard too), the grab handle over the content, and the content padded by the side insets and by the
/// bottom inset while the keyboard is closed.
class _DifySheet extends StatefulWidget {
  const _DifySheet({
    required this.detents,
    required this.initialDetent,
    required this.controller,
    required this.requestClose,
    required this.modalRoute,
    required this.shadow,
    required this.child,
    this.onDismiss,
    this.slideIn = false,
  });

  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;

  /// Asks the sheet's owner to close it (a drag to the bottom), the way Back and Escape do: a route's
  /// [Navigator.maybePop], a [DifySheetPortal]'s dismissal. Completes with whether the sheet is still open afterwards
  /// (a veto: it slides back to its detent). Null when the sheet cannot be dragged away.
  final Future<bool> Function()? requestClose;
  final bool modalRoute, shadow;
  final Widget child;

  /// A sheet without a route: what closing it does, after it slid away ([DifyPersistentSheet.onDismiss]).
  final VoidCallback? onDismiss;

  /// A page sheet: whether it rises into view ([DifyPersistentSheet.slideIn]).
  final bool slideIn;

  @override
  State<_DifySheet> createState() => _DifySheetState();
}

class _DifySheetState extends State<_DifySheet> with SingleTickerProviderStateMixin implements _SheetPointerDrag {
  final _sheet = DraggableScrollableController();

  /// The detent the sheet rests at or is settling on; kept across keyboard and size changes.
  late DifySheetDetent _resting = widget.initialDetent ?? widget.detents.first;
  bool _dragging = false, _asking = false;

  /// Whether the content lacks a scroll view on the sheet's controller (no body scroll view, or a platform where scroll
  /// views do not adopt the primary controller): an empty one then keeps the controller attached, which the handle's
  /// and the header's drags and [DifySheetController] need.
  bool _anchor = false;

  /// The geometry of the last layout: the viewport height, the room for the sheet (the [DraggableScrollableSheet]'s
  /// reference height), the bottom inset, the keyboard and the content's own height (null until measured: assumed to
  /// fill the room).
  double _viewport = 0, _room = 0, _bottom = 0, _keyboard = 0;
  double? _natural;
  List<double> _snaps = const [], _sheetSnaps = const [];
  double _min = 0, _max = 1;

  bool get _dismissible => widget.requestClose != null || widget.onDismiss != null;

  bool get _canClose => _dismissible && _keyboard == 0;

  /// A sheet without an owner's close request rising into view ([_DifySheet.slideIn]) or sliding away ([_dismiss]): it
  /// may sit below its lowest detent meanwhile, and the layout's re-snapping leaves it alone.
  bool _entering = false, _dismissing = false;

  double? get _offset => _sheet.isAttached ? _sheet.pixels + _keyboard : null;

  /// The scroll controller the sheet's [DraggableScrollableSheet] hands its content.
  ScrollController? _scroll;

  /// The sheet can be moved: its controller has exactly one scroll view (the content's, or the anchor). In the frame
  /// in which content gains a scroll view while the anchor is still there it has two, and after content dropped its
  /// scroll view (a list that turns back into a loading state) none: the anchor follows at once, and moves wait for it.
  bool get _ready {
    final scroll = _scroll;
    if (scroll != null && scroll.positions.length != 1) {
      _syncAnchor(scroll);
      return false;
    }
    return _sheet.isAttached;
  }

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    _sheet.addListener(_moved);
    _move.addListener(_moveTick);
    if (widget.slideIn && widget.requestClose == null) {
      _entering = true;
      SchedulerBinding.instance.addPostFrameCallback((_) => _enter());
    }
  }

  /// Rises from the bottom edge to the resting detent. Content without a scroll view of its own gets the controller's
  /// anchor a frame later: the rise waits for it (a few frames at most).
  Future<void> _enter([int wait = 3]) async {
    if (!mounted) return;
    if (!_ready && wait > 0) {
      SchedulerBinding.instance.addPostFrameCallback((_) => _enter(wait - 1));
      SchedulerBinding.instance.scheduleFrame();
      return;
    }
    if (_ready && _room > 0) {
      await _runTo(_fraction(_resting), duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    if (!mounted) return;
    setState(() => _entering = false);
    // Not attached in time: the layout puts it at its detent.
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (mounted && _ready && _sheet.size < 1e-3) _sheet.jumpTo(_fraction(_resting).clamp(_min, _max));
    });
  }

  /// Slides a routeless dismissible sheet to the bottom, then calls its `onDismiss`. When the owner keeps the sheet
  /// (it is still here a frame later), it slides back to where it rested.
  Future<void> _dismiss() async {
    final onDismiss = widget.onDismiss;
    if (widget.requestClose != null || onDismiss == null || _dismissing || !mounted) return;
    _dismissing = true;
    if (_keyboard > 0) FocusManager.instance.primaryFocus?.unfocus();
    if (_sheet.isAttached && _room > 0) {
      setState(() {});
      await SchedulerBinding.instance.endOfFrame;
      if (_ready) {
        await _runTo(0, duration: const Duration(milliseconds: 200), curve: Curves.easeIn);
      }
    }
    if (!mounted) return;
    onDismiss();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() => _dismissing = false);
      if (_sheet.isAttached) unawaited(_animateTo(_resting));
    });
  }

  @override
  void didUpdateWidget(_DifySheet old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (!widget.detents.contains(_resting)) _resting = widget.detents.first;
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _move.dispose();
    _sheet
      ..removeListener(_moved)
      ..dispose();
    super.dispose();
  }

  void _moved() => widget.controller?._moved();

  /// The sheet's own moves (to a detent, rising in, sliding away).
  late final _move = AnimationController(vsync: this);
  double _moveFrom = 0, _moveTo = 0;
  Curve _moveCurve = Curves.linear;

  /// Moves the sheet to [target] (a fraction of the room) with its own animation, a jump per frame. The framework's
  /// [DraggableScrollableController.animateTo] reads the controller's single scroll position on every tick, which
  /// throws in the frame a second scroll view attaches (content that turns from a loading state into a list while
  /// the sheet rises); here a frame with two scroll views is skipped and the move goes on.
  Future<void> _runTo(double target, {required Duration duration, required Curve curve}) async {
    if (!_sheet.isAttached) return;
    _move.stop();
    _moveFrom = _sheet.size;
    _moveTo = target;
    _moveCurve = curve;
    _move
      ..duration = duration
      ..value = 0;
    try {
      await _move.forward().orCancel;
    } on TickerCanceled {
      return; // another move took over
    }
    if (!mounted) return;
    // The last frame may have been skipped: land exactly, now or once one scroll view is attached.
    if (_ready) {
      _sheet.jumpTo(_moveTo.clamp(0.0, 1.0));
    } else {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (mounted && _ready && !_move.isAnimating && !_dragging) _sheet.jumpTo(_moveTo.clamp(0.0, 1.0));
      });
      SchedulerBinding.instance.scheduleFrame();
    }
  }

  void _moveTick() {
    if (!_ready) return;
    final t = _moveCurve.transform(_move.value);
    _sheet.jumpTo((_moveFrom + (_moveTo - _moveFrom) * t).clamp(0.0, 1.0));
  }

  /// [d] as a fraction of the room.
  double _fraction(DifySheetDetent d) {
    if (_room <= 0) return 0;
    final full = math.min(_room, (_natural ?? _room - _bottom) + _bottom);
    final pixels = switch (d._kind) {
      _DetentKind.peek => d.height! + _bottom,
      _DetentKind.half => _viewport / 2 + _bottom,
      _DetentKind.full => full,
    };
    return (math.min(pixels, full) / _room).clamp(0.0, 1.0);
  }

  List<(double, DifySheetDetent)> get _sorted =>
      [for (final d in widget.detents) (_fraction(d), d)]..sort((a, b) => a.$1.compareTo(b.$1));

  /// Updates the sizes for this layout; when they moved under a resting sheet (the keyboard opened, the content
  /// changed), the sheet follows its detent after the frame.
  void _resolve() {
    final sorted = _sorted;
    final lowest = sorted.first.$1, highest = sorted.last.$1;
    _min = _canClose || _entering || _dismissing ? 0 : lowest;
    _max = math.max(highest, _min);
    final snaps = <double>[];
    for (final (f, _) in sorted) {
      if (snaps.isEmpty || f > snaps.last + 1e-6) snaps.add(f);
    }
    // A new snap list makes the sheet snap again: it changes only when a size really changed.
    final sheetSnaps = [
      for (final f in snaps)
        if (f >= _min && f <= _max) f,
    ];
    if (!listEquals(sheetSnaps, _sheetSnaps)) _sheetSnaps = sheetSnaps;
    if (!listEquals(snaps, _snaps)) {
      _snaps = snaps;
      final target = _fraction(_resting);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _dragging || _entering || _dismissing || _move.isAnimating || !_ready) return;
        if ((_sheet.size - target).abs() > 1e-4) _sheet.jumpTo(target.clamp(_min, _max));
      });
    }
  }

  void _measured(double natural) {
    if (!mounted || (_natural != null && (natural - _natural!).abs() < 0.5)) return;
    setState(() => _natural = natural);
  }

  Future<void> _animateTo(
    DifySheetDetent detent, {
    Duration duration = DifySheetRecipe.settleDuration,
    Curve curve = Curves.easeOut,
  }) {
    _resting = detent;
    if (!_ready) {
      // The anchor comes or goes this frame: move after it.
      final done = Completer<void>();
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_ready || _resting != detent) return done.complete();
        done.complete(_runTo(_fraction(detent).clamp(_min, _max), duration: duration, curve: curve));
      });
      SchedulerBinding.instance.scheduleFrame();
      return done.future;
    }
    return _runTo(_fraction(detent).clamp(_min, _max), duration: duration, curve: curve);
  }

  @override
  void update(double dy) {
    if (!_ready || _room <= 0) return;
    if (_move.isAnimating) _move.stop();
    _dragging = true;
    if (dy > 0 && _keyboard > 0) FocusManager.instance.primaryFocus?.unfocus();
    // Held just above the bottom: reaching it is a request to close, asked once when the drag ends.
    final lower = _min == 0 ? 0.01 : _min;
    _sheet.jumpTo((_sheet.size - dy / _room).clamp(lower, _max));
  }

  @override
  void end(double velocityDy) {
    if (!_dragging) return;
    _dragging = false;
    if (!_ready) return;
    final size = _sheet.size;
    final sorted = _sorted;
    final lowest = sorted.first.$1;
    if (_canClose && size < lowest - 1e-3 && (velocityDy > DifySheetRecipe.flingVelocity || size < lowest / 2)) {
      _close();
      return;
    }
    DifySheetDetent target;
    if (velocityDy < -DifySheetRecipe.flingVelocity) {
      target = sorted.firstWhere((s) => s.$1 > size + 1e-3, orElse: () => sorted.last).$2;
    } else if (velocityDy > DifySheetRecipe.flingVelocity) {
      target = sorted.lastWhere((s) => s.$1 < size - 1e-3, orElse: () => sorted.first).$2;
    } else {
      target = sorted.reduce((a, b) => (a.$1 - size).abs() <= (b.$1 - size).abs() ? a : b).$2;
    }
    _animateTo(target);
  }

  /// A drag to the bottom asks the owner to close the sheet, the way Back and Escape do; a veto slides it back. A page
  /// sheet without such a request ([DifyPersistentSheet.onDismiss]) slides away and calls its `onDismiss`.
  void _close() {
    final request = widget.requestClose;
    if (request == null) {
      unawaited(_dismiss());
      return;
    }
    if (_asking) return;
    _asking = true;
    request().then((stillOpen) {
      _asking = false;
      if (mounted && stillOpen) _animateTo(_resting);
    });
  }

  bool _onExtent(DraggableScrollableNotification n) {
    // A move passing a detent does not rest there.
    if (_entering || _dismissing || _move.isAnimating) return false;
    // The scroll view's drag (or a settle) reached the bottom.
    if (_canClose && n.extent <= n.minExtent + 0.001 && !_dragging) _close();
    // Settled on a detent: it is where the sheet rests now.
    for (final (f, d) in _sorted) {
      if ((n.extent - f).abs() < 0.002) _resting = d;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    final top = widget.modalRoute ? _SheetTopInset.of(context) ?? padding.top : padding.top;
    return LayoutBuilder(
      builder: (context, box) {
        _viewport = box.maxHeight;
        _keyboard = keyboard;
        // `MediaQuery.padding` is the bottom inset at rest and 0 while the keyboard covers it.
        _bottom = padding.bottom;
        _room = math.max(0, _viewport - top - keyboard);
        _resolve();
        Widget sheet = NotificationListener<DraggableScrollableNotification>(
          onNotification: _onExtent,
          child: DraggableScrollableSheet(
            controller: _sheet,
            expand: !widget.modalRoute,
            initialChildSize: _entering ? 0 : _fraction(_resting).clamp(_min, _max),
            minChildSize: _min,
            maxChildSize: _max,
            snap: true,
            snapSizes: _sheetSnaps,
            // The framework would close at the bottom with a raw pop; this sheet asks ([_close]).
            shouldCloseOnMinExtent: false,
            builder: (context, scroll) => _content(context, scroll, padding),
          ),
        );
        if (widget.modalRoute) {
          // The route's sheet takes this widget's height: the detents above the keyboard, the surface behind it.
          return _surface(
            Padding(
              padding: EdgeInsets.only(bottom: keyboard),
              child: ConstrainedBox(
                constraints: BoxConstraints(maxHeight: _room),
                child: sheet,
              ),
            ),
          );
        }
        return Padding(
          padding: EdgeInsets.only(top: top, bottom: keyboard),
          child: sheet,
        );
      },
    );
  }

  Widget _surface(Widget child) {
    const radius = BorderRadius.vertical(top: Radius.circular(DifySheetRecipe.radius));
    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: DifyColors.componentsPanelBg,
          borderRadius: radius,
          boxShadow: widget.shadow ? DifySheetRecipe.shadow : null,
        ),
        child: ClipRRect(borderRadius: radius, child: child),
      ),
    );
  }

  /// After the frame: anchors the controller when the content attached no scroll view to it, and drops the anchor
  /// again once the content has its own (the controller must have exactly one).
  void _checkScrollable(ScrollController scroll) =>
      SchedulerBinding.instance.addPostFrameCallback((_) => _syncAnchor(scroll));

  void _syncAnchor(ScrollController scroll) {
    if (!mounted) return;
    if (SchedulerBinding.instance.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      return _checkScrollable(scroll);
    }
    final clients = scroll.positions.length;
    if (clients == 0 && !_anchor) setState(() => _anchor = true);
    if (clients > 1 && _anchor) setState(() => _anchor = false);
  }

  Widget _content(BuildContext context, ScrollController scroll, EdgeInsets padding) {
    _scroll = scroll;
    _checkScrollable(scroll);
    final media = MediaQuery.of(context);
    Widget content = DifySurface(
      child: DefaultTextStyle.merge(
        style: TextStyle(color: DifyColors.textPrimary, decoration: TextDecoration.none),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const DifySheetGrabHandle(),
            Flexible(child: widget.child),
          ],
        ),
      ),
    );
    // Always the same Stack around the content, the anchor only added or removed beside it: wrapping the content in a
    // Stack only while anchored would rebuild the content's subtree (and its State) each time the anchor flips, which
    // a content that loads (no scroll view, then a list) does over and over.
    content = Stack(
      fit: StackFit.passthrough,
      children: [
        content,
        if (_anchor)
          Positioned(
            left: 0,
            top: 0,
            width: 0,
            height: 0,
            child: SingleChildScrollView(
              controller: scroll,
              physics: const NeverScrollableScrollPhysics(),
              child: const SizedBox.shrink(),
            ),
          ),
      ],
    );
    // The content's body scroll view is the sheet's scrollable.
    // A scroll view the content gains or drops later (a loading state that turns into a list) does not rebuild this
    // builder: its first metrics re-check the anchor, so the controller never keeps two scroll views.
    content = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (n.metrics.axis == Axis.vertical) _syncAnchor(scroll);
        return false;
      },
      child: content,
    );
    content = PrimaryScrollController(controller: scroll, child: content);
    // The insets are the sheet's: nested SafeAreas and Scaffolds in the content must not add them again.
    content = MediaQuery(
      data: media
          .removePadding(removeLeft: true, removeTop: true, removeRight: true, removeBottom: true)
          .removeViewInsets(removeBottom: true),
      child: content,
    );
    content = _SheetDragScope(drag: this, child: content);
    content = _ContentHeight(maxHeight: math.max(0, _room - _bottom), onMeasured: _measured, child: content);
    content = Padding(padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, _bottom), child: content);
    content = GestureDetector(
      behavior: HitTestBehavior.opaque,
      supportedDevices: ScrollConfiguration.of(context).dragDevices,
      onVerticalDragUpdate: (d) => update(d.delta.dy),
      onVerticalDragEnd: (d) => end(d.velocity.pixelsPerSecond.dy),
      onVerticalDragCancel: () => end(0),
      child: content,
    );
    return widget.modalRoute ? content : _surface(content);
  }
}

/// Lays the content out at its own height (at most [maxHeight]) to measure it ([onMeasured]: the full detent of content
/// that does not fill the sheet), then, when it fills the sheet, at the sheet's height so a scroll view shows exactly
/// what is visible. It never lays the content out shorter than [_floor] (or its own height): a sheet being dragged
/// to the bottom does not squeeze its header.
class _ContentHeight extends SingleChildRenderObjectWidget {
  const _ContentHeight({required this.maxHeight, required this.onMeasured, required super.child});

  final double maxHeight;
  final ValueChanged<double> onMeasured;

  @override
  _RenderContentHeight createRenderObject(BuildContext context) =>
      _RenderContentHeight(maxHeight: maxHeight, onMeasured: onMeasured);

  @override
  void updateRenderObject(BuildContext context, _RenderContentHeight renderObject) => renderObject
    ..maxHeight = maxHeight
    ..onMeasured = onMeasured;
}

class _RenderContentHeight extends RenderProxyBox {
  _RenderContentHeight({required this._maxHeight, required this.onMeasured});

  static const _floor = 160.0;

  double get maxHeight => _maxHeight;
  double _maxHeight;
  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  ValueChanged<double> onMeasured;
  double? _reported;

  @override
  void performLayout() {
    final child = this.child;
    final width = constraints.maxWidth;
    final height = constraints.hasBoundedHeight ? constraints.maxHeight : _maxHeight;
    if (child == null) {
      size = constraints.constrain(Size(width, height));
      return;
    }
    child.layout(BoxConstraints(minWidth: width, maxWidth: width, maxHeight: _maxHeight), parentUsesSize: true);
    final natural = child.size.height;
    if (natural != _reported) {
      _reported = natural;
      SchedulerBinding.instance.addPostFrameCallback((_) => onMeasured(natural));
    }
    if (natural >= _maxHeight - 0.5) {
      // Not squeezed below half the room either: a sheet sliding away (or dragged low) keeps its header and its first
      // rows laid out, and is clipped rather than overflowing.
      final fill = math.max(height, math.min(natural, math.max(_floor, _maxHeight / 2)));
      if ((fill - natural).abs() > 0.01) {
        child.layout(BoxConstraints.tightFor(width: width, height: fill), parentUsesSize: true);
      }
    }
    size = constraints.constrain(Size(width, height));
  }
}

/// The sheets' grab handle (gen.py `.grab`): a 36x4 divider-regular bar centred in a 20 px row. It drags the sheet
/// with any pointer, a mouse included; the rest of the sheet drags too.
class DifySheetGrabHandle extends StatelessWidget {
  const DifySheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) => _SheetPointerDragArea(
    child: SizedBox(
      height: DifySheetRecipe.grabHeight,
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: DifyColors.dividerRegular,
            borderRadius: BorderRadius.circular(DifyRadius.xs),
          ),
          child: SizedBox.fromSize(size: DifySheetRecipe.grabSize),
        ),
      ),
    ),
  );
}

/// A sheet's header (mockups 4-6): `gap-2.5 pl-4 pr-2 pb-1`, [leading] (a node icon), a one-line [title] in
/// [DifyPhoneType.title] and an optional [subtitle] in system-xs-regular text-tertiary, the [actions]
/// ([DifyTouchIconButton]s) and a close button, in a row at least 48 px tall so the buttons' 48 px targets are whole.
/// Under it, an optional [tabs] row (`px-4`) over a divider-subtle line. The header drags the sheet with any pointer.
///
/// The close button shows when [onClose] is given, or inside [showDifyBottomSheet]'s content, where it pops the
/// route by default (through [Navigator.maybePop], so a non-dismissible sheet needs its own [onClose]), and inside a
/// [DifySheetPortal], where it dismisses the portal. Hide it with [showClose].
///
/// [titleWidget] replaces the title's text with another widget in the same place (an editable title: the node
/// settings sheet's); [title] still names the sheet.
class DifySheetHeader extends StatelessWidget {
  const DifySheetHeader({
    super.key,
    required this.title,
    this.titleWidget,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.onClose,
    this.showClose = true,
    this.closeLabel,
    this.tabs,
  });

  final String title;
  final Widget? titleWidget;
  final String? subtitle;
  final Widget? leading;
  final List<Widget> actions;
  final VoidCallback? onClose;
  final bool showClose;

  /// The close button's accessible name (common `operation.close` by default).
  final String? closeLabel;
  final Widget? tabs;

  @override
  Widget build(BuildContext context) {
    final scope = _ModalSheetScope.of(context);
    final close = !showClose
        ? null
        : onClose ?? (scope == null ? null : scope.close ?? () => Navigator.maybePop(context));
    final buttons = [
      ...actions,
      if (close != null)
        DifyTouchIconButton(
          label: closeLabel ?? DifyI18n.tr('common', 'operation.close'),
          icon: const RemixIcon('close-line', size: 22),
          onPressed: close,
        ),
    ];
    return _SheetPointerDragArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            // The row reaches 2 px past the last button: its 48 px target (44 px button) stays inside the row.
            padding: EdgeInsets.fromLTRB(16, 0, buttons.isEmpty ? 16 : 6, 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: DifyTouch.minTarget),
              // The buttons are the row's own children, so the 48 px row forwards their whole targets; explicit gaps
              // (not wrappers) keep it so.
              child: Row(
                children: [
                  if (leading case final l?) ...[l, const SizedBox(width: 10)],
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        titleWidget ??
                            Semantics(
                              header: true,
                              // Names the sheet's route scope: announced when the sheet opens.
                              namesRoute: true,
                              child: DifyText(title, DifyPhoneType.title, color: DifyColors.textPrimary),
                            ),
                        if (subtitle case final s?)
                          DifyText(s, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                      ],
                    ),
                  ),
                  for (final b in buttons) ...[const SizedBox(width: 10), b],
                  if (buttons.isNotEmpty) const SizedBox(width: 2),
                ],
              ),
            ),
          ),
          if (tabs case final t?)
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: DifyColors.dividerSubtle)),
              ),
              child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: t),
            ),
        ],
      ),
    );
  }
}

/// A modal bottom sheet a page shows from its own tree (dify-sf: the phone editor's node settings): the scrim and the
/// sheet are laid out in the root overlay over the whole window (the app bar included), while the content keeps the
/// page's inherited state (its stores and scopes, which a sheet route pushed on the navigator would lose), like
/// [DifyDrawerPortal] for drawers.
///
/// While [open], the sheet shows [builder]'s content (usually a [DifySheetHeader] over a scrolling body) at
/// [initialDetent] (the first of [detents]) and snaps between [detents]; it slides in and out. When [dismissible], a
/// tap on the scrim, a drag below the lowest detent, the header's close button, Escape and Android back (a
/// [DifyBackStep] on the page's route, newest layer first) call [onDismiss]; the owner closes it by setting [open] to
/// false (not doing so is a veto: the sheet slides back). While it closes, the last content stays.
///
/// Edge to edge like [showDifyBottomSheet]: it measures itself against the window's insets and keyboard
/// ([DifyWindowInsets]), so it paints to the bottom and side edges, keeps its content clear of the system bars, stops
/// at the top safe area, and rises with the keyboard (the keyboard's height replaces the bottom inset).
class DifySheetPortal extends StatefulWidget {
  const DifySheetPortal({
    super.key,
    required this.open,
    required this.onDismiss,
    required this.builder,
    this.child = const SizedBox.shrink(),
    this.detents = const [DifySheetDetent.half, DifySheetDetent.full],
    this.initialDetent,
    this.controller,
    this.dismissible = true,
    this.barrierLabel,
  });

  final bool open;
  final VoidCallback onDismiss;
  final WidgetBuilder builder;

  /// What the portal shows in the page's tree (nothing by default).
  final Widget child;
  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;
  final bool dismissible;
  final String? barrierLabel;

  @override
  State<DifySheetPortal> createState() => _DifySheetPortalState();
}

class _DifySheetPortalState extends State<DifySheetPortal> with SingleTickerProviderStateMixin {
  final _portal = OverlayPortalController();
  final _scope = FocusScopeNode(debugLabel: 'DifySheetPortal');
  late final _anim = AnimationController(vsync: this, duration: DifySheetRecipe.openDuration)
    ..addStatusListener((s) {
      if (s == AnimationStatus.dismissed && !widget.open && _portal.isShowing) {
        _portal.hide();
        _content = null;
        if (mounted) setState(() {});
      }
    });
  late final _curved = CurvedAnimation(parent: _anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
  late final _back = DifyBackStep(onDismiss: () => widget.onDismiss());

  /// The content the sheet shows: rebuilt while open, kept while it closes.
  Widget? _content;

  @override
  void initState() {
    super.initState();
    if (widget.open) _sync();
  }

  @override
  void didUpdateWidget(DifySheetPortal old) {
    super.didUpdateWidget(old);
    if (old.open != widget.open || old.dismissible != widget.dismissible) _sync();
  }

  @override
  void dispose() {
    _back.detach();
    _curved.dispose();
    _anim.dispose();
    _scope.dispose();
    super.dispose();
  }

  /// The overlay cannot be shown or hidden while building: after the frame.
  void _sync() {
    if (!widget.open) _back.detach();
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
      if (widget.open) {
        final opening = !_portal.isShowing || _anim.status == AnimationStatus.reverse;
        if (!_portal.isShowing) _portal.show();
        if (widget.dismissible) {
          _back.attach(context);
        } else {
          _back.detach();
        }
        reduce ? _anim.value = 1 : _anim.forward();
        // Modal: the focus moves into the sheet (Escape reaches it; a field of the page under it lets the keyboard go).
        if (opening) {
          SchedulerBinding.instance.addPostFrameCallback((_) {
            if (mounted && widget.open && !_scope.hasFocus) _scope.requestFocus();
          });
        }
        setState(() {});
      } else if (_portal.isShowing) {
        _back.detach();
        reduce ? _anim.value = 0 : _anim.reverse();
      }
    });
  }

  void _dismiss() {
    if (widget.open && widget.dismissible) widget.onDismiss();
  }

  @override
  Widget build(BuildContext context) {
    final modal = _portal.isShowing && widget.open;
    return DifyPortalSemantics(
      modal: modal,
      child: OverlayPortal(
        controller: _portal,
        overlayLocation: OverlayChildLocation.rootOverlay,
        overlayChildBuilder: _overlay,
        child: DifyPortalSemantics.place(modal: modal, child: widget.child),
      ),
    );
  }

  Widget _overlay(BuildContext context) {
    if (widget.open) _content = Builder(builder: widget.builder);
    return Shortcuts(
      shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
      child: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              _dismiss();
              return null;
            },
          ),
        },
        child: FocusScope(
          node: _scope,
          child: DifyPortalSheetFrame(
            animation: _curved,
            detents: widget.detents,
            initialDetent: widget.initialDetent,
            controller: widget.controller,
            onDismiss: widget.dismissible ? _dismiss : null,
            isOpen: () => mounted && widget.open,
            barrierLabel: widget.barrierLabel,
            child: IgnorePointer(ignoring: !widget.open, child: _content ?? const SizedBox.shrink()),
          ),
        ),
      ),
    );
  }
}

/// How a modal layer shown through an [OverlayPortal] from a page's tree ([DifySheetPortal], a [DifyFloating] picker
/// sheet, [DifyPortalPage]) is modal for accessibility, as a route is: put it around the [OverlayPortal]. While
/// [modal], only the topmost layer is in the semantics tree the platform gets: every layer below it (the page, a
/// lower sheet, its other popups) is hidden, and the topmost is never missing.
///
/// On Android and iOS an overlay child's semantics are sent under its [OverlayPortal]'s place (the portal's child),
/// and are dropped when that place is not in the tree. So the layer below is not blocked from the layer above: the
/// nearest [DifyModalLayer] around the portal (the lower sheet's, the page's) drops its whole content from the tree
/// and becomes that place itself, the layer above hanging from it. Without a [DifyModalLayer] around it (a page that is
/// not a [DifyPage]) the page painted before the portal is blocked ([BlockSemantics]) from a place of its own.
class DifyPortalSemantics extends StatefulWidget {
  const DifyPortalSemantics({super.key, required this.modal, required this.child});

  final bool modal;

  /// The [OverlayPortal] (or a widget whose first [OverlayPortal] descendant is the layer's).
  final Widget child;

  /// The [OverlayPortal]'s child, [child], at least 1 x 1 while [modal]: without a [DifyModalLayer] the layer's
  /// semantics hang from that place, and an empty place (a zero-size placeholder) would be dropped as invisible.
  static Widget place({required bool modal, required Widget child}) => ConstrainedBox(
    constraints: modal ? const BoxConstraints(minWidth: 1, minHeight: 1) : const BoxConstraints(),
    child: child,
  );

  @override
  State<DifyPortalSemantics> createState() => _DifyPortalSemanticsState();
}

class _DifyPortalSemanticsState extends State<DifyPortalSemantics> {
  _DifyModalLayerState? _layer;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final layer = _ModalLayerScope.of(context);
    if (layer != _layer) {
      _layer?._uncover(this);
      _layer = layer;
    }
    _sync();
  }

  @override
  void didUpdateWidget(DifyPortalSemantics old) {
    super.didUpdateWidget(old);
    _sync();
    // The layer below reads the portal's identity when it builds its semantics: a rebuilt portal may be another one.
    if (widget.modal) _layer?._render?.markNeedsSemanticsUpdate();
  }

  @override
  void dispose() {
    _layer?._uncover(this);
    super.dispose();
  }

  void _sync() => widget.modal ? _layer?._cover(this) : _layer?._uncover(this);

  /// The identity the [OverlayPortal] hangs its overlay child's semantics from (its State: `OverlayPortal`'s
  /// `Semantics(traversalParentIdentifier: this)`).
  Object? get _portalIdentity {
    Object? found;
    void visit(Element e) {
      if (found != null) return;
      if (e.widget is OverlayPortal && e is StatefulElement) {
        found = e.state;
        return;
      }
      e.visitChildren(visit);
    }

    if (mounted) (context as Element).visitChildren(visit);
    return found;
  }

  @override
  Widget build(BuildContext context) {
    // Without a modal layer around it the portal blocks the page painted before it, from a place of its own.
    final alone = widget.modal && _layer == null;
    return BlockSemantics(
      blocking: alone,
      child: Semantics(container: alone, child: widget.child),
    );
  }
}

/// A layer that modal layers can open over ([DifyPortalSemantics]): a page ([DifyPage]), a sheet shown from a page's
/// tree ([DifyPortalSheetFrame]), a [DifyPortalPage]. While a modal layer opened from inside it is open, its whole
/// content is dropped from the semantics tree, and it is the place that layer's semantics hang from, so only the
/// topmost layer is read (and it is never dropped with what it covers).
class DifyModalLayer extends StatefulWidget {
  const DifyModalLayer({super.key, required this.child});

  final Widget child;

  @override
  State<DifyModalLayer> createState() => _DifyModalLayerState();
}

class _DifyModalLayerState extends State<DifyModalLayer> {
  /// The modal layers open over this one, the last opened on top.
  final _covers = <_DifyPortalSemanticsState>[];
  _RenderModalLayer? _render;

  void _cover(_DifyPortalSemanticsState portal) {
    if (_covers.contains(portal)) return;
    _covers.add(portal);
    _render?.markNeedsSemanticsUpdate();
  }

  void _uncover(_DifyPortalSemanticsState portal) {
    if (!_covers.remove(portal)) return;
    _render?.markNeedsSemanticsUpdate();
  }

  /// The identity of the topmost layer open over this one.
  Object? get _coveredBy => _covers.isEmpty ? null : _covers.last._portalIdentity;

  @override
  Widget build(BuildContext context) => _ModalLayerScope(
    layer: this,
    child: _ModalLayerBox(layer: this, child: widget.child),
  );
}

class _ModalLayerScope extends InheritedWidget {
  const _ModalLayerScope({required this.layer, required super.child});
  final _DifyModalLayerState layer;

  static _DifyModalLayerState? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ModalLayerScope>()?.layer;

  @override
  bool updateShouldNotify(_ModalLayerScope old) => layer != old.layer;
}

class _ModalLayerBox extends SingleChildRenderObjectWidget {
  const _ModalLayerBox({required this.layer, super.child});
  final _DifyModalLayerState layer;

  @override
  _RenderModalLayer createRenderObject(BuildContext context) => _RenderModalLayer(layer).._attachTo(layer);

  @override
  void updateRenderObject(BuildContext context, _RenderModalLayer renderObject) => renderObject._attachTo(layer);

  @override
  void didUnmountRenderObject(_RenderModalLayer renderObject) {
    if (layer._render == renderObject) layer._render = null;
  }
}

/// While covered: no semantics of its content, a node of its own from which the covering layer's semantics hang.
class _RenderModalLayer extends RenderProxyBox {
  _RenderModalLayer(this._layer);
  _DifyModalLayerState _layer;

  void _attachTo(_DifyModalLayerState layer) {
    if (_layer != layer) {
      _layer = layer;
      markNeedsSemanticsUpdate();
    }
    layer._render = this;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) {
    if (_layer._coveredBy == null) super.visitChildrenForSemantics(visitor);
  }

  @override
  void describeSemanticsConfiguration(SemanticsConfiguration config) {
    super.describeSemanticsConfiguration(config);
    if (_layer._coveredBy case final covering?) {
      config
        ..isSemanticBoundary = true
        ..traversalParentIdentifier = covering;
    }
  }
}

/// The scrim and the sheet of a modal sheet shown in the root overlay from a page's tree ([DifySheetPortal]; a
/// [DifyFloating] picker in a compact window): the window-wide scrim fades and the sheet slides with [animation]
/// (0 closed, 1 open). The sheet is the same as [showDifyBottomSheet]'s ([detents], the grab handle, the header's
/// default close), measured against the window's insets and keyboard ([DifyWindowInsets]) since the overlay child
/// inherits the page's consumed ones. [onDismiss] (null: not dismissible) is called by a scrim tap, a drag below the
/// lowest detent and the header's close; [isOpen] tells, a frame later, whether the owner vetoed it.
class DifyPortalSheetFrame extends StatelessWidget {
  const DifyPortalSheetFrame({
    super.key,
    required this.animation,
    required this.child,
    required this.isOpen,
    this.onDismiss,
    this.detents = const [DifySheetDetent.full],
    this.initialDetent,
    this.controller,
    this.barrierLabel,
    this.takeFocus = true,
  });

  final Animation<double> animation;
  final Widget child;
  final bool Function() isOpen;
  final VoidCallback? onDismiss;
  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;
  final String? barrierLabel;

  /// The sheet takes the focus when it opens over a focused field: the keyboard goes down and keys no longer reach
  /// the field behind it; when the sheet closes with the focus still in it, the field gets it back (its caret where
  /// it was). False for a sheet that follows what is typed in the field (the prompt editor's typed `{` / `/`).
  final bool takeFocus;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final dismiss = onDismiss;
    return MediaQuery(
      data: media.copyWith(padding: DifyWindowInsets.of(context), viewInsets: DifyWindowInsets.viewInsetsOf(context)),
      child: _ModalSheetScope(
        close: dismiss ?? () {},
        // Layers opened from the sheet (a picker, a page, another sheet) hide it, scrim included.
        child: DifyModalLayer(
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The scrim takes every pointer (a tap dismisses); for accessibility it is the dismiss button a route's
              // barrier is. It does not hide the page itself ([DifyPortalSemantics] does, from the page).
              FadeTransition(
                opacity: animation,
                child: _PortalScrim(
                  key: const ValueKey('dify-sheet-scrim'),
                  onDismiss: dismiss,
                  label: barrierLabel ?? DifyI18n.tr('common', 'operation.close'),
                ),
              ),
              Align(
                alignment: Alignment.bottomCenter,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 1), end: Offset.zero).animate(animation),
                  // A node of its own (a semantics boundary): nothing in the sheet can block past it.
                  child: Semantics(
                    container: true,
                    sortKey: const OrdinalSortKey(0),
                    scopesRoute: true,
                    explicitChildNodes: true,
                    child: _SheetFocus(
                      take: takeFocus,
                      child: _DifySheet(
                        detents: detents,
                        initialDetent: initialDetent,
                        controller: controller,
                        requestClose: dismiss == null
                            ? null
                            : () async {
                                dismiss();
                                await SchedulerBinding.instance.endOfFrame;
                                return isOpen();
                              },
                        modalRoute: true,
                        shadow: false,
                        child: DifySelectionRegion(child: child),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The focus of a sheet shown from a page's tree ([DifyPortalSheetFrame.takeFocus]): when it opens, the focus moves
/// into the sheet unless it is there already (a portal's own scope around it), so a field behind it gives up the
/// keyboard; the node that had the focus is remembered and, when the sheet goes with the focus still in it, gets it
/// back after the frame (a text field keeps its selection, so an insert lands at its caret).
///
/// A screen reader's focus comes back too, as a route's does ([Navigator]): the node it was on when the sheet opened
/// (the control that opened it) gets it again when the sheet goes, not the page's route name.
class _SheetFocus extends StatefulWidget {
  const _SheetFocus({required this.take, required this.child});

  final bool take;
  final Widget child;

  @override
  State<_SheetFocus> createState() => _SheetFocusState();
}

class _SheetFocusState extends State<_SheetFocus> {
  final _scope = FocusScopeNode(debugLabel: 'DifyPortalSheetFrame');
  FocusNode? _previous;

  /// The semantics node a screen reader had its focus on when the sheet opened (the trigger), if any.
  int? _accessibilityFocus;

  /// As [Navigator] waits before it moves a screen reader's focus back on Android: the system's own refocus first.
  static const _androidRefocusDelay = Duration(milliseconds: 300);

  /// Gives the screen reader's focus back to [_accessibilityFocus] once the sheet's nodes are gone.
  void _restoreAccessibilityFocus() {
    final node = _accessibilityFocus;
    if (node == null) return;
    final delay = switch (defaultTargetPlatform) {
      TargetPlatform.android => _androidRefocusDelay,
      TargetPlatform.iOS => Duration.zero,
      _ => null,
    };
    if (delay == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(delay);
      await SystemChannels.accessibility.send(const FocusSemanticEvent().toMap(nodeId: node));
    });
  }

  @override
  void initState() {
    super.initState();
    _accessibilityFocus = ServicesBinding.instance.accessibilityFocus.value;
    if (!widget.take) return;
    _previous = FocusManager.instance.primaryFocus;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final now = FocusManager.instance.primaryFocus;
      if (now != null && (now == _scope || now.ancestors.contains(_scope))) return;
      _scope.requestFocus();
    });
  }

  @override
  void deactivate() {
    _restoreAccessibilityFocus();
    // Before the sheet's nodes are taken out: is the focus still in it?
    final previous = _previous;
    if (widget.take && previous != null && _scope.hasFocus) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (previous.context != null && previous.canRequestFocus) previous.requestFocus();
      });
    }
    super.deactivate();
  }

  @override
  void dispose() {
    _scope.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(node: _scope, child: widget.child);
}

/// The scrim of a sheet shown from a page's tree: window-wide, taking every pointer; a tap calls [onDismiss] (none:
/// the taps are only absorbed). For accessibility a dismiss button named [label], as a route's barrier.
class _PortalScrim extends StatelessWidget {
  const _PortalScrim({super.key, required this.onDismiss, required this.label});

  final VoidCallback? onDismiss;
  final String label;

  @override
  Widget build(BuildContext context) {
    final scrim = GestureDetector(
      behavior: HitTestBehavior.opaque,
      excludeFromSemantics: true,
      onTap: onDismiss,
      child: ColoredBox(color: DifySheetRecipe.scrim, child: const SizedBox.expand()),
    );
    final dismiss = onDismiss;
    if (dismiss == null) return ExcludeSemantics(child: scrim);
    // Last in the reading order, as a route's barrier (OrdinalSortKey 1): TalkBack starts at the sheet's title.
    return Semantics(
      container: true,
      button: true,
      label: label,
      onTap: dismiss,
      onDismiss: dismiss,
      sortKey: const OrdinalSortKey(1),
      child: scrim,
    );
  }
}
