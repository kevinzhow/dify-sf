/// dify-sf's phone floating buttons: the floating action button and the small canvas controls (a dify-sf divergence:
/// Dify has no floating actions).
library;

import 'package:flutter/widgets.dart';

import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'text.dart';
import 'touch_target.dart';

/// The phone's primary action (mockup 1 "Create", the editor toolbar's "+" in mockup 2): Dify's primary button colours
/// (pressed: the hover colours; disabled: the disabled ones) in a [size] 52 px tall shape with [radius] 16, lifted by
/// [DifyShadows.lg]. The regular form is a 52 px square around [icon] (28 px by convention) named [label] for
/// assistive technology; [DifyFab.extended] shows [icon] (22 px) and [label] (15 px semibold), 20 px side padding.
/// Icons without a colour of their own take the button's text colour.
class DifyFab extends StatelessWidget {
  const DifyFab({super.key, required this.icon, required this.label, this.onPressed, this.disabled = false})
    : extended = false;

  const DifyFab.extended({super.key, required this.icon, required this.label, this.onPressed, this.disabled = false})
    : extended = true;

  static const size = 52.0;
  static const radius = DifyRadius.xxl;

  final Widget icon;
  final String label;
  final VoidCallback? onPressed;
  final bool disabled;
  final bool extended;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed,
    disabled: disabled,
    semanticLabel: extended ? null : label,
    builder: (context, hovered, focused) {
      final base = difyButtonLook(
        DifyButtonVariant.primary,
        DifyButtonTone.normal,
        hovered: hovered,
        disabled: disabled,
      );
      return DifyButtonSurface(
        look: DifyButtonLook(
          foreground: base.foreground,
          background: base.background,
          ring: base.ring,
          shadows: disabled ? const [] : DifyShadows.lg,
        ),
        radius: radius,
        focused: focused,
        child: SizedBox(
          height: size,
          width: extended ? null : size,
          child: extended
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      ExcludeSemantics(child: icon),
                      DifyText(label, DifyPhoneType.labelStrong, color: base.foreground),
                    ],
                  ),
                )
              : Center(child: ExcludeSemantics(child: icon)),
        ),
      );
    },
  );
}

/// A small floating control over a canvas (mockup 3's pan/select toggle and fit-to-screen, gen.py `.fbtn`): a [size]
/// 44 px square with `rounded-xl`, components-button-secondary-bg (hover/pressed: its hover colour) with the
/// secondary border as an inset ring and shadow-md, and an icon (22 px by convention) in text-secondary. When
/// [selected] (a mode that is on) it shows state-accent-active with a text-accent icon and reports `toggled` to
/// assistive technology. [label] is its accessible name; its hit area is at least 48 px ([DifyTouchTarget]).
class DifyFloatingIconButton extends StatelessWidget {
  const DifyFloatingIconButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.selected,
    this.disabled = false,
  });

  static const size = 44.0;
  static const radius = DifyRadius.xl;

  final String label;
  final Widget icon;
  final VoidCallback? onPressed;

  /// On / off for a toggle; null for a plain action.
  final bool? selected;
  final bool disabled;

  @override
  Widget build(BuildContext context) {
    final on = selected ?? false;
    // The target outermost: a wrapper's own hit test would stop at the 44 px square.
    return DifyTouchTarget(
      // One node: the button with its name and, for a toggle, its state.
      child: MergeSemantics(
        child: Semantics(
          toggled: selected,
          child: DifyPressable(
            onPressed: onPressed,
            disabled: disabled,
            semanticLabel: label,
            builder: (context, hovered, focused) => DifyButtonSurface(
              look: DifyButtonLook(
                foreground: disabled
                    ? DifyColors.textDisabled
                    : on
                    ? DifyColors.textAccent
                    : DifyColors.textSecondary,
                background: on
                    ? DifyColors.stateAccentActive
                    : hovered && !disabled
                    ? DifyColors.componentsButtonSecondaryBgHover
                    : DifyColors.componentsButtonSecondaryBg,
                ring: on
                    ? DifyColors.componentsButtonSecondaryAccentBorder
                    : DifyColors.componentsButtonSecondaryBorder,
                shadows: DifyShadows.md,
              ),
              radius: radius,
              focused: focused,
              child: SizedBox.square(
                dimension: size,
                child: Center(child: ExcludeSemantics(child: icon)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
