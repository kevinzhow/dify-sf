/// dify-ui's StatusDot and StatusDotSkeleton (packages/dify-ui/src/status-dot/index.tsx).
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';

/// StatusDot `status`.
enum DifyStatusDotStatus { success, warning, error, normal, disabled }

/// StatusDot `size`: `small` = `size-1.5 rounded-xs`, `medium` = `size-2 rounded-[3px]`.
enum DifyStatusDotSize {
  small(6, DifyRadius.xs),
  medium(8, 3);

  const DifyStatusDotSize(this.extent, this.radius);
  final double extent, radius;
}

/// StatusDot: `block shrink-0 border border-solid` in the status's `components-badge-status-light-*` border-inner and
/// background with its `shadow-status-indicator-*` (the halo and the outer ring); decorative (`aria-hidden`).
class DifyStatusDot extends StatelessWidget {
  const DifyStatusDot({super.key, this.status = DifyStatusDotStatus.success, this.size = DifyStatusDotSize.medium});

  final DifyStatusDotStatus status;
  final DifyStatusDotSize size;

  /// The status's (background, border-inner, shadow).
  static (Color, Color, List<BoxShadow>) colorsOf(DifyStatusDotStatus status) => switch (status) {
    DifyStatusDotStatus.success => (
      DifyColors.componentsBadgeStatusLightSuccessBg,
      DifyColors.componentsBadgeStatusLightSuccessBorderInner,
      DifyShadows.statusIndicatorGreenShadow,
    ),
    DifyStatusDotStatus.warning => (
      DifyColors.componentsBadgeStatusLightWarningBg,
      DifyColors.componentsBadgeStatusLightWarningBorderInner,
      DifyShadows.statusIndicatorWarningShadow,
    ),
    DifyStatusDotStatus.error => (
      DifyColors.componentsBadgeStatusLightErrorBg,
      DifyColors.componentsBadgeStatusLightErrorBorderInner,
      DifyShadows.statusIndicatorRedShadow,
    ),
    DifyStatusDotStatus.normal => (
      DifyColors.componentsBadgeStatusLightNormalBg,
      DifyColors.componentsBadgeStatusLightNormalBorderInner,
      DifyShadows.statusIndicatorBlueShadow,
    ),
    DifyStatusDotStatus.disabled => (
      DifyColors.componentsBadgeStatusLightDisabledBg,
      DifyColors.componentsBadgeStatusLightDisabledBorderInner,
      DifyShadows.statusIndicatorGrayShadow,
    ),
  };

  @override
  Widget build(BuildContext context) {
    final (bg, border, shadow) = colorsOf(status);
    return ExcludeSemantics(
      child: Container(
        width: size.extent,
        height: size.extent,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(size.radius),
          border: Border.all(color: border),
          boxShadow: shadow,
        ),
      ),
    );
  }
}

/// StatusDotSkeleton: `block shrink-0 border border-transparent bg-text-primary opacity-30` at the size's extent and
/// radius; decorative.
class DifyStatusDotSkeleton extends StatelessWidget {
  const DifyStatusDotSkeleton({super.key, this.size = DifyStatusDotSize.medium});
  final DifyStatusDotSize size;

  @override
  Widget build(BuildContext context) {
    final color = DifyColors.textPrimary;
    return ExcludeSemantics(
      child: Container(
        width: size.extent,
        height: size.extent,
        decoration: BoxDecoration(
          color: color.withValues(alpha: color.a * 0.3),
          borderRadius: BorderRadius.circular(size.radius),
        ),
      ),
    );
  }
}
