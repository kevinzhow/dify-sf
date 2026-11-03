// A dialog that is open when the phone is rotated re-presents itself (fixes after PR #90, item 5): a sheet while the
// window is compact, the centred dialog while it is not (914x411 landscape), in place, keeping what was typed. Both
// ways, from 411x914 and from 360x780. Confirmations stay centred in both orientations.
import 'dart:async';

import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/header/publisher/version_info_modal.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Future<GlobalKey<NavigatorState>> _app(WidgetTester t, Size size) async {
  phoneWindow(t, size: size);
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: nav,
      home: const DifyPage(edgeToEdge: true, body: SizedBox.expand()),
    ),
  );
  await settle(t, 300);
  return nav;
}

/// Rotates the window to [size] (the system bars stay as they are).
Future<void> _rotate(WidgetTester t, Size size) async {
  t.view.physicalSize = size;
  await settle(t, 600);
}

/// The form the open dialog is drawn in.
DifyDialogForm? _form(WidgetTester t) {
  final title = find.byType(EditableText).first;
  return DifyDialogFrame.maybeOf(t.element(title));
}

String _tc(String key) => DifyI18n.tr('common', key);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final portrait in phoneSizes) {
    final landscape = Size(portrait.height, portrait.width);
    final at = '${portrait.width.toInt()}x${portrait.height.toInt()}';
    for (final startPortrait in [true, false]) {
      testWidgets('$at: Name this version opened in ${startPortrait ? 'portrait' : 'landscape'} re-presents on each '
          'rotation (sheet in portrait, centred dialog in landscape) and keeps the typed title and notes', (t) async {
        final nav = await _app(t, startPortrait ? portrait : landscape);
        VersionInfoUpdate? saved;
        unawaited(showVersionInfoModal(nav.currentContext!, onPublish: (v) => saved = v));
        await settle(t, 600);
        DifyDialogForm expected(bool p) => p ? DifyDialogForm.sheet : DifyDialogForm.dialog;
        expect(_form(t), expected(startPortrait));
        final fields = find.byType(EditableText);
        await t.enterText(fields.at(0), 'v1');
        await t.enterText(fields.at(1), 'notes');
        await settle(t, 200);
        var isPortrait = startPortrait;
        for (var i = 0; i < 3; i++) {
          isPortrait = !isPortrait;
          await _rotate(t, isPortrait ? portrait : landscape);
          expect(_form(t), expected(isPortrait), reason: 'rotation ${i + 1}');
          expect(find.byType(DifySheetHeader), isPortrait ? findsOneWidget : findsNothing);
          expect(t.widget<EditableText>(fields.at(0)).controller.text, 'v1', reason: 'rotation ${i + 1}: the title');
          expect(t.widget<EditableText>(fields.at(1)).controller.text, 'notes', reason: 'rotation ${i + 1}: notes');
          if (!isPortrait) {
            // Centred in the landscape window.
            final box = t.getRect(
              find
                  .ancestor(
                    of: fields.first,
                    matching: find.byWidgetPredicate((w) => w is DifySurface || w is DifyDialogSurface),
                  )
                  .last,
            );
            expect((box.center.dx - landscape.width / 2).abs(), lessThan(1), reason: 'centred: $box');
          }
        }
        // In a short landscape window the centred dialog scrolls to its Save (Dify's dialog body, at 80 % height).
        final save = find.widgetWithText(DifyButton, _tc('operation.save'));
        await t.ensureVisible(save);
        await settle(t, 300);
        await t.tap(save);
        await settle(t, 600);
        expect(saved?.title, 'v1');
        expect(saved?.releaseNotes, 'notes');
        expect(find.byType(EditableText), findsNothing);
        // Back after the rotations closes nothing more (the dialog is gone).
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('$at: a confirmation stays centred in portrait and in landscape', (t) async {
      final nav = await _app(t, portrait);
      final answer = showDifyConfirm(nav.currentContext!, title: 'Delete?');
      await settle(t, 600);
      Rect box() => t.getRect(find.byType(DifyAlertDialog));
      expect(find.byType(DifySheetHeader), findsNothing);
      expect((box().center.dx - portrait.width / 2).abs(), lessThan(1));
      await _rotate(t, landscape);
      expect(find.byType(DifySheetHeader), findsNothing);
      expect((box().center.dx - landscape.width / 2).abs(), lessThan(1));
      await t.tap(find.widgetWithText(DifyButton, _tc('operation.cancel')));
      await settle(t, 600);
      expect(await answer, isFalse);
    });
  }
}
