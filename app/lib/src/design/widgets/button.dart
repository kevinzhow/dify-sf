import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';

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

  @override
  Widget build(BuildContext context) {
    final off = disabled || loading;
    // compound variant: primary + small is `gap-0.75 px-2`.
    final primarySmall = variant == DifyButtonVariant.primary && size == DifyButtonSize.small;
    return DifyPressable(
      onPressed: onPressed,
      disabled: off,
      focusableWhenDisabled: focusableWhenDisabled ?? loading,
      focusNode: focusNode,
      semanticLabel: semanticLabel,
      builder: (context, hovered, focused) {
        final look = difyButtonLook(variant, tone, hovered: hovered, disabled: off);
        return DifyButtonSurface(
          look: look,
          radius: size.radius,
          focused: focused,
          child: SizedBox(
            height: size.height,
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

/// `animate-spin` (1 s linear, infinite).
class DifySpinner extends StatefulWidget {
  const DifySpinner({super.key, required this.color, this.size = 12});
  final Color color;
  final double size;

  @override
  State<DifySpinner> createState() => _DifySpinnerState();
}

class _DifySpinnerState extends State<DifySpinner> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // motion-reduce:animate-none
    if (MediaQuery.maybeDisableAnimationsOf(context) ?? false) {
      _c.stop();
    } else if (!_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RotationTransition(
      turns: _c,
      child: RemixIcon('loader-2-line', size: widget.size, color: widget.color),
    ),
  );
}
