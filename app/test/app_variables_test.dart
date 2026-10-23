import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/editor/notices.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/app_fonts.dart';

/// Protocol 1.7: the app's environment and conversation variables live in the collaborative document (`$app`), so
/// several people edit them like node config, and the workflow store follows the document.

const _app = Document.appNode;
const _env = [AppRegisters.environmentVariables];

Map<String, Object?> _variable(String id, String value) => {
  'id': id,
  'name': id,
  'value': value,
  'value_type': 'string',
  'description': '',
};

Future<void> _settle(WidgetTester t, [Duration d = const Duration(seconds: 2)]) async {
  for (var i = 0; i < d.inMilliseconds ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<DemoBackend> _open(WidgetTester t) async {
  await useAppFonts();
  t.view.physicalSize = const Size(1600, 900);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final demo = DemoBackend(withBo: false);
  await t.pumpWidget(
    MaterialApp(
      theme: ThemeData(fontFamily: 'Noto Sans'),
      home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
    ),
  );
  await _settle(t);
  return demo;
}

Future<void> _close(WidgetTester t, DemoBackend demo, List<CollabSession> others) async {
  for (final s in others) {
    await s.stop();
  }
  await t.pumpWidget(const SizedBox());
  await demo.dispose();
  await t.pump(const Duration(seconds: 20));
}

EditorController _controller(WidgetTester t) =>
    t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;

WorkflowStore _store(WidgetTester t) => WorkflowStoreScope.of(t.element(find.byKey(const ValueKey('node-start'))));

/// The value of each variable in the store, by id.
Map<Object?, Object?> _values(List<DifyJson> vars) => {for (final v in vars) v['id']: v['value']};

void main() {
  testWidgets('two people edit different variables at once; a stale edit of the same one is a conflict notice', (
    t,
  ) async {
    final demo = await _open(t);
    final c = _controller(t);
    final store = _store(t);
    final bo = CollabSession(clientId: 'bo-1', transport: FakeTransport(demo.server), store: MemoryStore());
    await bo.start();
    await _settle(t, const Duration(seconds: 1));

    // I add two variables: the store shows them right away (local edit) and after the commit.
    c.insertItem(_app, _env, Value.of(_variable('a', '1')), id: 'a');
    await t.pump(); // the view's change notification (no network round trip yet)
    expect(demo.server.doc.app, isEmpty);
    expect(_values(store.environmentVariables.value), {'a': '1'}, reason: 'a local optimistic edit');
    c.insertItem(_app, _env, Value.of(_variable('b', '1')), after: 'a', id: 'b');
    await _settle(t);
    expect(demo.server.doc.app[AppRegisters.environmentVariables], isA<VItems>());
    expect(_values(store.environmentVariables.value), {'a': '1', 'b': '1'});

    // Concurrently: I change a, Bo changes b. Both commit; my store follows Bo's remote edit.
    c.updateItem(_app, _env, 'a', Value.of(_variable('a', 'mine')), base: c.seenVersion);
    bo.edit(UpdateItem(_app, _env, 'b', Value.of(_variable('b', 'bo'))));
    await _settle(t);
    expect(_values(store.environmentVariables.value), {'a': 'mine', 'b': 'bo'});
    expect(AppRegisters.variables(demo.server.doc, AppRegisters.environmentVariables).map((v) => v['value']), [
      'mine',
      'bo',
    ]);
    expect(c.notices.where((n) => n.kind == NoticeKind.conflict), isEmpty);

    // Offline, I edit a; meanwhile Bo changes a too. When I am back, mine is refused with a conflict notice and
    // Bo's value stays (in the document and in my store).
    demo.setOffline(true);
    await _settle(t, const Duration(seconds: 1));
    c.updateItem(_app, _env, 'a', Value.of(_variable('a', 'stale')), base: c.seenVersion);
    await t.pump();
    expect(_values(store.environmentVariables.value)['a'], 'stale', reason: 'my view shows my pending edit');
    bo.edit(UpdateItem(_app, _env, 'a', Value.of(_variable('a', 'bo wins'))));
    await _settle(t, const Duration(seconds: 1));
    demo.setOffline(false);
    c.reconnectNow();
    await _settle(t, const Duration(seconds: 6));
    final conflict = c.notices.where((n) => n.kind == NoticeKind.conflict).single;
    expect(conflict.reason, isA<Conflict>().having((r) => r.by, 'by', 'bo-1').having((r) => r.node, 'node', _app));
    expect(conflict.message, contains(AppRegisters.environmentVariables));
    expect(_values(store.environmentVariables.value), {'a': 'bo wins', 'b': 'bo'});
    expect(c.appLists.environmentVariables.map((v) => v['value']), ['bo wins', 'bo']);

    // Like Dify, variable edits are not workflow history: nothing to undo.
    c.setConfig(_app, [AppRegisters.features, 'opening_statement'], const VString('Hello'));
    await _settle(t);
    expect(c.undo.past, isEmpty);
    expect(c.appLists.features, {'opening_statement': 'Hello'});
    await _close(t, demo, [bo]);
  });

  testWidgets('the store follows remote edits of both variable lists; secrets are stored aside', (t) async {
    final demo = await _open(t);
    final c = _controller(t);
    final store = _store(t);
    expect(store.environmentVariables.value, isEmpty);
    final bo = CollabSession(clientId: 'bo-2', transport: FakeTransport(demo.server), store: MemoryStore());
    await bo.start();
    await _settle(t, const Duration(seconds: 1));

    bo
      ..edit(InsertItem(_app, _env, Item('e1', Value.of(_variable('e1', 'eu'))), null))
      ..edit(
        InsertItem(_app, const [AppRegisters.conversationVariables], Item('c1', Value.of(_variable('c1', 'x'))), null),
      );
    await _settle(t);
    expect(_values(store.environmentVariables.value), {'e1': 'eu'});
    expect(_values(store.conversationVariables.value), {'c1': 'x'});
    bo.edit(const RemoveItem(_app, _env, 'e1'));
    await _settle(t);
    expect(store.environmentVariables.value, isEmpty);
    expect(_values(store.conversationVariables.value), {'c1': 'x'});

    // A secret: the plaintext goes to the server's secret store, the document gets the mask and the reference.
    final (:ref, :masked) = await c.storeSecret('sk-typed-in-the-panel');
    expect(masked, 'sk-typ************el');
    expect(demo.server.secrets[ref], 'sk-typed-in-the-panel');
    c.insertItem(
      _app,
      _env,
      Value.of({..._variable('k', masked), 'value_type': 'secret', AppRegisters.secretRef: ref}),
      id: 'k',
    );
    await _settle(t);
    expect(store.environmentVariables.value.single[AppRegisters.secretRef], ref);
    expect(bo.view.toJson().toString(), isNot(contains('sk-typed-in-the-panel')));
    await _close(t, demo, [bo]);
  });
}
