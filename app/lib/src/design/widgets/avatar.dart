import 'package:flutter/widgets.dart';

/// AvatarWithEdit.tsx explicitly uses bg-black/50 and text-white in both themes.
abstract final class DifyAvatarEditColors {
  static const overlay = Color(0x80000000);
  static const foreground = Color(0xFFFFFFFF);
}

/// Avatar sizes (avatar/index.tsx `avatarSizeClasses`): the box and the initial's font size.
enum DifyAvatarSize {
  xxs(16, 7),
  xs(20, 8),
  sm(24, 10),
  md(32, 12),
  lg(36, 14),
  xl(40, 16),
  xxl(48, 20),
  xxxl(64, 24);

  const DifyAvatarSize(this.box, this.fontSize);
  final double box;
  final double fontSize;
}

/// dify-ui's Avatar: a `rounded-full bg-primary-600` circle with the name's upper-cased initial (`font-medium
/// text-white`), covered by the image at [url] once it loads. [box] overrides the size's box (`className="size-7"`).
class DifyAvatar extends StatelessWidget {
  const DifyAvatar({super.key, required this.name, this.url, this.size = DifyAvatarSize.md, this.box, this.color});

  final String name;
  final String? url;
  final DifyAvatarSize size;
  final double? box;

  /// The circle's colour (`bg-primary-600` by default).
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final d = box ?? size.box;
    final initial = name.isEmpty ? '' : String.fromCharCode(name.runes.first).toUpperCase();
    return ExcludeSemantics(
      child: Container(
        width: d,
        height: d,
        decoration: BoxDecoration(shape: BoxShape.circle, color: color ?? const Color(0xFF155AEF)),
        clipBehavior: Clip.antiAlias,
        alignment: Alignment.center,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Text(
                initial,
                style: TextStyle(
                  fontSize: size.fontSize,
                  height: 1,
                  fontWeight: FontWeight.w500,
                  color: const Color(0xFFFFFFFF),
                ),
              ),
            ),
            if (url != null && url!.isNotEmpty)
              Image.network(url!, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox.shrink()),
          ],
        ),
      ),
    );
  }
}
