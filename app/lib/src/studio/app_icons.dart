/// base/app-icon (`AppIcon`) and app/type-selector's `AppTypeIcon`: the app's emoji (or image) tile and the small
/// mode badge on it, shared by the Studio cards and dialogs.
library;

import 'package:flutter/widgets.dart';

import '../design/css_metrics.dart';
import '../design/dify_icon.dart';
import '../design/dify_tokens.g.dart';
import '../design/widgets/emoji_catalog.dart';
import '../i18n/dify_i18n.dart';

/// AppIcon's sizes (`appIconVariants`): box, radius, emoji font size.
enum DifyAppIconSize {
  xs(16, DifyRadius.sm, 12),
  tiny(24, DifyRadius.md, 16),
  small(32, DifyRadius.lg, 20),
  medium(36, 10, 22),
  large(40, 10, 24),
  xl(48, DifyRadius.xl, 28),
  xxl(56, DifyRadius.xxl, 32);

  const DifyAppIconSize(this.box, this.radius, this.fontSize);
  final double box, radius, fontSize;
}

Color? _hex(String? value) {
  if (value == null || !value.startsWith('#') || value.length != 7) return null;
  final v = int.tryParse(value.substring(1), radix: 16);
  return v == null ? null : Color(0xFF000000 | v);
}

/// The native character of a Dify emoji value: an Emoji Mart id (`robot_face`) or already the character.
String nativeEmoji(String? icon) {
  final value = icon == null || icon.isEmpty ? '🤖' : icon;
  return EmojiCatalog.loaded?.emojis[value]?.native ?? value;
}

/// AppIcon: `border-[0.5px] border-divider-regular` on the emoji's background (`#FFEAD5` when none), the emoji
/// centred; an `image` icon with a URL shows the image instead. [rounded] = `rounded-full`. With [onTap] it is a
/// button (Dify's `role="button"` span), else decorative.
class DifyAppIcon extends StatelessWidget {
  const DifyAppIcon({
    super.key,
    this.size = DifyAppIconSize.medium,
    this.iconType,
    this.icon,
    this.background,
    this.imageUrl,
    this.rounded = false,
    this.radius,
    this.onTap,
    this.semanticLabel,
  });

  final DifyAppIconSize size;
  final String? iconType, icon, background, imageUrl;
  final bool rounded;

  /// A call site's radius over the size's (`rounded-2xl` on the create dialog's xxl icon).
  final double? radius;
  final VoidCallback? onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final image = iconType == 'image' && imageUrl != null && imageUrl!.isNotEmpty;
    final r = BorderRadius.circular(rounded ? size.box / 2 : radius ?? size.radius);
    Widget tile = Container(
      width: size.box,
      height: size.box,
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: image ? null : _hex(background) ?? const Color(0xFFFFEAD5),
        borderRadius: r,
        border: Border.all(color: DifyColors.dividerRegular, width: Css.hairline),
      ),
      child: image
          ? Image.network(
              imageUrl!,
              width: size.box,
              height: size.box,
              fit: BoxFit.cover,
              excludeFromSemantics: true,
              errorBuilder: (_, _, _) => SizedBox(width: size.box, height: size.box),
            )
          : Text(
              nativeEmoji(icon),
              textScaler: TextScaler.noScaling,
              style: TextStyle(fontSize: size.fontSize, height: 1),
            ),
    );
    if (onTap == null) return ExcludeSemantics(child: tile);
    return Semantics(
      button: true,
      label: semanticLabel,
      child: GestureDetector(
        onTap: onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: ExcludeSemantics(child: tile),
        ),
      ),
    );
  }
}

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
