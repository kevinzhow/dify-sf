import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/agents/inline_checks.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
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

Document workflow({Object? selected = binding}) => Document(
  nodes: [
    const Node(id: 'start', type: 'start', title: 'Start'),
    Node(
      id: 'node',
      type: 'agent',
      title: 'Agent',
      config: {
        'version': const VString('2'),
        'agent_node_kind': const VString('dify_agent'),
        'agent_binding': Value.fromJson(selected),
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
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async { await DifyI18n.load('en-US'); });
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
    expect(jsonEncode(result), contains(DifyI18n.tr('workflow', 'nodes.agent.modelNotSelected')));
    expect(jsonEncode(result), contains(DifyI18n.tr('agent-v-2', 'agentDetail.configure.files.missing')));
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
  test('portable task attachments and nested file defaults remain missing until repaired', () async {
    final api = _PinnedApi()
      ..response = {
        ...composerReply(),
        'agent_soul': configured,
        'node_job': {
          'metadata': {
            'file_refs': [
              {'name': 'Task file 1', 'is_missing': true},
            ],
          },
        },
      };
    final loaded = await InlineAgentChecks.load(api, 'app', workflow());
    final declarations = <Object?>[
      {
        'name': 'bundle',
        'type': 'object',
        'children': [
          {
            'name': 'artifacts',
            'type': 'array',
            'array_item': {'type': 'file'},
          },
        ],
        'failure_strategy': {
          'on_failure': 'default_value',
          'default_value': {
            'artifacts': [
              {'transfer_method': 'tool_file', 'reference': InlineAgentChecks.omittedFileReference},
            ],
          },
        },
      },
    ];
    final issues = InlineAgentChecks.issues(loaded.souls['node'], declarations: declarations);
    expect(issues.map((issue) => issue.key), containsAll(['inline.taskFileMissing', 'inline.defaultFileMissing']));
    expect(InlineAgentChecks.missingFileReference({'upload_file_id': '00000000-0000-0000-0000-000000000001'}), false);
    expect(InlineAgentChecks.missingFileReference({'reference': InlineAgentChecks.omittedFileReference}), true);
  });

  test('roster bindings and incompatible tool-capable models cannot pass either gate', () {
    final roster = workflow(selected: {'binding_type': 'roster_agent', 'agent_id': 'other'});
    final env = ChecklistEnv(appMode: 'workflow');
    expect(computeChecklist(roster, env).single.errorMessages.join(), contains(DifyI18n.tr('agent-v-2', 'inline.unsupported')));
    expect(checkBeforePublish(roster, env), contains(DifyI18n.tr('agent-v-2', 'inline.unsupported')));
    final blocked = {
      ...configured,
      'model': {'plugin_id': 'vendor/plugin', 'model_provider': 'provider', 'model': 'gpt-4o'},
    };
    final issues = InlineAgentChecks.issues(
      blocked,
      modelFeatures: {
        'vendor/plugin/provider/gpt-4o': ['tool-call'],
      },
    );
    expect(issues.map((v) => v.key), contains('inline.modelUnsupported'));
    expect(inlineAgentModelCompatible('claude-sonnet-4-5'), true);
    expect(inlineAgentModelCompatible('GPT-4o'), false);
  });
  test('pinned vendor exclusions apply to English catalog labels, including opaque provider IDs', () {
    for (final label in ['o3', 'claude-3-7-sonnet', 'deepseek-chat', 'qwen3-32b', 'gemini-2.0-flash', 'glm-4', 'minimax-m2']) {
      expect(inlineAgentModelCompatible(label), false, reason: label);
      final issues = InlineAgentChecks.issues({...configured, 'model': {
        'plugin_id': 'vendor/plugin', 'model_provider': 'provider', 'model': 'opaque-id',
      }}, modelLabels: {'vendor/plugin/provider/opaque-id': label}, modelFeatures: {'vendor/plugin/provider/opaque-id': ['tool-call']});
      expect(issues.map((v) => v.key), contains('inline.modelUnsupported'), reason: label);
    }
    final allowed = InlineAgentChecks.issues({...configured, 'model': {
      'plugin_id': 'vendor/plugin', 'model_provider': 'provider', 'model': 'deepseek-chat',
    }}, modelLabels: {'vendor/plugin/provider/deepseek-chat': 'Approved vendor alias'}, modelFeatures: {'vendor/plugin/provider/deepseek-chat': ['tool-call']});
    expect(allowed.map((v) => v.key), isNot(contains('inline.modelUnsupported')));
  });

  Map<String, Object?> profiles({String status = 'ok'}) => {
    'shell_enabled': true,
    'profiles': [
      {
        'name': 'default',
        'description': 'Default shell',
        'status': 'ok',
        'timeout_seconds_max': 1800,
      },
      {
        'name': 'rendering',
        'description': 'Prepared rendering tools',
        'status': status,
        'timeout_seconds_max': 10800,
      },
    ],
  };
  test('known missing profiles block editor and native checks while imports keep their name', () async {
    for (final name in ['rendering', 'imported-environment']) {
      final api = _PinnedApi()
        ..response = {
          ...composerReply(),
          'agent_soul': {...configured, 'executor_profile': name},
        }
        ..executorContext = profiles(status: 'image_missing');
      final loaded = await InlineAgentChecks.load(api, 'app', workflow());
      expect(loaded.souls['node']?['executor_profile'], name);
      expect(loaded.unavailable, isEmpty);
      final env = ChecklistEnv(inlineAgentSouls: loaded.souls);
      expect(
        WorkflowRunValidation.of(workflow(), env).validateBeforeRun((_) {}),
        false,
      );
      expect(checkBeforePublish(workflow(), env), contains(name));
      final checked = await reader(api).read('app', check: true);
      expect(checked['complete'], true);
      expect(checked['gate_passed'], false);
    }
  });
  test('unknown catalog is visible but does not block an actual run; native check stays incomplete', () async {
    final api = _PinnedApi()
      ..response = {
        ...composerReply(),
        'agent_soul': {...configured, 'executor_profile': 'rendering'},
      }
      ..executorFailure = const TransportException('down', timeout: true);
    final loaded = await InlineAgentChecks.load(api, 'app', workflow());
    final env = ChecklistEnv(inlineAgentSouls: loaded.souls);
    final warnings = computeChecklist(workflow(), env);
    expect(
      warnings.single.errorMessages.single,
      contains('could not be checked'),
    );
    expect(warnings.single.blocksRun, false);
    expect(
      WorkflowRunValidation.of(
        workflow(),
        env,
      ).validateBeforeRun((_) => fail('Unknown availability blocked a run')),
      true,
    );
    expect(checkBeforePublish(workflow(), env), isNull);
    final native = await reader(api).read('app', check: true);
    expect(native['complete'], false);
    expect(native['gate_passed'], false);
    expect(native['unavailable_context'], contains('agent_executor_profiles'));
    // A real configuration failure must still block when profile availability is unknown.
    final broken = InlineAgentChecks(
      souls: {
        'node': {...loaded.souls['node']!, 'model': null},
      },
    );
    expect(
      WorkflowRunValidation.of(
        workflow(),
        ChecklistEnv(inlineAgentSouls: broken.souls),
      ).hasValidationErrors,
      true,
    );
  });
  test('refreshing health preserves snapshots and Shell off retains the selected name', () {
    const original = InlineAgentChecks(
      souls: {
        'node': {'executor_profile': 'rendering'},
      },
    );
    final missing = original.withExecutors(
      AgentExecutorContext.parse(profiles(status: 'device_missing')),
    );
    expect(
      missing.souls['node']?['_executor_profile_status'],
      'device_missing',
    );
    expect(
      original.souls['node']?.containsKey('_executor_profile_status'),
      false,
    );
    final disabled = missing.withExecutors(
      const AgentExecutorContext(shellEnabled: false),
    );
    expect(disabled.souls['node']?['executor_profile'], 'rendering');
    expect(
      disabled.souls['node']?.containsKey('_executor_profile_status'),
      false,
    );
    final restored = disabled.withExecutors(
      AgentExecutorContext.parse(profiles()),
    );
    expect(restored.souls['node']?['_executor_profile_status'], 'ok');
  });
}
