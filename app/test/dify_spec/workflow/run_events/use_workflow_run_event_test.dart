// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-agent-log.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-failed.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-finished.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-finished.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-human-input-form-filled.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-human-input-form-timeout.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-human-input-required.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-iteration-finished.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-iteration-next.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-iteration-started.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-loop-finished.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-loop-next.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-loop-started.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-retry.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-node-started.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-paused.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-reasoning.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-started.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-text-chunk.spec.ts
// dify-spec: web/app/components/workflow/hooks/use-workflow-run-event/__tests__/use-workflow-text-replace.spec.ts
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:flutter_test/flutter_test.dart';

import 'run_event_harness.dart';

const _running = NodeRunningStatus.running, _succeeded = NodeRunningStatus.succeeded;

void main() {
  group('useWorkflowAgentLog', () {
    test('creates agent_log when execution_metadata has none', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n1', 'execution_metadata': <String, Object?>{}},
          ],
        }),
      );
      h.events.handleWorkflowAgentLog(
        const AgentLogEvent({
          'data': {'node_id': 'n1', 'message_id': 'm1'},
        }),
      );
      final log = (h.tracing[0]['execution_metadata'] as Map)['agent_log'] as List;
      expect(log, hasLength(1));
      expect((log[0] as Map)['message_id'], 'm1');
    });

    test('appends to existing agent_log', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'tracing': [
            {
              'node_id': 'n1',
              'execution_metadata': {
                'agent_log': [
                  {'message_id': 'm1', 'text': 'log1'},
                ],
              },
            },
          ],
        }),
      );
      h.events.handleWorkflowAgentLog(
        const AgentLogEvent({
          'data': {'node_id': 'n1', 'message_id': 'm2'},
        }),
      );
      expect((h.tracing[0]['execution_metadata'] as Map)['agent_log'], hasLength(2));
    });

    test('updates an existing log entry by message_id', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'tracing': [
            {
              'node_id': 'n1',
              'execution_metadata': {
                'agent_log': [
                  {'message_id': 'm1', 'text': 'old'},
                ],
              },
            },
          ],
        }),
      );
      h.events.handleWorkflowAgentLog(
        const AgentLogEvent({
          'data': {'node_id': 'n1', 'message_id': 'm1', 'text': 'new'},
        }),
      );
      final log = (h.tracing[0]['execution_metadata'] as Map)['agent_log'] as List;
      expect(log, hasLength(1));
      expect((log[0] as Map)['text'], 'new');
    });

    test('creates execution_metadata when it does not exist', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n1'},
          ],
        }),
      );
      h.events.handleWorkflowAgentLog(
        const AgentLogEvent({
          'data': {'node_id': 'n1', 'message_id': 'm1'},
        }),
      );
      expect((h.tracing[0]['execution_metadata'] as Map)['agent_log'], hasLength(1));
    });
  });

  group('useWorkflowFailed', () {
    test('settles active workflow and canvas state as failed', () {
      final h = RunEventHarness(
        nodes: [
          createNode('running-node', data: {'_runningStatus': _running, '_waitingRun': false}),
          createNode('succeeded-node', data: {'_runningStatus': _succeeded, '_waitingRun': false}),
          createNode('waiting-node', data: {'_waitingRun': true}),
        ],
        edges: [
          createEdge(
            'running-edge',
            'succeeded-node',
            'running-node',
            data: {'_sourceRunningStatus': _succeeded, '_targetRunningStatus': _running, '_waitingRun': false},
          ),
          createEdge(
            'waiting-edge',
            'running-node',
            'waiting-node',
            data: {'_sourceRunningStatus': _running, '_waitingRun': true},
          ),
        ],
        workflowRunningData: baseRunningData({
          'tracing': [
            createNodeTracing(nodeId: 'running-node', status: _running),
            createNodeTracing(nodeId: 'succeeded-node', status: _succeeded),
          ],
        }),
      );
      h.events.handleWorkflowFailed('LLM provider and model are required.');
      expect(resultOf(h.state)['status'], WorkflowRunningStatus.failed);
      expect(resultOf(h.state)['error'], 'LLM provider and model are required.');
      expect(h.tracing.map((t) => t['status']), [NodeRunningStatus.failed, _succeeded]);
      expect(h.node('running-node'), {'_runningStatus': NodeRunningStatus.failed, '_waitingRun': false});
      expect(h.node('succeeded-node')['_runningStatus'], _succeeded);
      expect(h.node('waiting-node')['_waitingRun'], false);
      expect(h.edge('running-edge'), {
        '_sourceRunningStatus': _succeeded,
        '_targetRunningStatus': NodeRunningStatus.failed,
        '_waitingRun': false,
      });
      expect(h.edge('waiting-edge'), {'_sourceRunningStatus': NodeRunningStatus.failed, '_waitingRun': false});
    });

    test('ignores a late failure after the workflow has stopped', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'result': {'status': WorkflowRunningStatus.stopped},
        }),
      );
      h.events.handleWorkflowFailed();
      expect(resultOf(h.state)['status'], WorkflowRunningStatus.stopped);
    });

    test('adds a late error message to an already failed workflow', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'result': {'status': WorkflowRunningStatus.failed},
        }),
      );
      h.events.handleWorkflowFailed('LLM provider and model are required.');
      expect(resultOf(h.state), {
        'status': WorkflowRunningStatus.failed,
        'error': 'LLM provider and model are required.',
      });
    });

    test('keeps the workflow_finished error when a generic error arrives later', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'result': {'status': WorkflowRunningStatus.failed, 'error': 'LLM provider and model are required.'},
        }),
      );
      h.events.handleWorkflowFailed('Server Error');
      expect(resultOf(h.state)['error'], 'LLM provider and model are required.');
    });
  });

  group('useWorkflowFinished', () {
    test('merges data into result and activates result tab for single string output', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData());
      h.events.handleWorkflowFinished(
        const WorkflowFinishedEvent({
          'data': {
            'status': 'succeeded',
            'outputs': {'answer': 'hello'},
          },
        }),
      );
      expect(resultOf(h.state)['status'], 'succeeded');
      expect(h.state['resultTabActive'], true);
      expect(h.state['resultText'], 'hello');
    });

    test('does not activate the result tab for multi-key outputs', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData());
      h.events.handleWorkflowFinished(
        const WorkflowFinishedEvent({
          'data': {
            'status': 'succeeded',
            'outputs': {'a': 'hello', 'b': 'world'},
          },
        }),
      );
      expect(resultOf(h.state)['status'], 'succeeded');
      expect(h.state['resultTabActive'], false);
      expect(h.state['resultText'], '');
    });
  });

  group('useWorkflowNodeFinished', () {
    test('updates tracing and node running status', () {
      final h = RunEventHarness(
        nodes: [
          createNode('n1', data: {'_runningStatus': _running}),
        ],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'id': 'trace-1', 'node_id': 'n1', 'status': _running},
          ],
        }),
      );
      h.events.handleWorkflowNodeFinished(
        const NodeFinishedEvent({
          'data': {'id': 'trace-1', 'node_id': 'n1', 'status': _succeeded},
        }),
      );
      expect(h.tracing[0]['status'], _succeeded);
      expect(h.firstNode['_runningStatus'], _succeeded);
      expect(h.firstEdge['_targetRunningStatus'], _succeeded);
    });

    test('sets _runningBranchId for IfElse nodes', () {
      final h = RunEventHarness(
        nodes: [
          createNode('n1', data: {'_runningStatus': _running}),
        ],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'id': 'trace-1', 'node_id': 'n1', 'status': _running},
          ],
        }),
      );
      h.events.handleWorkflowNodeFinished(
        const NodeFinishedEvent({
          'data': {
            'id': 'trace-1',
            'node_id': 'n1',
            'node_type': 'if-else',
            'status': _succeeded,
            'outputs': {'selected_case_id': 'branch-a'},
          },
        }),
      );
      expect(h.firstNode['_runningBranchId'], 'branch-a');
    });
  });

  group('useWorkflowNodeHumanInputFormFilled', () {
    DifyJsonList forms() => [
      {'node_id': 'n1', 'form_id': 'f1', 'node_title': 'Node 1', 'form_content': ''},
    ];

    test('removes the form from pending and adds it to filled', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'humanInputFormDataList': forms()}));
      h.events.handleWorkflowNodeHumanInputFormFilled(
        const HumanInputFormFilledEvent({
          'data': {'node_id': 'n1', 'node_title': 'Node 1', 'rendered_content': 'done'},
        }),
      );
      expect(h.state['humanInputFormDataList'], isEmpty);
      final filled = h.state['humanInputFilledFormDataList'] as List;
      expect(filled, hasLength(1));
      expect((filled[0] as Map)['node_id'], 'n1');
    });

    test('creates humanInputFilledFormDataList when it does not exist', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'humanInputFormDataList': forms()}));
      h.events.handleWorkflowNodeHumanInputFormFilled(
        const HumanInputFormFilledEvent({
          'data': {'node_id': 'n1', 'node_title': 'Node 1', 'rendered_content': 'done'},
        }),
      );
      expect(h.state['humanInputFilledFormDataList'], isNotNull);
    });
  });

  group('useWorkflowNodeHumanInputFormTimeout', () {
    test('sets expiration_time on the matching form', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'humanInputFormDataList': [
            {'node_id': 'n1', 'form_id': 'f1', 'node_title': 'Node 1', 'form_content': '', 'expiration_time': 0},
          ],
        }),
      );
      h.events.handleWorkflowNodeHumanInputFormTimeout(
        const HumanInputFormTimeoutEvent({
          'data': {'node_id': 'n1', 'node_title': 'Node 1', 'expiration_time': 1000},
        }),
      );
      expect(((h.state['humanInputFormDataList'] as List)[0] as Map)['expiration_time'], 1000);
    });
  });

  group('useWorkflowNodeHumanInputRequired', () {
    List<TestNode> nodes() => [
      createNode('n1', data: {'_runningStatus': _running}),
      createNode('n2', x: 300, data: {'_runningStatus': _running}),
    ];

    test('creates humanInputFormDataList and sets tracing and node to Paused', () {
      final h = RunEventHarness(
        nodes: nodes(),
        edges: const [],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n1', 'status': _running},
          ],
        }),
      );
      h.events.handleWorkflowNodeHumanInputRequired(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'n1', 'form_id': 'f1', 'node_title': 'Node 1', 'form_content': 'content'},
        }),
      );
      final list = h.state['humanInputFormDataList'] as List;
      expect(list, hasLength(1));
      expect((list[0] as Map)['form_id'], 'f1');
      expect(h.tracing[0]['status'], NodeRunningStatus.paused);
      expect(h.node('n1')['_runningStatus'], NodeRunningStatus.paused);
    });

    test('updates existing form entry for the same node_id', () {
      final h = RunEventHarness(
        nodes: nodes(),
        edges: const [],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n1', 'status': _running},
          ],
          'humanInputFormDataList': [
            {'node_id': 'n1', 'form_id': 'old', 'node_title': 'Node 1', 'form_content': 'old'},
          ],
        }),
      );
      h.events.handleWorkflowNodeHumanInputRequired(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'n1', 'form_id': 'new', 'node_title': 'Node 1', 'form_content': 'new'},
        }),
      );
      final list = h.state['humanInputFormDataList'] as List;
      expect(list, hasLength(1));
      expect((list[0] as Map)['form_id'], 'new');
    });

    test('appends a new form entry for a different node_id', () {
      final h = RunEventHarness(
        nodes: nodes(),
        edges: const [],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n2', 'status': _running},
          ],
          'humanInputFormDataList': [
            {'node_id': 'n1', 'form_id': 'f1', 'node_title': 'Node 1', 'form_content': ''},
          ],
        }),
      );
      h.events.handleWorkflowNodeHumanInputRequired(
        const HumanInputRequiredEvent({
          'data': {'node_id': 'n2', 'form_id': 'f2', 'node_title': 'Node 2', 'form_content': 'content2'},
        }),
      );
      expect(h.state['humanInputFormDataList'], hasLength(2));
    });
  });

  group('useWorkflowNodeIterationFinished', () {
    test('updates tracing, resets iterTimes, updates node status and edges', () {
      final h = RunEventHarness(
        nodes: [
          createNode('n1', data: {'_runningStatus': _running}),
        ],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'id': 'iter-1', 'node_id': 'n1', 'status': _running},
          ],
        }),
        iterTimes: 10,
      );
      h.events.handleWorkflowNodeIterationFinished(
        const IterationCompletedEvent({
          'data': {'id': 'iter-1', 'node_id': 'n1', 'status': _succeeded},
        }),
      );
      expect(h.store.iterTimes.value, defaultIterTimes);
      expect(h.firstNode['_runningStatus'], _succeeded);
      expect(h.firstEdge['_targetRunningStatus'], _succeeded);
    });
  });

  group('useWorkflowNodeIterationNext', () {
    test('sets _iterationIndex and increments iterTimes', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData(), iterTimes: 3);
      h.events.handleWorkflowNodeIterationNext(
        const IterationNextEvent({
          'data': {'node_id': 'n1'},
        }),
      );
      expect(h.firstNode['_iterationIndex'], 3);
      expect(h.store.iterTimes.value, 4);
    });
  });

  group('useWorkflowNodeIterationStarted', () {
    test('pushes to tracing, resets iterTimes, sets viewport, and updates node with _iterationLength', () {
      final h = RunEventHarness(
        nodes: createViewportNodes().sublist(0, 2),
        edges: createViewportEdges(),
        workflowRunningData: baseRunningData(),
        iterTimes: 99,
      );
      h.events.handleWorkflowNodeIterationStarted(
        const IterationStartedEvent({
          'data': {
            'node_id': 'n1',
            'metadata': {'iterator_length': 10},
          },
        }),
        containerParams,
      );
      expect(h.tracing[0]['status'], _running);
      expect(h.store.iterTimes.value, defaultIterTimes);
      expect(h.viewport.transform, [200, 310, 1]);
      expect(h.node('n1')['_runningStatus'], _running);
      expect(h.node('n1')['_iterationLength'], 10);
      expect(h.node('n1')['_waitingRun'], false);
      expect(h.firstEdge['_targetRunningStatus'], _running);
    });
  });

  group('useWorkflowNodeLoopFinished', () {
    test('updates tracing, node status and edges', () {
      final h = RunEventHarness(
        nodes: [
          createNode('n1', data: {'_runningStatus': _running}),
        ],
        workflowRunningData: baseRunningData({
          'tracing': [
            {'id': 'loop-1', 'node_id': 'n1', 'status': _running},
          ],
        }),
      );
      h.events.handleWorkflowNodeLoopFinished(
        const LoopCompletedEvent({
          'data': {'id': 'loop-1', 'node_id': 'n1', 'status': _succeeded},
        }),
      );
      expect(h.tracing[0]['status'], _succeeded);
      expect(h.firstNode['_runningStatus'], _succeeded);
      expect(h.firstEdge['_targetRunningStatus'], _succeeded);
    });
  });

  group('useWorkflowNodeLoopNext', () {
    test('sets _loopIndex and resets child nodes to waiting', () {
      final h = RunEventHarness(
        nodes: [
          createNode('n1'),
          createNode('n2', x: 300, parentId: 'n1', data: {'_waitingRun': false}),
        ],
        edges: const [],
        workflowRunningData: baseRunningData(),
      );
      h.events.handleWorkflowNodeLoopNext(
        const LoopNextEvent({
          'data': {'node_id': 'n1', 'index': 5},
        }),
      );
      expect(h.node('n1')['_loopIndex'], 5);
      expect(h.node('n2')['_waitingRun'], true);
      expect(h.node('n2')['_runningStatus'], NodeRunningStatus.waiting);
    });
  });

  group('useWorkflowNodeLoopStarted', () {
    test('pushes to tracing, sets viewport, and updates node with _loopLength', () {
      final h = RunEventHarness(
        nodes: createViewportNodes().sublist(0, 2),
        edges: createViewportEdges(),
        workflowRunningData: baseRunningData(),
      );
      h.events.handleWorkflowNodeLoopStarted(
        const LoopStartedEvent({
          'data': {
            'node_id': 'n1',
            'metadata': {'loop_length': 5},
          },
        }),
        containerParams,
      );
      expect(h.tracing[0]['status'], _running);
      expect(h.viewport.transform, [200, 310, 1]);
      expect(h.node('n1')['_runningStatus'], _running);
      expect(h.node('n1')['_loopLength'], 5);
      expect(h.node('n1')['_waitingRun'], false);
      expect(h.firstEdge['_targetRunningStatus'], _running);
    });
  });

  group('useWorkflowNodeRetry', () {
    test('pushes retry data to tracing and updates _retryIndex', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData());
      h.events.handleWorkflowNodeRetry(
        const NodeRetryEvent({
          'data': {'node_id': 'n1', 'retry_index': 2},
        }),
      );
      expect(h.tracing, hasLength(1));
      expect(h.firstNode['_retryIndex'], 2);
    });
  });

  group('useWorkflowNodeStarted', () {
    test('pushes to tracing, sets node running, and adjusts viewport for root node', () {
      final h = RunEventHarness(
        nodes: createViewportNodes(),
        edges: createViewportEdges(),
        workflowRunningData: baseRunningData(),
      );
      h.events.handleWorkflowNodeStarted(
        const NodeStartedEvent({
          'data': {'node_id': 'n1'},
        }),
        containerParams,
      );
      expect(h.tracing, hasLength(1));
      expect(h.tracing[0]['status'], _running);
      expect(h.viewport.transform, [200, 310, 1]);
      expect(h.node('n1')['_runningStatus'], _running);
      expect(h.node('n1')['_waitingRun'], false);
      expect(h.firstEdge['_targetRunningStatus'], _running);
    });

    test('does not adjust viewport for child nodes', () {
      final h = RunEventHarness(
        nodes: createViewportNodes(),
        edges: createViewportEdges(),
        workflowRunningData: baseRunningData(),
      );
      h.events.handleWorkflowNodeStarted(
        const NodeStartedEvent({
          'data': {'node_id': 'n2'},
        }),
        containerParams,
      );
      expect(h.viewport.transform, [0, 0, 1]);
      expect(h.node('n2')['_runningStatus'], _running);
    });

    test('updates existing tracing entry when node_id already exists', () {
      final h = RunEventHarness(
        nodes: createViewportNodes(),
        edges: createViewportEdges(),
        workflowRunningData: baseRunningData({
          'tracing': [
            {'node_id': 'n0', 'status': _succeeded},
            {'node_id': 'n1', 'status': _succeeded},
          ],
        }),
      );
      h.events.handleWorkflowNodeStarted(
        const NodeStartedEvent({
          'data': {'node_id': 'n1'},
        }),
        containerParams,
      );
      expect(h.tracing, hasLength(2));
      expect(h.tracing[1]['status'], _running);
    });
  });

  group('useWorkflowPaused', () {
    test('sets status to Paused', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData());
      h.events.handleWorkflowPaused();
      expect(resultOf(h.state)['status'], WorkflowRunningStatus.paused);
    });
  });

  group('useWorkflowReasoning', () {
    ReasoningChunkEvent chunk(String reasoning, {String? nodeId, bool? isFinal}) => ReasoningChunkEvent({
      'task_id': 't',
      'event': 'reasoning_chunk',
      'data': {'message_id': 'm', 'reasoning': reasoning, 'node_id': ?nodeId, 'is_final': ?isFinal},
    });

    test('accumulates reasoning deltas per LLM node id', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'resultText': ''}));
      h.events
        ..handleWorkflowReasoning(chunk('let me ', nodeId: 'llm'))
        ..handleWorkflowReasoning(chunk('think', nodeId: 'llm'));
      expect(h.state['reasoningContent'], {'llm': 'let me think'});
      expect(h.state['reasoningFinished'] ?? false, isFalse);
    });

    test('keeps reasoning from multiple LLM nodes in separate buckets', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'resultText': ''}));
      h.events
        ..handleWorkflowReasoning(chunk('a', nodeId: 'llm-1'))
        ..handleWorkflowReasoning(chunk('b', nodeId: 'llm-2'));
      expect(h.state['reasoningContent'], {'llm-1': 'a', 'llm-2': 'b'});
    });

    test('falls back to "_" when the chunk carries no node id', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'resultText': ''}));
      h.events.handleWorkflowReasoning(chunk('x'));
      expect(h.state['reasoningContent'], {'_': 'x'});
    });

    test('marks reasoning finished on the terminal marker without appending empty text', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'resultText': '',
          'reasoningContent': {'llm': 'done'},
        }),
      );
      h.events.handleWorkflowReasoning(chunk('', nodeId: 'llm', isFinal: true));
      expect(h.state['reasoningContent'], {'llm': 'done'});
      expect(h.state['reasoningFinished'], true);
    });
  });

  group('useWorkflowStarted', () {
    test('initializes workflow running data and resets nodes and edges', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData());
      h.events.handleWorkflowStarted(
        const WorkflowStartedEvent({
          'task_id': 'task-2',
          'data': {'id': 'run-1', 'workflow_id': 'wf-1', 'created_at': 1000},
        }),
      );
      expect(h.state['task_id'], 'task-2');
      expect(resultOf(h.state)['status'], WorkflowRunningStatus.running);
      expect(h.state['resultText'], '');
      expect(h.firstNode['_waitingRun'], true);
      expect(h.firstNode.containsKey('_runningBranchId'), isFalse);
      expect(h.firstEdge.containsKey('_sourceRunningStatus'), isFalse);
      expect(h.firstEdge.containsKey('_targetRunningStatus'), isFalse);
      expect(h.firstEdge['_waitingRun'], true);
    });

    test('resumes from Paused without resetting nodes or edges', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({
          'result': {'status': WorkflowRunningStatus.paused},
        }),
      );
      h.events.handleWorkflowStarted(
        const WorkflowStartedEvent({
          'task_id': 'task-2',
          'data': {'id': 'run-2', 'workflow_id': 'wf-1', 'created_at': 2000},
        }),
      );
      expect(resultOf(h.state)['status'], WorkflowRunningStatus.running);
      expect(h.firstNode['_waitingRun'], false);
      expect(h.firstEdge['_waitingRun'], isNull);
    });
  });

  group('useWorkflowTextChunk', () {
    test('appends text and activates the result tab', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'resultText': 'Hello'}));
      h.events.handleWorkflowTextChunk(
        const TextChunkEvent({
          'data': {'text': ' World'},
        }),
      );
      expect(h.state['resultText'], 'Hello World');
      expect(h.state['resultTabActive'], true);
    });

    test('inserts a line break when text chunks switch to a different output selector', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({'resultText': 'Hello', 'resultTextSelectorKey': 'end.answer'}),
      );
      h.events.handleWorkflowTextChunk(
        const TextChunkEvent({
          'data': {
            'text': '42',
            'from_variable_selector': ['end', 'count'],
          },
        }),
      );
      expect(h.state['resultText'], 'Hello\n42');
      expect(h.state['resultTextSelectorKey'], 'end.count');
    });

    test('does not add an extra line break when the incoming chunk already starts with one', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({'resultText': 'Hello', 'resultTextSelectorKey': 'end.answer'}),
      );
      h.events.handleWorkflowTextChunk(
        const TextChunkEvent({
          'data': {
            'text': '\n42',
            'from_variable_selector': ['end', 'count'],
          },
        }),
      );
      expect(h.state['resultText'], 'Hello\n42');
      expect(h.state['resultTextSelectorKey'], 'end.count');
    });

    test('does not insert a line break when text chunks stay on the same output selector', () {
      final h = RunEventHarness(
        workflowRunningData: baseRunningData({'resultText': 'Hello', 'resultTextSelectorKey': 'end.answer'}),
      );
      h.events.handleWorkflowTextChunk(
        const TextChunkEvent({
          'data': {
            'text': ' world',
            'from_variable_selector': ['end', 'answer'],
          },
        }),
      );
      expect(h.state['resultText'], 'Hello world');
      expect(h.state['resultTextSelectorKey'], 'end.answer');
    });
  });

  group('useWorkflowTextReplace', () {
    test('replaces resultText', () {
      final h = RunEventHarness(workflowRunningData: baseRunningData({'resultText': 'old text'}));
      h.events.handleWorkflowTextReplace(
        const TextReplaceEvent({
          'data': {'text': 'new text'},
        }),
      );
      expect(h.state['resultText'], 'new text');
    });
  });
}

typedef DifyJsonList = List<Map<String, Object?>>;
