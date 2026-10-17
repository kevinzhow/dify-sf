import 'package:flutter/widgets.dart';

import '../../design/css_metrics.dart';
import '../../design/dify_icon.dart';
import '../../design/dify_tokens.g.dart';
import '../../design/widgets/widgets.dart';

/// The secondary button group look the header's pills share: `rounded-lg border-[0.5px]
/// border-components-button-secondary-border bg-components-button-secondary-bg shadow-xs`.
BoxDecoration headerPillDecoration() => BoxDecoration(
  color: DifyColors.componentsButtonSecondaryBg,
  border: Border.all(color: DifyColors.componentsButtonSecondaryBorder, width: Css.hairline),
  borderRadius: BorderRadius.circular(DifyRadius.lg),
  boxShadow: DifyShadows.xs,
);

/// A plain `<button>` of the header: [builder] gets whether the pointer is over it; disabled ones get
/// `cursor-not-allowed` and no hover.
class HeaderPressable extends StatelessWidget {
  const HeaderPressable({
    super.key,
    required this.builder,
    this.onPressed,
    this.disabled = false,
    this.semanticLabel,
  });

  final Widget Function(BuildContext context, bool hovered) builder;
  final VoidCallback? onPressed;
  final bool disabled;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => DifyPressable(
    onPressed: onPressed ?? () {},
    disabled: disabled,
    semanticLabel: semanticLabel,
    builder: (context, hovered, focused) => builder(context, hovered && !disabled),
  );
}

/// `animate-spin` (1 s per turn) on [child].
class Spinning extends StatefulWidget {
  const Spinning({super.key, required this.child});
  final Widget child;

  @override
  State<Spinning> createState() => _SpinningState();
}

class _SpinningState extends State<Spinning> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(turns: _c, child: widget.child);
}

/// Dify's base Loading in a popup: a spinning `i-ri-loader-2-line`.
class HeaderLoading extends StatelessWidget {
  const HeaderLoading({super.key});

  @override
  Widget build(BuildContext context) => const Spinning(
    child: RemixIcon('loader-2-line', size: 16, color: DifyColors.textTertiary),
  );
}

/// The workflow chrome's vertical divider (`Divider type="vertical" className="h-3.5"`, `mx-2` from the Divider's
/// own `mx-2`, overridden to `mx-auto` in the header row, i.e. no margin there).
class HeaderDivider extends StatelessWidget {
  const HeaderDivider({super.key, this.margin = 0});
  final double margin;

  @override
  Widget build(BuildContext context) => Container(
    width: 1,
    height: 14,
    margin: EdgeInsets.symmetric(horizontal: margin),
    color: DifyColors.dividerRegular,
  );
}

/// A popup surface the header's popovers draw themselves (`rounded-xl border-[0.5px]
/// border-components-panel-border bg-components-panel-bg shadow-xl`, or the given colour and radius).
BoxDecoration headerPopupDecoration({
  Color color = DifyColors.componentsPanelBg,
  double radius = DifyRadius.xl,
  List<BoxShadow> shadow = DifyShadows.xl,
}) => BoxDecoration(
  color: color,
  border: Border.all(color: DifyColors.componentsPanelBorder, width: Css.hairline),
  borderRadius: BorderRadius.circular(radius),
  boxShadow: shadow,
);

/// A close button (`size-6`/`size-7`, `i-ri-close-line` 16 px in text-tertiary) named "Close".
class HeaderCloseButton extends StatelessWidget {
  const HeaderCloseButton({super.key, required this.onPressed, this.size = 24, required this.label});
  final VoidCallback onPressed;
  final double size;
  final String label;

  @override
  Widget build(BuildContext context) => HeaderPressable(
    onPressed: onPressed,
    semanticLabel: label,
    builder: (context, _) => SizedBox.square(
      dimension: size,
      child: const Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
    ),
  );
}
