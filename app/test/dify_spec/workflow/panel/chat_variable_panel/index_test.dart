// dify-spec: web/app/components/workflow/panel/chat-variable-panel/__tests__/index.spec.tsx
//
// Dify saves the list through its conversation-variables API; here a change is item ops on the document's
// `conversation_variables` (under `$app`), checked with the node rewrites that go with them.
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

const convPath = ['conversation_variables'];

Map<String, Object?> createConversationVariable([Map<String, Object?> overrides = const {}]) => {
  'id': 'var-1',
  'name': 'conversation_var',
  'value_type': ChatVarType.string,
  'value': '',
  'description': 'Conversation variable',
  ...overrides,
};

void main() {
  setUp(useDifyTestTranslator);

  final nodes = [
    difyNode('node-1', 'answer', {'answer': 'Hi {{#conversation.conversation_var#}}', 'variables': []}),
    difyNode('node-2', 'code', {
      'code_language': 'python3',
      'code': '',
      'outputs': {},
      'variables': [
        {
          'variable': 'x',
          'value_selector': ['conversation', 'conversation_var'],
        },
      ],
    }),
    difyNode('node-3', 'answer', {'answer': 'plain', 'variables': []}),
  ];

  Future<VarHarness> render(WidgetTester t) async {
    final h = await VarHarness.start(t, nodes: nodes, conversation: [createConversationVariable()]);
    h.store.setShowChatVariablePanel(true);
    await pumpPanel(t, ChatVariablePanel(controller: h.controller), store: h.store);
    return h;
  }

  /// The tips button's `aria-expanded`.
  bool? tipsExpanded(WidgetTester t) => t
      .widget<Semantics>(
        find.ancestor(
          of: buttonNamed('workflow.chatVariable.tips'),
          matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.expanded != null),
        ),
      )
      .properties
      .expanded;

  group('ChatVariablePanel', () {
    testWidgets('should toggle the tips area and close the panel', (t) async {
      final h = await render(t);

      expect(find.text('workflow.chatVariable.panelDescription'), findsOneWidget);
      expect(tipsExpanded(t), isTrue);

      await tap(t, buttonNamed('workflow.chatVariable.tips'));
      expect(find.text('workflow.chatVariable.panelDescription'), findsNothing);
      expect(tipsExpanded(t), isFalse);

      await tap(t, buttonNamed('common.operation.close'));

      expect(h.store.showChatVariablePanel.value, isFalse);
      await h.dispose(t);
    });

    testWidgets('should prepend newly added variables and sync the workflow draft', (t) async {
      final h = await render(t);

      await tap(t, buttonNamed('workflow.chatVariable.button'));
      await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'fresh_var');
      await type(t, byPlaceholder('workflow.chatVariable.modal.descriptionPlaceholder'), 'Added variable');
      await tap(t, find.text('common.operation.save'));

      final op = h.controller.appOps.single;
      final value = op.value! as Map;
      expect(op.kind, 'insert');
      expect(op.path, convPath);
      expect(op.id, value['id']);
      expect({...value}..remove('id'), {
        'name': 'fresh_var',
        'value_type': ChatVarType.string,
        'value': '',
        'description': 'Added variable',
      });
      await h.dispose(t);
    });

    testWidgets('should rename existing variables and update affected node references', (t) async {
      final h = await render(t);
      final seen = h.controller.seenVersion;

      await tap(t, buttonNamed('common.operation.edit'));
      await type(t, byDisplayValue('conversation_var'), 'conversation_var_next');
      await tap(t, find.text('common.operation.save'));

      final op = h.controller.appOps.single;
      expect((op.kind, op.path, op.id, op.base), ('update', convPath, 'var-1', seen));
      expect(op.value, createConversationVariable({'name': 'conversation_var_next'}));
      expect(difyDataOf(h.doc.nodes['node-1']!)['answer'], 'Hi {{#conversation.conversation_var_next#}}');
      expect((difyDataOf(h.doc.nodes['node-2']!)['variables']! as List).single, {
        'variable': 'x',
        'value_selector': ['conversation', 'conversation_var_next'],
      });
      expect(h.controller.nodeOps.where((o) => o.node == 'node-3'), isEmpty);
      expect(h.store.controlPromptEditorRerenderKey.value, greaterThan(0));
      await h.dispose(t);
    });

    testWidgets('should require confirmation before deleting variables referenced by workflow nodes', (t) async {
      final h = await render(t);

      await tap(t, buttonNamed('common.operation.delete'));
      expect(find.text('workflow.common.effectVarConfirm.title'), findsOneWidget);

      await tap(t, buttonNamed('common.operation.confirm'));

      expect((difyDataOf(h.doc.nodes['node-2']!)['variables']! as List).single, {
        'variable': 'x',
        'value_selector': <Object?>[],
      });
      expect(h.controller.appOps.single, (
        kind: 'remove',
        node: r'$app',
        path: convPath,
        id: 'var-1',
        value: null,
        base: null,
      ));
      await h.dispose(t);
    });
  });
}
