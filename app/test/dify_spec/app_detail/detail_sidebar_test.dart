// dify-spec: web/app/components/detail-sidebar/__tests__/index.spec.tsx
//
// The frame's preference lives in SharedPreferences (Dify: localStorage). dify-sf has no help menu and no environment
// tag; the bottom's account section is replaced as Dify's spec mocks it.
import 'package:dify_sf_app/src/app_detail/detail_sidebar.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

Future<void> _render(WidgetTester t) => renderDetail(
  t,
  DetailSidebarFrame(
    renderTop: (context, expand, onToggle) => Align(
      key: ValueKey('detail-top-$expand'),
      alignment: Alignment.centerLeft,
      child: GestureDetector(
        key: const ValueKey('detail-toggle'),
        onTap: onToggle,
        child: const SizedBox(width: 32, height: 32, child: Text('T')),
      ),
    ),
    renderSection: (context, expand) => Text('Section', key: ValueKey('detail-section-$expand')),
    accountSection: (context, compact) =>
        Text(compact ? 'Compact account' : 'Expanded account', key: const ValueKey('account')),
    child: const Padding(
      padding: EdgeInsets.all(24),
      child: Column(
        children: [
          TextField(key: ValueKey('Note')),
          TextField(key: ValueKey('Note text')),
          TextField(key: ValueKey('Name')),
          TextField(key: ValueKey('Description'), maxLines: 3),
        ],
      ),
    ),
  ),
);

bool _expanded() => find.byKey(const ValueKey('detail-top-true')).evaluate().isNotEmpty;

Future<String?> _stored() async => (await SharedPreferences.getInstance()).getString(detailSidebarStorageKey);

Future<void> _modB(WidgetTester t, String platform) async {
  final mod = platform == 'mac' ? LogicalKeyboardKey.metaLeft : LogicalKeyboardKey.controlLeft;
  await t.sendKeyDownEvent(mod);
  await t.sendKeyEvent(LogicalKeyboardKey.keyB);
  await t.sendKeyUpEvent(mod);
  await t.pump();
}

Future<TestGesture> _hover(WidgetTester t, Finder f) async {
  final g = await t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: const Offset(1000, 800));
  addTearDown(g.removePointer);
  await g.moveTo(t.getCenter(f));
  await t.pump();
  return g;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('DetailSidebarFrame', () {
    testWidgets('keeps unsaved page input across desktop and phone layout changes', (t) async {
      await _render(t);
      final note = find.byKey(const ValueKey('Note'));
      await t.enterText(note, 'Unsaved draft with 中文 and emoji 🚀');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      for (final width in [390.0, 800.0, 320.0, 1440.0]) {
        t.view.physicalSize = Size(width, 900);
        await settle(t);
        final input = t.widget<EditableText>(find.descendant(of: note, matching: find.byType(EditableText)));
        expect(input.controller.text, 'Unsaved draft with 中文 and emoji 🚀', reason: 'width $width');
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('renders expanded detail content by default', (t) async {
      await _render(t);
      expect(find.byKey(const ValueKey('detail-top-true')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-section-true')), findsOneWidget);
    });

    for (final platform in ['mac', 'windows']) {
      group('%s shortcut', () {
        setUp(
          () => debugDefaultTargetPlatformOverride = platform == 'mac' ? TargetPlatform.macOS : TargetPlatform.windows,
        );
        tearDown(() => debugDefaultTargetPlatformOverride = null);

        testWidgets('toggles detail content outside editing fields', (t) async {
          await _render(t);
          await _modB(t, platform);
          expect(_expanded(), isFalse, reason: platform);
          expect(await _stored(), 'collapse');
          await _modB(t, platform);
          expect(_expanded(), isTrue);
          expect(await _stored(), 'expand');
          debugDefaultTargetPlatformOverride = null;
        });

        testWidgets('leaves the shortcut to the %s editor', (t) async {
          for (final name in ['Note', 'Note text', 'Name', 'Description']) {
            await _render(t);
            await t.tap(find.byKey(ValueKey(name)));
            await t.pump();
            await _modB(t, platform);
            expect(_expanded(), isTrue, reason: '$platform $name');
            expect(await _stored(), isNull, reason: 'nothing stored: the default expand');
          }
          debugDefaultTargetPlatformOverride = null;
        });
      });
    }

    testWidgets('collapses detail content from the top toggle and hides environment metadata', (t) async {
      await _render(t);
      await t.tap(find.byKey(const ValueKey('detail-toggle')));
      await t.pump();
      expect(find.byKey(const ValueKey('detail-top-false')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-section-false')), findsOneWidget);
      expect(find.text('Environment tag'), findsNothing);
      expect(await _stored(), 'collapse');
    });

    testWidgets('shows a floating preview on collapsed hover without changing persisted state', (t) async {
      await _render(t);
      await t.tap(find.byKey(const ValueKey('detail-toggle')));
      await t.pump();
      await _hover(t, find.byKey(const ValueKey('detail-top-false')));
      expect(find.byKey(const ValueKey('detail-top-true')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-section-true')), findsOneWidget);
      expect(await _stored(), 'collapse');
    });

    testWidgets('keeps collapsed bottom actions in place when they are hovered', (t) async {
      await _render(t);
      await t.tap(find.byKey(const ValueKey('detail-toggle')));
      await settle(t, 3);
      await _hover(t, find.byKey(const ValueKey('account')));
      expect(_expanded(), isFalse);
      expect(find.text('Compact account'), findsOneWidget);
      expect(await _stored(), 'collapse');
    });

    testWidgets('persists expansion when the hovered preview toggle is clicked', (t) async {
      await _render(t);
      await t.tap(find.byKey(const ValueKey('detail-toggle')));
      await t.pump();
      final g = await _hover(t, find.byKey(const ValueKey('detail-top-false')));
      await g.down(t.getCenter(find.byKey(const ValueKey('detail-toggle'))));
      await g.up();
      await t.pump();
      expect(find.byKey(const ValueKey('detail-top-true')), findsOneWidget);
      expect(find.byKey(const ValueKey('detail-section-true')), findsOneWidget);
      expect(await _stored(), 'expand');
      await settle(t, 3);
    });
  });
}
