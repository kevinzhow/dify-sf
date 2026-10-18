import 'package:flutter/widgets.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// Icons decoded ahead of time, so widgets draw them in their first frame. Cards on the canvas are captured right
/// after they first paint; an icon still loading then would be missing from the capture.
abstract final class IconCache {
  static final _pictures = <(String, int), PictureInfo>{};

  static PictureInfo? get(String asset, Color color) => _pictures[(asset, color.toARGB32())];

  /// Decodes [icons] (asset path, colour for `currentColor`).
  static Future<void> preload(Iterable<(String, Color)> icons) async {
    for (final (asset, color) in icons) {
      final key = (asset, color.toARGB32());
      if (_pictures.containsKey(key)) continue;
      try {
        _pictures[key] = await vg.loadPicture(SvgAssetLoader(asset, theme: SvgTheme(currentColor: color)), null);
      } catch (_) {
        // A missing or unreadable icon falls back to SvgPicture.
      }
    }
  }
}

/// Draws a preloaded icon, or loads it like SvgPicture.
Widget _icon(BuildContext context, String asset, double size, Color? color) {
  final c = color ?? DefaultTextStyle.of(context).style.color ?? const Color(0xFF000000);
  final picture = IconCache.get(asset, c);
  if (picture != null) {
    return CustomPaint(size: Size.square(size), painter: _PicturePainter(picture));
  }
  // Fitted (contained) in the square like the preloaded picture and a CSS-sized <svg>: SvgPicture given a width and a
  // height scales a non-square icon to the height and overflows the width.
  return SizedBox.square(
    dimension: size,
    child: SvgPicture.asset(asset, theme: SvgTheme(currentColor: c)),
  );
}

class _PicturePainter extends CustomPainter {
  _PicturePainter(this.info);
  final PictureInfo info;

  @override
  void paint(Canvas canvas, Size size) {
    final s = info.size;
    if (s.isEmpty) return;
    final k = (size.width / s.width) < (size.height / s.height) ? size.width / s.width : size.height / s.height;
    canvas
      ..save()
      ..translate((size.width - s.width * k) / 2, (size.height - s.height * k) / 2)
      ..scale(k)
      ..drawPicture(info.picture)
      ..restore();
  }

  @override
  bool shouldRepaint(_PicturePainter old) => old.info != info;
}

/// One of Dify's icons (assets/dify_icons, generated from Dify's icon JSON by tool/gen_dify_icons.py), e.g.
/// `DifyIcon('vender/workflow/IfElse', size: 16, color: white)`. Icons drawn in `currentColor` take [color].
class DifyIcon extends StatelessWidget {
  const DifyIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => _icon(context, 'assets/dify_icons/$name.svg', size, color);
}

/// A Remix icon as Dify uses it (`i-ri-<name>` / `Ri<Name>`), e.g. `RemixIcon('loader-2-line')`.
class RemixIcon extends StatelessWidget {
  const RemixIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => _icon(context, 'assets/remix_icons/$name.svg', size, color);
}

/// A Heroicon as Dify uses it (`i-heroicons-<name>`, outline set), e.g. `HeroIcon('globe-alt')`.
class HeroIcon extends StatelessWidget {
  const HeroIcon(this.name, {super.key, this.size = 16, this.color});

  final String name;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => _icon(context, 'assets/heroicons/$name.svg', size, color);
}

/// base/logo/dify-logo.tsx `DifyLogo` (`/logo/logo.svg`, 48 x 22, `object-contain`): `small` 36 x 16, `medium`
/// 48 x 22, `large` 64 x 28. [alt] is the image's accessible name.
class DifyLogo extends StatelessWidget {
  const DifyLogo({super.key, this.alt = 'Dify', this.size = DifyLogoSize.medium});

  final String alt;
  final DifyLogoSize size;

  @override
  Widget build(BuildContext context) => Semantics(
    image: true,
    label: alt.isEmpty ? null : alt,
    excludeSemantics: true,
    child: SizedBox(
      width: size.width,
      height: size.height,
      child: SvgPicture.asset('assets/brand/logo.svg'),
    ),
  );
}

enum DifyLogoSize {
  small(36, 16),
  medium(48, 22),
  large(64, 28);

  const DifyLogoSize(this.width, this.height);
  final double width, height;
}

/// The block icon glyph per node type (workflow/block-icon.tsx: Start draws `user-input`, the others
/// DEFAULT_ICON_MAP).
/// The glyph of the small node icon in variable labels (VarBlockIcon: DEFAULT_ICON_MAP, where Start is `home`).
String varBlockGlyph(String type) =>
    type == 'start' || type == 'start-placeholder' ? 'vender/workflow/home' : blockGlyph(type);

String blockGlyph(String type) =>
    'vender/workflow/${switch (type) {
      'start' => 'user-input',
      'start-placeholder' => 'start-placeholder',
      'llm' => 'llm',
      'code' => 'code',
      'end' => 'end',
      'if-else' => 'if-else',
      'http-request' => 'http',
      'answer' => 'answer',
      'knowledge-retrieval' => 'knowledge-retrieval',
      'question-classifier' => 'question-classifier',
      'template-transform' => 'templating-transform',
      'assigner' => 'assigner',
      'iteration' => 'iteration',
      'loop' => 'loop',
      'loop-end' => 'loop-end',
      'parameter-extractor' => 'parameter-extractor',
      'document-extractor' => 'docs-extractor',
      'list-operator' => 'list-filter',
      'agent' || 'agent-v2' => 'agent',
      'knowledge-index' => 'knowledge-base',
      'datasource' => 'datasource',
      'trigger-schedule' => 'schedule',
      'trigger-webhook' => 'webhook-line',
      'human-input' => 'human-in-loop',
      _ => 'variable-x', // variable assigner/aggregator, tool, iteration/loop start, trigger plugin
    }}';
