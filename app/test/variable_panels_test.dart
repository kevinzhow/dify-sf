// The variable panels on a live collaborative document (protocol 1.7): edits become item ops under `$app`, the
// store follows the document, renames reach the nodes, secrets never travel in ops, a stale edit is a conflict.
import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/notices.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/variable_panels.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/panel/harness.dart';

const envPath = [AppRegisters.environmentVariables];
const convPath = [AppRegisters.conversationVariables];

Node codeUsing(String id, List<String> selector) => difyNode(id, 'code', {
  'code_language': 'python3',
  'code': '',
  'outputs': {},
  'variables': [
    {'variable': 'x', 'value_selector': selector},
  ],
});

void main() {
  setUp(useDifyTestTranslator);

  Future<VarHarness> open(
    WidgetTester t, {
    List<Node> nodes = const [],
    List<Map<String, Object?>> env = const [],
    List<Map<String, Object?>> conversation = const [],
    bool chat = false,
  }) async {
    final h = await VarHarness.start(t, nodes: nodes, env: env, conversation: conversation);
    chat ? h.store.setShowChatVariablePanel(true) : h.store.setShowEnvPanel(true);
    await pumpPanel(
      t,
      VariablePanels(controller: h.controller, isChatMode: chat, storeSecret: h.controller.storeSecret),
      store: h.store,
    );
    return h;
  }

  Future<void> settleSession(WidgetTester t, VarHarness h) async {
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  List<Map<String, Object?>> envOf(VarHarness h) => AppRegisters.variables(h.doc, AppRegisters.environmentVariables);

  testWidgets('adding, editing and deleting an environment variable are item ops the store follows', (t) async {
    final h = await open(t);

    await tap(t, buttonNamed('workflow.env.envPanelButton'));
    await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'api_url');
    await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'https://example.test');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);

    final id = envOf(h).single['id']! as String;
    expect(envOf(h).single, {
      'id': id,
      'name': 'api_url',
      'value': 'https://example.test',
      'value_type': 'string',
      'description': '',
    });
    expect(h.store.environmentVariables.value, envOf(h));
    expect(find.text('api_url'), findsOneWidget);
    expect(h.server.doc.app[AppRegisters.environmentVariables], isA<VItems>());

    await tap(t, buttonNamed('common.operation.edit'));
    await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'https://example.org');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);
    expect(envOf(h).single['value'], 'https://example.org');
    expect(h.controller.appOps.last.kind, 'update');

    await tap(t, buttonNamed('common.operation.delete'));
    await settleSession(t, h);
    expect(envOf(h), isEmpty);
    expect(h.store.environmentVariables.value, isEmpty);
    expect(h.controller.appOps.map((o) => o.kind), ['insert', 'update', 'remove']);
    expect(h.controller.undo.canUndo, isFalse); // like Dify, not in the workflow history
    await h.dispose(t);
  });

  testWidgets('renaming an environment variable renames its uses in the nodes', (t) async {
    final h = await open(
      t,
      nodes: [
        codeUsing('a', ['env', 'token']),
        difyNode('b', 'answer', {'answer': 'T: {{#env.token#}}', 'variables': []}),
      ],
      env: [
        {'id': 'e1', 'name': 'token', 'value': 'x', 'value_type': 'string', 'description': ''},
      ],
    );

    await tap(t, buttonNamed('common.operation.edit'));
    await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'api_token');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);

    expect(envOf(h).single['name'], 'api_token');
    expect((difyDataOf(h.server.doc.nodes['a']!)['variables']! as List).single, {
      'variable': 'x',
      'value_selector': ['env', 'api_token'],
    });
    expect(difyDataOf(h.server.doc.nodes['b']!)['answer'], 'T: {{#env.api_token#}}');
    await h.dispose(t);
  });

  testWidgets('a secret is stored aside: its plaintext is in no op, the item holds the mask and the reference', (
    t,
  ) async {
    final h = await open(t);

    await tap(t, buttonNamed('workflow.env.envPanelButton'));
    await tap(t, find.text('Secret'));
    await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'openai_key');
    await type(t, byPlaceholder('workflow.env.modal.valuePlaceholder'), 'sk-very-secret-42');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);

    final item = envOf(h).single;
    expect(item['value'], 'sk-ver************42');
    expect(h.server.secrets[item[AppRegisters.secretRef]], 'sk-very-secret-42');
    final sent = jsonEncode([for (final e in h.server.log) e.op.toJson()]);
    expect(sent, isNot(contains('sk-very-secret-42')));
    expect(h.controller.ops.toString(), isNot(contains('sk-very-secret-42')));
    // The list shows the mask.
    expect(find.text('sk-ver************42'), findsOneWidget);

    // Saved again unchanged: the secret is not stored again, the reference stays.
    await tap(t, buttonNamed('common.operation.edit'));
    await type(t, byPlaceholder('workflow.env.modal.descriptionPlaceholder'), 'prod');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);
    expect(h.server.secrets, hasLength(1));
    expect(envOf(h).single, containsPair(AppRegisters.secretRef, item[AppRegisters.secretRef]));
    expect(envOf(h).single['description'], 'prod');
    await h.dispose(t);
  });

  testWidgets('saving a variable someone changed since the modal opened is a conflict, and its uses stay', (t) async {
    final h = await open(
      t,
      nodes: [
        codeUsing('a', ['env', 'token']),
      ],
      env: [
        {'id': 'e1', 'name': 'token', 'value': 'x', 'value_type': 'string', 'description': ''},
      ],
    );

    await tap(t, buttonNamed('common.operation.edit'));
    // Another client changes the variable meanwhile.
    final otherBackend = DemoBackend(server: h.server, withBo: false);
    final other = await otherBackend.openSession('demo', clientId: 'other-xyz789', journaled: false);
    await other.session.start();
    await settleSession(t, h);
    other.session.edit(
      UpdateItem(
        Document.appNode,
        envPath,
        'e1',
        Value.of({'id': 'e1', 'name': 'token', 'value': 'y', 'value_type': 'string', 'description': ''}),
      ),
    );
    await settleSession(t, h);
    expect(envOf(h).single['value'], 'y');

    await type(t, byPlaceholder('workflow.env.modal.namePlaceholder'), 'renamed');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);

    expect(envOf(h).single['name'], 'token');
    expect(h.controller.notices.any((n) => n.kind == NoticeKind.conflict), isTrue);
    expect(h.controller.nodeOps, isEmpty);
    await other.close();
    await otherBackend.dispose();
    await h.dispose(t);
  });

  testWidgets('conversation variables: an array and an object edited in the modal are saved as Dify values', (t) async {
    final h = await open(t, chat: true);
    List<Map<String, Object?>> conv() => AppRegisters.variables(h.doc, AppRegisters.conversationVariables);

    // array[string], one value at a time, then edited in JSON.
    await tap(t, buttonNamed('workflow.chatVariable.button'));
    await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'tags');
    await tap(t, find.text('string'));
    await tap(t, find.text('array[string]'));
    await type(t, byPlaceholder('workflow.chatVariable.modal.arrayValue'), 'a');
    await tap(t, find.text('workflow.chatVariable.modal.addArrayValue'));
    await type(t, byPlaceholder('workflow.chatVariable.modal.arrayValue').last, 'b');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);
    expect(conv().single, containsPair('value', ['a', 'b']));
    expect(conv().single['value_type'], 'array[string]');

    // object, in the form.
    await tap(t, buttonNamed('workflow.chatVariable.button'));
    await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'profile');
    await tap(t, find.text('string'));
    await tap(t, find.text('object'));
    await type(t, byPlaceholder('workflow.chatVariable.modal.objectKey'), 'age');
    await tap(t, find.text('string').last);
    await tap(t, find.text('number').last);
    await type(t, byPlaceholder('workflow.chatVariable.modal.objectValue').first, '20');
    await tap(t, find.text('common.operation.save'));
    await settleSession(t, h);

    // New variables go first.
    expect(conv().map((v) => v['name']), ['profile', 'tags']);
    expect(conv().first['value'], {'age': 20});
    expect(h.controller.appOps.every((o) => o.path.join() == convPath.join()), isTrue);
    await h.dispose(t);
  });
}
