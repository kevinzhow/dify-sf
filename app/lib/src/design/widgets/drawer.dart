/// dify-ui's Drawer (packages/dify-ui/src/drawer/index.tsx): [showDifyDrawer] (Root + Portal + Backdrop + Viewport),
/// [DifyDrawerBackdrop], [DifyDrawerPopup], [DifyDrawerCloseButton].
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../css_metrics.dart';
import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// The `bg-black/25` backdrop FeaturePanelDrawer gives DrawerBackdrop
/// (web/app/components/base/features/new-feature-panel/feature-panel-drawer.tsx).
const difyDrawerBlackBackdrop = Color.fromRGBO(0, 0, 0, 0.25);

/// Shows a drawer sliding in from the right (`swipeDirection="right"`, `transition-transform duration-200`): [builder]
/// (usually a [DifyDrawerPopup]) gets the close callback and is placed against the right edge inside [insets]
/// (`top-16 right-2 bottom-3`, …), at most [maxWidth] wide (`w-120`). [backdrop]: DrawerBackdrop's
/// `bg-background-overlay` (false: none, as the logs open it on desktop). Escape closes it, and so does a click outside
/// unless [dismissible] is false (`disablePointerDismissal`). Resolves with what it pops.
Future<T?> showDifyDrawer<T>(
  BuildContext context, {
  required Widget Function(BuildContext context, VoidCallback close) builder,
  EdgeInsets insets = EdgeInsets.zero,
  double maxWidth = 480,
  bool backdrop = true,
  bool dismissible = true,
  String? barrierLabel,
  Duration duration = const Duration(milliseconds: 200),
  Curve curve = Curves.easeOutCubic,
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
  pageBuilder: (dialogContext, _, _) => SafeArea(
    child: Padding(
      padding: insets,
      child: Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: builder(dialogContext, () => Navigator.of(dialogContext).maybePop()),
        ),
      ),
    ),
  ),
);

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
/// the right `rounded-l-2xl`. The screens restyle it by className; [color], [border], [borderRadius] and [boxShadow]
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

  /// `border-[0.5px] border-components-panel-border` by default; `const Border()` for none.
  final BoxBorder? border;
  final BorderRadiusGeometry borderRadius;

  /// `shadow-xl` by default.
  final List<BoxShadow>? boxShadow;
  final double? width;
  final bool scopesRoute, material;

  @override
  Widget build(BuildContext context) {
    Widget box = Container(
      width: width,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: color ?? DifyColors.componentsPanelBg,
        border: border ?? Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
        borderRadius: borderRadius,
        boxShadow: boxShadow ?? DifyShadows.xl,
      ),
      child: child,
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
