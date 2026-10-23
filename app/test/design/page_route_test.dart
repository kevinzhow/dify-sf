import 'package:dify_sf_app/src/design/widgets/page_route.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('desktop page push/pop never moves or fades either page', (t) async {
    final navigator = GlobalKey<NavigatorState>();
    const home = ValueKey('studio-page'), detail = ValueKey('detail-page');
    await t.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: const ColoredBox(key: home, color: Colors.white),
      ),
    );
    final origin = t.getRect(find.byKey(home));
    final result = navigator.currentState!.push<String>(
      difyPageRoute<String>(
        settings: const RouteSettings(name: '/account'),
        builder: (_) => const ColoredBox(key: detail, color: Colors.blue),
      ),
    );
    await t.pump();
    expect(t.getRect(find.byKey(detail)), origin);
    expect(find.byKey(home), findsNothing, reason: 'an opaque page, not a moving mobile overlay');
    expect(ModalRoute.of(t.element(find.byKey(detail)))!.settings.name, '/account');
    await t.pump(const Duration(milliseconds: 80));
    expect(t.getRect(find.byKey(detail)), origin);
    navigator.currentState!.pop('back');
    await t.pump();
    expect(t.getRect(find.byKey(home)), origin);
    expect(find.byKey(detail), findsNothing);
    expect(await result, 'back');
  }, variant: TargetPlatformVariant({TargetPlatform.linux, TargetPlatform.macOS, TargetPlatform.windows}));

  test('native Android/iOS retain platform navigation', () {
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(difyPageRoute<void>(builder: (_) => const SizedBox()), isA<MaterialPageRoute<void>>());
    }
  });
}
