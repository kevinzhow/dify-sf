/// Renders the editor to PNG files for eyeballing the layout, with the real Material fonts from the Flutter
/// SDK. Only runs when `SCREENSHOT_DIR` is set (and `FLUTTER_ROOT`, which `flutter test` provides):
///
///     SCREENSHOT_DIR=/tmp/shots flutter test test/screenshot_test.dart
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _loadFonts() async {
  final root = Platform.environment['FLUTTER_ROOT']!;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      loader.addFont(Future.value(ByteData.sublistView(File('$dir/$f').readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', ['Roboto-Regular.ttf', 'Roboto-Medium.ttf', 'Roboto-Bold.ttf']);
  await load('MaterialIcons', ['MaterialIcons-Regular.otf']);
}

void main() {
  final out = Platform.environment['SCREENSHOT_DIR'];
  if (out == null) return;

  testWidgets('screenshots', (t) async {
    await _loadFonts();
    t.view.physicalSize = const Size(1500, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final boundary = GlobalKey();
    final demo = DemoBackend();
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: ThemeData(colorSchemeSeed: const Color(0xFF3F51B5), useMaterial3: true, fontFamily: 'Roboto'),
          home: EditorPage(
            backend: demo,
            docId: 'demo',
            clientId: 'alice-abc123',
            journaled: true,
            extraActions: demo.actions,
          ),
        ),
      ),
    );
    Future<void> settle([int ms = 1500]) async {
      for (var i = 0; i < ms ~/ 100; i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> shot(String name) async {
      await t.runAsync(() async {
        final render = boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final image = await render.toImage();
        final bytes = (await image.toByteData(format: ui.ImageByteFormat.png))!;
        Directory(out).createSync(recursive: true);
        File('$out/$name.png').writeAsBytesSync(bytes.buffer.asUint8List());
      });
    }

    await settle();
    await shot('1-canvas');

    await t.tap(find.byKey(const ValueKey('node-code')), warnIfMissed: false);
    await settle(500);
    await shot('2-code-node-panel');

    // Offline edit + Bo's conflicting edit -> notice.
    await t.tap(find.byKey(const ValueKey('node-llm')), warnIfMissed: false);
    await settle(300);
    demo.setOffline(true);
    await settle(500);
    await t.enterText(find.byKey(const ValueKey('cfg-llm-prompt')), 'Summarize the text in one sentence.');
    await settle(1500);
    demo.boSets('llm', ['prompt'], 'Answer in French: {{#start.query#}}');
    await settle(500);
    await shot('3-offline-pending');
    demo.setOffline(false);
    await t.tap(find.byKey(const Key('reconnect-now')));
    await settle(3000);
    await shot('4-conflict-notice');

    // Delete a referenced node -> broken references.
    await t.tap(find.byKey(const Key('discard')));
    await settle(300);
    await t.tap(find.byKey(const ValueKey('node-llm')), warnIfMissed: false);
    await settle(300);
    await t.tap(find.byKey(const Key('delete-node')));
    await settle(500);
    await shot('5-delete-dialog');
    await t.tap(find.byKey(const Key('confirm-delete')));
    await settle(800);
    await t.tap(find.byKey(const ValueKey('node-code')), warnIfMissed: false);
    await settle(500);
    await shot('6-broken-reference');

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
