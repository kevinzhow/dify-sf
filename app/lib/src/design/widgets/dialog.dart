/// dify-ui's Dialog for the node panels: a modal route over the `bg-background-overlay` backdrop, scaling from 0.95
/// and fading in (150 ms), with the `rounded-2xl bg-components-panel-bg shadow-xl` content box ([DifyDialogSurface]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';

import '../css_metrics.dart';
import '../dify_tokens.g.dart';
import 'widgets.dart';

/// How a [showDifyDialog] route comes in and goes out.
enum DifyDialogTransition {
  /// dify-ui's `modalPopupAnimationClassName`: scale from 0.95 and fade ([difyTransitionCurve]).
  scaleFade,

  /// A fade on [difyTransitionCurve] (MenuDialog, the create-app shell).
  fade,

  /// A linear fade (Flutter's `showGeneralDialog` default).
  linearFade,

  /// No animation of the popup (the backdrop still fades in).
  none,
}

/// Material's `showDialog` barrier (`Colors.black54`), for the dev shell's dialogs (not Dify screens).
const materialDialogBarrierColor = Color(0x8A000000);

/// Shows [builder]'s dialog (usually a [DifyDialogSurface]); resolves with what it pops. Escape closes it (unless
/// [closeOnEscape] is false: the dialog handles Escape itself), and so does a backdrop click unless [dismissible] is
/// false (Dify's `disablePointerDismissal`). [barrierColor] defaults to dify-ui's `modalBackdropClassName`
/// (`bg-background-overlay`); [transition] and [transitionDuration] (150 ms) default to its popup animation.
Future<T?> showDifyDialog<T>(
  BuildContext context, {
  required WidgetBuilder builder,
  bool dismissible = true,
  bool closeOnEscape = true,
  Color? barrierColor,
  String? barrierLabel,
  DifyDialogTransition transition = DifyDialogTransition.scaleFade,
  Duration transitionDuration = difyTransitionDuration,
  bool useRootNavigator = true,
}) => showGeneralDialog<T>(
  context: context,
  barrierDismissible: dismissible,
  barrierLabel: barrierLabel ?? MaterialLocalizations.of(context).modalBarrierDismissLabel,
  barrierColor: barrierColor ?? DifyColors.backgroundOverlay,
  transitionDuration: transitionDuration,
  useRootNavigator: useRootNavigator,
  transitionBuilder: (context, animation, _, child) => switch (transition) {
    DifyDialogTransition.scaleFade => () {
      final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
      return FadeTransition(
        opacity: a,
        child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
      );
    }(),
    DifyDialogTransition.fade => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: difyTransitionCurve),
      child: child,
    ),
    DifyDialogTransition.linearFade => FadeTransition(opacity: animation, child: child),
    DifyDialogTransition.none => child,
  },
  pageBuilder: (context, _, _) => !closeOnEscape
      ? FocusScope(autofocus: true, child: builder(context))
      : Shortcuts(
          shortcuts: const {SingleActivator(LogicalKeyboardKey.escape): DismissIntent()},
          child: Actions(
            actions: {
              DismissIntent: CallbackAction<DismissIntent>(
                onInvoke: (_) {
                  Navigator.of(context).pop();
                  return null;
                },
              ),
            },
            child: FocusScope(autofocus: true, child: builder(context)),
          ),
        ),
);

/// DialogContent: centred (or [top] below the viewport's top: `mt-*`), [width] wide (at most the viewport less 2 rem),
/// `rounded-2xl` ([radius]) `bg-components-panel-bg shadow-xl` with [padding]; [height] fixes the height, else it hugs
/// the content up to [maxHeight] (80 % of the viewport below [top] by default), scrolling when [scrollable]. Named
/// [label] (the dialog's title) for assistive technology; [namesRoute] also makes it the route's scope and name.
/// [bordered] adds dify-ui 1.17's `border-[0.5px] border-components-panel-border`.
class DifyDialogSurface extends StatelessWidget {
  const DifyDialogSurface({
    super.key,
    required this.child,
    this.label,
    this.width = 480,
    this.height,
    this.maxHeight,
    this.padding = EdgeInsets.zero,
    this.scrollable = false,
    this.bordered = false,
    this.radius = DifyRadius.xxl,
    this.top,
    this.namesRoute = false,
  });

  final Widget child;
  final String? label;
  final double width;
  final double? height, maxHeight;
  final EdgeInsetsGeometry padding;
  final bool scrollable;
  final bool bordered;
  final double radius;
  final double? top;
  final bool namesRoute;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final box = ConstrainedBox(
      constraints: BoxConstraints(
        maxWidth: width,
        maxHeight: height ?? maxHeight ?? (screen.height - (top ?? 0)) * 0.8,
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Semantics(
          container: true,
          role: SemanticsRole.dialog,
          scopesRoute: namesRoute ? true : null,
          namesRoute: namesRoute ? true : null,
          explicitChildNodes: true,
          label: label,
          child: Container(
            width: width,
            height: height,
            clipBehavior: Clip.antiAlias,
            padding: padding,
            decoration: BoxDecoration(
              color: DifyColors.componentsPanelBg,
              borderRadius: BorderRadius.circular(radius),
              border: bordered ? Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline) : null,
              boxShadow: DifyShadows.xl,
            ),
            child: scrollable ? SingleChildScrollView(child: child) : child,
          ),
        ),
      ),
    );
    if (top case final t?) {
      return Align(
        alignment: Alignment.topCenter,
        child: Padding(padding: EdgeInsets.fromLTRB(16, t, 16, 0), child: box),
      );
    }
    return Center(
      child: Padding(padding: const EdgeInsets.all(16), child: box),
    );
  }
}
