/// Dify's AppIcon (web/app/components/base/app-icon): the app's emoji (or image) tile.
library;

import 'package:flutter/widgets.dart';

import '../css_metrics.dart';
import '../dify_tokens.g.dart';
import 'emoji_catalog.dart';
import 'text_line.dart';

/// The plain emoji fallback used by AppIcon and API-provided agent/tool icons. Keep its line box independent
/// of inherited body text; callers that intentionally inherit line height can pass null.
TextStyle difyEmojiTextStyle(double size, {double? lineHeight = 1}) => TextStyle(fontSize: size, height: lineHeight);

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
          : DifyTextLine(
              nativeEmoji(icon),
              textScaler: TextScaler.noScaling,
              style: difyEmojiTextStyle(size.fontSize),
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
