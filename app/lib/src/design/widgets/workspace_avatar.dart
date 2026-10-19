/// Dify's WorkspaceAvatar (web/app/components/base/workspace-avatar).
library;

import 'package:flutter/widgets.dart';

import '../dify_tokens.g.dart';

/// base/workspace-avatar sizes: the box, its radius and the initial's font size / line height.
enum DifyWorkspaceAvatarSize {
  xs(20, DifyRadius.md, 10, 12),
  sm(24, DifyRadius.md, 13, 16),
  lg(36, DifyRadius.lg, 16, 20),
  xxl(48, DifyRadius.xl, 20, 28);

  const DifyWorkspaceAvatarSize(this.box, this.radius, this.fontSize, this.lineHeight);
  final double box, radius, fontSize, lineHeight;
}

/// base/workspace-avatar: the workspace's upper-cased initial (`?` without a name) in white (`font-semibold
/// uppercase opacity-90`) on `bg-components-icon-bg-orange-dark-solid` under the avatar mask gradient, `border
/// border-divider-regular`, `shadow-xs`.
class DifyWorkspaceAvatar extends StatelessWidget {
  const DifyWorkspaceAvatar({super.key, this.name, this.size = DifyWorkspaceAvatarSize.sm});

  final String? name;
  final DifyWorkspaceAvatarSize size;

  @override
  Widget build(BuildContext context) {
    final n = name ?? '';
    final initial = n.isEmpty ? '?' : String.fromCharCode(n.runes.first).toUpperCase();
    final r = BorderRadius.circular(size.radius);
    // The colour under the mask gradient (CSS paints background-color below background-image).
    return ExcludeSemantics(
      child: Container(
        width: size.box,
        height: size.box,
        decoration: BoxDecoration(
          borderRadius: r,
          color: DifyColors.componentsIconBgOrangeDarkSolid,
          boxShadow: DifyShadows.xs,
        ),
        foregroundDecoration: BoxDecoration(
          borderRadius: r,
          border: Border.all(color: DifyColors.dividerRegular),
        ),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: r,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [DifyColors.componentsAvatarBgMaskStop0, DifyColors.componentsAvatarBgMaskStop100],
            ),
          ),
          alignment: Alignment.center,
          child: Opacity(
            opacity: 0.9,
            child: Text(
              initial,
              style: TextStyle(
                fontSize: size.fontSize,
                height: size.lineHeight / size.fontSize,
                fontWeight: FontWeight.w600,
                color: DifyColors.componentsAvatarShapeFillStop0,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
