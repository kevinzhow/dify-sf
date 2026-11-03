// The stacked build's device check, subpages' leftovers: on a phone's pages the small controls are 44 dp touch boxes
// (also their accessible bounds): the Add Annotation page's "Add" and its "Add another" checkbox, the Edit
// Annotation page's inline Edit and "Remove this Annotation", and My Account's "Show N apps". (The Logs chips are in
// phone_subpages_test.)
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

String _a(String key) => DifyI18n.tr('app-annotation', key);
String _c(String key) => DifyI18n.tr('common', key);

Future<void> _page(WidgetTester t, Size size, Widget home) async {
  phoneWindow(t, size: size);
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      home: DifyPage(edgeToEdge: true, body: home),
    ),
  );
  await settle(t, 600);
}

/// [f] is at least 44 dp in each direction.
void _touchSized(WidgetTester t, Finder f, String reason) {
  expect(f, findsOneWidget, reason: reason);
  final size = t.getSize(f);
  expect(size.height, greaterThanOrEqualTo(44), reason: '$reason: $size');
  expect(size.width, greaterThanOrEqualTo(44), reason: '$reason: $size');
}

/// The touch box around [control].
Finder _box(Finder control) => find.ancestor(of: control, matching: find.byType(DifyTouchArea)).first;

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: the Add Annotation page\'s "Add" and "Add another" are 44 dp touch targets', (t) async {
      await _page(t, size, AddAnnotationModal(isShow: true, onHide: () {}, onAdd: (_) async {}));
      final drawer = find.byKey(const ValueKey('annotation-drawer'));
      final add = find.ancestor(
        of: find.descendant(of: drawer, matching: find.text(_c('operation.add'))),
        matching: find.byType(DifyButton),
      );
      _touchSized(t, add.first, 'Add');
      final checkbox = find.descendant(of: drawer, matching: find.byType(DifyCheckbox));
      _touchSized(t, _box(checkbox), 'Add another');
      // The box toggles it.
      final before = t.widget<DifyCheckbox>(checkbox).checked;
      await t.tapAt(t.getRect(_box(checkbox)).bottomLeft + const Offset(2, -2));
      await settle(t, 300);
      expect(t.widget<DifyCheckbox>(checkbox).checked, !before);
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at: the Edit Annotation page\'s inline Edit and "Remove this Annotation" are 44 dp touch targets', (
      t,
    ) async {
      await _page(
        t,
        size,
        EditAnnotationModal(
          isShow: true,
          onHide: () {},
          annotationId: 'a1',
          query: 'What is Dify?',
          answer: 'An LLM app platform.',
          onEdited: (_, _) {},
          onRemove: () {},
          editAnnotation: (id, {required question, required answer, messageId}) async {},
          createdAt: 1700000000,
        ),
      );
      final edit = find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == _c('operation.edit'));
      expect(edit, findsWidgets);
      for (final e in edit.evaluate()) {
        _touchSized(t, _box(find.byWidget(e.widget)), 'Edit');
      }
      final remove = find.byWidgetPredicate(
        (w) => w is DifyPressable && w.semanticLabel == _a('editModal.removeThisCache'),
      );
      _touchSized(t, _box(remove), 'Remove this Annotation');
      expect(t.takeException(), isNull);
      await unmount(t);
    });

    testWidgets('$at: My Account\'s "Show N apps" is touch-high', (t) async {
      phoneWindow(t, size: size);
      final ws = await workspace();
      ws.api.seed(name: 'Support triage');
      await pumpApp(t, ws);
      await t.tap(
        find.descendant(of: find.byKey(const ValueKey('phone-home-navigation')), matching: find.text('Account')),
      );
      await settle(t);
      await t.tap(find.byKey(const ValueKey('account-tab-my-account')));
      await settle(t);
      final toggle = find.byKey(const ValueKey('collapse-toggle'));
      await t.scrollUntilVisible(toggle, 100, scrollable: find.byType(Scrollable).last);
      expect(t.getSize(toggle).height, greaterThanOrEqualTo(44));
      expect(t.takeException(), isNull);
      await unmount(t);
    });
  }
}
