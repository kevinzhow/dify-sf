/// dify-ui's Dialog for the model-node panels: a modal route over the `bg-background-overlay` backdrop, scaling from
/// 0.95 and fading in (150 ms), with a `rounded-2xl bg-components-panel-bg shadow-xl` content box.
library;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import '../../../../design/dify_tokens.g.dart';
import '../../../../design/widgets/widgets.dart';

/// Shows [builder]'s dialog content; resolves with what it pops. [dismissible] false is Dify's
/// `disablePointerDismissal` (Escape still closes).
Future<T?> showLlmDialog<T>(BuildContext context, {required WidgetBuilder builder, bool dismissible = true}) =>
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
/// shadow-xl` with [padding]; [height] fixes the height (else it hugs the content, at most 80 % of the viewport).
class LlmDialogSurface extends StatelessWidget {
  const LlmDialogSurface({
    super.key,
    required this.child,
    required this.label,
    this.width = 480,
    this.height,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;

  /// The dialog's title (its accessible name).
  final String label;
  final double width;
  final double? height;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: height ?? screen.height * 0.8),
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
                child: child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
