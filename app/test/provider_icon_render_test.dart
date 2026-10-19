import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/provider_icon_image.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('all ten provider icons render in light and dark without losing embedded bitmap content', (t) async {
    final cases = jsonDecode(File('test/fixtures/provider_icons/cases.json').readAsStringSync()) as List;
    for (final entry in cases) {
      final provider = entry['name'];
      final svg = File('test/fixtures/provider_icons/$provider.svg').readAsStringSync();
      final background = entry['dark'] == true ? const ui.Color(0xff101828) : const ui.Color(0xffffffff);
      final source = CachedProviderIconSource(
        (_) async => ModelProviderIcon(
          bytes: utf8.encode(svg),
          contentType: 'image/svg+xml',
        ),
      );
      final icon = (await t.runAsync(() => source.load('fixture')))!;
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder)..drawColor(background, ui.BlendMode.src);
      if (icon.isSvg) {
        final info = (await t.runAsync(
          () => vg.loadPicture(SvgBytesLoader(Uint8List.fromList(icon.bytes)), null, filterRasterScale: 2),
        ))!;
        final scale = math.min(80 / info.size.width, 80 / info.size.height);
        canvas
          ..translate((80 - info.size.width * scale) / 2, (80 - info.size.height * scale) / 2)
          ..scale(scale)
          ..drawPicture(info.picture);
        info.picture.dispose();
      } else {
        final codec = (await t.runAsync(() => ui.instantiateImageCodec(Uint8List.fromList(icon.bytes))))!;
        final frame = (await t.runAsync(codec.getNextFrame))!;
        canvas.drawImageRect(
          frame.image,
          ui.Rect.fromLTWH(0, 0, frame.image.width.toDouble(), frame.image.height.toDouble()),
          const ui.Rect.fromLTWH(0, 0, 80, 80),
          ui.Paint()..filterQuality = ui.FilterQuality.medium,
        );
        frame.image.dispose();
        codec.dispose();
      }
      final picture = recorder.endRecording();
      final image = await t.runAsync(() => picture.toImage(80, 80));
      final pixels = await t.runAsync(() => image!.toByteData());
      final rgba = pixels!.buffer.asUint8List();
      final backgroundRgb = [background.r * 255, background.g * 255, background.b * 255];
      var visible = 0;
      for (var i = 0; i < rgba.length; i += 4) {
        if (List.generate(3, (channel) => (rgba[i + channel] - backgroundRgb[channel]).abs()).any((d) => d > 32)) {
          visible++;
        }
      }
      expect(visible, greaterThan(100), reason: provider);
      final output = Platform.environment['PROVIDER_ICON_OUT'];
      if (output != null) {
        Directory(output).createSync(recursive: true);
        final bytes = await t.runAsync(() => image!.toByteData(format: ui.ImageByteFormat.png));
        File('$output/$provider-flutter.png').writeAsBytesSync(bytes!.buffer.asUint8List());
      }
      image!.dispose();
      picture.dispose();
    }
  });
}
