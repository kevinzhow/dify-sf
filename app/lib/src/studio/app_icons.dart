/// app/type-selector's `AppTypeIcon`: the small mode badge on the app's tile (base/app-icon's `DifyAppIcon` lives in
/// design/widgets), shared by the Studio cards and dialogs.
library;

import 'package:flutter/widgets.dart';

import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../i18n/dify_i18n.dart';

/// AppTypeIcon: the mode's `rounded-md border border-divider-regular` badge (`size-5` by default, the cards' `w-4
/// h-4` with a `size-3` icon) on the mode's solid colour, the icon in `components-avatar-shape-fill-stop-100`. Unknown
/// modes render nothing.
class AppTypeIcon extends StatelessWidget {
  const AppTypeIcon({super.key, required this.type, this.box = 20, this.iconSize = 14, this.shadow = false});

  final String type;
  final double box, iconSize;

  /// The cards' `shadow-sm`.
  final bool shadow;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Widget icon)? look = switch (type) {
      'chat' => (
        DifyColors.componentsIconBgBlueSolid,
        DifyIcon(
          'vender/solid/communication/chat-bot',
          size: iconSize,
          color: DifyColors.componentsAvatarShapeFillStop100,
        ),
      ),
      'agent-chat' => (
        DifyColors.componentsIconBgVioletSolid,
        DifyIcon(
          'vender/solid/communication/logic',
          size: iconSize,
          color: DifyColors.componentsAvatarShapeFillStop100,
        ),
      ),
      'advanced-chat' => (
        DifyColors.componentsIconBgBlueLightSolid,
        DifyIcon(
          'vender/solid/communication/bubble-text-mod',
          size: iconSize,
          color: DifyColors.componentsAvatarShapeFillStop100,
        ),
      ),
      'workflow' => (
        DifyColors.componentsIconBgIndigoSolid,
        RemixIcon('exchange-2-fill', size: iconSize, color: DifyColors.componentsAvatarShapeFillStop100),
      ),
      'completion' => (
        DifyColors.componentsIconBgTealSolid,
        DifyIcon(
          'vender/solid/communication/list-sparkle',
          size: iconSize,
          color: DifyColors.componentsAvatarShapeFillStop100,
        ),
      ),
      _ => null,
    };
    if (look == null) return const SizedBox.shrink();
    return ExcludeSemantics(
      child: Container(
        key: ValueKey('app-type-icon-$type'),
        width: box,
        height: box,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: look.$1,
          borderRadius: BorderRadius.circular(DifyRadius.md),
          border: Border.all(color: DifyColors.dividerRegular),
          boxShadow: shadow ? DifyShadows.sm : null,
        ),
        child: look.$2,
      ),
    );
  }
}

/// type-selector's `getAppTypeLabel` (`app.typeSelector.*`); "" for an unknown mode.
String appTypeLabel(String type) => switch (type) {
  'chat' => DifyI18n.tr('app', 'typeSelector.chatbot'),
  'agent-chat' => DifyI18n.tr('app', 'typeSelector.agent'),
  'completion' => DifyI18n.tr('app', 'typeSelector.completion'),
  'advanced-chat' => DifyI18n.tr('app', 'typeSelector.advanced'),
  'workflow' => DifyI18n.tr('app', 'typeSelector.workflow'),
  _ => '',
};
