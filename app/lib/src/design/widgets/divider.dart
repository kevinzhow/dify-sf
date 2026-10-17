import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';

/// Divider orientation (base/divider `type`).
enum DifyDividerType { horizontal, vertical }

/// Dify's base Divider: horizontal `my-2 h-[0.5px] w-full`, vertical `mx-2 h-full w-px`; `bg-divider-regular`, or
/// with [gradient] `bg-linear-to-r from-divider-regular to-background-gradient-mask-transparent`. [margin]
/// replaces the default `my-2` / `mx-2` (call sites override it with classes such as `mx-0`); [length] fixes the
/// otherwise full length (`h-3.5`, ...).
class DifyDivider extends StatelessWidget {
  const DifyDivider({
    super.key,
    this.type = DifyDividerType.horizontal,
    this.gradient = false,
    this.margin,
    this.length,
    this.color = DifyColors.dividerRegular,
  });

  const DifyDivider.vertical({
    super.key,
    this.gradient = false,
    this.margin,
    this.length,
    this.color = DifyColors.dividerRegular,
  }) : type = DifyDividerType.vertical;

  final DifyDividerType type;
  final bool gradient;
  final EdgeInsetsGeometry? margin;
  final double? length;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final horizontal = type == DifyDividerType.horizontal;
    return Container(
      margin:
          margin ?? (horizontal ? const EdgeInsets.symmetric(vertical: 8) : const EdgeInsets.symmetric(horizontal: 8)),
      width: horizontal ? (length ?? double.infinity) : 1,
      height: horizontal ? 0.5 : (length ?? double.infinity),
      decoration: BoxDecoration(
        color: gradient ? null : color,
        gradient: gradient ? LinearGradient(colors: [color, DifyColors.backgroundGradientMaskTransparent]) : null,
      ),
    );
  }
}
