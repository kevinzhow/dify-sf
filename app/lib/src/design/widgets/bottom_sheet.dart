/// dify-sf's phone bottom sheets, built on smooth_sheets (a dify-sf divergence: Dify's console uses centred dialogs
/// and side panels). Feature code uses these widgets; it never imports smooth_sheets itself.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart' show kMinFlingVelocity;
import 'package:flutter/material.dart' show MaterialLocalizations;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:smooth_sheets/smooth_sheets.dart';

import '../dify_icon.dart';
import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import '../../i18n/dify_i18n.dart';
import 'page.dart' show DifySurface;
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
}

enum _DetentKind { peek, half, full }

/// A height a bottom sheet rests at. The sheet snaps to the nearest of its detents when released, or to the next one
/// in the direction of a fling. Heights are measured from the top of the keyboard when it is open (so the sheet grows
/// by the keyboard's height and what was visible stays visible) and above the bottom system inset otherwise; none
/// exceeds [full].
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

  SheetOffset get _offset => _DetentOffset(this);

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

/// A [DifySheetDetent] as smooth_sheets' offset: the visible height above the viewport's bottom. The content
/// baseline is the keyboard (or the bottom inset) the content is padded by.
@immutable
class _DetentOffset implements SheetOffset {
  const _DetentOffset(this.detent);
  final DifySheetDetent detent;

  @override
  double resolve(ViewportLayout layout) {
    final base = layout.contentBaseline;
    final full = layout.contentSize.height + base;
    return switch (detent._kind) {
      _DetentKind.peek => math.min(full, base + detent.height!),
      _DetentKind.half => math.min(full, base + layout.viewportSize.height / 2),
      _DetentKind.full => full,
    };
  }

  @override
  bool operator ==(Object other) => other is _DetentOffset && other.detent == detent;

  @override
  int get hashCode => detent.hashCode;
}

/// Snaps between [detents] in their resolved order (smooth_sheets' own grid expects them pre-sorted, which a peek
/// height cannot be against half the window): released slowly, to the nearest; flung, to the nearest one's
/// neighbour in the fling's direction.
@immutable
class _DetentSnapGrid implements SheetSnapGrid {
  const _DetentSnapGrid(this.detents);
  final List<DifySheetDetent> detents;

  List<(double, SheetOffset)> _sorted(ViewportLayout layout) =>
      [for (final d in detents) (d._offset.resolve(layout), d._offset)]..sort((a, b) => a.$1.compareTo(b.$1));

  @override
  (SheetOffset, SheetOffset) getBoundaries(ViewportLayout layout) {
    final s = _sorted(layout);
    return (s.first.$2, s.last.$2);
  }

  @override
  SheetOffset getSnapOffset(ViewportLayout layout, double offset, double velocity) {
    final s = _sorted(layout);
    if (offset <= s.first.$1) return s.first.$2;
    if (offset >= s.last.$1) return s.last.$2;
    var nearest = 0;
    for (var i = 1; i < s.length; i++) {
      if ((s[i].$1 - offset).abs() < (s[nearest].$1 - offset).abs()) nearest = i;
    }
    if (velocity.abs() < kMinFlingVelocity) return s[nearest].$2;
    return s[(nearest + (velocity < 0 ? -1 : 1)).clamp(0, s.length - 1)].$2;
  }
}

/// A modal sheet is dismissed when released below 70 % of its lowest detent (dragged down by 30 % of what it
/// showed), or flung down.
@immutable
class _DismissalOffset implements SheetOffset {
  const _DismissalOffset(this.detents);
  final List<DifySheetDetent> detents;

  @override
  double resolve(ViewportLayout layout) => 0.7 * detents.map((d) => d._offset.resolve(layout)).reduce(math.min);

  @override
  bool operator ==(Object other) => other is _DismissalOffset && listEquals(other.detents, detents);

  @override
  int get hashCode => Object.hashAll(detents);
}

/// Moves a sheet between its detents and reports its position. Give it to [showDifyBottomSheet] or
/// [DifyPersistentSheet]; dispose it with its owner.
class DifySheetController extends ChangeNotifier {
  DifySheetController() {
    _sheet.addListener(notifyListeners);
  }

  final _sheet = SheetController();

  /// Whether a sheet is attached.
  bool get isAttached => _sheet.hasClient;

  /// The sheet's visible height above the bottom of its viewport (null before it is laid out).
  double? get offset => _sheet.value;

  /// Animates the attached sheet to [detent]; completes at once when none is attached.
  Future<void> animateTo(
    DifySheetDetent detent, {
    Duration duration = const Duration(milliseconds: 300),
    Curve curve = Curves.easeInOut,
  }) => _sheet.hasClient ? _sheet.animateTo(detent._offset, duration: duration, curve: curve) : Future.value();

  @override
  void dispose() {
    _sheet
      ..removeListener(notifyListeners)
      ..dispose();
    super.dispose();
  }
}

/// Marks the content of a modal sheet route, so [DifySheetHeader]'s close button can pop it by default.
class _ModalSheetScope extends InheritedWidget {
  const _ModalSheetScope({required super.child});

  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<_ModalSheetScope>() != null;

  @override
  bool updateShouldNotify(_ModalSheetScope oldWidget) => false;
}

/// Pushes a bottom sheet route showing [builder]'s content (usually a [DifySheetHeader] over a body; a scrolling body
/// fills the sheet) and resolves with what it pops.
///
/// The sheet starts at [initialDetent] (the first of [detents] by default) and snaps between [detents]. When
/// [modal], a scrim (`DifySheetRecipe.scrim`) covers the window and blocks the page; otherwise the page stays
/// interactive around the sheet. When [dismissible], dragging it below its lowest detent, a tap on the scrim, the
/// system back button and Escape close it; otherwise only the content can close it (`Navigator.pop`).
///
/// The sheet paints to the window's bottom and side edges and keeps its content clear of the system insets and the
/// keyboard: the keyboard's height replaces the bottom inset (never added to it) and the sheet grows with it, so a
/// focused field stays visible (its scroll view brings it into view). Dragging the sheet down hides the keyboard.
/// A scroll view in the body drags the sheet once scrolled to its top (on Android and iOS; elsewhere give it
/// `primary: true`).
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
}) {
  assert(detents.isNotEmpty, 'A sheet needs at least one detent');
  assert(initialDetent == null || detents.contains(initialDetent), 'initialDetent must be one of detents');
  final route = _DifySheetRoute<T>(
    modal: modal,
    barrierDismissible: dismissible,
    swipeDismissible: dismissible,
    barrierColor: DifySheetRecipe.scrim,
    barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
    swipeDismissSensitivity: SwipeDismissSensitivity(dismissalOffset: _DismissalOffset(detents)),
    viewportBuilder: (context, child) => SheetViewport(
      padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
      child: child,
    ),
    builder: (context) {
      Widget sheet = _ModalSheetScope(
        child: _DifySheet(
          detents: detents,
          initialDetent: initialDetent,
          controller: controller,
          shadow: !modal,
          child: DifySelectionRegion(child: Builder(builder: builder)),
        ),
      );
      if (!dismissible) sheet = SheetPopScope<T>(canPop: false, child: sheet);
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
  return Navigator.of(context, rootNavigator: useRootNavigator).push(route);
}

/// smooth_sheets' modal sheet route; when not [modal], the barrier lets pointers through to the page.
class _DifySheetRoute<T> extends ModalSheetRoute<T> {
  _DifySheetRoute({
    required this.modal,
    required super.builder,
    super.viewportBuilder,
    super.barrierDismissible,
    super.swipeDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.swipeDismissSensitivity,
  });

  final bool modal;

  @override
  Widget buildModalBarrier() => modal ? super.buildModalBarrier() : const IgnorePointer(child: SizedBox.expand());
}

/// A sheet that lives in a page instead of a route (mockup 7's run panel): the page behind stays interactive. Put
/// it last in a Stack that fills the page; it fills the Stack and only its sheet takes pointers. It rests at
/// [initialDetent] (the first of [detents]) and snaps between [detents]; it cannot be dragged away. A route holds at
/// most one such sheet.
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
  });

  final Widget child;
  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;

  @override
  Widget build(BuildContext context) => SheetViewport(
    padding: EdgeInsets.only(top: MediaQuery.paddingOf(context).top),
    child: _DifySheet(
      detents: detents,
      initialDetent: initialDetent,
      controller: controller,
      shadow: true,
      child: child,
    ),
  );
}

/// The sheet itself: smooth_sheets' [Sheet] with the detents, `rounded-t-2xl bg-components-panel-bg` stretched to the
/// viewport's bottom edge, the grab handle over [child], and the content padded by the side insets and by the
/// keyboard or the bottom inset.
class _DifySheet extends StatelessWidget {
  const _DifySheet({
    required this.detents,
    required this.initialDetent,
    required this.controller,
    required this.shadow,
    required this.child,
  });

  final List<DifySheetDetent> detents;
  final DifySheetDetent? initialDetent;
  final DifySheetController? controller;
  final bool shadow;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final padding = MediaQuery.paddingOf(context);
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    const radius = BorderRadius.vertical(top: Radius.circular(DifySheetRecipe.radius));
    return SheetKeyboardDismissible(
      dismissBehavior: const SheetKeyboardDismissBehavior.onDragDown(),
      child: Sheet(
        controller: controller?._sheet,
        initialOffset: (initialDetent ?? detents.first)._offset,
        snapGrid: _DetentSnapGrid(detents),
        scrollConfiguration: const SheetScrollConfiguration(),
        decoration: SheetDecorationBuilder(
          size: SheetSize.stretch,
          builder: (context, child) => DecoratedBox(
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: radius,
              boxShadow: shadow ? DifySheetRecipe.shadow : null,
            ),
            child: ClipRRect(borderRadius: radius, child: child),
          ),
        ),
        // The content's margin, not a Padding: detents stay measured from the keyboard's top (smooth_sheets'
        // Sheet.padding), and the content's MediaQuery no longer carries these insets.
        padding: EdgeInsets.fromLTRB(padding.left, 0, padding.right, math.max(keyboard, padding.bottom)),
        child: DifySurface(
          child: DefaultTextStyle.merge(
            style: TextStyle(color: DifyColors.textPrimary, decoration: TextDecoration.none),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const DifySheetGrabHandle(),
                Flexible(child: child),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The sheets' grab handle (gen.py `.grab`): a 36x4 divider-regular bar centred in a 20 px row. The whole sheet is
/// draggable; the handle only shows it.
class DifySheetGrabHandle extends StatelessWidget {
  const DifySheetGrabHandle({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
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
  );
}

/// A sheet's header (mockups 4-6): `gap-2.5 pl-4 pr-2 pt-0.5 pb-1.5`, [leading] (a node icon), a one-line [title] in
/// [DifyPhoneType.title] and an optional [subtitle] in system-xs-regular text-tertiary, the [actions]
/// ([DifyTouchIconButton]s) and a close button. Under it, an optional [tabs] row (`px-4`) over a divider-subtle line.
///
/// The close button shows when [onClose] is given, or inside [showDifyBottomSheet]'s content, where it pops the
/// route by default (through [Navigator.maybePop], so a non-dismissible sheet needs its own [onClose]). Hide it with
/// [showClose].
class DifySheetHeader extends StatelessWidget {
  const DifySheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.onClose,
    this.showClose = true,
    this.closeLabel,
    this.tabs,
  });

  final String title;
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
    final close = !showClose
        ? null
        : onClose ?? (_ModalSheetScope.of(context) ? () => Navigator.maybePop(context) : null);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, 2, close == null && actions.isEmpty ? 16 : 8, 6),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(
              spacing: 10,
              children: [
                ?leading,
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Semantics(
                        header: true,
                        child: DifyText(title, DifyPhoneType.title, color: DifyColors.textPrimary),
                      ),
                      if (subtitle case final s?) DifyText(s, DifyType.systemXsRegular, color: DifyColors.textTertiary),
                    ],
                  ),
                ),
                ...actions,
                if (close != null)
                  DifyTouchIconButton(
                    label: closeLabel ?? DifyI18n.tr('common', 'operation.close'),
                    icon: const RemixIcon('close-line', size: 22),
                    onPressed: close,
                  ),
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
    );
  }
}
