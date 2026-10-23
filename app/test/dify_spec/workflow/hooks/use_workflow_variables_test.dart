// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-variables.spec.ts
//
// useWorkflowVariables().getNodeAvailableVars is NodeVars.scopeOver (the store's environment and conversation
// variables, the app's chat mode, `environment` / `conversation` off for hideEnv / hideChatVar);
// getCurrentVariableType / useWorkflowVariableType are the scope's typeOf (VarTypes.typeOf with the container as
// parentNode).
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import '../context_menu/harness.dart';

NodePanelProps _props(Harness h, String id, {bool chat = false}) => NodePanelProps(
  node: h[id]!,
  controller: h.controller,
  actions: h.actions(WorkflowMenuOptions(isChatMode: chat)),
);

List<String> _groups(NodeVars v) => [for (final g in v.scope.vars) g.nodeId];

void main() {
  group('useWorkflowVariables', () {
    group('getNodeAvailableVars', () {
      testWidgets('should call toNodeAvailableVars with store data', (t) async {
        final h = await Harness.start(t, [node('n1')]);
        h.store
          ..setEnvironmentVariables([
            {'id': 'ev1', 'name': 'key', 'value_type': 'string', 'value': ''},
          ])
          ..setConversationVariables([
            {'id': 'cv1', 'name': 'history', 'value_type': 'string', 'value': ''},
          ]);
        final p = _props(h, 'n1', chat: true);
        final vars = NodeVars.scopeOver(p, const []);
        expect([for (final g in vars.vars) g.nodeId], containsAll(['env', 'conversation']));
        await h.dispose(t);
      });

      testWidgets('should hide env variables when hideEnv is true', (t) async {
        final h = await Harness.start(t, [node('n1')]);
        h.store.setEnvironmentVariables([
          {'id': 'ev1', 'name': 'key', 'value_type': 'string', 'value': ''},
        ]);
        final vars = NodeVars.scopeOver(_props(h, 'n1'), const [], environment: false);
        expect([for (final g in vars.vars) g.nodeId], isNot(contains('env')));
        await h.dispose(t);
      });

      testWidgets('should hide chat variables when not in chat mode', (t) async {
        final h = await Harness.start(t, [node('n1')]);
        h.store.setConversationVariables([
          {'id': 'cv1', 'name': 'history', 'value_type': 'string', 'value': ''},
        ]);
        final vars = NodeVars.scopeOver(_props(h, 'n1'), const []);
        expect([for (final g in vars.vars) g.nodeId], isNot(contains('conversation')));
        await h.dispose(t);
      });
    });

    group('getCurrentVariableType', () {
      testWidgets('should call getVarType with store data and return the result', (t) async {
        final h = await Harness.start(t, [
          node(
            'node-1',
            config: const {
              'outputs': VMap({
                'output': VMap({'type': VString('number'), 'children': VNull()}),
              }),
            },
          ),
          node('n2', x: 300),
        ]);
        h.controller.connect('node-1', 'n2');
        await t.pump();
        final scope = NodeVars.of(_props(h, 'n2'));
        expect(_groups(scope), contains('node-1'));
        expect(scope.scope.typeOf!(['node-1', 'output']), 'number');
        await h.dispose(t);
      });
    });
  });

  group('useWorkflowVariableType', () {
    Future<Harness> start(WidgetTester t) => Harness.start(t, [
      node(
        'n1',
        config: const {
          'outputs': VMap({
            'output': VMap({'type': VString('string'), 'children': VNull()}),
          }),
        },
      ),
      node(
        'iter-1',
        type: 'iteration',
        y: 200,
        config: const {
          'iterator_selector': VList([VString('n1'), VString('output')]),
        },
      ),
      node('n2', x: 300, parent: 'iter-1'),
    ]);

    testWidgets('should call getCurrentVariableType with the correct node', (t) async {
      final h = await start(t);
      final scope = NodeVars.of(_props(h, 'n1'));
      expect(scope.parent, isNull);
      // A node outside a container types its own outputs without a parentNode.
      expect(NodeVars.scopeOver(_props(h, 'n1'), [h['n1']!]).typeOf!(['n1', 'output']), 'string');
      await h.dispose(t);
    });

    testWidgets('should pass iterationNode as parentNode when node is in iteration', (t) async {
      final h = await start(t);
      final scope = NodeVars.of(_props(h, 'n2'));
      expect(scope.parent?.id, 'iter-1');
      // With the iteration as parentNode, its `item` is the iterated array's element.
      expect(scope.scope.typeOf!(['iter-1', 'item']), isNotNull);
      await h.dispose(t);
    });
  });
}
