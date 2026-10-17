import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';

/// The operator's bars (control.tsx, undo-redo.tsx, zoom-in-out.tsx): `rounded-lg border-[0.5px]
/// border-components-actionbar-border bg-components-actionbar-bg p-0.5 shadow-lg`, with [blur] `backdrop-blur-[5px]`.
class ActionBar extends StatelessWidget {
  const ActionBar({super.key, required this.child, this.blur = false, this.color = DifyColors.componentsActionbarBg});

  final Widget child;
  final bool blur;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(DifyRadius.lg);
    return DifyBlurredBox(
      blur: blur ? 5 : 0,
      borderRadius: r,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: color,
        border: Border.all(color: DifyColors.componentsActionbarBorder, width: Css.hairline),
        borderRadius: r,
        boxShadow: DifyShadows.lg,
      ),
      child: child,
    );
  }
}

/// The operator's `IconButton size="lg" className="rounded-md"` (32 px, a 16 px icon), focusable when disabled.
/// [pressed] makes it a Toggle (`aria-pressed`; pressed: `bg-state-accent-active text-text-accent`, hovered back to
/// the hover look); [active] is a popup's open look (`bg-state-accent-active text-text-accent`, also on hover).
class OperatorButton extends StatelessWidget {
  const OperatorButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.disabled = false,
    this.pressed,
    this.active = false,
  });

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool? pressed;
  final bool active;

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Semantics(
      toggled: pressed,
      child: DifyPressable(
        onPressed: onPressed,
        disabled: disabled,
        focusableWhenDisabled: true,
        semanticLabel: label,
        builder: (context, hovered, focused) {
          final accent = active || (pressed == true && (disabled || !hovered));
          final hover = hovered && !disabled && !accent;
          return DifyButtonSurface(
            look: DifyButtonLook(
              foreground: disabled
                  ? DifyColors.textDisabled
                  : accent
                  ? DifyColors.textAccent
                  : hover
                  ? DifyColors.textSecondary
                  : DifyColors.textTertiary,
              background: accent
                  ? DifyColors.stateAccentActive
                  : hover
                  ? DifyColors.stateBaseHover
                  : null,
            ),
            radius: DifyRadius.md,
            focused: focused,
            child: SizedBox.square(dimension: 32, child: Center(child: icon)),
          );
        },
      ),
    ),
  );
}
