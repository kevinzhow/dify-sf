/// dify-ui's Switch (packages/dify-ui/src/switch).
library;

import 'package:flutter/material.dart';

import '../dify_tokens.g.dart';
import 'widgets.dart';

/// Switch sizes (switch/index.tsx): track, radius, padding, thumb, thumb radius, checked travel.
enum DifySwitchSize {
  xs(Size(14, 10), 2, 2, Size(4, 6), 1, 6),
  sm(Size(20, 12), 3.5, 2, Size(7, 8), 2, 9),
  md(Size(28, 16), 5, 2, Size(10, 12), 3, 14),
  lg(Size(36, 20), 6, 3, Size(14, 14), 4, 16);

  const DifySwitchSize(this.track, this.radius, this.padding, this.thumb, this.thumbRadius, this.travel);
  final Size track;
  final double radius, padding;
  final Size thumb;
  final double thumbRadius, travel;
}

/// dify-ui's Switch: the toggle background and knob, sliding over 200 ms.
class DifySwitch extends StatelessWidget {
  const DifySwitch({
    super.key,
    required this.checked,
    this.onCheckedChange,
    this.size = DifySwitchSize.md,
    this.disabled = false,
    this.loading = false,
    this.semanticLabel,
  });

  final bool checked;
  final ValueChanged<bool>? onCheckedChange;
  final DifySwitchSize size;
  final bool disabled, loading;
  bool get _disabled => disabled || loading;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    toggled: checked,
    enabled: !_disabled,
    label: semanticLabel,
    onTap: _disabled ? null : () => onCheckedChange?.call(!checked),
    child: DifyControl(
      disabled: _disabled,
      onActivate: () => onCheckedChange?.call(!checked),
      builder: (context, hovered, focused) {
        final bg = switch ((checked, _disabled)) {
          (true, true) => DifyColors.componentsToggleBgDisabled,
          (false, true) => DifyColors.componentsToggleBgUncheckedDisabled,
          (true, false) => hovered ? DifyColors.componentsToggleBgHover : DifyColors.componentsToggleBg,
          (false, false) =>
            hovered ? DifyColors.componentsToggleBgUncheckedHover : DifyColors.componentsToggleBgUnchecked,
        };
        final knob = _disabled
            ? DifyColors.componentsToggleKnobDisabled
            : hovered
            ? DifyColors.componentsToggleKnobHover
            : DifyColors.componentsToggleKnob;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: size.track.width,
          height: size.track.height,
          padding: EdgeInsets.all(size.padding),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(size.radius),
            boxShadow: difyFocusRing(focused),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              AnimatedSlide(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                offset: Offset(checked ? size.travel / size.thumb.width : 0, 0),
                child: Container(
                  width: size.thumb.width,
                  height: size.thumb.height,
                  decoration: BoxDecoration(
                    color: knob,
                    borderRadius: BorderRadius.circular(size.thumbRadius),
                    boxShadow: _disabled
                        ? null
                        : hovered
                        ? DifyShadows.md
                        : DifyShadows.sm,
                  ),
                ),
              ),
              if (loading && (size == DifySwitchSize.md || size == DifySwitchSize.lg))
                Positioned(
                  left: checked ? 2 : size.track.width / 2,
                  top: 2,
                  child: DifySpinner(
                    color: DifyColors.textTertiary,
                    size: size == DifySwitchSize.md ? 8 : 10,
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
}
