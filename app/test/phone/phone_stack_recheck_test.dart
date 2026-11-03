// The stacked build's device check (check-stack.md), fixes' part: the annotation drawers in a wider touch window
// (a landscape phone, a tablet) are read by assistive technology and hide the page behind, as on a phone (finding 1);
// Bulk Import's sheet closes on Back without leaving the page, its close is touch-sized (finding 2); Create from
// DSL's version confirmation survives a rotation (the reviewer's finding 8).
import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppImport, AppImportStatus, AppModes;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/app_detail/annotations/batch_add_modal.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart' show DSLConfirmModal;
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../dify_spec/annotation/harness.dart' show MockAnnotationServices;
import '../support/app_fonts.dart';
import '../support/platform_semantics.dart';
import 'phone_harness.dart';

const _behind = 'Page behind the overlay';

Future<GlobalKey<NavigatorState>> _app(WidgetTester t, Size size, Widget home) async {
  phoneWindow(t, size: size);
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: nav,
      home: DifyPage(
        edgeToEdge: true,
        body: Stack(
          children: [
            Semantics(label: _behind, button: true, child: const SizedBox(width: 200, height: 48)),
            home,
          ],
        ),
      ),
    ),
  );
  await settle(t, 600);
  return nav;
}

String _a(String key) => DifyI18n.tr('app-annotation', key);
String _tc(String key) => DifyI18n.tr('common', key);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in const [Size(914, 411), Size(1280, 800)]) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: the Add Annotation drawer is in the platform semantics tree and the page behind is not', (
      t,
    ) async {
      final semantics = t.ensureSemantics();
      await _app(t, size, AddAnnotationModal(isShow: true, onHide: () {}, onAdd: (_) async {}));
      expect(find.byKey(const ValueKey('annotation-drawer')), findsOneWidget, reason: 'the inset drawer form');
      final labels = platformLabels(t);
      expect(labels, contains(_a('addModal.title')), reason: 'the drawer is read: $labels');
      expect(labels, contains(_tc('operation.close')), reason: "the drawer's close is read: $labels");
      expect(labels, isNot(contains(_behind)), reason: 'the page behind is hidden: $labels');
      semantics.dispose();
      expect(t.takeException(), isNull);
    });

    testWidgets('$at: a confirmation opened over the Edit Annotation drawer hides the drawer; cancelling it shows the '
        'drawer again', (t) async {
      final semantics = t.ensureSemantics();
      await _app(
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
      final drawerName = _a('editModal.title');
      expect(platformLabels(t), contains(drawerName));
      await t.tap(find.text(_a('editModal.removeThisCache')));
      await settle(t, 600);
      final confirm = find.byKey(const ValueKey('annotation-alert-dialog'));
      expect(confirm, findsOneWidget);
      final title = t.widget<DifyAlertDialog>(find.ancestor(of: confirm, matching: find.byType(DifyAlertDialog))).title;
      var labels = platformLabels(t);
      expect(labels.join(' | '), contains(title), reason: 'the confirmation is read');
      expect(labels, isNot(contains(drawerName)), reason: 'the drawer under it is hidden: $labels');
      expect(labels, isNot(contains(_behind)));
      await t.tap(find.descendant(of: confirm, matching: find.text(_tc('operation.cancel'))));
      await settle(t, 600);
      labels = platformLabels(t);
      expect(labels, contains(drawerName), reason: 'the drawer is read again: $labels');
      semantics.dispose();
      expect(t.takeException(), isNull);
    });
  }

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: Back closes only the Bulk Import sheet, not the page under it; its close is touch-sized', (
      t,
    ) async {
      final nav = await _app(t, size, const SizedBox.shrink());
      var cancels = 0;
      var show = true;
      late StateSetter set;
      unawaited(
        nav.currentState!.push(
          PageRouteBuilder<void>(
            pageBuilder: (_, _, _) => DifyPage(
              edgeToEdge: true,
              body: StatefulBuilder(
                builder: (context, s) => Stack(
                  children: [
                    const Text('Annotations page', key: ValueKey('annotations-page')),
                    if (show)
                      AnnotationBatchModal(
                        isShow: show,
                        services: MockAnnotationServices(),
                        onCancel: () => (set = s)(() {
                          cancels++;
                          show = false;
                        }),
                        onAdded: () {},
                        saveFile: (_, _, _) async {},
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await settle(t, 800);
      final header = find.byType(DifySheetHeader);
      expect(find.descendant(of: header, matching: find.text(_a('batchModal.title'))), findsOneWidget);
      final close = find.descendant(of: header, matching: find.byType(DifyTouchIconButton));
      expect(close, findsOneWidget, reason: "the sheet header's close (no second close inside the sheet)");
      expect(t.getSize(close).height, greaterThanOrEqualTo(44));
      expect(t.getSize(close).width, greaterThanOrEqualTo(44));
      expect(await systemBack(t), isTrue);
      expect(cancels, 1, reason: 'Back closes the sheet');
      expect(header, findsNothing);
      expect(find.byKey(const ValueKey('annotations-page')), findsOneWidget, reason: 'and stays on the page');
      // Again, and the close in the header.
      set(() => show = true);
      await settle(t, 800);
      await t.tap(find.descendant(of: find.byType(DifySheetHeader), matching: find.byType(DifyTouchIconButton)));
      await settle(t, 600);
      expect(cancels, 2);
      expect(find.byKey(const ValueKey('annotations-page')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('desktop: Bulk Import keeps its own close (no sheet header) and ignores Escape (Dify: `onClose={noop}`)', (t) async {
    phoneWindow(t, size: const Size(1280, 800));
    var cancels = 0;
    await t.pumpWidget(
      DifyApplication(
        theme: difyTheme(),
        home: DifyPage(
          body: AnnotationBatchModal(
            isShow: true,
            services: MockAnnotationServices(),
            onCancel: () => cancels++,
            onAdded: () {},
            saveFile: (_, _, _) async {},
          ),
        ),
      ),
    );
    await settle(t, 600);
    expect(find.byType(DifySheetHeader), findsNothing);
    final close = find.byWidgetPredicate((w) => w is DifyIconButton && w.label == _tc('operation.close'));
    expect(close, findsOneWidget);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(t, 300);
    expect(cancels, 0);
    expect(t.takeException(), isNull);
  });

  for (final (from, to) in const [(Size(800, 1280), Size(411, 914)), (Size(411, 914), Size(914, 411))]) {
    final at = '${from.width.toInt()}x${from.height.toInt()} -> ${to.width.toInt()}x${to.height.toInt()}';

    testWidgets('$at: the DSL version confirmation survives the rotation and confirms the pending import', (t) async {
      final nav = await _app(t, from, const SizedBox.shrink());
      var confirmed = 0;
      unawaited(
        showCreateFromDSLModal(
          nav.currentContext!,
          (close) => CreateFromDSLModal(
            activeTab: CreateFromDSLModalTab.fromUrl,
            dslUrl: 'https://example.com/app.yml',
            onClose: close,
            importDsl: (_) async => AppImport(
              id: 'test-import',
              status: AppImportStatus.pending,
              importedDslVersion: '1.0.0',
              currentDslVersion: '2.0.0',
            ),
            confirmImport: (id) async {
              confirmed++;
              return AppImport(
                id: id,
                status: AppImportStatus.completed,
                appId: 'app-1',
                appMode: AppModes.workflow,
                currentDslVersion: '2.0.0',
              );
            },
            fetchUrl: (_) async => 'app: demo',
          ),
        ),
      );
      await settle(t, 800);
      await t.tap(find.byKey(const ValueKey('dsl-create')));
      await settle(t, 800);
      expect(find.byType(DSLConfirmModal), findsOneWidget);
      t.view.physicalSize = to;
      await settle(t, 1000);
      expect(find.byType(DSLConfirmModal), findsOneWidget, reason: 'one confirmation, still offering confirm / cancel');
      // A landscape phone's confirmation scrolls its content to the buttons.
      await t.ensureVisible(find.byKey(const ValueKey('dsl-confirm-confirm')));
      await t.pump();
      await t.tap(find.byKey(const ValueKey('dsl-confirm-confirm')));
      await settle(t, 800);
      expect(confirmed, 1);
      expect(find.byType(CreateFromDSLModal), findsNothing);
      await unmount(t);
      expect(t.takeException(), isNull);
    });
  }
}
