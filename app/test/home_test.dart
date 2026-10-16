import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> settle(WidgetTester t, [int ms = 2000]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('rejects document ids the protocol does not allow', (t) async {
    t.view.physicalSize = const Size(1200, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = await AppSettings.load();
    await t.pumpWidget(buildApp(settings));
    await t.enterText(find.byKey(const Key('doc-field')), 'not a valid id!');
    await t.tap(find.byKey(const Key('open-button')));
    await t.pump();
    expect(find.textContaining('letters, digits'), findsOneWidget);
  });

  testWidgets('opens a document and remembers the choices; the client id is stable and well-formed', (t) async {
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final settings = await AppSettings.load();
    expect(settings.clientId, matches(RegExp(r'^me-[0-9a-f]{6}$')));
    final demo = DemoBackend(withBo: false);
    await t.pumpWidget(buildApp(settings, backendFor: (_) => demo));
    await t.enterText(find.byKey(const Key('name-field')), 'Alice B.');
    await t.enterText(find.byKey(const Key('doc-field')), 'wf-1');
    await t.tap(find.byKey(const Key('journal-switch')));
    await t.tap(find.byKey(const Key('open-button')));
    await settle(t);
    expect(find.byKey(const ValueKey('node-start')), findsOneWidget);
    expect(find.textContaining('volatile · aliceb-'), findsOneWidget);

    final saved = await SharedPreferences.getInstance();
    expect(saved.getString('lastDoc'), 'wf-1');
    expect(saved.getBool('journaled'), isFalse);
    expect(saved.getString('userName'), 'Alice B.');

    await t.pageBack();
    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });

  test('command line options', () {
    final o = LaunchOptions.parse(['--server', 'http://x:1', '--doc', 'd', '--name', 'Bo', '--volatile']);
    expect((o.server, o.doc, o.name, o.volatile, o.demo, o.autoOpen), ('http://x:1', 'd', 'Bo', true, false, true));
    expect(LaunchOptions.parse(const []).autoOpen, isFalse);
    expect(LaunchOptions.parse(['--demo']).autoOpen, isTrue);
  });
}
