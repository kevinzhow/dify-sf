/// dify-ui's Drawer (packages/dify-ui/src/drawer/index.tsx): [showDifyDrawer] (Root + Portal + Backdrop + Viewport),
/// [DifyDrawerBackdrop], [DifyDrawerPopup], [DifyDrawerCloseButton].
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// The `bg-black/25` backdrop FeaturePanelDrawer gives DrawerBackdrop
/// (web/app/components/base/features/new-feature-panel/feature-panel-drawer.tsx).
const difyDrawerBlackBackdrop = Color.fromRGBO(0, 0, 0, 0.25);

/// dify-ui's DrawerPortal: retain the caller's inherited state while laying out
/// the drawer and backdrop in the root overlay, against the window's safe area ([DifyOverlaySafeArea]).
class DifyDrawerPortal extends StatefulWidget {
  const DifyDrawerPortal({super.key, required this.open, required this.child});

  final bool open;
  final Widget child;

  @override
  State<DifyDrawerPortal> createState() => _DifyDrawerPortalState();
}

class _DifyDrawerPortalState extends State<DifyDrawerPortal> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(DifyDrawerPortal oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() => WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!mounted) return;
    if (widget.open && !_portal.isShowing) _portal.show();
    if (!widget.open && _portal.isShowing) _portal.hide();
  });

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayLocation: OverlayChildLocation.rootOverlay,
    // The root overlay fills the window; the drawer keeps today's geometry inside the safe area.
    overlayChildBuilder: (_) => DifyOverlaySafeArea(child: widget.child),
    child: const SizedBox.shrink(),
  );
}

/// Shows a drawer sliding in from the right (`swipeDirection="right"`, `transition-transform duration-200`): [builder]
/// (usually a [DifyDrawerPopup]) gets the close callback and is placed against the right edge inside [insets]
/// (`top-16 right-2 bottom-3`, …), at most [maxWidth] wide (`w-120`) and fills its available height.
/// [viewportGutter] is the space excluded from the viewport width by `max-w-[calc(100vw-2rem)]`;
/// inset callers can explicitly override it to match their source recipe. [backdrop]: DrawerBackdrop's
/// `bg-background-overlay` (false: none, as the logs open it on desktop). Escape closes it, and so does a click outside
/// unless [dismissible] is false (`disablePointerDismissal`). Resolves with what it pops.
///
/// In a compact window (a phone; a dify-sf divergence, raft-flutter's `RaftPresentationPolicy.detail`) the drawer is a
/// page unless [pageOnCompact] is false: it fills the window edge to edge, [insets] and [maxWidth] do not apply, and the
/// [DifyDrawerPopup] inside drops its rounded border and keeps its content in the safe area ([DifyDrawerPage]). Its
/// controls are touch-sized ([DifyTouchSurface]) there and on a touch tablet (the inset drawer of the touch desktop). The form follows the live width, so a rotation switches it with the
/// content's state kept. Back closes it, as before.
Future<T?> showDifyDrawer<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
  EdgeInsets insets = EdgeInsets.zero,
  double maxWidth = DifyDrawerRecipe.width,
  double viewportGutter = DifyDrawerRecipe.viewportGutter,
  bool backdrop = true,
  bool dismissible = true,
  String? barrierLabel,
  Duration duration = const Duration(milliseconds: 200),
  Curve curve = Curves.easeOutCubic,
  bool pageOnCompact = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: backdrop ? DifyColors.backgroundOverlay : const Color(0x00000000),
  transitionDuration: duration,
  transitionBuilder: (context, animation, _, child) => SlideTransition(
    position: Tween(
      begin: const Offset(1, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: animation, curve: curve)),
    child: child,
  ),
  // One tree for both forms (the page form only flips its parameters), so a rotation keeps the content's state.
  pageBuilder: (dialogContext, _, _) {
    final page = pageOnCompact && DifyWindowClass.of(dialogContext) == DifyWindowClass.compact;
    return SafeArea(
      left: !page,
      top: !page,
      right: !page,
      bottom: !page,
      child: Padding(
        padding:
            (page ? EdgeInsets.zero : insets) + EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(dialogContext).bottom),
        child: LayoutBuilder(
          builder: (context, constraints) => Align(
            alignment: Alignment.centerRight,
            child: SizedBox(
              width: page
                  ? constraints.maxWidth
                  : math.max(
                      0,
                      math.min(
                        maxWidth,
                        math.min(constraints.maxWidth, MediaQuery.sizeOf(context).width - viewportGutter),
                      ),
                    ),
              height: constraints.maxHeight,
              child: DifyDrawerPage(
                page: page,
                child: DifyTouchSurface(
                  enabled: page || DifyTouch.compactOf(dialogContext),
                  child: DifySelectionRegion(
                    child: builder(dialogContext, () => Navigator.of(dialogContext).maybePop()),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  },
);

/// Marks a drawer shown as a page (a compact window, see [showDifyDrawer]): the [DifyDrawerPopup] under it fills the
/// window without its rounded border and shadow, its colour reaching under the system bars and its content inside
/// the safe area. Drawers a screen shows in its own tree put it around their popup the same way.
///
/// [page] false marks nothing: a drawer that switches between its forms in place keeps this widget in its tree (and
/// so its content's state) and flips [page].
class DifyDrawerPage extends InheritedWidget {
  const DifyDrawerPage({super.key, this.page = true, required super.child});

  final bool page;

  /// Whether [context] is inside a drawer shown as a page.
  static bool of(BuildContext context) => context.dependOnInheritedWidgetOfExactType<DifyDrawerPage>()?.page ?? false;

  @override
  bool updateShouldNotify(DifyDrawerPage oldWidget) => oldWidget.page != page;
}

/// DrawerBackdrop for drawers shown in the tree (not as a route): [color] (`bg-background-overlay` by default) faded by
/// [opacity] (the open animation and the swipe progress); a click on it calls [onTap].
class DifyDrawerBackdrop extends StatelessWidget {
  const DifyDrawerBackdrop({super.key, this.color, this.opacity = 1, this.onTap});

  final Color? color;
  final double opacity;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = color ?? DifyColors.backgroundOverlay;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ColoredBox(color: c.withValues(alpha: c.a * opacity.clamp(0.0, 1.0))),
    );
  }
}

/// DrawerPopup: `overflow-hidden border-[0.5px] border-components-panel-border bg-components-panel-bg shadow-xl`, from
/// the right `rounded-l-2xl border-r-0`. The screens restyle it by className; [color], [border], [borderRadius] and [boxShadow]
/// stand for that. A dialog for assistive technology, named [label]; [scopesRoute] when it is a route's whole
/// content. [material]: a transparent Material around it (for Material descendants such as text fields).
class DifyDrawerPopup extends StatelessWidget {
  const DifyDrawerPopup({
    super.key,
    required this.child,
    this.label,
    this.color,
    this.border,
    this.borderRadius = const BorderRadius.horizontal(left: Radius.circular(DifyRadius.xxl)),
    this.boxShadow,
    this.width,
    this.scopesRoute = false,
    this.material = false,
  });

  final Widget child;
  final String? label;

  /// `bg-components-panel-bg` by default.
  final Color? color;

  /// `border-[0.5px] border-components-panel-border border-r-0` by default; `const Border()` for none.
  final BoxBorder? border;
  final BorderRadiusGeometry borderRadius;

  /// `shadow-xl` by default.
  final List<BoxShadow>? boxShadow;
  final double? width;
  final bool scopesRoute, material;

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: DifyColors.componentsPanelBorder, width: Css.hairline);
    final page = DifyDrawerPage.of(context);
    Widget box = Container(
      // Always constrained (a tight size in a page), so switching the form keeps the content's elements.
      constraints: BoxConstraints.tightFor(
        width: page ? double.infinity : width,
        height: page ? double.infinity : null,
      ),
      clipBehavior: Clip.antiAlias,
      decoration: page
          ? BoxDecoration(color: color ?? DifyColors.componentsPanelBg)
          : BoxDecoration(
              color: color ?? DifyColors.componentsPanelBg,
              border: border ?? Border(top: side, bottom: side, left: side),
              borderRadius: borderRadius,
              boxShadow: boxShadow ?? DifyShadows.xl,
            ),
      // A drawer is a separate route: it does not inherit the page's typography boundary.
      // Establish the Dify body style here so plain labels cannot receive WidgetsApp's debug text style.
      child: DefaultTextStyle(
        style: difyTextStyle(
          DifyType.systemSmRegular,
          DifyColors.textPrimary,
        ).copyWith(decoration: TextDecoration.none),
        // Always a SafeArea (off outside a page), so a rotation that switches the form keeps the content's state.
        child: SafeArea(left: page, top: page, right: page, bottom: page, child: child),
      ),
    );
    if (material) box = Material(type: MaterialType.transparency, child: box);
    return Semantics(
      container: true,
      role: SemanticsRole.dialog,
      scopesRoute: scopesRoute,
      namesRoute: scopesRoute && label != null,
      explicitChildNodes: true,
      label: label,
      child: box,
    );
  }
}

/// DrawerCloseButton: an `lg` IconButton with `i-ri-close-line` (16 px), named [label] (`aria-label`, "Close drawer"
/// by default, as dify-ui).
class DifyDrawerCloseButton extends StatelessWidget {
  const DifyDrawerCloseButton({super.key, required this.onPressed, this.label = 'Close drawer', this.icon});

  final VoidCallback? onPressed;
  final String label;

  /// `children` (the close icon by default).
  final Widget? icon;

  @override
  Widget build(BuildContext context) => DifyIconButton(
    label: label,
    size: DifyIconButtonSize.lg,
    icon: icon ?? const RemixIcon('close-line', size: 16),
    onPressed: onPressed,
  );
}
