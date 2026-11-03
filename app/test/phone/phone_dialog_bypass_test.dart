// Dialogs that bypassed the shared dialog primitive on phones (fixes after PR #90, item 3), now under its policy: forms
// are sheets (the sheet's header with its close, Back closes them first), confirmations stay centred over the window
// and Back cancels only them. The annotation drawers and their remove confirmation, Debug & Preview's conversation
// variables, and the confirmations nested in Create from DSL and the conversation opener; at 411x914 and 360x780.
import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppImport, AppImportStatus, AppModes;
import 'package:dify_sf_app/src/app_detail/annotations/annotation_modals.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/studio/app_modals.dart' show DSLConfirmModal;
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/features/conversation_opener.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/debug_and_preview.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

Future<GlobalKey<NavigatorState>> _app(WidgetTester t, Size size, Widget home) async {
  phoneWindow(t, size: size);
  final nav = GlobalKey<NavigatorState>();
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: nav,
      home: DifyPage(edgeToEdge: true, body: home),
    ),
  );
  await settle(t, 600);
  return nav;
}

/// Android's back button.
Future<bool> _back(WidgetTester t) async {
  final handled = await t.binding.handlePopRoute();
  await settle(t, 600);
  return handled;
}

final _header = find.byType(DifySheetHeader);

/// [f]'s box is centred in the window ([size]) and inside it.
void _centred(WidgetTester t, Finder f, Size size) {
  final r = t.getRect(f);
  expect((r.center.dx - size.width / 2).abs(), lessThan(1), reason: '$r');
  expect(r.left >= 0 && r.right <= size.width, isTrue, reason: '$r');
}

String _a(String key) => DifyI18n.tr('app-annotation', key);
String _tc(String key) => DifyI18n.tr('common', key);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final size in phoneSizes) {
    final at = '${size.width.toInt()}x${size.height.toInt()}';

    testWidgets('$at: Edit Annotation Reply is a sheet (header and close); its remove confirmation is centred over the '
        'window, Back cancels only it, then Back closes the sheet', (t) async {
      var hidden = 0, removed = 0;
      late StateSetter set;
      var show = true;
      await _app(
        t,
        size,
        StatefulBuilder(
          builder: (context, s) {
            set = s;
            return EditAnnotationModal(
              isShow: show,
              onHide: () => s(() {
                hidden++;
                show = false;
              }),
              annotationId: 'a1',
              query: 'What is Dify?',
              answer: 'An LLM app platform.',
              onEdited: (_, _) {},
              onRemove: () => removed++,
              editAnnotation: (id, {required question, required answer, messageId}) async {},
              createdAt: 1700000000,
            );
          },
        ),
      );
      final title = _a('editModal.title');
      expect(
        find.descendant(of: _header, matching: find.text(title)),
        findsOneWidget,
        reason: 'the sheet header',
      );
      final close = find.descendant(of: _header, matching: find.byType(DifyTouchIconButton));
      expect(t.getSize(close).height, greaterThanOrEqualTo(44));
      // The remove confirmation: centred, over the window.
      await t.tap(find.text(_a('editModal.removeThisCache')));
      await settle(t, 600);
      final confirm = find.byKey(const ValueKey('annotation-alert-dialog'));
      expect(confirm, findsOneWidget);
      _centred(t, confirm, size);
      expect(await _back(t), isTrue);
      expect(confirm, findsNothing, reason: 'Back cancels the confirmation');
      expect(hidden, 0, reason: 'and only it');
      expect(removed, 0);
      expect(find.descendant(of: _header, matching: find.text(title)), findsOneWidget);
      // Back again: the sheet.
      expect(await _back(t), isTrue);
      expect(hidden, 1);
      set(() {});
      await settle(t, 600);
      expect(_header, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('$at: Add Annotation Reply is a sheet; its close hides it', (t) async {
      var hidden = 0;
      await _app(
        t,
        size,
        StatefulBuilder(
          builder: (context, s) => AddAnnotationModal(
            isShow: hidden == 0,
            onHide: () => s(() => hidden++),
            onAdd: (_) async {},
          ),
        ),
      );
      final title = _a('addModal.title');
      expect(find.descendant(of: _header, matching: find.text(title)), findsOneWidget);
      // The fields are on the sheet, inside the window.
      final field = find.byType(EditableText).first;
      final r = t.getRect(field);
      expect(r.left >= 0 && r.right <= size.width, isTrue, reason: '$r');
      // A rotation re-presents it (the drawer in landscape, the sheet again in portrait), keeping what was typed and
      // the focus.
      await t.tap(field);
      t.testTextInput.enterText('Draft question');
      await settle(t, 300);
      final node = t.widget<EditableText>(field).focusNode;
      for (final (w, h, sheet) in [(size.height, size.width, false), (size.width, size.height, true)]) {
        t.view.physicalSize = Size(w, h);
        await settle(t, 600);
        expect(_header, sheet ? findsOneWidget : findsNothing, reason: '${w}x$h');
        expect(t.widget<EditableText>(field).controller.text, 'Draft question', reason: '${w}x$h');
        expect(t.widget<EditableText>(field).focusNode, same(node));
        expect(node.hasFocus, isTrue, reason: '${w}x$h: the field keeps the focus');
      }
      await t.tap(find.descendant(of: _header, matching: find.byType(DifyTouchIconButton)));
      await settle(t, 600);
      expect(hidden, 1);
      expect(_header, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets("$at: Debug & Preview's conversation variables open as a sheet (rows of 48, the value under them); "
        'Back closes it and tells the panel', (t) async {
      final nav = await _app(t, size, const SizedBox.expand());
      var hidden = 0;
      unawaited(
        showDifyDialog<void>(
          nav.currentContext!,
          dismissible: false,
          closeOnEscape: false,
          builder: (dialog) => ConversationVariableModal(
            conversationId: 'c1',
            varList: const [
              {'id': 'v1', 'name': 'session_state', 'value_type': 'string', 'value': 'draft'},
              {'id': 'v2', 'name': 'summary', 'value_type': 'string', 'value': 'plain text'},
            ],
            fetchValues: (_) async => const [
              {'id': 'v1', 'value': 'draft'},
              {'id': 'v2', 'value': 'plain text'},
            ],
            onHide: () {
              hidden++;
              Navigator.of(dialog).pop();
            },
          ),
        ),
      );
      await settle(t, 800);
      expect(
        find.descendant(of: _header, matching: find.text(DifyI18n.tr('workflow', 'chatVariable.panelTitle'))),
        findsOneWidget,
      );
      final row = find.ancestor(of: find.text('summary'), matching: find.byType(DifyPressable)).first;
      expect(t.getSize(row).height, greaterThanOrEqualTo(48));
      expect(t.getRect(row).right, lessThanOrEqualTo(size.width));
      await t.tap(row);
      await settle(t, 400);
      expect(find.text('plain text'), findsOneWidget, reason: 'the selected value');
      await t.tap(find.descendant(of: _header, matching: find.byType(DifyTouchIconButton)));
      await settle(t, 600);
      expect(hidden, 1);
      expect(_header, findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('$at: Create from DSL\'s version confirmation is centred over the window (not inside the sheet); Back '
        'cancels only it; Confirm closes both', (t) async {
      final nav = await _app(t, size, const SizedBox.expand());
      final confirms = <String>[];
      var closed = 0;
      Future<void> open() async {
        unawaited(
          showCreateFromDSLModal(
            nav.currentContext!,
            (close) => CreateFromDSLModal(
              activeTab: CreateFromDSLModalTab.fromUrl,
              dslUrl: 'https://example.com/app.yml',
              onClose: () {
                closed++;
                close();
              },
              importDsl: (_) async => AppImport(
                id: 'import-1',
                status: AppImportStatus.pending,
                importedDslVersion: '1.0.0',
                currentDslVersion: '2.0.0',
              ),
              confirmImport: (id) async {
                confirms.add(id);
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
      }

      await open();
      final confirm = find.byType(DSLConfirmModal);
      expect(confirm, findsOneWidget);
      final card = find.descendant(of: confirm, matching: find.byType(DifyAlertDialog));
      _centred(t, card, size);
      expect(find.ancestor(of: confirm, matching: find.byType(DifySheetHeader)), findsNothing);
      final button = find.byKey(const ValueKey('dsl-confirm-confirm'));
      expect(t.getSize(button).height, greaterThanOrEqualTo(44));
      // Back: the confirmation only.
      expect(await _back(t), isTrue);
      expect(confirm, findsNothing);
      expect(find.byKey(const ValueKey('dsl-create')), findsOneWidget, reason: 'the dialog stays');
      expect(closed, 0);
      // Asked again; Confirm imports and closes the confirmation and the dialog.
      await t.tap(find.byKey(const ValueKey('dsl-create')));
      await settle(t, 800);
      await t.tap(find.byKey(const ValueKey('dsl-confirm-confirm')));
      await settle(t, 1000);
      expect(confirms, ['import-1']);
      expect(closed, 1);
      expect(confirm, findsNothing);
      expect(find.byKey(const ValueKey('dsl-create')), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('$at: the conversation opener\'s "add these variables?" is centred over the window; Back cancels only '
        'it; Add adds and saves', (t) async {
      final nav = await _app(t, size, const SizedBox.expand());
      final saved = <Map<String, Object?>>[];
      final added = <List<Map<String, Object?>>>[];
      unawaited(
        showDifyDialog<void>(
          nav.currentContext!,
          dismissible: false,
          builder: (dialog) => OpeningSettingModal(
            data: const {'enabled': true, 'opening_statement': 'Hello {{city}}', 'suggested_questions': <String>[]},
            promptVariables: const [
              {'key': 'name', 'name': 'name', 'type': 'string'},
            ],
            workflowVariables: const [],
            onAutoAddPromptVariable: added.add,
            onSave: (v) {
              saved.add(v);
              Navigator.of(dialog).pop();
            },
            onCancel: () => Navigator.of(dialog).pop(),
          ),
        ),
      );
      await settle(t, 800);
      final save = find.widgetWithText(DifyButton, _tc('operation.save'));
      await t.ensureVisible(save);
      await settle(t, 300);
      await t.tap(save);
      await settle(t, 800);
      final ask = find.byType(ConfirmAddVar);
      expect(ask, findsOneWidget);
      _centred(t, ask, size);
      expect(await _back(t), isTrue);
      expect(ask, findsNothing, reason: 'Back closes the question');
      expect(saved, isEmpty, reason: 'nothing saved');
      expect(save, findsOneWidget, reason: 'the opener stays');
      await t.tap(save);
      await settle(t, 800);
      await t.tap(find.descendant(of: ask, matching: find.widgetWithText(DifyButton, _tc('operation.add'))));
      await settle(t, 800);
      expect(added.single.single['key'], 'city');
      expect(saved.single['opening_statement'], 'Hello {{city}}');
      expect(t.takeException(), isNull);
    });
  }
}
