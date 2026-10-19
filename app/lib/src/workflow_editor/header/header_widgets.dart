import 'package:flutter/rendering.dart';
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

/// The old name of [DifySpinnerIcon], kept for workflow_editor/run/ (owned by the runtime work; switch it there).
typedef Spinning = DifySpinnerIcon;

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
  Color? color,
  double radius = DifyRadius.xl,
  List<BoxShadow> shadow = DifyShadows.xl,
}) => BoxDecoration(
  color: color ?? DifyColors.componentsPanelBg,
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
      child: Center(child: RemixIcon('close-line', size: 16, color: DifyColors.textTertiary)),
    ),
  );
}

/// A flex item that may render nothing (a fragment, `null`), after a [gap] (the row's `gap-*`): the gap goes with
/// it when [child] lays out zero wide, as a flex row has no item (and no gap) for an empty fragment.
class GapBefore extends SingleChildRenderObjectWidget {
  const GapBefore({super.key, required this.gap, required Widget super.child});
  final double gap;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGapBefore(gap);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderGapBefore).gap = gap;
}

class _RenderGapBefore extends RenderShiftedBox {
  _RenderGapBefore(this._gap) : super(null);
  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child!..layout(constraints.loosen().deflate(EdgeInsets.only(left: _gap)), parentUsesSize: true);
    final empty = c.size.width == 0;
    (c.parentData! as BoxParentData).offset = Offset(empty ? 0 : _gap, 0);
    size = constraints.constrain(empty ? Size.zero : Size(c.size.width + _gap, c.size.height));
  }
}
