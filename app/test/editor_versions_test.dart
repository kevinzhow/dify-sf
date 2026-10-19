import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/editor_versions.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/version_history/version_history_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

/// An app on the shared in-memory apps server (protocol 1.11 fakes), opened like the editor opens it: a demo backend
/// on the app's document server.
Future<({FakeAppsApi apps, FakeVersionsApi versions, String id, DemoBackend demo})> _app() async {
  final apps = FakeAppsApi(accountId: 'a1', accountName: 'Mo', clock: () => _now);
  final app = await apps.create(name: 'Flow', mode: AppModes.workflow);
  return (
    apps: apps,
    versions: FakeVersionsApi(apps),
    id: app.id,
    demo: DemoBackend(server: apps.server(app.id), withBo: false),
  );
}

var _now = DateTime.utc(2026, 10, 19, 8);

/// Moves the fake clock on (versions are timed in seconds).
void _tick() => _now = _now.add(const Duration(minutes: 1));

Future<void> _settle(WidgetTester t, [int ms = 2000]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<EditorController> _controller(DemoBackend demo, String id) async {
  final opened = await demo.openSession(id, clientId: 'me-abc123', journaled: false);
  await opened.session.start();
  final controller = EditorController(session: opened.session, docId: id, journaled: false);
  addTearDown(() async {
    controller.dispose();
    await opened.close();
  });
  for (var i = 0; i < 50 && !controller.ready; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  return controller;
}

void main() {
  test('publish, list, rename, delete, browse and restore over the versions API', () async {
    final f = await _app();
    addTearDown(f.demo.dispose);
    final controller = await _controller(f.demo, f.id);
    final saved = <(String, String)>[];
    final versions = EditorVersions(
      api: f.versions,
      controller: controller,
      appName: 'Support Bot',
      saveDsl: (name, yaml) async => saved.add((name, yaml)),
    );
    addTearDown(versions.dispose);
    final start = controller.doc.nodes.keys.single;

    await versions.refreshPublished();
    expect(versions.loaded, isTrue);
    expect(versions.published, isNull, reason: 'never published');
    expect((await versions.fetchVersions(page: 1, limit: 10, userId: '', namedOnly: false)).items, isEmpty);

    // Publishing answers Dify's {result, created_at} and refetches the published version.
    _tick();
    final res = await versions.publish(title: 'First', releaseNotes: 'Notes');
    expect(res['result'], 'success');
    expect(res['created_at'], _now.millisecondsSinceEpoch ~/ 1000);
    final v1 = versions.published!;
    expect(versions.publishedInfo?.markedName, 'First');
    expect(versions.publishedInfo?.markedComment, 'Notes');
    expect(publishedGraphHasUserInput(v1.graph), isFalse, reason: 'a lone Start node');

    // A second version: the draft with an End node after the Start node.
    final end = controller.addNode('end', x: 400, y: 282);
    controller.connect(start, end);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    _tick();
    await versions.publish();
    final v2 = versions.published!;
    expect(v2.id, isNot(v1.id));
    expect(publishedGraphHasUserInput(v2.graph), isTrue);

    // The list: the draft first, then the versions newest first (Dify's JSON for the panel); the filters pass through.
    final page = await versions.fetchVersions(page: 1, limit: 10, userId: '', namedOnly: false);
    expect([for (final i in page.items) i['id']], [f.id, v2.id, v1.id]);
    expect(page.items.first['version'], 'draft');
    final named = await versions.fetchVersions(page: 1, limit: 10, userId: 'a1', namedOnly: true);
    expect([for (final i in named.items) i['id']], [v1.id]);

    // Renaming the published version refetches it.
    await versions.updateVersion(v2.id, title: 'Second', releaseNotes: '');
    expect(versions.published?.markedName, 'Second');

    // Exporting one version (Dify's handleExportDSL(false, id)): that version's file, saved as `<app name>.yml`.
    await versions.exportVersion(v1.id);
    expect(saved.single.$1, 'Support Bot.yml');
    expect(saved.single.$2, contains('kind'));
    expect(saved.single.$2, isNot(contains('"end"')));

    // Browsing shows a version read-only (`GET .../workflows/{id}`, its document); the draft comes back.
    await versions.showVersion(v1.toJson());
    expect(controller.previewing, isTrue);
    expect(controller.doc.nodes.keys.toSet(), {start});
    versions.showDraft();
    expect(controller.previewing, isFalse);
    expect(controller.doc.nodes.keys.toSet(), {start, end});

    // Restoring replaces the document through the session (ordinary ops), clears undo and leaves the preview.
    expect(controller.undo.canUndo, isTrue);
    await versions.showVersion(v1.toJson());
    await versions.restore(v1.id);
    expect(controller.previewing, isFalse);
    expect(controller.undo.canUndo, isFalse);
    expect(f.apps.server(f.id).doc.nodes.keys.toSet(), {start});
    expect(controller.doc.nodes.keys.toSet(), {start});
    expect(versions.published?.id, v2.id, reason: 'restoring does not publish');

    // The published version cannot be deleted; an older one can.
    await expectLater(versions.deleteVersion(v2.id), throwsA(isA<TransportException>()));
    await versions.deleteVersion(v1.id);
    final left = await versions.fetchVersions(page: 1, limit: 10, userId: '', namedOnly: false);
    expect([for (final i in left.items) i['id']], [f.id, v2.id]);
  });

  testWidgets('the editor publishes, shows the published time, browses versions on the canvas and restores one', (
    t,
  ) async {
    await useAppFonts();
    t.view.physicalSize = const Size(1600, 900);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final f = await t.runAsync(_app);
    final (:apps, :versions, :id, :demo) = f!;
    _tick();
    await t.runAsync(() => versions.publish(id, markedName: 'Launch'));
    final v1 = (await t.runAsync(() => versions.published(id)))!;
    await t.pumpWidget(
      MaterialApp(
        theme: ThemeData(fontFamily: 'Noto Sans'),
        home: EditorPage(
          backend: demo,
          docId: id,
          clientId: 'me-abc123',
          journaled: false,
          account: Account(id: 'a1', email: 'm@example.com', name: 'Mo', role: AccountRole.owner),
          versions: versions,
        ),
      ),
    );
    await _settle(t);

    // use-workflow-init: the published version's time and its connected Start node, into the store.
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowHeader)));
    expect(store.publishedAt.value, v1.createdAt * 1000);
    expect(store.lastPublishedHasUserInput.value, isFalse);

    // The publisher shows the published version; "Publish update" publishes the draft.
    final controller = t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
    expect(store.checklistItems.value, isEmpty);
    await t.tap(find.text('common.publish').first);
    await _settle(t, 500);
    expect(find.text('Launch'), findsOneWidget, reason: "the summary: the published version's name");
    _tick();
    await t.tap(find.text('common.publishUpdate'));
    await _settle(t, 1000);
    expect(apps.requests['versions.publish'], 2);
    final v2 = (await t.runAsync(() => versions.published(id)))!;
    expect(v2.id, isNot(v1.id));
    expect(store.publishedAt.value, v2.createdAt * 1000);
    await t.tapAt(const Offset(800, 600));
    await _settle(t, 500);

    // The draft moves on: a node only it has.
    final start = controller.doc.nodes.keys.single;
    final end = controller.addNode('end', x: 400, y: 282);
    await _settle(t, 500);
    expect(find.byKey(ValueKey('node-$end')), findsOneWidget);

    // Version History: the list from the server; a click shows the version on the canvas, read-only.
    await t.tap(find.byType(VersionHistoryButton));
    await _settle(t, 1000);
    expect(find.byType(VersionHistoryPanel), findsOneWidget);
    expect(find.byType(VersionHistoryItem), findsNWidgets(3), reason: 'the draft, then v2 and v1');
    await t.tap(find.widgetWithText(VersionHistoryItem, 'Launch'));
    await _settle(t, 1000);
    expect(store.currentVersion.value?['id'], v1.id);
    expect(controller.previewing, isTrue);
    expect(find.byKey(ValueKey('node-$end')), findsNothing, reason: 'v1 has no End node');

    // The restoring header's Restore replaces the draft with it.
    await t.tap(find.descendant(of: find.byType(HeaderInRestoring), matching: find.text('common.restore')));
    await _settle(t);
    expect(apps.requests['versions.restore'], 1);
    expect(apps.server(id).doc.nodes.keys.toSet(), {start});
    expect(store.isRestoring.value, isFalse);
    expect(controller.previewing, isFalse);

    await t.pumpWidget(const SizedBox());
    await t.runAsync(demo.dispose);
    await t.pump(const Duration(seconds: 20));
  });
}
