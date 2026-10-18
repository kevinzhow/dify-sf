import 'package:dify_sf_app/src/auth/auth_api.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_buttons.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

Future<void> _settle(WidgetTester t, [int ms = 2000]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<DemoBackend> _open(WidgetTester t, String role) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: EditorPage(
        backend: demo,
        docId: 'demo',
        clientId: 'me-abc123',
        journaled: false,
        account: Account(id: 'a1', email: 'm@example.com', name: 'Mo', role: role),
      ),
    ),
  );
  await _settle(t);
  return demo;
}

Future<void> _close(WidgetTester t, DemoBackend demo) async {
  await t.pumpWidget(const SizedBox());
  await demo.dispose();
  await t.pump(const Duration(seconds: 20));
}

void main() {
  for (final role in [AccountRole.normal, AccountRole.datasetOperator]) {
    testWidgets('a $role member sees the workflow read-only (Dify: canEdit false -> nodesReadOnly)', (t) async {
      final demo = await _open(t, role);
      final store = WorkflowStoreScope.of(t.element(find.byKey(const ValueKey('node-llm'))));
      expect(store.canvasReadOnly.value, isTrue);
      expect(find.byType(VersionHistoryButton), findsNothing, reason: 'canReleaseAndVersion is off');

      // Nodes do not move and Delete does nothing.
      final before = demo.server.doc.nodes['llm']!;
      await t.drag(find.byKey(const ValueKey('node-llm')), const Offset(100, 60));
      await _settle(t);
      await t.sendKeyEvent(LogicalKeyboardKey.delete);
      await _settle(t);
      final after = demo.server.doc.nodes['llm'];
      expect(after, isNotNull);
      expect((after!.x, after.y), (before.x, before.y));
      expect(demo.server.log, isEmpty, reason: 'no op was sent');

      // The session menu offers neither Add node nor the DSL export.
      await t.tap(find.byKey(const Key('session-menu')));
      await t.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('add-node-menu')), findsNothing);
      expect(find.byKey(const Key('export-dsl')), findsNothing);
      await _close(t, demo);
    });
  }

  testWidgets('an editor member edits (Dify: canEdit for owner, admin and editor)', (t) async {
    final demo = await _open(t, AccountRole.editor);
    final before = demo.server.doc.nodes['llm']!;
    await t.drag(find.byKey(const ValueKey('node-llm')), const Offset(100, 60));
    await _settle(t);
    expect(demo.server.doc.nodes['llm']!.x, greaterThan(before.x + 50));
    expect(find.byType(VersionHistoryButton), findsOneWidget);
    await _close(t, demo);
  });
}
