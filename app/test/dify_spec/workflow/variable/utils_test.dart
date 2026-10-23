// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/utils.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:flutter_test/flutter_test.dart';

/// `createNode`: Dify node `data` (type, title and the config) as a document node `node-1`.
Node createNode(Map<String, Object?> data) => Node(
  id: 'node-1',
  type: data['type']! as String,
  title: data['title'] as String? ?? '',
  config: {
    for (final e in data.entries)
      if (e.key != 'type' && e.key != 'title') e.key: Value.of(e.value),
  },
);

Map<String, Object?> createPromptItem([Map<String, Object?> overrides = const {}]) => {
  'role': 'user',
  'text': '',
  ...overrides,
};

Map<String, Object?> createLLMNodeData(List<Map<String, Object?>> promptTemplate) => {
  'type': 'llm',
  'title': 'LLM',
  'desc': '',
  'model': {'provider': 'provider', 'name': 'model', 'mode': 'chat', 'completion_params': <String, Object?>{}},
  'prompt_template': promptTemplate,
  'context': {'enabled': false, 'variable_selector': <String>[]},
  'vision': {'enabled': false},
};

Map<String, Object?> humanInputNodeData(List<String> defaultSelector, List<String> optionSelector) => {
  'type': 'human-input',
  'title': 'Human Input',
  'desc': '',
  'form_content': '',
  'inputs': [
    {
      'type': 'paragraph',
      'output_variable_name': 'summary',
      'default': {'type': 'variable', 'selector': defaultSelector, 'value': ''},
    },
    {
      'type': 'select',
      'output_variable_name': 'decision',
      'option_source': {'type': 'variable', 'selector': optionSelector, 'value': <String>[]},
    },
  ],
  'user_actions': <Object?>[],
  'timeout': 1,
  'timeout_unit': 'day',
  'delivery_methods': [
    {
      'id': 'email',
      'type': 'email',
      'enabled': true,
      'config': {
        'recipients': {'whole_workspace': true, 'items': <Object?>[]},
        'subject': 'Subject {{#conversation.memory#}}',
        'body': 'Body {{#env.API_KEY#}}',
        'debug_mode': false,
      },
    },
  ],
};

/// A config field of [node] as plain JSON.
Object? field(Node node, String key) => plainOf(node.config[key]);

void main() {
  group('variable utils', () {
    group('toNodeAvailableVars', () {
      test('excludes LLM environment aliases from generic variable pickers', () {
        const environmentVariables = [DeclaredVar('query', 'string'), DeclaredVar('shared_model', 'llm')];

        final availableVars = toNodeAvailableVars(beforeNodes: [], environmentVariables: environmentVariables);

        expect(availableVars.firstWhere((item) => item.nodeId == 'env').vars, [
          const DifyVar('env.query', VarType.string),
        ]);
      });

      test('uses Agent v2 default declared outputs for agent nodes', () {
        final node = createNode({
          'type': 'agent',
          'title': 'Agent',
          'desc': '',
          'agent_node_kind': 'dify_agent',
          'version': '2',
        });

        final availableVars = toNodeAvailableVars(beforeNodes: [node]);

        final vars = availableVars.firstWhere((item) => item.nodeId == 'node-1').vars;
        expect(vars, [const DifyVar('text', VarType.string)]);
        expect(vars, isNot(contains(const DifyVar('usage', VarType.object))));
      });

      test('uses Agent v2 declared outputs from graph data', () {
        final node = createNode({
          'type': 'agent-v2',
          'title': 'Agent',
          'desc': '',
          'agent_node_kind': 'dify_agent',
          'agent_declared_outputs': [
            {'name': 'summary', 'type': 'string', 'description': 'Short summary'},
            {
              'name': 'attachments',
              'type': 'array',
              'array_item': {'type': 'file'},
            },
          ],
          'version': '2',
        });

        final availableVars = toNodeAvailableVars(beforeNodes: [node]);

        expect(availableVars.firstWhere((item) => item.nodeId == 'node-1').vars, [
          const DifyVar('text', VarType.string),
          const DifyVar('summary', VarType.string),
          const DifyVar('attachments', VarType.arrayFile),
        ]);
      });
    });

    group('getNodeUsedVars', () {
      test('should read variables from llm jinja prompt text', () {
        final node = createNode(
          createLLMNodeData([
            createPromptItem({'edition_type': 'jinja2', 'jinja2_text': 'Hello {{#env.API_KEY#}}'}),
          ]),
        );

        expect(getNodeUsedVars(node), contains(equals(['env', 'API_KEY'])));
      });

      test('should read an LLM model environment selector', () {
        final node = createNode({
          ...createLLMNodeData([]),
          'model_selector': ['env', 'for_summarize'],
        });

        expect(getNodeUsedVars(node), contains(equals(['env', 'for_summarize'])));
      });

      test('should read variables from human input email body', () {
        final node = createNode(humanInputNodeData(['conversation', 'memory'], ['env', 'OPTIONS']));

        expect(
          getNodeUsedVars(node),
          containsAll([
            ['env', 'API_KEY'],
            ['conversation', 'memory'],
            ['env', 'OPTIONS'],
          ]),
        );
      });

      test('should read variables from agent task', () {
        final node = createNode({
          'type': 'agent',
          'title': 'Agent',
          'desc': '',
          'agent_node_kind': 'dify_agent',
          'agent_task': 'Clarify {{#start.tender#}}',
          'version': '2',
        });

        expect(getNodeUsedVars(node), contains(equals(['start', 'tender'])));
      });
    });

    group('updateNodeVars', () {
      test('should replace answer prompt references', () {
        final node = createNode({
          'type': 'answer',
          'title': 'Answer',
          'desc': '',
          'answer': 'Answer {{#env.API_KEY#}}',
          'variables': <Object?>[],
        });

        final updatedNode = updateNodeVars(node, ['env', 'API_KEY'], ['env', 'RENAMED_KEY']);

        expect(field(updatedNode, 'answer'), 'Answer {{#env.RENAMED_KEY#}}');
      });

      test('should replace llm jinja prompt references', () {
        final node = createNode(
          createLLMNodeData([
            createPromptItem({
              'text': '{{#env.API_KEY#}}',
              'edition_type': 'jinja2',
              'jinja2_text': 'Hello {{#env.API_KEY#}}',
            }),
          ]),
        );

        final updatedNode = updateNodeVars(node, ['env', 'API_KEY'], ['env', 'RENAMED_KEY']);

        expect(
          (field(updatedNode, 'prompt_template')! as List).first,
          allOf(
            containsPair('text', '{{#env.RENAMED_KEY#}}'),
            containsPair('jinja2_text', 'Hello {{#env.RENAMED_KEY#}}'),
          ),
        );
      });

      test('should replace an LLM model environment selector', () {
        final node = createNode({
          ...createLLMNodeData([]),
          'model_selector': ['env', 'for_summarize'],
        });

        final updatedNode = updateNodeVars(node, ['env', 'for_summarize'], ['env', 'for_research']);

        expect(field(updatedNode, 'model_selector'), ['env', 'for_research']);
      });

      test('should replace agent task references', () {
        final node = createNode({
          'type': 'agent',
          'title': 'Agent',
          'desc': '',
          'agent_node_kind': 'dify_agent',
          'agent_task': 'Clarify {{#start.tender#}}',
          'version': '2',
        });

        final updatedNode = updateNodeVars(node, ['start', 'tender'], ['start', 'question']);

        expect(field(updatedNode, 'agent_task'), 'Clarify {{#start.question#}}');
      });

      test('should replace human input email template references', () {
        final node = createNode(humanInputNodeData(['env', 'API_KEY'], ['env', 'API_KEY']));

        final updatedNode = updateNodeVars(node, ['env', 'API_KEY'], ['env', 'RENAMED_KEY']);

        final data = (
          deliveryMethods: field(updatedNode, 'delivery_methods')! as List,
          inputs: field(updatedNode, 'inputs')! as List,
        );
        expect(
          (data.deliveryMethods.first as Map)['config'],
          allOf(
            containsPair('subject', 'Subject {{#conversation.memory#}}'),
            containsPair('body', 'Body {{#env.RENAMED_KEY#}}'),
          ),
        );
        expect(
          data.inputs[0],
          containsPair('default', containsPair('selector', ['env', 'RENAMED_KEY'])),
        );
        expect(
          data.inputs[1],
          containsPair('option_source', containsPair('selector', ['env', 'RENAMED_KEY'])),
        );
      });
    });
  });
}
