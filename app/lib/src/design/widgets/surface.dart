import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';

/// A box with `backdrop-blur-[blur px]` behind it: the backdrop is blurred inside [borderRadius], the decoration
/// (whose shadows fall outside the clip) is painted over it.
class DifyBlurredBox extends StatelessWidget {
  const DifyBlurredBox({
    super.key,
    required this.blur,
    required this.borderRadius,
    required this.child,
    this.decoration,
    this.padding,
  });

  /// CSS `blur()` length: the Gaussian's standard deviation.
  final double blur;
  final BorderRadius borderRadius;
  final Decoration? decoration;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Like Container (and CSS's border-box), the border insets the content.
    final inset = (decoration?.padding ?? EdgeInsets.zero).add(padding ?? EdgeInsets.zero);
    Widget box = inset == EdgeInsets.zero ? child : Padding(padding: inset, child: child);
    if (decoration != null) box = DecoratedBox(decoration: decoration!, child: box);
    if (blur <= 0) return box;
    return Stack(
      children: [
        Positioned.fill(
          child: ClipRRect(
            borderRadius: borderRadius,
            child: BackdropFilter(
              filter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
              child: const SizedBox.expand(),
            ),
          ),
        ),
        box,
      ],
    );
  }
}
