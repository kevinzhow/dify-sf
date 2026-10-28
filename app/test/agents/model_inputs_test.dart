import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/model_inputs.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow/node_used_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inline_checks_test.dart' show workflow;

Node agent(Object? inputs) => Node(
  id: 'node',
  type: 'agent',
  title: 'Agent',
  config: {
    'version': const VString('2'),
    'agent_node_kind': const VString('dify_agent'),
    'agent_task': const VString('Use {{#start.task#}}'),
    'agent_model': Value.of(inputs),
  },
);

void main() {
  test('model and effort join normal reference tracking and rename without changing other bindings', () {
    final node = agent({
      'model': '{{#start.model#}}',
      'reasoning_effort': '{{#start.effort#}}',
    });
    expect(getNodeUsedVars(node), [
      ['start', 'task'],
      ['start', 'model'],
      ['start', 'effort'],
    ]);
    final changed = updateNodeVars(
      node,
      ['start', 'effort'],
      ['start', 'reasoning'],
    );
    expect(difyDataOf(changed)['agent_model'], {
      'model': '{{#start.model#}}',
      'reasoning_effort': '{{#start.reasoning#}}',
    });
    expect(getNodeUsedVars(changed), contains(equals(['start', 'reasoning'])));
  });

  test('only exact model references are valid; fixed settings stay in inline configuration', () {
    expect(validAgentModelInputs(null), true);
    expect(
      validAgentModelInputs({'reasoning_effort': '{{#start-node.effort#}}'}),
      true,
    );
    for (final invalid in [
      1,
      {'model': ''},
      {'reasoning_effort': 'high'},
      {'model': '{{#start.#}}'},
      {'model': 'prefix {{#start.model#}}'},
      {'provider': '{{#start.provider#}}'},
    ]) {
      expect(validAgentModelInputs(invalid), false, reason: '$invalid');
    }
  });

  test('checklist accepts a start dropdown binding and rejects a deleted or wrong-type input', () {
    final soul = <String, Object?>{
      'model': {
        'plugin_id': 'vendor/plugin',
        'model_provider': 'provider',
        'model': 'fixture',
      },
    };
    Document graph(String type, String selected) {
      final doc = workflow();
      return Document(
        nodes: [
          for (final n in doc.nodes.values)
            if (n.id == 'start')
              n.copyWith(
                config: {
                  'variables': Value.of([
                    {
                      'variable': 'effort',
                      'type': type,
                      'required': true,
                      'options': ['high', 'xhigh', 'max'],
                    },
                  ]),
                },
              )
            else if (n.id == 'node')
              n.copyWith(
                config: {
                  ...n.config,
                  'agent_model': Value.of({
                    'reasoning_effort': '{{#start.$selected#}}',
                  }),
                },
              )
            else
              n,
        ],
        edges: doc.edges.values.toList(),
      );
    }

    ChecklistEnv env() =>
        ChecklistEnv(appMode: 'workflow', inlineAgentSouls: {'node': soul});
    expect(
      computeChecklist(
        graph('select', 'effort'),
        env(),
      ).where((e) => e.id == 'node'),
      isEmpty,
    );
    expect(
      computeChecklist(
        graph('select', 'missing'),
        env(),
      ).where((e) => e.id == 'node'),
      isNotEmpty,
    );
    expect(
      computeChecklist(
        graph('number', 'effort'),
        env(),
      ).where((e) => e.id == 'node'),
      isNotEmpty,
    );
  });
}
