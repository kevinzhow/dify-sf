/// dify-ui's Dialog for the node panels: a modal route over the `bg-background-overlay` backdrop, scaling from 0.95
/// and fading in (150 ms), with the `rounded-2xl bg-components-panel-bg shadow-xl` content box ([DifyDialogSurface]).
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';

/// Shows [builder]'s dialog (usually a [DifyDialogSurface]); resolves with what it pops. Escape closes it, and so does
/// a backdrop click unless [dismissible] is false (Dify's `disablePointerDismissal`).
Future<T?> showDifyDialog<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) =>
    showGeneralDialog<T>(
      context: context,
      barrierDismissible: dismissible,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: DifyColors.backgroundOverlay,
      transitionDuration: difyTransitionDuration,
      transitionBuilder: (context, animation, _, child) {
        final a = CurvedAnimation(parent: animation, curve: difyTransitionCurve);
        return FadeTransition(
          opacity: a,
          child: ScaleTransition(scale: Tween(begin: 0.95, end: 1.0).animate(a), child: child),
        );
      },
      pageBuilder: (context, _, _) => builder(context),
    );

/// DialogContent: centred, [width] wide (at most the viewport less 2 rem), `rounded-2xl bg-components-panel-bg
/// shadow-xl` with [padding]; [height] fixes the height, else it hugs the content up to [maxHeight] (80 % of the
/// viewport by default), scrolling when [scrollable]. Named [label] (the dialog's title) for assistive technology.
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
  });

  final Widget child;
  final String? label;
  final double width;
  final double? height, maxHeight;
  final EdgeInsetsGeometry padding;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height ?? maxHeight ?? screen.height * 0.8),
          child: Material(
            type: MaterialType.transparency,
            child: Semantics(
              container: true,
              role: SemanticsRole.dialog,
              explicitChildNodes: true,
              label: label,
              child: Container(
                width: width,
                height: height,
                clipBehavior: Clip.antiAlias,
                padding: padding,
                decoration: BoxDecoration(
                  color: DifyColors.componentsPanelBg,
                  borderRadius: BorderRadius.circular(DifyRadius.xxl),
                  boxShadow: DifyShadows.xl,
                ),
                child: scrollable ? SingleChildScrollView(child: child) : child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
