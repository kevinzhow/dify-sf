import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

/// The demo backend serving the app metadata of an imported Dify chatflow, or failing to.
class _MetaDemoBackend extends DemoBackend {
  _MetaDemoBackend(this._meta, {this.delay = Duration.zero, super.server}) : super(withBo: false);
  final DocMeta? _meta;

  /// How long the metadata takes to arrive (it may come after the document is shown).
  final Duration delay;

  @override
  Future<DocMeta> docMeta(String docId) async {
    await Future<void>.delayed(delay);
    return _meta ?? (throw TransportException('HTTP 404', statusCode: 404));
  }
}

const _chatflow = DocMeta(
  appMode: 'advanced-chat',
  appName: 'Chat',
  // What the server's meta said when it was fetched; the editor takes the variables from the document (protocol 1.7).
  environmentVariables: [
    {'id': 'e0', 'name': 'stale-meta', 'value': 'x', 'value_type': 'string'},
  ],
);

/// The example workflow with the app's variables in its document-level registers (as an import puts them).
FakeServer _serverWithVariables() {
  final doc = Templates.example();
  return FakeServer(
    initial: Document(
      nodes: doc.nodes.values,
      edges: doc.edges.values,
      app: {
        AppRegisters.environmentVariables: VItems([
          Item('e1', Value.of({'id': 'e1', 'name': 'region', 'value': 'eu', 'value_type': 'string'})),
        ]),
        AppRegisters.conversationVariables: VItems([
          Item('c1', Value.of({'id': 'c1', 'name': 'str', 'value': 'default', 'value_type': 'string'})),
        ]),
      },
    ),
  );
}

String _tr(String key) => DifyI18n.tr('workflow', key);

Future<void> _open(WidgetTester t, DemoBackend backend) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: EditorPage(backend: backend, docId: 'demo', clientId: 'me-abc123', journaled: false),
    ),
  );
  for (var i = 0; i < 20; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _close(WidgetTester t, DemoBackend backend) async {
  await t.pumpWidget(const SizedBox());
  await backend.dispose();
  await t.pump(const Duration(seconds: 20));
}

WorkflowStore _store(WidgetTester t) => WorkflowStoreScope.of(t.element(find.byKey(const ValueKey('node-start'))));

void main() {
  testWidgets('a chatflow document shows Preview and Features instead of Test Run; its variables are in the store', (
    t,
  ) async {
    for (final delay in [Duration.zero, const Duration(seconds: 3)]) {
      final backend = _MetaDemoBackend(_chatflow, delay: delay, server: _serverWithVariables());
      await _open(t, backend);
      if (delay > Duration.zero) {
        expect(find.text(_tr('common.run')), findsOneWidget, reason: 'a workflow until the metadata arrives');
        await t.pump(delay);
        await t.pump();
      }
      expect(find.text(_tr('common.debugAndPreview')), findsOneWidget);
      expect(find.text(_tr('common.features')), findsOneWidget);
      expect(find.text(_tr('common.run')), findsNothing);
      expect(_store(t).environmentVariables.value.single['name'], 'region', reason: "the document's, not the meta's");
      expect(_store(t).conversationVariables.value.single['name'], 'str');
      await _close(t, backend);
    }
  });

  testWidgets('a workflow, or metadata that cannot be read, shows Test Run; the document opens either way', (t) async {
    for (final backend in [DemoBackend(withBo: false), _MetaDemoBackend(null)]) {
      await _open(t, backend);
      expect(find.byKey(const ValueKey('node-start')), findsOneWidget);
      expect(find.text(_tr('common.run')), findsOneWidget);
      expect(find.text(_tr('common.debugAndPreview')), findsNothing);
      expect(_store(t).environmentVariables.value, isEmpty);
      await _close(t, backend);
    }
  });
}
