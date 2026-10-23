// dify-spec: web/app/components/workflow-app/hooks/__tests__/use-workflow-run.spec.ts
// dify-spec: web/app/components/workflow-app/hooks/__tests__/use-workflow-run-utils.spec.ts
// The service (mock runtime) stands where Dify's tests mock `ssePost` / `post` / `stopWorkflowRun`: its requests are
// what the controller sent. Endpoint URLs belong to the service implementation, not to the controller.
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('useWorkflowRun', () {
    late WorkflowStore store;
    late MockWorkflowRunService service;
    late WorkflowRunController hook;
    var cancelSelection = 0;
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'node-1', type: 'start'),
        RunGraphNode(id: 'schedule-1', type: 'trigger-schedule'),
        RunGraphNode(id: 'webhook-1', type: 'trigger-webhook'),
        RunGraphNode(id: 'plugin-1', type: 'trigger-plugin'),
        RunGraphNode(id: 'trigger-1', type: 'trigger-webhook'),
        RunGraphNode(id: 'trigger-2', type: 'trigger-plugin'),
      ],
    );

    setUp(() {
      store = WorkflowStore();
      service = MockWorkflowRunService(
        graph: () => graph,
        scenario: const MockRunScenario(stepDelay: Duration.zero, triggerDelay: Duration(seconds: 1)),
      );
      cancelSelection = 0;
      hook = WorkflowRunController(
        store: store,
        service: service,
        graph: graph,
        onCancelSelection: () => cancelSelection++,
      );
    });
    tearDown(() {
      hook.dispose();
      store.dispose();
    });

    test('should prepare the graph and dispatch a workflow run through ssePost for user-input mode', () async {
      store
        ..setNodeRunData('node-1', {'_runningStatus': NodeRunningStatus.succeeded})
        ..setHistoryWorkflowData({'id': 'old'})
        ..setIsListening(true)
        ..setListeningTriggerType('trigger-webhook')
        ..setListeningTriggerNodeId('x')
        ..setListeningTriggerNodeIds(['x'])
        ..setListeningTriggerIsAll(true);
      await hook.handleRun({
        'inputs': {'query': 'hello'},
      });
      expect(cancelSelection, 1);
      expect(store.nodeRunDataOf('node-1').containsKey('_runningStatus'), isFalse);
      expect(store.historyWorkflowData.value, isNull);
      expect(store.isListening.value, isFalse);
      expect(store.listeningTriggerType.value, isNull);
      expect(store.listeningTriggerNodeId.value, isNull);
      expect(store.listeningTriggerNodeIds.value, isEmpty);
      expect(store.listeningTriggerIsAll.value, isFalse);
      expect(resultOf(store.workflowRunningData.value)['status'], WorkflowRunningStatus.running);
      final request = service.requests.single as WorkflowDraftRunRequest;
      expect(request.mode, TriggerType.userInput);
      expect(request.body, {
        'inputs': {'query': 'hello'},
      });
    });

    test('should dispatch \$title trigger runs through the debug runner integration', () async {
      for (final (params, options, body, nodeIds, isAll) in [
        (
          const <String, Object?>{},
          const HandleRunOptions(mode: TriggerType.schedule, scheduleNodeId: 'schedule-1'),
          {'node_id': 'schedule-1'},
          ['schedule-1'],
          false,
        ),
        (
          const {'node_id': 'webhook-1'},
          const HandleRunOptions(mode: TriggerType.webhook, webhookNodeId: 'webhook-1'),
          {'node_id': 'webhook-1'},
          ['webhook-1'],
          false,
        ),
        (
          const {'node_id': 'plugin-1'},
          const HandleRunOptions(mode: TriggerType.plugin, pluginNodeId: 'plugin-1'),
          {'node_id': 'plugin-1'},
          ['plugin-1'],
          false,
        ),
        (
          const {
            'node_ids': ['trigger-1', 'trigger-2'],
          },
          const HandleRunOptions(mode: TriggerType.all, allNodeIds: ['trigger-1', 'trigger-2']),
          {
            'node_ids': ['trigger-1', 'trigger-2'],
          },
          ['trigger-1', 'trigger-2'],
          true,
        ),
      ]) {
        service.requests.clear();
        await hook.handleRun(params, options: options);
        final request = service.requests.single as WorkflowDraftRunRequest;
        expect(request.mode, options.mode);
        expect(request.body, body);
        expect(store.isListening.value, isTrue);
        expect(store.listeningTriggerNodeIds.value, nodeIds);
        expect(store.listeningTriggerIsAll.value, isAll);
        hook.handleStopRun('');
      }
    });

    test('should stop workflow runs by task id or by aborting active debug controllers', () async {
      await hook.handleRun({
        'inputs': {'query': 'hello'},
      });
      hook.handleStopRun('task-1');
      expect(service.stoppedTasks, ['task-1']);
      expect(resultOf(store.workflowRunningData.value)['status'], WorkflowRunningStatus.stopped);

      // A trigger debug run listening: stopping without a task id aborts it, nothing runs when the trigger fires.
      await hook.handleRun(
        {'node_id': 'webhook-1'},
        options: const HandleRunOptions(mode: TriggerType.webhook, webhookNodeId: 'webhook-1'),
      );
      expect(store.isListening.value, isTrue);
      hook.handleStopRun('');
      expect(store.isListening.value, isFalse);
      expect(resultOf(store.workflowRunningData.value)['status'], WorkflowRunningStatus.stopped);
      await Future<void>.delayed(const Duration(milliseconds: 1100));
      await pumpEventQueue();
      expect(resultOf(store.workflowRunningData.value)['status'], WorkflowRunningStatus.stopped);
      expect(tracingOf(store.workflowRunningData.value), isEmpty);
    });
  });

  group('useWorkflowRun utils', () {
    test('should build request bodies and validation errors for trigger runs', () {
      expect(
        buildWorkflowRunRequestBody(
          TriggerType.schedule,
          {},
          const HandleRunOptions(scheduleNodeId: 'schedule-1'),
        ),
        {'node_id': 'schedule-1'},
      );
      expect(buildWorkflowRunRequestBody(TriggerType.webhook, {}, const HandleRunOptions(webhookNodeId: 'webhook-1')), {
        'node_id': 'webhook-1',
      });
      expect(buildWorkflowRunRequestBody(TriggerType.plugin, {}, const HandleRunOptions(pluginNodeId: 'plugin-1')), {
        'node_id': 'plugin-1',
      });
      expect(
        buildWorkflowRunRequestBody(
          TriggerType.all,
          {},
          const HandleRunOptions(allNodeIds: ['trigger-1', 'trigger-2']),
        ),
        {
          'node_ids': ['trigger-1', 'trigger-2'],
        },
      );
      expect(
        buildWorkflowRunRequestBody(TriggerType.userInput, {
          'inputs': {'query': 'hello'},
        }),
        {
          'inputs': {'query': 'hello'},
        },
      );
      expect(validateWorkflowRunRequest(TriggerType.schedule), 'handleRun: schedule trigger run requires node id');
      expect(validateWorkflowRunRequest(TriggerType.webhook), 'handleRun: webhook trigger run requires node id');
      expect(validateWorkflowRunRequest(TriggerType.plugin), 'handleRun: plugin trigger run requires node id');
      expect(validateWorkflowRunRequest(TriggerType.all), '');
      expect(validateWorkflowRunRequest(TriggerType.all, const HandleRunOptions(allNodeIds: [])), '');
    });

    test('should configure listening state for trigger and non-trigger modes', () {
      final trigger = WorkflowStore();
      applyRunningStateForMode(
        trigger,
        TriggerType.all,
        const HandleRunOptions(allNodeIds: ['trigger-1', 'trigger-2']),
      );
      expect(trigger.isListening.value, isTrue);
      expect(trigger.showVariableInspectPanel.value, isTrue);
      expect(trigger.listeningTriggerIsAll.value, isTrue);
      expect(trigger.listeningTriggerNodeIds.value, ['trigger-1', 'trigger-2']);
      expect(trigger.workflowRunningData.value, createRunningWorkflowState());

      final normal = WorkflowStore()
        ..setIsListening(true)
        ..setListeningTriggerType('trigger-webhook')
        ..setListeningTriggerNodeId('x')
        ..setListeningTriggerNodeIds(['x'])
        ..setListeningTriggerIsAll(true);
      applyRunningStateForMode(normal, TriggerType.userInput);
      expect(normal.isListening.value, isFalse);
      expect(normal.listeningTriggerType.value, isNull);
      expect(normal.listeningTriggerNodeId.value, isNull);
      expect(normal.listeningTriggerNodeIds.value, isEmpty);
      expect(normal.listeningTriggerIsAll.value, isFalse);
      expect(normal.workflowRunningData.value, createRunningWorkflowState());
    });

    test('should clear listening state, stop state, and remove debug controllers', () {
      final listening = WorkflowStore()
        ..setIsListening(true)
        ..setListeningTriggerType('trigger-webhook')
        ..setListeningTriggerNodeId('x')
        ..setListeningTriggerNodeIds(['x'])
        ..setListeningTriggerIsAll(true);
      clearListeningState(listening);
      expect(listening.isListening.value, isFalse);
      expect(listening.listeningTriggerType.value, isNull);
      expect(listening.listeningTriggerNodeId.value, isNull);
      expect(listening.listeningTriggerNodeIds.value, isEmpty);
      expect(listening.listeningTriggerIsAll.value, isFalse);

      final stopped = WorkflowStore();
      applyStoppedState(stopped);
      expect(stopped.workflowRunningData.value, createStoppedWorkflowState());
      expect(stopped.showVariableInspectPanel.value, isTrue);
      // The debug controllers are the controller's stream handles (no window globals): see useWorkflowRun's stop.
    });

    test('should derive listening node ids, tts config, and published workflow mappings', () {
      expect(
        buildListeningTriggerNodeIds(TriggerType.webhook, const HandleRunOptions(webhookNodeId: 'webhook-1')),
        ['webhook-1'],
      );
      expect(
        buildListeningTriggerNodeIds(TriggerType.schedule, const HandleRunOptions(scheduleNodeId: 'schedule-1')),
        ['schedule-1'],
      );
      expect(buildListeningTriggerNodeIds(TriggerType.plugin, const HandleRunOptions(pluginNodeId: 'plugin-1')), [
        'plugin-1',
      ]);
      expect(
        buildListeningTriggerNodeIds(TriggerType.all, const HandleRunOptions(allNodeIds: ['trigger-1', 'trigger-2'])),
        ['trigger-1', 'trigger-2'],
      );
      // Text-to-speech and restoring a published workflow over the draft are not ported (no audio player; the
      // collaborative document is never replaced by a version).
    });

    test('should expose the canonical workflow state factories', () {
      expect(resultOf(createRunningWorkflowState())['status'], WorkflowRunningStatus.running);
      expect(resultOf(createStoppedWorkflowState())['status'], WorkflowRunningStatus.stopped);
      expect(resultOf(createFailedWorkflowState('failed'))['status'], WorkflowRunningStatus.failed);
    });
  });
}
