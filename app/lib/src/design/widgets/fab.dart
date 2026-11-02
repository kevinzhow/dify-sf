/// dify-sf's phone floating action button (a dify-sf divergence: Dify has no floating actions).
library;

import 'package:flutter/widgets.dart';

import '../dify_phone_tokens.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'text.dart';

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
