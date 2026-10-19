// Manual native rendering stage for svg_inventory.py; run from app/ with flutter test ../tool/visual/render_svg_inventory.dart.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('render the complete SVG resource inventory in both themes', (tester) async {
    final out = Directory(Platform.environment['SVG_ASSET_OUT']!);
    out.createSync(recursive: true);
    final assets = Directory(Platform.environment['SVG_ASSET_ROOT'] ?? 'assets');
    final files =
        assets.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.svg')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    final rows = <Map<String, Object?>>[];
    final errors = <String>[];
    Future<void> render(File source, String name, bool dark, {bool provider = false}) async {
      final id = '${rows.length.toString().padLeft(4, '0')}-${dark ? 'dark' : 'light'}';
      final svg = source.readAsStringSync();
      final foreground = dark ? const ui.Color(0xfff9fafb) : const ui.Color(0xff101828);
      final background = dark ? const ui.Color(0xff101828) : const ui.Color(0xffffffff);
      final loader = SvgStringLoader(svg, theme: SvgTheme(currentColor: foreground));
      try {
        await tester.runAsync(() async {
          var info = await vg.loadPicture(loader, null);
          final scale = 80 / math.max(info.size.width, info.size.height);
          if (info.requiresRasterResolution && scale != 1) {
            info.picture.dispose();
            info = await vg.loadPicture(loader, null, filterRasterScale: scale);
          }
          final recorder = ui.PictureRecorder();
          final canvas = ui.Canvas(recorder)..drawColor(background, ui.BlendMode.src);
          canvas
            ..translate((80 - info.size.width * scale) / 2, (80 - info.size.height * scale) / 2)
            ..scale(scale)
            ..drawPicture(info.picture);
          final picture = recorder.endRecording();
          info.picture.dispose();
          final image = await picture.toImage(80, 80);
          try {
            final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
            File('${out.path}/$id-flutter.png').writeAsBytesSync(bytes!.buffer.asUint8List());
          } finally {
            image.dispose();
            picture.dispose();
          }
        });
        rows.add({'id': id, 'name': name, 'source': source.absolute.path, 'dark': dark, 'provider': provider});
      } catch (error) {
        errors.add('$name ($dark): $error');
      }
    }

    for (final file in files) {
      final name = file.path.substring(assets.path.length + 1);
      await render(file, name, false);
      await render(file, name, true);
    }
    final providers = jsonDecode(File('test/fixtures/provider_icons/cases.json').readAsStringSync()) as List;
    for (final entry in providers) {
      final name = entry['name'] as String;
      await render(
        File('test/fixtures/provider_icons/$name.svg'),
        'provider/$name.svg',
        entry['dark'] == true,
        provider: true,
      );
    }
    File('${out.path}/index.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(rows)}\n');
    File('${out.path}/errors.json').writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(errors)}\n');
    expect(errors, isEmpty);
    expect(rows.length, files.length * 2 + providers.length);
  }, timeout: const Timeout(Duration(minutes: 15)));
}
