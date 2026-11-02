// Screenshots of the Steps view preview (tool/steps_view_preview_main.dart) at 411x914 with gesture-navigation
// insets, rendered by the test engine with Noto Sans (not a device). Only with STEPS_SHOTS=<directory>:
//
//   STEPS_SHOTS=/some/dir flutter test test/workflow_editor/steps/steps_view_shots_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/rendering.dart';

import '../../../tool/steps_view_preview_main.dart';
import '../../dify_spec/dify_ui/phone_harness.dart';
import '../../support/app_fonts.dart';

final _boundary = GlobalKey();

Future<void> _settle(WidgetTester t, [int ms = 800]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _shot(WidgetTester t, String name) async {
  final dir = Platform.environment['STEPS_SHOTS']!;
  await t.runAsync(() async {
    // Let the icons (SVG assets) decode.
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await t.pump();
  await t.runAsync(() async {
    final ro = _boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await ro.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

void main() {
  if (Platform.environment['STEPS_SHOTS'] == null) return;

  testWidgets('Steps view screenshots', (t) async {
    await t.runAsync(() => DifyI18n.load('en-US'));
    await useAppFonts();
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await t.pumpWidget(RepaintBoundary(key: _boundary, child: const StepsPreviewApp()));
    await _settle(t, 1500);
    await _shot(t, '01-mockup');

    await t.tap(find.bySemanticsLabel('Simulated run'));
    await _settle(t, 300);
    await _shot(t, '02-run');
    await t.tap(find.bySemanticsLabel('Simulated run'));
    await t.tap(find.bySemanticsLabel('Checklist problems'));
    await _settle(t, 300);
    await _shot(t, '03-issue');
    await t.tap(find.bySemanticsLabel('Checklist problems'));
    await _settle(t, 300);

    await t.longPress(find.text('Count Android'));
    await _settle(t, 800);
    await _shot(t, '04-long-press');
    await t.tap(find.text('Cancel'));
    await _settle(t, 800);

    await t.tap(
      find.descendant(of: find.byKey(const ValueKey('step-plus-j:end')), matching: find.byType(DifyPressable)),
    );
    await _settle(t, 800);
    await _shot(t, '05-add-at-join');
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settle(t, 500);

    await t.tap(find.bySemanticsLabel('Next sample'));
    await _settle(t, 1500);
    await _shot(t, '06-branches-top');
    await t.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await _settle(t, 800);
    await _shot(t, '07-branches-middle');
    await t.drag(find.byType(Scrollable).first, const Offset(0, -2000));
    await _settle(t, 800);
    await _shot(t, '08-branches-end');

    DifyColors.useDark(true);
    await t.pumpWidget(
      RepaintBoundary(
        key: _boundary,
        child: const StepsPreviewApp(key: ValueKey('dark')),
      ),
    );
    await _settle(t, 1500);
    await _shot(t, '09-mockup-dark');
    DifyColors.useDark(false);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });
}
