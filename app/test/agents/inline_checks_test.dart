import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/inline_checks.dart';
import 'package:dify_sf_app/src/mcp/workflow_reader.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

import 'inline_composer_test.dart' show binding, composerReply, ComposerApi;

class _PinnedApi extends ComposerApi {
  final identities = <List<String?>>[];
  Object? refusal;
  @override
  Future<Map<String, Object?>> readInlineAgent(String app, String node, {String? snapshotId, String? agentId}) async {
    identities.add([app, node, agentId, snapshotId]);
    if (refusal != null) throw refusal!;
    return response;
  }
}

Document workflow() => Document(
  nodes: [
    const Node(id: 'start', type: 'start', title: 'Start'),
    Node(
      id: 'node',
      type: 'agent',
      title: 'Agent',
      config: {
        'version': const VString('2'),
        'agent_node_kind': const VString('dify_agent'),
        'agent_binding': Value.fromJson(binding),
        'agent_task': const VString('Task in frozen graph'),
        'agent_declared_outputs': const VList([]),
      },
    ),
    Node(
      id: 'end',
      type: 'end',
      title: 'End',
      config: {
        'outputs': Value.fromJson([
          {
            'variable': 'answer',
            'value_selector': ['node', 'text'],
          },
        ]),
      },
    ),
  ],
  edges: [
    const Edge(id: 'a', source: 'start', target: 'node'),
    const Edge(id: 'b', source: 'node', target: 'end'),
  ],
);
void main() {
  final configured = <String, Object?>{
    'schema_version': 1,
    'model': {'plugin_id': 'vendor/plugin', 'model_provider': 'provider', 'model': 'fixture'},
    'prompt': {'system_prompt': 'Private prompt must not appear in MCP'},
    'config_files': <Object?>[],
    'tools': {'dify_tools': [], 'cli_tools': []},
  };
  ReadonlyWorkflowReader reader(_PinnedApi api) => ReadonlyWorkflowReader(
    snapshot: (_) async => (seq: 7, doc: workflow(), mode: 'workflow'),
    context: (app, doc, mode) async {
      final agents = await InlineAgentChecks.load(api, app, doc);
      return (env: ChecklistEnv(appMode: mode, inlineAgentSouls: agents.souls), unavailable: agents.unavailable);
    },
  );
  test('MCP and editor use the exact frozen config identities and return identical checks', () async {
    final api = _PinnedApi()..response = {...composerReply(), 'agent_soul': configured};
    final result = await reader(api).read('app', check: true);
    expect(api.identities, [
      ['app', 'node', 'private-agent', 's1'],
    ]);
    expect(result['complete'], true);
    expect(result['gate_passed'], true);
    expect(result['warning_count'], 0);
    expect(jsonEncode(result), isNot(contains('Private prompt')));
    final env = ChecklistEnv(appMode: 'workflow', inlineAgentSouls: {'node': configured});
    expect(result['items'], [for (final item in computeChecklist(workflow(), env)) item.toJson()]);
    expect(result['publish_error'], checkBeforePublish(workflow(), env));
  });
  test('missing model and file are shared editor warnings that stop publishing', () async {
    final api = _PinnedApi()
      ..response = {
        ...composerReply(),
        'agent_soul': {
          ...configured,
          'model': null,
          'config_files': [
            {'name': 'missing', 'file_id': null, 'is_missing': true},
          ],
        },
      };
    final result = await reader(api).read('app', check: true);
    expect(result['complete'], true);
    expect(result['gate_passed'], false);
    expect(result['warning_count'], 1); // one node with two issue messages
    final issues =
        ((result['items'] as List).single as Map)['errorMessages'] ??
        ((result['items'] as List).single as Map)['error_messages'];
    expect(jsonEncode(result), contains('modelNotSelected'));
    expect(jsonEncode(result), contains('files.missing'));
    expect(issues, isNotNull);
    expect(result['publish_error'], isNotNull);
  });
  test('network failure and mismatched immutable response remain incomplete, never a zero gate', () async {
    for (final mismatch in [false, true]) {
      final api = _PinnedApi();
      if (mismatch) {
        api.response = {
          ...composerReply(selected: {...binding, 'current_snapshot_id': 'new-draft'}),
          'agent_soul': configured,
        };
      } else {
        api.refusal = const TransportException('not reachable', timeout: true);
      }
      final result = await reader(api).read('app', check: true);
      expect(result['complete'], false);
      expect(result['gate_passed'], false);
      expect(result['warning_count'], isNull);
    }
  });
  test('definitively missing config warns and unsupported active tools remain incomplete', () async {
    final missing = _PinnedApi()..refusal = const TransportException('missing', statusCode: 404);
    final absent = await reader(missing).read('app', check: true);
    expect(absent['complete'], true);
    expect(absent['gate_passed'], false);
    final active = _PinnedApi()
      ..response = {
        ...composerReply(),
        'agent_soul': {
          ...configured,
          'tools': {
            'dify_tools': [
              {'id': 'not-implemented'},
            ],
          },
        },
      };
    final unsupported = await reader(active).read('app', check: true);
    expect(unsupported['complete'], false);
    expect(unsupported['gate_passed'], false);
  });
  test('imported secrets and models without tool calls block both editor gates', () {
    final soul = {
      ...configured,
      'env': {
        'secret_refs': [
          {'name': 'TOKEN'},
        ],
      },
    };
    final checks = InlineAgentChecks.issues(
      soul,
      modelFeatures: {
        'vendor/plugin/provider/fixture': ['vision'],
      },
    );
    expect(checks.map((value) => value.key), containsAll(['inline.secretMissing', 'inline.toolCallsRequired']));
    final env = ChecklistEnv(
      appMode: 'workflow',
      inlineAgentSouls: {'node': soul},
      inlineAgentModelFeatures: {
        'vendor/plugin/provider/fixture': ['vision'],
      },
    );
    expect(checkBeforePublish(workflow(), env), isNotNull);
    expect(computeChecklist(workflow(), env).single.errorMessages.length, 2);
  });
}
