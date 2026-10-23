import 'package:flutter/widgets.dart';

import '../dify_icon.dart';
import '../dify_tokens.g.dart';
import 'button_style.dart';
import 'surface.dart';
import 'text.dart';

/// main-nav/components/nav-link.tsx: `h-8 rounded-[10px] px-2 py-1.5 gap-2`, the 20 px icon and the label
/// (`system-md-medium text-components-main-nav-nav-button-text`, hover `bg-components-main-nav-nav-button-bg-hover`).
/// Active page state uses the original active icon, background, border and text tokens.
class MainNavLink extends StatelessWidget {
  const MainNavLink({
    super.key,
    required this.label,
    required this.icon,
    required this.activeIcon,
    required this.onTap,
    this.active = false,
  });

  final String label, icon, activeIcon;
  final VoidCallback onTap;
  final bool active;

  @override
  Widget build(BuildContext context) => DifyPressable(
    semanticLabel: label,
    onPressed: onTap,
    builder: (context, hovered, focused) {
      final content = Container(
        constraints: const BoxConstraints(minHeight: 32),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: active
              ? null
              : hovered
              ? DifyColors.componentsMainNavNavButtonBgHover
              : DifyColors.componentsMainNavNavButtonBg,
          borderRadius: BorderRadius.circular(10),
        ),
        foregroundDecoration: focused
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: DifyColors.stateAccentSolid, width: 2),
              )
            : null,
        child: Row(
          spacing: 8,
          children: [
            DifyIcon(
              active ? activeIcon : icon,
              size: 20,
              color: active ? DifyColors.saasDifyBlueInverted : DifyColors.componentsMainNavNavButtonText,
            ),
            Expanded(
              child: DifyTextLine(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: active
                    ? null
                    : difyTextStyle(DifyType.systemMdMedium, DifyColors.componentsMainNavNavButtonText),
              ),
            ),
          ],
        ),
      );
      return Semantics(
        selected: active,
        child: active ? DifyBlueGlassSurface(child: content) : content,
      );
    },
  );
}
