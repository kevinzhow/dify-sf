// dify-spec: web/app/components/app/create-from-dsl-modal/__tests__/index.spec.tsx
import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Tristate;

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeAppsApi;
import 'package:dify_sf_app/src/design/widgets/widgets.dart' show DifyKbd;
import 'package:dify_sf_app/src/studio/app_modals.dart' show DSLConfirmModal;
import 'package:dify_sf_app/src/studio/create_from_dsl_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Dify's mocks: `POST /apps/imports` and its confirm answer what the test sets.
class _Calls {
  final imports = <String>[];
  final confirms = <String>[];
  final imported = <AppImport>[];
  final urls = <String>[];
  int closes = 0, successes = 0;
  FutureOr<AppImport> Function(String yaml) onImport = (_) => _completed('app-1');
  FutureOr<AppImport> Function(String id) onConfirm = (_) => _completed('app-confirmed');
}

AppImport _completed(String appId, {String mode = AppModes.workflow, String status = AppImportStatus.completed}) =>
    AppImport(id: 'import-x', status: status, appId: appId, appMode: mode, currentDslVersion: '0.7.0');

AppImport _pending(String id) => AppImport(
  id: id,
  status: AppImportStatus.pending,
  importedDslVersion: '1.0.0',
  currentDslVersion: '2.0.0',
);

Future<_Calls> _render(
  WidgetTester t, {
  String activeTab = CreateFromDSLModalTab.fromFile,
  String dslUrl = '',
  DslFileData? droppedFile,
  _Calls? calls,
}) async {
  final c = calls ?? _Calls();
  await renderMembers(
    t,
    CreateFromDSLModal(
      activeTab: activeTab,
      dslUrl: dslUrl,
      droppedFile: droppedFile,
      onClose: () => c.closes++,
      onSuccess: () => c.successes++,
      importDsl: (yaml) async {
        c.imports.add(yaml);
        return c.onImport(yaml);
      },
      confirmImport: (id) async {
        c.confirms.add(id);
        return c.onConfirm(id);
      },
      onImported: (r) async => c.imported.add(r),
      fetchUrl: (url) async {
        c.urls.add(url);
        return 'app: demo';
      },
    ),
  );
  return c;
}

Finder _urlInput() => find.descendant(of: find.byKey(const ValueKey('dsl-url')), matching: find.byType(EditableText));

bool _focusIn(Finder f) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final targets = f.evaluate().toSet();
  var inside = targets.contains(focused);
  focused.visitAncestorElements((e) {
    if (targets.contains(e)) inside = true;
    return !inside;
  });
  return inside;
}

Future<void> _modEnter(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await settle(t);
}

Future<void> _escape(WidgetTester t) async {
  await t.sendKeyEvent(LogicalKeyboardKey.escape);
  await settle(t);
}

Future<void> _focusUrl(WidgetTester t) async {
  await t.tap(_urlInput());
  await t.pump();
}

void main() {
  group('CreateFromDSLModal', () {
    testWidgets('should render the file tab and show the dropped file', (t) async {
      await _render(t, droppedFile: dslFileOf('demo.yml', 'app: demo'));
      expect(find.text('app.importApp'), findsOneWidget);
      expect(find.text('demo.yml'), findsOneWidget);
    });

    testWidgets('should switch tabs, close from the header icon, and ignore shortcuts without valid input', (t) async {
      final c = await _render(t);
      await _modEnter(t);
      expect(c.imports, isEmpty);
      await t.tap(find.byKey(const ValueKey('dsl-tab-from-url')));
      await settle(t);
      expect(find.text('app.importFromDSLUrlPlaceholder'), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('dsl-close')));
      await settle(t);
      expect(c.closes, 1);
    });

    testWidgets('should expose the URL as a named form field', (t) async {
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl);
      final field = t.widget<TextField>(
        find.descendant(of: find.byKey(const ValueKey('dsl-url')), matching: find.byType(TextField)),
      );
      expect(field.keyboardType, TextInputType.url);
      expect(
        find.semantics.byPredicate(
          (n) => n.getSemanticsData().flagsCollection.isTextField && n.label.contains('app.importFromDSLUrl'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('should initially focus Browse when the file import dialog opens, without a focus ring', (t) async {
      await _render(t);
      expect(_focusIn(find.byKey(const ValueKey('dsl-browse'))), isTrue);
      // `initialFocus` with `focusVisible: false`: focused, but the ring waits for the keyboard (the comparison
      // against Dify's dialog showed ours drawing it on open).
      final box = t.widget<Container>(
        find.descendant(of: find.byKey(const ValueKey('dsl-browse')), matching: find.byType(Container)).first,
      );
      expect((box.decoration as BoxDecoration?)?.border, isNull);
    });

    testWidgets('should move focus from each active tab directly to its first panel control', (t) async {
      await _render(t);
      await t.tap(find.byKey(const ValueKey('dsl-tab-from-file')));
      await t.pump();
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(_focusIn(find.byKey(const ValueKey('dsl-browse'))), isTrue);
      await t.tap(find.byKey(const ValueKey('dsl-tab-from-url')));
      await settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(_focusIn(find.byKey(const ValueKey('dsl-url'))), isTrue);
    });

    testWidgets('should render the import shortcut with kbd primitives', (t) async {
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml');
      expect(
        find.descendant(of: find.byKey(const ValueKey('dsl-create')), matching: find.byType(DifyKbd)),
        findsNWidgets(2),
      );
    });

    testWidgets('should import from a URL and redirect after a successful import', (t) async {
      final c = await _render(t, activeTab: CreateFromDSLModalTab.fromUrl);
      await t.enterText(_urlInput(), 'https://example.com/app.yml');
      await tapButton(t, 'app.newApp.Create');
      expect(c.urls, ['https://example.com/app.yml']);
      expect(c.imports, ['app: demo']);
      expect((c.successes, c.closes), (1, 1));
      expect(c.imported.single.appId, 'app-1', reason: 'the new app opens (getRedirection)');
    });

    testWidgets('should pass creator context when import response has no permission keys', (t) async {
      // The import answer has no permission keys: the page reads the new app (its creator's keys) and opens it.
      final f = await StudioFixture.create();
      final calls = await renderStudio(t, f);
      calls.urlContent = jsonEncode(FakeAppsApi.seedDsl(AppModes.workflow));
      unawaited(studioState(t).openImportDsl());
      await settle(t);
      await t.tap(find.byKey(const ValueKey('dsl-tab-from-url')));
      await settle(t);
      await t.enterText(_urlInput(), 'https://example.com/app.yml');
      await tapButton(t, 'app.newApp.Create');
      await settle(t);
      final opened = calls.opened.single;
      expect(opened.app.mode, AppModes.workflow);
      expect(opened.app.permissionKeys, AppPermissionKeys.forRole(AccountRole.owner));
      expect(opened.path, endsWith('/workflow'));
    });

    testWidgets('should import from a file with the loaded file content', (t) async {
      final c = _Calls()
        ..onImport = (_) => AppImport(
          id: 'import-2',
          status: AppImportStatus.completedWithWarnings,
          appId: 'app-2',
          appMode: AppModes.workflow,
          currentDslVersion: '0.7.0',
          warnings: const [
            {'code': 'agent_secret_required', 'message': "Agent secret 'SEARCH_TOKEN' must be configured."},
          ],
        );
      await _render(t, droppedFile: dslFileOf('demo.yml', 'app: demo'), calls: c);
      expect(find.text('demo.yml'), findsOneWidget);
      await tapButton(t, 'app.newApp.Create');
      expect(c.imports, ['app: demo']);
      expect(find.text('app.newApp.caution'), findsOneWidget);
      expect(find.text("Agent secret 'SEARCH_TOKEN' must be configured."), findsOneWidget);
    });

    testWidgets('should lock the complete file import while reading its content', (t) async {
      final reading = Completer<String>();
      var reads = 0;
      final c = await _render(
        t,
        droppedFile: (
          name: 'demo.yml',
          size: 9,
          read: () {
            reads++;
            return reading.future;
          },
        ),
      );
      await tapButton(t, 'app.newApp.Create');
      expect(reads, 1);
      expect(isEnabled('app.newApp.Create'), isFalse);
      await t.tap(find.byKey(const ValueKey('dsl-create')), warnIfMissed: false);
      await t.tap(find.byKey(const ValueKey('dsl-cancel')), warnIfMissed: false);
      await _escape(t);
      expect(reads, 1);
      expect(c.imports, isEmpty);
      expect(c.closes, 0);
      reading.complete('app: demo');
      await settle(t);
      expect(c.imports, ['app: demo']);
    });

    testWidgets('should remove the current file and keep the create shortcut guarded', (t) async {
      final c = await _render(t, droppedFile: dslFileOf('demo.yml', 'app: demo'));
      await tapButton(t, 'common.operation.delete');
      expect(find.text('demo.yml'), findsNothing);
      expect(isEnabled('app.newApp.Create'), isFalse);
      await _modEnter(t);
      expect(c.imports, isEmpty);
    });

    testWidgets('should show the DSL mismatch modal and confirm a pending import', (t) async {
      final c = _Calls()
        ..onImport = ((_) => _pending('import-3'))
        ..onConfirm = ((_) => _completed('app-3'));
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsOneWidget);
      await tapButton(t, 'app.newApp.Confirm');
      expect(c.confirms, ['import-3']);
      expect(c.imported.single.appId, 'app-3');
      expect(find.byType(DSLConfirmModal), findsNothing);
    });

    testWidgets('should close the DSL mismatch modal when dialog requests close', (t) async {
      final c = _Calls()..onImport = ((_) => _pending('import-close'));
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsOneWidget);
      await _escape(t);
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsNothing);
      expect(c.closes, 0, reason: 'only the confirmation closes');
    });

    testWidgets('should close the DSL mismatch modal when cancel is clicked', (t) async {
      final c = _Calls()..onImport = ((_) => _pending('import-cancel'));
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      await t.tap(find.byKey(const ValueKey('dsl-confirm-cancel')));
      await settle(t);
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsNothing);
    });

    testWidgets('should show import progress and lock dialog interactions while a request is in flight', (t) async {
      final gate = Completer<AppImport>();
      final c = _Calls()..onImport = ((_) => gate.future);
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await _focusUrl(t);
      await tapButton(t, 'app.newApp.Create');
      expect(c.imports, hasLength(1));
      expect(isEnabled('app.newApp.Create'), isFalse);
      await t.tap(find.byKey(const ValueKey('dsl-create')), warnIfMissed: false);
      await settle(t);
      expect(c.imports, hasLength(1));
      expect(isEnabled('app.importFromDSLFile'), isFalse, reason: 'the tabs are locked');
      await t.tap(find.byKey(const ValueKey('dsl-cancel')), warnIfMissed: false);
      await _escape(t);
      expect(c.closes, 0);
      gate.complete(_completed('app-1'));
      await settle(t);
      expect(c.closes, 1);
    });

    testWidgets('should show confirmation progress and prevent cancellation while confirming', (t) async {
      final gate = Completer<AppImport>();
      final c = _Calls()
        ..onImport = ((_) => _pending('import-confirming'))
        ..onConfirm = ((_) => gate.future);
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      await tapButton(t, 'app.newApp.Confirm');
      expect(c.confirms, hasLength(1));
      expect(isEnabled('app.newApp.Confirm'), isFalse, reason: 'loading');
      await t.tap(find.byKey(const ValueKey('dsl-confirm-confirm')), warnIfMissed: false);
      await settle(t);
      expect(c.confirms, hasLength(1));
      final cancel = find.byKey(const ValueKey('dsl-confirm-cancel'));
      expect(
        find.semantics
            .byPredicate(
              (n) =>
                  n.getSemanticsData().flagsCollection.isButton &&
                  n.label == 'app.newApp.Cancel' &&
                  n.getSemanticsData().flagsCollection.isEnabled != Tristate.isTrue,
            )
            .evaluate(),
        isNotEmpty,
      );
      await t.tap(cancel, warnIfMissed: false);
      await settle(t);
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsOneWidget);
      gate.complete(_completed('app-confirming'));
      await settle(t);
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsNothing);
    });

    // dify-sf has no app quota (community edition): the quota half of the case never applies.
    testWidgets('should handle keyboard shortcut and quota guard', (t) async {
      final c = await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml');
      await _focusUrl(t);
      await _modEnter(t);
      expect(c.urls, ['https://example.com/app.yml']);
      expect(c.imports, ['app: demo']);
    });

    testWidgets('should show failure toasts for failed and rejected imports', (t) async {
      var n = 0;
      final c = _Calls()
        ..onImport = (_) {
          if (n++ == 0) {
            return const AppImport(
              id: 'import-failed',
              status: AppImportStatus.failed,
              currentDslVersion: '0.7.0',
              error: 'Invalid YAML format',
            );
          }
          throw StateError('boom');
        };
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      expect(find.text('Invalid YAML format'), findsOneWidget);
      await tapButton(t, 'app.newApp.Create');
      expect(find.text('app.newApp.appCreateFailed'), findsOneWidget);
    });

    testWidgets('should handle pending import confirmation failures and cancellation', (t) async {
      var n = 0;
      final c = _Calls()
        ..onImport = ((_) => _pending('import-4'))
        ..onConfirm = (_) {
          if (n++ == 0) {
            return const AppImport(
              id: 'import-4',
              status: AppImportStatus.failed,
              currentDslVersion: '0.7.0',
              error: 'Confirm failed',
            );
          }
          throw StateError('boom');
        };
      await _render(t, activeTab: CreateFromDSLModalTab.fromUrl, dslUrl: 'https://example.com/app.yml', calls: c);
      await tapButton(t, 'app.newApp.Create');
      await t.tap(find.byKey(const ValueKey('dsl-confirm-cancel')));
      await settle(t);
      expect(find.text('app.newApp.appCreateDSLErrorTitle'), findsNothing);
      await tapButton(t, 'app.newApp.Create');
      await tapButton(t, 'app.newApp.Confirm');
      expect(find.text('Confirm failed'), findsOneWidget);
      await tapButton(t, 'app.newApp.Confirm');
      expect(find.text('app.newApp.appCreateFailed'), findsOneWidget);
    });
  });
}
