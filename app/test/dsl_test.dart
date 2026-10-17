import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

import 'package:shared_preferences/shared_preferences.dart';

/// The demo backend with a stand-in for the server's workflow-file converter.
class _DslDemoBackend extends DemoBackend {
  _DslDemoBackend() : super(withBo: false);
  String? imported;

  @override
  bool get supportsDifyDsl => true;

  @override
  Future<String> importDifyDsl(String yaml) async {
    imported = yaml;
    return 'demo';
  }

  @override
  Future<String> exportDifyDsl(String docId) async => 'app:\n  name: exported $docId\nkind: app\n';
}

Future<void> settle(WidgetTester t, [int ms = 2000]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a pasted Dify workflow file is imported and opened; the editor exports and copies it', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    String? clipboard;
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final backend = _DslDemoBackend();
    await t.pumpWidget(buildApp(await AppSettings.load(), backendFor: (_) => backend));

    await t.tap(find.byKey(const Key('import-dsl-button')));
    await t.pumpAndSettle();
    await t.enterText(find.byKey(const Key('import-dsl-text')), 'app:\n  name: from dify\n');
    await t.tap(find.byKey(const Key('import-dsl-confirm')));
    await settle(t);
    expect(backend.imported, contains('from dify'));
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget, reason: 'the imported document is open');

    await t.tap(find.byKey(const Key('session-menu')));
    await t.pump(const Duration(milliseconds: 300));
    await t.tap(find.byKey(const Key('export-dsl')));
    await settle(t, 500);
    expect(find.textContaining('exported demo'), findsOneWidget);
    await t.tap(find.byKey(const Key('export-dsl-copy')));
    await settle(t, 500);
    expect(clipboard, contains('exported demo'));

    if (find.byKey(const Key('back-to-documents')).evaluate().isEmpty) {
      await t.tap(find.byKey(const Key('session-menu')));
      await t.pump(const Duration(milliseconds: 300));
    }
    await t.tap(find.byKey(const Key('back-to-documents')));
    await t.pumpWidget(const SizedBox());
    await backend.dispose();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('the demo backend offers no workflow-file export', (t) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final demo = DemoBackend(withBo: false);
    expect(demo.supportsDifyDsl, isFalse);
    await demo.dispose();
  });
}
