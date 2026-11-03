import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'bottom_sheet.dart' show DifySheetRecipe;
import 'dialog.dart' show DifyDialogFrame;
import 'kbd.dart' show DifyKbd, DifyKeycaps;
import 'loading.dart' show DifySpinner;
import 'responsive.dart';
import 'touch_target.dart' show DifyTouchSurface;

/// Button sizes (button/index.tsx): height, gap, radius, horizontal padding, text.
enum DifyButtonSize {
  /// `h-6 gap-1 rounded-md px-2.25 text-xs font-medium`
  small(24, 4, DifyRadius.md, 9, TextStyle(fontSize: 12, height: 16 / 12, fontWeight: FontWeight.w500)),

  /// `h-8 gap-1 rounded-lg px-3.5 text-[13px] leading-4 font-medium`
  medium(32, 4, DifyRadius.lg, 14, TextStyle(fontSize: 13, height: 16 / 13, fontWeight: FontWeight.w500)),

  /// `h-9 gap-1.5 rounded-[10px] px-4 text-sm font-semibold`
  large(36, 6, 10, 16, TextStyle(fontSize: 14, height: 20 / 14, fontWeight: FontWeight.w600));

  const DifyButtonSize(this.height, this.gap, this.radius, this.paddingX, this.text);
  final double height;
  final double gap;
  final double radius;
  final double paddingX;
  final TextStyle text;
}

/// dify-ui's Button. [child] is the label (usually a [Text]); [leading] and [trailing] sit beside it with the size's
/// gap. [loading] blocks activation, keeps the button focusable (unless [focusableWhenDisabled] is false) and
/// appends a spinning `i-ri-loader-2-line` (12 px).
class DifyButton extends StatelessWidget {
  const DifyButton({
    super.key,
    required this.child,
    this.onPressed,
    this.leading,
    this.trailing,
    this.variant = DifyButtonVariant.secondary,
    this.tone = DifyButtonTone.normal,
    this.size = DifyButtonSize.medium,
    this.disabled = false,
    this.loading = false,
    this.focusableWhenDisabled,
    this.focusNode,
    this.semanticLabel,
    this.paddingX,
    this.restyle,
  }) : assert(variant != DifyButtonVariant.plain, 'Button has no plain variant');

  final Widget child;
  final VoidCallback? onPressed;
  final Widget? leading;
  final Widget? trailing;
  final DifyButtonVariant variant;
  final DifyButtonTone tone;
  final DifyButtonSize size;
  final bool disabled;
  final bool loading;
  final bool? focusableWhenDisabled;
  final FocusNode? focusNode;
  final String? semanticLabel;

  /// A call site's `px-*` over the size's padding.
  final double? paddingX;

  /// A call site's classes over the variant's look ([difyDarkGlass]).
  final DifyButtonRestyle? restyle;

  @override
  Widget build(BuildContext context) {
    final off = disabled || loading;
    // In a sheet, a dialog or a touch surface (a pushed page) on a phone a button is touch-high (44 px), as the fields
    // there are, and at least as wide (a short label: "Add"); elsewhere Dify's sizes.
    final touch =
        DifyTouch.compactOf(context) &&
        (DifySheetRecipe.contains(context) || DifyDialogFrame.maybeOf(context) != null || DifyTouchSurface.of(context));
    final height = touch ? math.max(size.height, DifyTouch.controlHeight) : size.height;
    // Keycaps a phone does not show leave the row, with the gap before them (the label stays centred).
    final keycaps = DifyKbd.shownIn(context);
    final leading = this.leading is DifyKeycaps && !keycaps ? null : this.leading;
    final trailing = this.trailing is DifyKeycaps && !keycaps ? null : this.trailing;
    // compound variant: primary + small is `gap-0.75 px-2`.
    final primarySmall = variant == DifyButtonVariant.primary && size == DifyButtonSize.small;
    return DifyPressable(
      onPressed: onPressed,
      disabled: off,
      focusableWhenDisabled: focusableWhenDisabled ?? loading,
      focusNode: focusNode,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) {
        final base = difyButtonLook(variant, tone, hovered: hovered, disabled: off);
        // `data-disabled:` colours win over a call site's classes.
        final look = off ? base : restyle?.call(base, hovered) ?? base;
        return DifyButtonSurface(
          look: look,
          radius: size.radius,
          focused: focused,
          child: Container(
            height: height,
            constraints: BoxConstraints(minWidth: touch ? DifyTouch.controlHeight : 0),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: paddingX ?? (primarySmall ? 8 : size.paddingX)),
              child: DefaultTextStyle.merge(
                style: size.text,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.clip,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  spacing: primarySmall ? 3 : size.gap,
                  children: [
                    ?leading,
                    Flexible(child: child),
                    ?trailing,
                    if (loading) DifySpinner(color: look.foreground),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
