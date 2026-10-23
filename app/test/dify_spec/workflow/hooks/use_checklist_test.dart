// dify-spec: web/app/components/workflow/hooks/__tests__/use-checklist.spec.ts
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow/var_types.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/checklist_item.dart';
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

/// A config value from plain JSON.
Value _value(Object? plain) => switch (plain) {
  null => const VNull(),
  final bool b => VBool(b),
  final int i => VInt(i),
  final double d => VDouble(d),
  final String s => VString(s),
  final List l => VList([for (final e in l) _value(e)]),
  final Map m => VMap({for (final e in m.entries) '${e.key}': _value(e.value)}),
  _ => throw ArgumentError(plain),
};

/// The fixtures' `createNode`: a node of React Flow type [rfType] with Dify [data].
Node _node(String id, String type, String title, {Map<String, Object?> data = const {}, String? rfType}) => Node(
  id: id,
  type: type,
  title: title,
  config: {
    for (final e in data.entries) e.key: _value(e.value),
    if (rfType != null) '_dify_node': _value({'type': rfType}),
  },
);

var _edgeCount = 0;
Edge _edge(String source, String target) => Edge(id: 'edge-${++_edgeCount}', source: source, target: target);

Document _doc(List<Node> nodes, [List<Edge> edges = const []]) => Document(nodes: nodes, edges: edges);

// The spec's mocks.
late Map<String, NodeMeta> mockNodesMap;
late List<String> mockModelProviders;
late List<List<String>> mockUsedVars;
late Map<String, List<NodeOutputVars>> mockAvailableVarMap;
late List<DifyJson> buildInTools;
String? flowType;

String _valid(Map<String, Object?> data, ChecklistTranslate t, Map<String, Object?>? more) => '';

ChecklistEnv _env() => ChecklistEnv(
  appMode: 'workflow',
  nodesMeta: mockNodesMap,
  flowType: flowType,
  language: 'en',
  builtInTools: buildInTools,
  customTools: const [],
  workflowTools: const [],
  mcpTools: const [],
  strategyProviders: const [],
  modelProviders: mockModelProviders,
  usedVars: (_) => mockUsedVars,
  availableVars: (n) => mockAvailableVarMap[n.id] ?? const [],
  isSpecialVar: (_) => false,
  t: DifyTestTranslator().t,
);

List<ChecklistItem> useChecklist(List<Node> nodes, List<Edge> edges) => computeChecklist(_doc(nodes, edges), _env());

Node _start() => _node('start', 'start', 'Start');

({List<Node> nodes, List<Edge> edges}) buildConnectedGraph() => (
  nodes: [_start(), _node('code', 'code', 'Code'), _node('end', 'end', 'End')],
  edges: [_edge('start', 'code'), _edge('code', 'end')],
);

({List<Node> nodes, List<Edge> edges}) buildLegacyAgentGraph() => (
  nodes: [
    _start(),
    _node(
      'legacy-agent',
      'agent',
      'Legacy Agent',
      data: {'agent_strategy_provider_name': 'provider', 'agent_strategy_name': 'strategy'},
    ),
  ],
  edges: [_edge('start', 'legacy-agent')],
);

void main() {
  setUp(() {
    mockNodesMap = {
      'start': const NodeMeta(isStart: true, checkValid: _valid),
      'code': const NodeMeta(checkValid: _valid),
      'llm': const NodeMeta(checkValid: _valid),
      'end': const NodeMeta(checkValid: _valid),
      'tool': const NodeMeta(checkValid: _valid),
      'agent-v2': const NodeMeta(checkValid: _valid),
    };
    mockModelProviders = [];
    mockUsedVars = [];
    mockAvailableVarMap = {};
    buildInTools = [];
    flowType = null;
  });

  group('useChecklist', () {
    test('should return empty list when all nodes are valid and connected', () {
      final g = buildConnectedGraph();
      expect(useChecklist(g.nodes, g.edges), isEmpty);
    });

    test('should detect disconnected nodes', () {
      final result = useChecklist(
        [_start(), _node('code', 'code', 'Code'), _node('llm', 'llm', 'LLM')],
        [_edge('start', 'code')],
      );
      final warning = result.firstWhere((i) => i.id == 'llm');
      expect(warning.unConnected, true);
    });

    test('should detect validation errors from checkValid', () {
      mockNodesMap['llm'] = NodeMeta(checkValid: (_, _, _) => 'Model not configured');
      final result = useChecklist([_start(), _node('llm', 'llm', 'LLM')], [_edge('start', 'llm')]);
      expect(result.firstWhere((i) => i.id == 'llm').errorMessages, contains('Model not configured'));
    });

    test('should validate legacy Agent nodes when their metadata is hidden by Agent v2', () {
      final g = buildLegacyAgentGraph();
      final result = useChecklist(g.nodes, g.edges);
      expect(result, hasLength(1));
      expect(result.single.id, 'legacy-agent');
      expect(result.single.errorMessages, ['workflow.nodes.agent.checkList.strategyNotSelected']);
    });

    test('should pass flow type to node validators', () {
      final calls = <(Map<String, Object?>, Map<String, Object?>?)>[];
      mockNodesMap['llm'] = NodeMeta(
        checkValid: (data, t, more) {
          calls.add((data, more));
          return '';
        },
      );
      flowType = 'snippet';
      useChecklist([_start(), _node('llm', 'llm', 'LLM')], [_edge('start', 'llm')]);
      expect(calls, hasLength(1));
      expect(calls.single.$1['type'], 'llm');
      expect(calls.single.$2?['flowType'], 'snippet');
    });

    test('should report missing start node in workflow mode', () {
      final result = useChecklist([_node('code', 'code', 'Code')], []);
      final startRequired = result.firstWhere((i) => i.id == 'start-node-required');
      expect(startRequired.canNavigate, false);
    });

    test('should not report the global missing start node item when a start placeholder is present', () {
      mockNodesMap['start-placeholder'] = NodeMeta(
        checkValid: (_, _, _) => 'workflow.nodes.startPlaceholder.validationRequired',
      );
      final result = useChecklist([_node('start-placeholder', 'start-placeholder', 'Workflow start')], []);
      expect(result.where((i) => i.id == 'start-node-required'), isEmpty);
      expect(result, hasLength(1));
      expect(
        (result.single.id, result.single.type, result.single.unConnected),
        (
          'start-placeholder',
          'start-placeholder',
          false,
        ),
      );
      expect(result.single.errorMessages, ['workflow.nodes.startPlaceholder.validationRequired']);
    });

    test('should detect plugin not installed', () {
      final tool = _node(
        'tool',
        'tool',
        'My Tool',
        data: {
          'provider_type': 'builtin',
          'provider_id': 'missing-provider',
          'plugin_unique_identifier': 'plugin/tool@0.0.1',
        },
      );
      final warning = useChecklist([_start(), tool], [_edge('start', 'tool')]).firstWhere((i) => i.id == 'tool');
      expect(warning.canNavigate, false);
      expect(warning.disableGoTo, true);
      expect(warning.isPluginMissing, true);
      expect(warning.pluginUniqueIdentifier, 'plugin/tool@0.0.1');
      expect(warning.errorMessages, contains('workflow.nodes.common.pluginNotInstalled'));
    });

    test('should report required node types that are missing', () {
      mockNodesMap['end'] = const NodeMeta(isRequired: true, checkValid: _valid);
      final requiredItem = useChecklist([_start()], []).firstWhere((i) => i.id == 'end-need-added');
      expect(requiredItem.canNavigate, false);
    });

    test('should not flag start nodes as unconnected', () {
      final result = useChecklist([_start(), _node('code', 'code', 'Code')], []);
      expect(result.where((i) => i.id == 'start'), isEmpty);
    });

    test('should skip nodes without CUSTOM_NODE type', () {
      final alien = _node('alien', 'code', 'Non-Custom', rfType: 'not-custom');
      final result = useChecklist([_start(), alien], []);
      expect(result.where((i) => i.id == 'alien'), isEmpty);
    });

    test('should report configure model errors when an llm model provider plugin is missing', () {
      final llm = _node(
        'llm',
        'llm',
        'LLM',
        data: {
          'model': {'provider': 'langgenius/openai/openai'},
        },
      );
      final warning = useChecklist([_start(), llm], [_edge('start', 'llm')]).firstWhere((i) => i.id == 'llm');
      expect(warning.errorMessages, contains('workflow.errorMsg.configureModel'));
      expect(warning.canNavigate, true);
    });

    test('should accumulate validation and invalid variable errors for the same node', () {
      mockNodesMap['llm'] = NodeMeta(checkValid: (_, _, _) => 'Model not configured');
      mockUsedVars = [
        ['start', 'missingVar'],
      ];
      mockAvailableVarMap['llm'] = [
        const NodeOutputVars('start', 'Start', [DifyVar('existingVar', 'string')]),
      ];
      final warning = useChecklist(
        [
          _start(),
          _node('llm', 'llm', 'LLM'),
        ],
        [_edge('start', 'llm')],
      ).firstWhere((i) => i.id == 'llm');
      expect(warning.errorMessages, ['Model not configured', 'workflow.errorMsg.invalidVariable']);
    });

    test('should detect duplicate output variables across end nodes', () {
      Node end(String id, String title) => _node(
        id,
        'end',
        title,
        data: {
          'outputs': [
            {
              'variable': 'workflow_id',
              'value_selector': ['sys', 'workflow_id'],
            },
          ],
        },
      );
      final result = useChecklist(
        [_start(), end('end-1', 'Output 1'), end('end-2', 'Output 2')],
        [_edge('start', 'end-1'), _edge('start', 'end-2')],
      );
      for (final id in ['end-1', 'end-2']) {
        final warning = result.firstWhere((i) => i.id == id);
        expect(warning.errorMessages.any((m) => m.contains('duplicateOutputVariable')), true);
      }
    });

    test('should sync checklist items to the workflow store without render phase update warnings', () {
      final store = WorkflowStore();
      var notified = 0;
      store.checklistItems.addListener(() => notified++);
      final items = useChecklist([_start(), _node('code', 'code', 'Code')], []);
      syncChecklistItems(store, items);
      expect(store.checklistItems.value, hasLength(1));
      // Unchanged items do not notify again (Dify's isDeepEqual guard).
      syncChecklistItems(store, useChecklist([_start(), _node('code', 'code', 'Code')], []));
      expect(notified, 1);
      store.dispose();
    });
  });

  group('useChecklistBeforePublish', () {
    test('should reject an invalid legacy Agent instead of throwing when its metadata is hidden', () {
      final g = buildLegacyAgentGraph();
      final error = checkBeforePublish(_doc(g.nodes, g.edges), _env());
      expect(error, '[Legacy Agent] workflow.nodes.agent.checkList.strategyNotSelected');
    });
  });

  group('useWorkflowRunValidation', () {
    test('should return hasValidationErrors false when there are no warnings', () {
      final g = buildConnectedGraph();
      final result = WorkflowRunValidation.of(_doc(g.nodes, g.edges), _env());
      expect(result.hasValidationErrors, false);
      expect(result.warningNodes, isEmpty);
    });

    test('should return validateBeforeRun as a function that returns true when valid', () {
      final g = buildConnectedGraph();
      final result = WorkflowRunValidation.of(_doc(g.nodes, g.edges), _env());
      final toasts = <String>[];
      expect(result.validateBeforeRun(toasts.add), true);
      expect(toasts, isEmpty);
    });
  });
}
