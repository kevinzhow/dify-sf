// The reviewer's (Winnie's) repro of the stacked build, copied from her review (mobile41_dsl_rotate_review3): with a
// touch tablet's Import DSL waiting for the version confirmation, a rotation to portrait keeps the confirmation, and
// confirming imports once.
import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart';
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../phone/phone_harness.dart';
import '../support/app_fonts.dart';

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    DifyInteraction.debugDefault = DifyInteractionMode.touch;
  });
  tearDown(() => DifyInteraction.debugDefault = null);
  for (final rotate in [false, true]) {
    testWidgets('DSL version confirmation survives ${rotate ? "wide to compact rotation" : "ordinary rebuild"}', (
      t,
    ) async {
      phoneWindow(t, size: const Size(800, 1280));
      final nav = GlobalKey<NavigatorState>();
      var confirmed = 0;
      await t.pumpWidget(
        DifyApplication(
          theme: difyTheme(),
          navigatorKey: nav,
          home: const DifyPage(body: SizedBox.expand()),
        ),
      );
      addTearDown(() => unmount(t));
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
      if (rotate) t.view.physicalSize = const Size(411, 914);
      await settle(t, 1000);
      expect(
        find.byType(DSLConfirmModal),
        findsOneWidget,
        reason: 'the pending import must still offer confirm/cancel after rotating',
      );
      await t.tap(find.byKey(const ValueKey('dsl-confirm-confirm')));
      await settle(t, 800);
      expect(confirmed, 1);
      expect(find.byType(CreateFromDSLModal), findsNothing);
      expect(t.takeException(), isNull);
    });
  }
}
