import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:flutter_test/flutter_test.dart';
// The fixtures are Dify workflow files; package:yaml comes with the Flutter SDK's dependencies.
import 'package:yaml/yaml.dart';

/// YAML to plain JSON (maps with string keys).
Object? _json(Object? y) => switch (y) {
  final YamlMap m => {for (final e in m.entries) '${e.key}': _json(e.value)},
  final YamlList l => [for (final e in l) _json(e)],
  _ => y,
};

/// A node's selectors the way the importer stores them: two-segment node selectors as references, others as lists.
Object? _refs(Object? v) => switch (v) {
  final Map<String, Object?> m => {
    for (final e in m.entries)
      e.key: e.key.endsWith('selector') && e.value is List && _isNodeRef(e.value! as List)
          ? {
              r'$ref': {'node': (e.value! as List)[0], 'output': (e.value! as List)[1]},
            }
          : _refs(e.value),
  },
  final List<Object?> l => [for (final e in l) _refs(e)],
  _ => v,
};

bool _isNodeRef(List<Object?> s) =>
    s.length == 2 && s.every((e) => e is String) && !const {'sys', 'env', 'conversation', 'rag'}.contains(s[0]);

typedef _Workflow = ({Map<String, Node> nodes, bool chat, List<DeclaredVar> env, List<DeclaredVar> conv});

_Workflow _load(String fixture) {
  final file = File('../tool/visual/fixtures/$fixture');
  final dsl = _json(loadYaml(file.readAsStringSync()))! as Map<String, Object?>;
  final workflow = dsl['workflow']! as Map<String, Object?>;
  final graph = workflow['graph']! as Map<String, Object?>;
  final nodes = <String, Node>{};
  for (final raw in (graph['nodes']! as List).cast<Map<String, Object?>>()) {
    final data = Map.of(raw['data']! as Map<String, Object?>);
    final type = data.remove('type')! as String;
    final title = data.remove('title') as String? ?? '';
    final config = _refs(data)! as Map<String, Object?>;
    nodes['${raw['id']}'] = Node(
      id: '${raw['id']}',
      type: type,
      title: title,
      config: {for (final e in config.entries) e.key: Value.fromJson(e.value)},
    );
  }
  return (
    nodes: nodes,
    chat: (dsl['app']! as Map)['mode'] == 'advanced-chat',
    env: DeclaredVar.listOf(workflow['environment_variables']),
    conv: DeclaredVar.listOf(workflow['conversation_variables']),
  );
}

VarTypes _typesFor(_Workflow w, {bool? chat}) => VarTypes(
  lookup: (id) => w.nodes[id],
  start: w.nodes.values.where((n) => n.type == 'start').firstOrNull,
  chatMode: chat ?? w.chat,
  environmentVariables: w.env,
  conversationVariables: w.conv,
);

/// The End nodes' types, as nodes/end/node.tsx computes them.
List<String?> _endTypes(_Workflow w) {
  final types = _typesFor(w);
  return [
    for (final end in w.nodes.values.where((n) => n.type == 'end'))
      for (final o
          in (end.config['outputs'] is VList ? (end.config['outputs']! as VList).items : const <Value>[])
              .whereType<VMap>())
        if (selectorOf(o.entries['value_selector']) case final sel? when sel.isNotEmpty) types.typeOf(sel),
  ];
}

Node _node(String id, String type, [Map<String, Object?> config = const {}]) => Node(
  id: id,
  type: type,
  config: {for (final e in config.entries) e.key: Value.fromJson(e.value)},
);

VarTypes _with(
  List<Node> nodes, {
  bool chat = false,
  List<DeclaredVar> env = const [],
  List<DeclaredVar> conv = const [],
  List<RagVariable> rag = const [],
}) {
  final byId = {for (final n in nodes) n.id: n};
  return VarTypes(
    lookup: (id) => byId[id],
    start: nodes.where((n) => n.type == 'start').firstOrNull,
    chatMode: chat,
    environmentVariables: env,
    conversationVariables: conv,
    ragVariables: rag,
  );
}

void main() {
  group('fixtures', () {
    test('basic_llm_chat_workflow End: LLM text is string', () {
      final w = _load('basic_llm_chat_workflow.yml');
      expect(_endTypes(w), ['string']);
      final t = _typesFor(w);
      expect(t.typeOf(['start_node', 'query']), 'string');
      expect(t.typeOf(['llm_node', 'usage']), 'object');
      expect(t.typeOf(['llm_node', 'structured_output']), 'string', reason: 'disabled: no such var, typed string');
    });

    test('http_request_with_json_tool_workflow End: number, and a tool output Dify does not know is string', () {
      expect(_endTypes(_load('http_request_with_json_tool_workflow.yml')), ['number', 'string']);
    });

    test('dual_switch_variable_aggregator_workflow End: group outputs', () {
      final w = _load('dual_switch_variable_aggregator_workflow.yml');
      expect(_endTypes(w), ['string', 'string']);
      final t = _typesFor(w);
      expect(t.typeOf(['1754405693104', 'Group1']), 'object');
      expect(t.typeOf(['1754405693104', 'output']), 'string', reason: 'grouped: no plain output, typed string');
    });

    test('array_iteration_formatting_workflow: iteration output and item', () {
      final w = _load('array_iteration_formatting_workflow.yml');
      expect(_endTypes(w), ['array[string]']);
      final t = _typesFor(w);
      final iteration = w.nodes['1754683430480']!;
      expect(t.typeOf(['1754683442688', 'result']), 'array[number]');
      expect(t.typeOf(['1754683430480', 'item'], parent: iteration), 'number');
      expect(t.typeOf(['1754683430480', 'index'], parent: iteration), 'number');
      expect(t.typeOf(['1754683442688', 'result'], isIterationItem: true), 'number');
      expect(t.typeOf(['1754683430480', 'item']), 'string', reason: 'outside the iteration: not a var');
    });

    test('every fixture types its End outputs', () {
      for (final f in Directory('../tool/visual/fixtures').listSync().whereType<File>()) {
        if (!f.path.endsWith('.yml')) continue;
        final w = _load(f.uri.pathSegments.last);
        if (!w.nodes.values.any((n) => n.type == 'end')) continue;
        expect(_endTypes(w), everyElement(isNotNull), reason: f.path);
      }
    });
  });

  group('system, environment, conversation', () {
    final start = _node('s', 'start');

    test('sys variables per mode', () {
      final wf = _with([start]);
      final chat = _with([start], chat: true);
      expect(wf.typeOf(['sys', 'files']), 'array[file]');
      expect(wf.typeOf(['sys', 'query']), isNull);
      expect(chat.typeOf(['sys', 'query']), 'string');
      expect(wf.typeOf(['sys', 'user_id']), 'string');
      expect(wf.typeOf(['sys', 'timestamp']), 'number');
      expect(chat.typeOf(['sys', 'timestamp']), isNull);
      expect(chat.typeOf(['sys', 'dialogue_count']), 'number');
      expect(chat.typeOf(['sys', 'conversation_id']), 'string');
      expect(wf.typeOf(['sys', 'conversation_id']), isNull);
      expect(_with([]).typeOf(['sys', 'files']), 'string', reason: 'no Start node');
      expect(_with([start], chat: true).typeOf(['sys', 'files', 'name']), isNull);
    });

    test('env and conversation', () {
      final env = DeclaredVar.listOf([
        {'name': 'API_KEY', 'value_type': 'secret'},
        {'name': 'N', 'value_type': 'number'},
        {'name': 'M', 'value_type': 'llm'},
      ]);
      final conv = DeclaredVar.listOf(
        Value.fromJson([
          {'name': 'history', 'value_type': 'array[object]'},
        ]),
      );
      final t = _with([start], env: env, conv: conv, chat: true);
      expect(t.typeOf(['env', 'API_KEY']), 'secret');
      expect(t.typeOf(['env', 'N']), 'number');
      expect(t.typeOf(['env', 'M']), isNull);
      expect(t.typeOf(['env', 'missing']), isNull);
      expect(_with([start]).typeOf(['env', 'missing']), 'string', reason: 'no env declared at all');
      expect(t.typeOf(['conversation', 'history']), 'array[object]');
      expect(_with([start], conv: conv).typeOf(['conversation', 'history']), 'string', reason: 'workflow mode');
    });

    test('rag pipeline inputs', () {
      final ds = _node('ds', 'datasource', {'provider_type': 'local_file'});
      final t = _with(
        [ds],
        rag: const [
          RagVariable(variable: 'url', type: 'text-input', belongToNodeId: 'ds'),
          RagVariable(variable: 'n', type: 'number', belongToNodeId: 'shared'),
        ],
      );
      expect(t.typeOf(['rag', 'shared', 'n']), 'number');
      expect(t.typeOf(['rag', 'ds', 'url']), 'string');
      expect(t.typeOf(['ds', 'file']), 'file');
      expect(t.typeOf(['ds', 'file', 'size']), 'number');
      expect(t.typeOf(['ds', 'datasource_type']), 'string');
    });
  });

  group('node outputs', () {
    test('start input types and members', () {
      final t = _with([
        _node('s', 'start', {
          'variables': [
            {'variable': 'n', 'type': 'number'},
            {'variable': 'c', 'type': 'checkbox'},
            {'variable': 'f', 'type': 'file'},
            {'variable': 'fl', 'type': 'file-list'},
            {'variable': 'p', 'type': 'paragraph'},
            {'variable': 'sel', 'type': 'select'},
            {
              'variable': 'j',
              'type': 'json_object',
              'json_schema':
                  '{"type":"object","properties":{"a":{"type":"integer"},'
                  '"o":{"type":"object","properties":{"b":{"type":"boolean"}}},"l":{"type":"array"}}}',
            },
            {'variable': 'j2', 'type': 'json_object'},
          ],
        }),
      ]);
      expect(t.typeOf(['s', 'n']), 'number');
      expect(t.typeOf(['s', 'c']), 'boolean');
      expect(t.typeOf(['s', 'f']), 'file');
      expect(t.typeOf(['s', 'f', 'size']), 'number');
      expect(t.typeOf(['s', 'f', 'transfer_method']), isNull);
      expect(t.typeOf(['s', 'fl']), 'array[file]');
      expect(t.typeOf(['s', 'fl', 'name']), 'array[file]', reason: 'no members: the walk stays on the list');
      expect(t.typeOf(['s', 'p']), 'string');
      expect(t.typeOf(['s', 'sel']), 'string');
      expect(t.typeOf(['s', 'j']), 'object');
      expect(t.typeOf(['s', 'j', 'a']), 'string', reason: 'structTypeToVarType has no integer');
      expect(t.typeOf(['s', 'j', 'o', 'b']), 'boolean');
      expect(t.typeOf(['s', 'j', 'l']), 'array');
      expect(t.typeOf(['s', 'j', 'nope']), 'string');
      expect(t.typeOf(['s', 'j', 'l', 'x']), isNull, reason: 'Dify throws reading properties of a leaf');
      expect(t.typeOf(['s', 'j2']), 'object');
      expect(t.typeOf(['s', 'missing']), 'string');
    });

    test('llm with structured output, error strategy', () {
      final t = _with([
        _node('l', 'llm', {
          'structured_output_enabled': true,
          'structured_output': {
            'schema': {
              'type': 'object',
              'properties': {
                'name': {'type': 'string'},
                'tags': {
                  'type': 'array',
                  'items': {'type': 'string'},
                },
              },
            },
          },
          'error_strategy': 'none',
        }),
      ]);
      expect(t.typeOf(['l', 'text']), 'string');
      expect(t.typeOf(['l', 'reasoning_content']), 'string');
      expect(t.typeOf(['l', 'usage']), 'object');
      expect(t.typeOf(['l', 'usage', 'x']), isNull);
      expect(t.typeOf(['l', 'text', 'x']), 'string', reason: 'a scalar keeps its type down the path');
      expect(t.typeOf(['l', 'structured_output']), 'object');
      expect(t.typeOf(['l', 'structured_output', 'name']), 'string');
      expect(t.typeOf(['l', 'structured_output', 'tags']), 'array');
      expect(t.typeOf(['l', 'error_message']), 'string', reason: "any truthy error_strategy, even 'none'");
      expect(t.typeOf(['l', 'error_type']), 'string');
    });

    test('fixed-output nodes', () {
      final t = _with([
        _node('kr', 'knowledge-retrieval'),
        _node('qc', 'question-classifier'),
        _node('tt', 'template-transform'),
        _node('h', 'http-request'),
        _node('tool', 'tool'),
        _node('if', 'if-else'),
        _node('ki', 'knowledge-index'),
        _node('ts', 'trigger-schedule'),
      ]);
      expect(t.typeOf(['kr', 'result']), 'array[object]');
      expect(t.typeOf(['qc', 'class_name']), 'string');
      expect(t.typeOf(['qc', 'usage']), 'object');
      expect(t.typeOf(['tt', 'output']), 'string');
      expect(t.typeOf(['h', 'body']), 'string');
      expect(t.typeOf(['h', 'status_code']), 'number');
      expect(t.typeOf(['h', 'headers']), 'object');
      expect(t.typeOf(['h', 'files']), 'array[file]');
      expect(t.typeOf(['tool', 'text']), 'string');
      expect(t.typeOf(['tool', 'files']), 'array[file]');
      expect(t.typeOf(['tool', 'json']), 'array[object]');
      expect(t.typeOf(['if', 'result']), 'string', reason: 'not an output node');
      expect(t.typeOf(['ki', 'result']), 'string');
      expect(t.typeOf(['ts', 'current_time']), 'string');
      expect(t.typeOf(['gone', 'x']), 'string');
    });

    test('code, parameter extractor, doc extractor, list operator', () {
      final t = _with([
        _node('c', 'code', {
          'outputs': {
            'r': {'type': 'array[number]', 'children': null},
            'o': {'type': 'object'},
          },
        }),
        _node('c2', 'code', {
          'outputs': {
            r'$items': [
              {
                'id': 'i1',
                'value': {'name': 'result', 'type': 'string'},
              },
            ],
          },
        }),
        _node('c3', 'code'),
        _node('pe', 'parameter-extractor', {
          'parameters': [
            {'name': 'city', 'type': 'string'},
            {'name': 'kind', 'type': 'select'},
            {'name': 'ns', 'type': 'array[number]'},
          ],
        }),
        _node('de', 'document-extractor', {'is_array_file': true}),
        _node('de2', 'document-extractor'),
        _node('lo', 'list-operator', {'var_type': 'array[file]', 'item_var_type': 'file'}),
        _node('lo2', 'list-operator'),
      ]);
      expect(t.typeOf(['c', 'r']), 'array[number]');
      expect(t.typeOf(['c', 'o']), 'object');
      expect(t.typeOf(['c', 'o', 'x']), isNull);
      expect(t.typeOf(['c2', 'result']), 'string');
      expect(t.typeOf(['c3', 'result']), 'string', reason: 'no variables: the node is not listed');
      expect(t.typeOf(['pe', 'city']), 'string');
      expect(t.typeOf(['pe', 'kind']), 'select');
      expect(t.typeOf(['pe', 'ns']), 'array[number]');
      expect(t.typeOf(['pe', '__is_success']), 'number');
      expect(t.typeOf(['pe', '__reason']), 'string');
      expect(t.typeOf(['de', 'text']), 'array[string]');
      expect(t.typeOf(['de2', 'text']), 'string');
      expect(t.typeOf(['lo', 'result']), 'array[file]');
      expect(t.typeOf(['lo', 'first_record']), 'file');
      expect(t.typeOf(['lo', 'last_record', 'name']), 'string');
      expect(t.typeOf(['lo2', 'result']), 'string');
    });

    test('assigner / aggregator, iteration, loop', () {
      final t = _with([
        _node('va', 'variable-assigner', {'output_type': 'number'}),
        _node('ag', 'variable-aggregator', {
          'output_type': 'string',
          'advanced_settings': {
            'group_enabled': true,
            'groups': [
              {'group_name': 'G', 'output_type': 'array[object]'},
            ],
          },
        }),
        _node('it', 'iteration'),
        _node('src', 'code', {
          'outputs': {
            'xs': {'type': 'array[object]'},
            'any': {'type': 'array'},
          },
        }),
        _node('lp', 'loop', {
          'loop_variables': [
            {'label': 'i', 'var_type': 'number'},
            {'label': 'acc', 'var_type': 'array[string]'},
          ],
        }),
      ]);
      expect(t.typeOf(['va', 'output']), 'number');
      expect(t.typeOf(['ag', 'G']), 'object');
      expect(t.typeOf(['ag', 'G', 'output']), 'array[object]');
      expect(t.typeOf(['ag', 'G', 'other']), isNull);
      expect(t.typeOf(['it', 'output']), 'array[string]', reason: 'default output_type');
      expect(t.typeOf(['lp', 'i']), 'number');
      expect(t.typeOf(['lp', 'acc']), 'array[string]');
      expect(t.typeOf(['src', 'xs'], isIterationItem: true), 'object');
      expect(t.typeOf(['src', 'any'], isIterationItem: true), 'array[object]');
      expect(t.typeOf(['src', 'any'], isLoopItem: true), 'any');
      expect(t.typeOf(['lp', 'acc'], isLoopItem: true), 'string');
      final parent = _node('it2', 'iteration', {
        'iterator_selector': {
          r'$ref': {'node': 'src', 'output': 'xs'},
        },
      });
      expect(t.typeOf(['it2', 'item'], parent: parent), 'object');
      expect(t.typeOf(['whatever', 'item'], parent: parent), 'object', reason: 'Dify only checks the second segment');
    });

    test('agent, agent v2, human input', () {
      final t = _with([
        _node('a', 'agent', {
          'output_schema': {
            'properties': {
              'score': {'type': 'number'},
              'list': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'blank': <String, Object?>{},
            },
          },
        }),
        _node('a2', 'agent', {
          'agent_node_kind': 'dify_agent',
          'version': '2',
          'agent_declared_outputs': [
            {'name': 'n', 'type': 'number'},
            {
              'name': 'xs',
              'type': 'array',
              'array_item': {'type': 'file'},
            },
            {'name': 'ys', 'type': 'array'},
            {'name': 'switch', 'type': 'object'},
          ],
        }),
        _node('a3', 'agent-v2'),
        _node('hi', 'human-input', {
          'inputs': [
            {'output_variable_name': 'doc', 'type': 'file'},
            {'output_variable_name': 'docs', 'type': 'file-list'},
            {'output_variable_name': 'note', 'type': 'paragraph'},
          ],
        }),
      ]);
      expect(t.typeOf(['a', 'score']), 'Number');
      expect(t.typeOf(['a', 'list']), 'Array[String]');
      expect(t.typeOf(['a', 'blank']), 'Unknown');
      expect(t.typeOf(['a', 'json']), 'array[object]', reason: "TOOL_OUTPUT_STRUCT's json comes first");
      expect(t.typeOf(['a', 'text']), 'string');
      expect(t.typeOf(['a2', 'text']), 'string');
      expect(t.typeOf(['a2', 'n']), 'number');
      expect(t.typeOf(['a2', 'xs']), 'array[file]');
      expect(t.typeOf(['a2', 'ys']), 'array[object]');
      expect(t.typeOf(['a2', 'switch']), 'string', reason: 'reserved: not a var');
      expect(t.typeOf(['a3', 'text']), 'string');
      expect(t.typeOf(['hi', 'doc']), 'file');
      expect(t.typeOf(['hi', 'docs']), 'array[file]');
      expect(t.typeOf(['hi', 'note']), 'string');
      expect(t.typeOf(['hi', '__action_id']), 'string');
    });

    test('triggers', () {
      final t = _with([
        _node('wh', 'trigger-webhook', {
          'variables': [
            {'variable': 'id', 'value_type': 'number'},
            {'variable': 'raw'},
          ],
        }),
        _node('tp', 'trigger-plugin', {
          'output_schema': {
            'properties': {
              'count': {'type': 'integer'},
              'tags': {
                'type': 'array',
                'items': {'type': 'string'},
              },
              'maybe': {
                'type': ['null', 'boolean'],
              },
              'payload': {
                'type': 'object',
                'properties': {
                  'n': {'type': 'integer'},
                  'f': {'type': 'object', 'schema_type': 'file'},
                },
              },
              'untyped': <String, Object?>{},
            },
          },
        }),
      ]);
      expect(t.typeOf(['wh', 'id']), 'number');
      expect(t.typeOf(['wh', 'raw']), 'string');
      expect(t.typeOf(['tp', 'count']), 'integer');
      expect(t.typeOf(['tp', 'tags']), 'array[string]');
      expect(t.typeOf(['tp', 'maybe']), 'boolean');
      expect(t.typeOf(['tp', 'payload']), 'object');
      expect(t.typeOf(['tp', 'payload', 'n']), 'number');
      expect(t.typeOf(['tp', 'payload', 'f']), 'string', reason: 'field type file maps to string');
      expect(t.typeOf(['tp', 'untyped']), 'any');
    });
  });

  test('selectorOf and varTypeLabel', () {
    expect(selectorOf(const VRef(OutputRef('n', 'text'))), ['n', 'text']);
    expect(selectorOf(Value.fromJson(['sys', 'query'])), ['sys', 'query']);
    expect(selectorOf(const VString('x')), isNull);
    expect(varTypeLabel('array[file]'), 'Array[file]');
    expect(varTypeLabel('Array[String]'), 'Array[string]');
    expect(varTypeLabel(null), isNull);
  });
}
