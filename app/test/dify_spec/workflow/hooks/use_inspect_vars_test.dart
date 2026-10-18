// dify-spec: web/app/components/workflow/hooks/__tests__/use-fetch-workflow-inspect-vars.spec.ts
// dify-spec: web/app/components/workflow/hooks/__tests__/use-inspect-vars-crud-common.spec.ts
// dify-spec: web/app/components/workflow/hooks/__tests__/use-inspect-vars-crud.spec.ts
//
// useSetWorkflowVarsWithValue, useInspectVarsCrudCommon and useInspectVarsCrud are InspectVarsCrud over the store.
// Dify mocks toNodeOutputVars to give `answer` the schema type `simple`; here the node is a trigger plugin whose
// output schema says so, and the real output variables give the type.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:flutter_test/flutter_test.dart';

import '../variable_inspect/inspect_harness.dart';

DifyJson _var([DifyJson overrides = const {}]) => {
  'id': 'var-1',
  'type': 'node',
  'name': 'answer',
  'description': 'Answer',
  'selector': ['node-1', 'answer'],
  'value_type': 'string',
  'value': 'hello',
  'edited': false,
  'visible': true,
  'is_truncated': false,
  'full_content': {'size_bytes': 5, 'download_url': 'https://example.com/answer.txt'},
  ...overrides,
};

/// A node whose output `answer` has the schema type `simple`.
const _node = Node(
  id: 'node-1',
  type: 'trigger-plugin',
  title: 'Code',
  config: {
    'output_schema': VMap({
      'properties': VMap({
        'answer': VMap({'type': VString('string'), 'schema_type': VString('simple')}),
      }),
    }),
  },
);

class _Services extends RecordingServices {
  _Services({super.nodeVars, super.systemVars, this.all = const []});
  final List<DifyJson> all;
  var systemFetches = 0;

  @override
  Future<List<DifyJson>> fetchAllInspectVars() async {
    calls.add('fetchAll');
    return all;
  }

  @override
  Future<List<DifyJson>> fetchSystemVars() async {
    systemFetches++;
    return super.fetchSystemVars();
  }
}

void main() {
  group('use-fetch-workflow-inspect-vars', () {
    test('fetches inspect vars, invalidates cached values, and stores schema-enriched node vars', () async {
      final services = _Services(
        all: [
          _var(),
          _var({
            'id': 'missing-node-var',
            'selector': ['missing-node', 'answer'],
          }),
        ],
      );
      final h = InspectHarness(services: services, nodes: [_node]);
      addTearDown(h.store.dispose);
      h.store
        ..setNodeRunData('node-1', {'_runningStatus': 'succeeded'})
        ..setNodeRunData('other', {'_runningStatus': 'failed'});

      await h.crud.fetchInspectVars();

      expect(services.systemFetches, 1);
      expect(services.calls, contains('fetchAll'));
      // handleCancelAllNodeSuccessStatus.
      expect(h.store.nodeRunDataOf('node-1')['_runningStatus'], isNull);
      expect(h.store.nodeRunDataOf('other')['_runningStatus'], 'failed');
      final nodes = h.store.nodesWithInspectVars.value;
      expect(nodes, hasLength(1));
      expect(nodes[0]['nodeId'], 'node-1');
      expect(nodes[0]['nodeType'], 'trigger-plugin');
      expect(nodes[0]['title'], 'Code');
      expect(nodes[0]['isValueFetched'], false);
      final v = (nodes[0]['vars'] as List).single as Map;
      expect(v['id'], 'var-1');
      expect(v['selector'], ['node-1', 'answer']);
      expect(v['schemaType'], 'simple');
      expect(v['value'], 'hello');
    });

    test('accepts passed-in vars and plugin metadata without refetching from the API', () async {
      final services = _Services();
      final h = InspectHarness(services: services, nodes: [_node]);
      addTearDown(h.store.dispose);

      await h.crud.fetchInspectVars(
        vars: [
          _var({'id': 'var-2', 'value': 'passed-in'}),
        ],
      );

      expect(services.calls, isNot(contains('fetchAll')));
      final v = (h.store.nodesWithInspectVars.value[0]['vars'] as List).single as Map;
      expect(v['id'], 'var-2');
      expect(v['value'], 'passed-in');
      expect(v['schemaType'], 'simple');
    });
  });

  group('useInspectVarsCrudCommon', () {
    test('invalidates cached system vars without refetching node values for system selectors', () async {
      final services = _Services();
      final h = InspectHarness(services: services, nodes: [_node]);
      addTearDown(h.store.dispose);

      await h.crud.fetchInspectVarValue(VarInInspectType.system);

      expect(services.systemFetches, 1);
      expect(services.calls.where((c) => c.startsWith('fetchNodeInspectVars')), isEmpty);
    });

    test('fetches node inspect vars, adds schema types, and marks the node as fetched', () async {
      final services = _Services(
        nodeVars: {
          'node-1': [_var()],
        },
      );
      final h = InspectHarness(services: services, nodes: [_node]);
      addTearDown(h.store.dispose);
      h.store.setNodesWithInspectVars([createNodeWithVar(isValueFetched: false)]);

      await h.crud.fetchInspectVarValue('node-1');

      expect(services.calls, contains('fetchNodeInspectVars node-1'));
      final node = h.store.nodesWithInspectVars.value[0];
      expect(node['nodeId'], 'node-1');
      expect(node['isValueFetched'], true);
      final v = (node['vars'] as List).single as Map;
      expect(v['id'], 'var-1');
      expect(v['schemaType'], 'simple');
    });

    test('deletes all inspect vars, invalidates cached values, and clears edge running state', () async {
      final services = _Services();
      final h = InspectHarness(services: services, nodes: [_node]);
      addTearDown(h.store.dispose);
      h.store
        ..setNodesWithInspectVars([
          createNodeWithVar(vars: [_var()]),
        ])
        ..setEdgeRunData('e1', {
          '_sourceRunningStatus': 'succeeded',
          '_targetRunningStatus': 'running',
          '_waitingRun': true,
        })
        ..setConversationVariables([
          {'id': 'c1', 'name': 'history', 'value_type': 'string', 'value': ''},
        ]);
      h.crud.conversationEdits.value = {'c1': 'edited'};

      await h.crud.deleteAllInspectorVars();

      expect(services.calls, contains('deleteAll'));
      // invalidateConversationVarValues: the drafts go; invalidateSysVarValues: fetched again.
      expect(h.crud.conversationEdits.value, isEmpty);
      expect(services.systemFetches, 1);
      expect(h.store.edgeRunDataOf('e1'), {'_waitingRun': false});
      expect(h.store.nodesWithInspectVars.value, isEmpty);
    });
  });

  group('useInspectVarsCrud', () {
    test('should append query and files vars to the start node and keep other system vars separate', () async {
      final services = _Services(
        systemVars: [
          _var({
            'id': 'query-var',
            'name': 'query',
            'selector': ['sys', 'query'],
          }),
          _var({
            'id': 'files-var',
            'name': 'files',
            'selector': ['sys', 'files'],
          }),
          _var({
            'id': 'time-var',
            'name': 'time',
            'selector': ['sys', 'time'],
          }),
        ],
      );
      final h = InspectHarness(services: services);
      addTearDown(h.store.dispose);
      h.store
        ..setConversationVariables([
          {'id': 'conversation-var', 'name': 'history', 'value_type': 'string', 'value': ''},
        ])
        ..setNodesWithInspectVars([
          createNodeWithVar(
            nodeId: 'start-node',
            type: 'start',
            title: 'Start',
            vars: [
              _var({
                'id': 'start-answer',
                'selector': ['start-node', 'answer'],
              }),
            ],
          ),
        ]);
      await h.crud.invalidateSysVarValues();

      expect(h.crud.conversationVars, hasLength(1));
      expect([for (final v in h.crud.systemVars) v['name']], ['time']);
      expect(
        [for (final v in InspectVarsCrud.varsOf(h.crud.nodesWithInspectVars[0])) v['name']],
        [
          'answer',
          'query',
          'files',
        ],
      );
    });
  });
}
