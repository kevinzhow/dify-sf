// dify-spec: web/app/components/workflow-app/hooks/__tests__/use-workflow-start-run.spec.tsx
// The draft sync before a run is not ported (the collaborative document is the draft): Dify's
// `doSyncWorkflowDraft` expectations are left out; store setters are checked by the state they leave.
import 'package:dify_sf_app/src/workflow_editor/header/test_run_menu.dart' show TriggerType;
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _Run = ({DifyJson? params, RunCallbacks? callback, HandleRunOptions? options});

/// The hook with `handleRun` and `handleCancelDebugAndPreviewPanel` mocked.
class _Hook extends WorkflowRunController {
  _Hook(this.nodes, {required super.store, bool chat = false})
    : super(
        service: MockWorkflowRunService(graph: () => const StaticRunGraph()),
        graph: _Graph(nodes),
        isChatMode: () => chat,
      );

  final List<RunGraphNode> nodes;
  final runs = <_Run>[];
  var cancelled = 0;

  @override
  Future<void> handleRun(DifyJson? params, {RunCallbacks? callback, HandleRunOptions? options}) async =>
      runs.add((params: params, callback: callback, options: options));

  @override
  void handleCancelDebugAndPreviewPanel() => cancelled++;
}

class _Graph implements RunGraph {
  _Graph(this.nodes);
  @override
  final List<RunGraphNode> nodes;
  @override
  List<RunGraphEdge> get edges => const [];
}

void main() {
  group('useWorkflowStartRunByCanEdit', () {
    late WorkflowStore store;
    late List<RunGraphNode> nodes;

    setUp(() {
      store = WorkflowStore()
        ..setShowEnvPanel(true)
        ..setFeatures({
          'file_upload': {
            'image': {'enabled': false},
          },
        });
      nodes = [
        const RunGraphNode(id: 'inset-s-1', type: 'start', data: {'type': 'start', 'variables': <Object?>[]}),
      ];
    });
    tearDown(() => store.dispose());

    _Hook hook({bool chat = false}) => _Hook(nodes, store: store, chat: chat);

    void expectOptions(
      HandleRunOptions? o, {
      required TriggerType mode,
      String? schedule,
      String? webhook,
      String? plugin,
      List<String>? all,
    }) {
      expect(o?.mode, mode);
      expect(o?.scheduleNodeId, schedule);
      expect(o?.webhookNodeId, webhook);
      expect(o?.pluginNodeId, plugin);
      expect(o?.allNodeIds, all);
    }

    test('should run the workflow immediately when there are no start variables and no image upload input', () async {
      final h = hook();
      store.setShowGlobalVariablePanel(true);
      await h.handleWorkflowStartRunInWorkflow();
      expect(store.showEnvPanel.value, isFalse);
      expect(store.showGlobalVariablePanel.value, isFalse);
      expect(h.runs.single.params, {'inputs': <String, Object?>{}, 'files': <Object?>[]});
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(store.showInputsPanel.value, isFalse);
    });

    test('should not sync or run when only the start placeholder exists', () async {
      nodes = [const RunGraphNode(id: 'start-placeholder', type: 'start-placeholder')];
      final h = hook();
      await h.handleWorkflowStartRunInWorkflow();
      expect(h.runs, isEmpty);
      expect(store.showDebugAndPreviewPanel.value, isFalse);
      expect(store.showInputsPanel.value, isFalse);
    });

    test('should open the input panel instead of running immediately when start inputs are required', () async {
      nodes = [
        const RunGraphNode(
          id: 'inset-s-1',
          type: 'start',
          data: {
            'variables': [
              {'name': 'query'},
            ],
          },
        ),
      ];
      final h = hook();
      await h.handleWorkflowStartRunInWorkflow();
      expect(h.runs, isEmpty);
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(store.showInputsPanel.value, isTrue);
    });

    test('should open the input panel when image upload is enabled even without start variables', () async {
      store.setFeatures({
        'file_upload': {
          'image': {'enabled': true},
        },
      });
      final h = hook();
      await h.handleWorkflowStartRunInWorkflow();
      expect(h.runs, isEmpty);
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(store.showInputsPanel.value, isTrue);
    });

    test(
      'should cancel the current debug panel instead of starting another workflow when one is already open',
      () async {
        store.setShowDebugAndPreviewPanel(true);
        final h = hook();
        await h.handleWorkflowStartRunInWorkflow();
        expect(h.cancelled, 1);
        expect(h.runs, isEmpty);
      },
    );

    test('should short-circuit workflow start when a run is already in progress', () async {
      store.setWorkflowRunningData({
        'result': {'status': WorkflowRunningStatus.running},
      });
      final h = hook();
      await h.handleWorkflowStartRunInWorkflow();
      expect(store.showEnvPanel.value, isTrue, reason: 'setShowEnvPanel not called');
      expect(h.runs, isEmpty);
    });

    test('should configure schedule trigger runs and execute the workflow with schedule options', () async {
      nodes = [const RunGraphNode(id: 'schedule-1', type: 'trigger-schedule')];
      store.setShowGlobalVariablePanel(true);
      final h = hook();
      await h.handleWorkflowTriggerScheduleRunInWorkflow('schedule-1');
      expect(store.showEnvPanel.value, isFalse);
      expect(store.showGlobalVariablePanel.value, isFalse);
      expect(store.listeningTriggerType.value, 'trigger-schedule');
      expect(store.listeningTriggerNodeId.value, 'schedule-1');
      expect(store.listeningTriggerNodeIds.value, ['schedule-1']);
      expect(store.listeningTriggerIsAll.value, isFalse);
      final run = h.runs.single;
      expect(run.params, isEmpty);
      expect(run.callback, isNull);
      expectOptions(run.options, mode: TriggerType.schedule, schedule: 'schedule-1');
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(store.showInputsPanel.value, isFalse);
    });

    test('should cancel schedule trigger execution when the debug panel is already open', () async {
      store.setShowDebugAndPreviewPanel(true);
      nodes = [const RunGraphNode(id: 'schedule-1', type: 'trigger-schedule')];
      final h = hook();
      await h.handleWorkflowTriggerScheduleRunInWorkflow('schedule-1');
      expect(h.cancelled, 1);
      expect(h.runs, isEmpty);
    });

    test('should ignore \$title trigger execution when the node id is empty', () async {
      for (final invoke in <Future<void> Function(_Hook h)>[
        (h) => h.handleWorkflowTriggerScheduleRunInWorkflow(null),
        (h) => h.handleWorkflowTriggerWebhookRunInWorkflow(''),
        (h) => h.handleWorkflowTriggerPluginRunInWorkflow(''),
      ]) {
        final h = hook();
        await invoke(h);
        expect(h.runs, isEmpty);
      }
    });

    test('should warn when the \$title trigger node cannot be found', () async {
      nodes = [const RunGraphNode(id: 'other-node', type: 'start')];
      for (final invoke in <Future<void> Function(_Hook h)>[
        (h) => h.handleWorkflowTriggerScheduleRunInWorkflow('schedule-missing'),
        (h) => h.handleWorkflowTriggerWebhookRunInWorkflow('webhook-missing'),
        (h) => h.handleWorkflowTriggerPluginRunInWorkflow('plugin-missing'),
      ]) {
        final h = hook();
        await invoke(h);
        expect(h.runs, isEmpty);
      }
    });

    test('should configure \$title trigger runs with node-specific options', () async {
      for (final (nodeId, nodeType, mode) in [
        ('webhook-1', 'trigger-webhook', TriggerType.webhook),
        ('plugin-1', 'trigger-plugin', TriggerType.plugin),
      ]) {
        nodes = [RunGraphNode(id: nodeId, type: nodeType)];
        store
          ..setShowEnvPanel(true)
          ..setShowDebugAndPreviewPanel(false)
          ..setShowInputsPanel(true);
        final h = hook();
        if (mode == TriggerType.webhook) {
          await h.handleWorkflowTriggerWebhookRunInWorkflow(nodeId);
        } else {
          await h.handleWorkflowTriggerPluginRunInWorkflow(nodeId);
        }
        expect(store.showEnvPanel.value, isFalse);
        expect(store.showGlobalVariablePanel.value, isFalse);
        expect(store.showDebugAndPreviewPanel.value, isTrue);
        expect(store.showInputsPanel.value, isFalse);
        expect(store.listeningTriggerType.value, nodeType);
        expect(store.listeningTriggerNodeId.value, nodeId);
        expect(store.listeningTriggerNodeIds.value, [nodeId]);
        expect(store.listeningTriggerIsAll.value, isFalse);
        expect(h.runs.single.params, {'node_id': nodeId});
        expectOptions(
          h.runs.single.options,
          mode: mode,
          webhook: mode == TriggerType.webhook ? nodeId : null,
          plugin: mode == TriggerType.plugin ? nodeId : null,
        );
      }
    });

    test('should run all triggers and mark the listener state as global', () async {
      store
        ..setShowInputsPanel(true)
        ..setListeningTriggerNodeId('x');
      final h = hook();
      await h.handleWorkflowRunAllTriggersInWorkflow(['trigger-1', 'trigger-2']);
      expect(store.showEnvPanel.value, isFalse);
      expect(store.showGlobalVariablePanel.value, isFalse);
      expect(store.showInputsPanel.value, isFalse);
      expect(store.listeningTriggerIsAll.value, isTrue);
      expect(store.listeningTriggerNodeIds.value, ['trigger-1', 'trigger-2']);
      expect(store.listeningTriggerNodeId.value, isNull);
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(h.runs.single.params, {
        'node_ids': ['trigger-1', 'trigger-2'],
      });
      expectOptions(h.runs.single.options, mode: TriggerType.all, all: ['trigger-1', 'trigger-2']);
    });

    test('should ignore run-all requests when there are no trigger nodes', () async {
      final h = hook();
      await h.handleWorkflowRunAllTriggersInWorkflow([]);
      expect(store.listeningTriggerIsAll.value, isFalse);
      expect(h.runs, isEmpty);
    });

    test('should route handleStartWorkflowRun to the chatflow path when chat mode is enabled', () async {
      store
        ..setShowChatVariablePanel(true)
        ..setHistoryWorkflowData({'id': 'run-1'});
      final h = hook(chat: true);
      h.handleStartWorkflowRun();
      await pumpEventQueue();
      expect(store.showEnvPanel.value, isFalse);
      expect(store.showChatVariablePanel.value, isFalse);
      expect(store.showGlobalVariablePanel.value, isFalse);
      expect(store.showDebugAndPreviewPanel.value, isTrue);
      expect(store.historyWorkflowData.value, isNull);
      expect(h.runs, isEmpty);
    });
  });
}
