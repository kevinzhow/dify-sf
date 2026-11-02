import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'responsive.dart' show DifyTouch;
import 'touch_target.dart' show DifyTouchArea;

/// IconButton sizes (icon-button/variants.ts): box, radius, padding.
enum DifyIconButtonSize {
  xs(16, DifyRadius.sm, 0),
  sm(20, DifyRadius.md, 0),
  md(24, DifyRadius.md, 2),
  lg(32, DifyRadius.lg, 6),
  xl(36, DifyRadius.lg, 8);

  const DifyIconButtonSize(this.box, this.radius, this.padding);
  final double box;
  final double radius;
  final double padding;
}

/// dify-ui's IconButton: a square button around one icon, with a required accessible [label]. The icon takes the
/// variant's colour (a [DifyIcon] or [RemixIcon] without a colour of its own).
///
/// In a sheet on a phone (a compact window) it sits in a touch box ([DifyTouchArea], [DifyTouch.controlHeight]
/// square) that is also its bounds for accessibility, as a [DifyButton] there is touch-high: the icon and its look
/// keep Dify's size, the slot around them grows. Elsewhere Dify's sizes.
class DifyIconButton extends StatelessWidget {
  const DifyIconButton({
    super.key,
    required this.label,
    required this.icon,
    this.onPressed,
    this.variant = DifyButtonVariant.plain,
    this.tone = DifyButtonTone.normal,
    this.size = DifyIconButtonSize.md,
    this.disabled = false,
    this.focusNode,
    this.restyle,
    this.touchBox = true,
  });

  /// `aria-label`.
  final String label;
  final Widget icon;
  final VoidCallback? onPressed;
  final DifyButtonVariant variant;
  final DifyButtonTone tone;
  final DifyIconButtonSize size;
  final bool disabled;
  final FocusNode? focusNode;

  /// A call site's classes over the variant's look ([difyDarkGlass]).
  final DifyButtonRestyle? restyle;

  /// Takes the touch box in a phone's sheet (see the class). False for a control a finger does not tap: a drag
  /// handle or a button shown only on hover, which keep Dify's size (and take no room they do not use).
  final bool touchBox;

  @override
  Widget build(BuildContext context) => touchBox ? DifyTouchArea.inPhoneSheet(context, _button()) : _button();

  Widget _button() => DifyPressable(
    onPressed: onPressed,
    disabled: disabled,
    focusNode: focusNode,
    semanticLabel: label,
    builder: (context, hovered, focused) => DifyButtonSurface(
      look: switch (difyButtonLook(variant, tone, hovered: hovered, disabled: disabled)) {
        // `data-disabled:` colours win over a call site's classes.
        final look => disabled ? look : restyle?.call(look, hovered) ?? look,
      },
      radius: size.radius,
      focused: focused,
      child: SizedBox.square(
        dimension: size.box,
        child: Padding(
          padding: EdgeInsets.all(size.padding),
          child: Center(child: ExcludeSemantics(child: icon)),
        ),
      ),
    ),
  );
}
