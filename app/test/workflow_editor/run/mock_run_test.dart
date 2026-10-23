import 'dart:async';

import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/single_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// start → llm → if-else ─(c1)→ code → end
///                        └(false)→ template → end
///                 llm → iteration [iteration-start → tool] → end
RunGraph fixtureGraph() => const StaticRunGraph(
  nodes: [
    RunGraphNode(
      id: 'start',
      type: 'start',
      title: 'Start',
      data: {
        'type': 'start',
        'title': 'Start',
        'variables': [
          {'variable': 'query', 'type': 'text-input'},
        ],
      },
    ),
    RunGraphNode(id: 'llm', type: 'llm', title: 'LLM', x: 300, data: {'type': 'llm', 'title': 'LLM'}),
    RunGraphNode(
      id: 'if',
      type: 'if-else',
      title: 'IF',
      x: 600,
      data: {
        'type': 'if-else',
        'cases': [
          {'case_id': 'c1', 'conditions': <Object?>[]},
        ],
      },
    ),
    RunGraphNode(id: 'code', type: 'code', title: 'Code', x: 900, data: {'type': 'code'}),
    RunGraphNode(id: 'tpl', type: 'template-transform', title: 'Template', x: 900, y: 200, data: {}),
    RunGraphNode(
      id: 'iter',
      type: 'iteration',
      title: 'Iteration',
      x: 600,
      y: 300,
      data: {
        'type': 'iteration',
        'iterator_selector': ['start', 'items'],
      },
    ),
    RunGraphNode(id: 'iterstart', type: 'iteration-start', parentId: 'iter', data: {}),
    RunGraphNode(id: 'tool', type: 'tool', title: 'Tool', parentId: 'iter', data: {'type': 'tool'}),
    RunGraphNode(
      id: 'end',
      type: 'end',
      title: 'End',
      x: 1200,
      data: {
        'type': 'end',
        'outputs': [
          {
            'variable': 'answer',
            'value_selector': ['llm', 'text'],
          },
        ],
      },
    ),
  ],
  edges: [
    RunGraphEdge(id: 'e1', source: 'start', target: 'llm'),
    RunGraphEdge(id: 'e2', source: 'llm', target: 'if'),
    RunGraphEdge(id: 'e3', source: 'if', target: 'code', sourceHandle: 'c1'),
    RunGraphEdge(id: 'e4', source: 'if', target: 'tpl', sourceHandle: 'false'),
    RunGraphEdge(id: 'e5', source: 'code', target: 'end'),
    RunGraphEdge(id: 'e6', source: 'tpl', target: 'end'),
    RunGraphEdge(id: 'e7', source: 'llm', target: 'iter'),
    RunGraphEdge(id: 'e8', source: 'iter', target: 'end'),
    RunGraphEdge(id: 'e9', source: 'iterstart', target: 'tool'),
  ],
);

class _Rig {
  _Rig({MockRunScenario scenario = const MockRunScenario(stepDelay: Duration.zero), RunGraph? graph, bool chat = false})
    : graph = graph ?? fixtureGraph() {
    service = MockWorkflowRunService(graph: () => this.graph, scenario: scenario, now: () => DateTime(2026, 10, 18));
    run = WorkflowRunController(
      store: store,
      service: service,
      graph: this.graph,
      isChatMode: () => chat,
      toast: (_, m) => toasts.add(m),
    );
    store.nodeRunData.addListener(() {
      store.nodeRunData.value.forEach((id, d) {
        final s = d['_runningStatus'] as String?;
        if (s != null && (transitions[id]?.lastOrNull != s)) (transitions[id] ??= []).add(s);
      });
    });
  }

  final RunGraph graph;
  final store = WorkflowStore();
  late final MockWorkflowRunService service;
  late final WorkflowRunController run;
  final toasts = <String>[];

  /// Node id → the `_runningStatus` values it went through, in order.
  final transitions = <String, List<String>>{};

  DifyJson get data => store.workflowRunningData.value!;
  List<DifyJson> get tracing => tracingOf(data);
  String? get status => resultOf(data)['status'] as String?;
}

Future<void> settle() => pumpEventQueue(times: 200);

void main() {
  setUp(() => runStreamToast = (_) {});

  test(
    'a mock run walks the graph: statuses on the nodes and the tracing list in order, the branch taken only',
    () async {
      final r = _Rig();
      final order = <String>[];
      await r.run.handleRun(
        {
          'inputs': {
            'query': 'hi',
            'items': ['a', 'b'],
          },
        },
        callback: RunCallbacks(onNodeStarted: (e) => order.add(e.nodeId!)),
      );
      expect(r.status, WorkflowRunningStatus.running);
      await settle();
      expect(r.status, WorkflowRunningStatus.succeeded);
      // Topological order: start, llm, then if and the iteration together (a parallel level), the taken branch, end.
      expect(order, ['start', 'llm', 'if', 'iterstart', 'tool', 'iterstart', 'tool', 'code', 'end']);
      expect(r.tracing.map((t) => t['node_id']), ['start', 'llm', 'if', 'iter', 'iterstart', 'tool', 'code', 'end']);
      expect(r.tracing.every((t) => t['status'] == NodeRunningStatus.succeeded), isTrue);
      for (final id in ['start', 'llm', 'if', 'code', 'end', 'iter']) {
        expect(r.transitions[id], [NodeRunningStatus.running, NodeRunningStatus.succeeded], reason: id);
      }
      expect(r.transitions['tpl'], isNull, reason: 'the false branch is not taken');
      expect(r.store.nodeRunDataOf('tpl')['_waitingRun'], true);
      expect(r.store.nodeRunDataOf('if')['_runningBranchId'], 'c1');
      expect(r.store.edgeRunDataOf('e3'), {
        '_sourceRunningStatus': NodeRunningStatus.succeeded,
        '_targetRunningStatus': NodeRunningStatus.succeeded,
        '_waitingRun': false,
      });
      expect(r.store.edgeRunDataOf('e4')['_waitingRun'], true);
      // The End's output (the LLM's text) streamed as text chunks into the result.
      expect(r.data['resultText'], const MockRunScenario().llmText);
      expect(resultOf(r.data)['outputs'], {'answer': const MockRunScenario().llmText});
      // The run is in the history with its node executions; each node's last run is kept.
      final history = await r.service.fetchWorkflowRunHistory();
      expect(history.single['status'], WorkflowRunningStatus.succeeded);
      final tracing = await r.service.fetchTracingList(history.single['id'] as String);
      expect(tracing.map((t) => t['node_id']), contains('code'));
      expect((await r.service.fetchNodeLastRun('llm'))?['status'], NodeRunningStatus.succeeded);
      expect(r.run.lastRunVersion.value, greaterThan(0));
    },
  );

  test('stop: the run stops at once, the stream ends with workflow_finished(stopped)', () async {
    final r = _Rig(scenario: const MockRunScenario(stepDelay: Duration(milliseconds: 5)));
    var completed = false;
    await r.run.handleRun({
      'inputs': <String, Object?>{},
    }, callback: RunCallbacks(onCompleted: ([_ = false, _]) => completed = true));
    await Future<void>.delayed(const Duration(milliseconds: 22));
    final taskId = r.data['task_id'] as String;
    expect(r.status, WorkflowRunningStatus.running);
    r.run.handleStopRun(taskId);
    expect(r.status, WorkflowRunningStatus.stopped);
    expect(r.store.showVariableInspectPanel.value, isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(r.service.stoppedTasks, [taskId]);
    expect(completed, isTrue);
    expect(r.status, WorkflowRunningStatus.stopped);
    expect((await r.service.fetchWorkflowRunHistory()).single['status'], WorkflowRunningStatus.stopped);
  });

  test('failure: the failing node and the run fail, nothing after it runs', () async {
    final r = _Rig(
      scenario: const MockRunScenario(stepDelay: Duration.zero, failNodeId: 'llm', failMessage: 'Boom'),
    );
    await r.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    expect(r.status, WorkflowRunningStatus.failed);
    expect(resultOf(r.data)['error'], 'Boom');
    expect(r.transitions['llm'], [NodeRunningStatus.running, NodeRunningStatus.failed]);
    expect(r.transitions['if'], isNull);
    expect(r.tracing.map((t) => t['node_id']), ['start', 'llm']);
  });

  test('an error event fails the run; a failed request fails it with a toast', () async {
    final r = _Rig()
      ..service.script = (_) => [
        {
          'event': 'node_started',
          'data': {'id': 'x1', 'node_id': 'start'},
        },
        {'event': 'error', 'message': 'Server error', 'status': 500},
      ];
    await r.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    expect(r.status, WorkflowRunningStatus.failed);
    expect(r.transitions['start'], [NodeRunningStatus.running, NodeRunningStatus.failed]);

    final r2 = _Rig(
      scenario: const MockRunScenario(stepDelay: Duration.zero, requestError: 'No runtime'),
    );
    final shown = <String>[];
    runStreamToast = shown.add;
    await r2.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    expect(r2.status, WorkflowRunningStatus.failed);
    expect(resultOf(r2.data)['error'], 'No runtime');
    expect(shown, ['No runtime']);
  });

  test('exceptions take the fail branch; retries are reported before the result', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(id: 'http', type: 'http-request', data: {'error_strategy': 'fail-branch'}),
        RunGraphNode(id: 'ok', type: 'code'),
        RunGraphNode(id: 'fallback', type: 'template-transform'),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'http'),
        RunGraphEdge(id: 'b', source: 'http', target: 'ok'),
        RunGraphEdge(id: 'c', source: 'http', target: 'fallback', sourceHandle: 'fail-branch'),
      ],
    );
    final r = _Rig(
      graph: graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, exceptionNodeIds: {'http'}, retries: {'http': 2}),
    );
    final retries = <int>[];
    await r.run.handleRun(
      {'inputs': <String, Object?>{}},
      callback: RunCallbacks(onNodeRetry: (e) => retries.add(e.data['retry_index'] as int)),
    );
    await settle();
    expect(retries, [1, 2]);
    expect(r.store.nodeRunDataOf('http')['_retryIndex'], 2);
    expect(r.status, WorkflowRunningStatus.succeeded);
    expect(r.transitions['http']!.last, NodeRunningStatus.exception);
    expect(r.store.nodeRunDataOf('http')['_runningBranchId'], 'fail-branch');
    expect(r.transitions['fallback']!.last, NodeRunningStatus.succeeded);
    expect(r.transitions['ok'], isNull);
  });

  test('iteration: started, one round per item over the children, completed; iterTimes reset', () async {
    final r = _Rig();
    final events = <String>[];
    await r.run.handleRun(
      {
        'inputs': {
          'items': ['a', 'b', 'c'],
        },
      },
      callback: RunCallbacks(
        onIterationStart: (e) => events.add('start ${e.data['metadata']}'),
        onIterationNext: (e) => events.add('next ${e.data['index']}'),
        onIterationFinish: (e) => events.add('done'),
      ),
    );
    await settle();
    expect(events, [
      'start {iterator_length: 3}',
      'next 0',
      'next 1',
      'next 2',
      'done',
    ]);
    expect(r.store.nodeRunDataOf('iter')['_iterationLength'], 3);
    expect(r.store.nodeRunDataOf('iter')['_iterationIndex'], 3);
    expect(r.store.iterTimes.value, defaultIterTimes);
    final iter = r.tracing.firstWhere((t) => t['node_id'] == 'iter');
    expect(iter['outputs'], isA<Map>());
    expect((iter['execution_metadata'] as Map)['iteration_duration_map'], hasLength(3));
    final tool = r.tracing.firstWhere((t) => t['node_id'] == 'tool');
    expect(tool['iteration_id'], 'iter');
  });

  test('loop: loop_next resets the children to waiting each round after the first', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(id: 'loop', type: 'loop'),
        RunGraphNode(id: 'ls', type: 'loop-start', parentId: 'loop'),
        RunGraphNode(id: 'inc', type: 'code', parentId: 'loop'),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'loop'),
        RunGraphEdge(id: 'b', source: 'ls', target: 'inc'),
      ],
    );
    final r = _Rig(
      graph: graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, loopLength: 2),
    );
    await r.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    expect(r.store.nodeRunDataOf('loop')['_loopLength'], 2);
    expect(r.store.nodeRunDataOf('loop')['_loopIndex'], 1);
    expect(r.transitions['inc'], [
      NodeRunningStatus.running,
      NodeRunningStatus.succeeded,
      NodeRunningStatus.waiting,
      NodeRunningStatus.running,
      NodeRunningStatus.succeeded,
    ]);
    expect(r.transitions['loop']!.last, NodeRunningStatus.succeeded);
  });

  test('human input pauses the run until the form is submitted, then it resumes', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(
          id: 'hi',
          type: 'human-input',
          data: {
            'user_actions': [
              {'id': 'approve', 'title': 'Approve'},
              {'id': 'reject', 'title': 'Reject'},
            ],
          },
        ),
        RunGraphNode(id: 'yes', type: 'code'),
        RunGraphNode(id: 'no', type: 'code'),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'hi'),
        RunGraphEdge(id: 'b', source: 'hi', target: 'yes', sourceHandle: 'approve'),
        RunGraphEdge(id: 'c', source: 'hi', target: 'no', sourceHandle: 'reject'),
      ],
    );
    final r = _Rig(
      graph: graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, pauseNodeIds: {'hi'}),
    );
    await r.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    expect(r.status, WorkflowRunningStatus.paused);
    expect(r.store.nodeRunDataOf('hi')['_runningStatus'], NodeRunningStatus.paused);
    final form = (r.data['humanInputFormDataList'] as List).single as Map;
    await r.service.submitHumanInputForm(form['form_token'] as String, {
      'action': 'approve',
      'inputs': <String, Object?>{},
    });
    await settle();
    expect(r.status, WorkflowRunningStatus.succeeded);
    expect(r.data['humanInputFormDataList'], isEmpty);
    expect((r.data['humanInputFilledFormDataList'] as List).single, containsPair('action_id', 'approve'));
    expect(r.transitions['yes']!.last, NodeRunningStatus.succeeded);
  });

  test('human input continues along the branch of the action submitted, not the first one', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(
          id: 'hi',
          type: 'human-input',
          data: {
            'user_actions': [
              {'id': 'approve', 'title': 'Approve'},
              {'id': 'reject', 'title': 'Reject'},
            ],
          },
        ),
        RunGraphNode(id: 'yes', type: 'code'),
        RunGraphNode(id: 'no', type: 'code'),
        RunGraphNode(id: 'after', type: 'template-transform'),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'hi'),
        RunGraphEdge(id: 'b', source: 'hi', target: 'yes', sourceHandle: 'approve'),
        RunGraphEdge(id: 'c', source: 'hi', target: 'no', sourceHandle: 'reject'),
        RunGraphEdge(id: 'd', source: 'no', target: 'after'),
      ],
    );
    final r = _Rig(
      graph: graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, pauseNodeIds: {'hi'}),
    );
    await r.run.handleRun({'inputs': <String, Object?>{}});
    await settle();
    final form = (r.data['humanInputFormDataList'] as List).single as Map;
    await r.service.submitHumanInputForm(form['form_token'] as String, {
      'action': 'reject',
      'inputs': <String, Object?>{},
    });
    await settle();
    expect(r.status, WorkflowRunningStatus.succeeded);
    expect((r.data['humanInputFilledFormDataList'] as List).single, containsPair('action_id', 'reject'));
    expect(r.tracing.map((t) => t['node_id']), ['start', 'hi', 'no', 'after']);
    expect(r.transitions['yes'], isNull);
    final hi = r.tracing.firstWhere((t) => t['node_id'] == 'hi');
    expect((hi['outputs'] as Map)['__action_id'], 'reject');
    // The node's last run (its Last Run tab) says so too.
    expect(((await r.service.fetchNodeLastRun('hi'))!['outputs'] as Map)['__action_id'], 'reject');
  });

  test('loop rounds as graphon announces them: no loop_next for the first, then index 1, 2 (rounds done)', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(
          id: 'loop',
          type: 'loop',
          data: {
            'loop_variables': [
              {'label': 'num', 'var_type': 'number', 'value_type': 'constant', 'value': 1},
            ],
          },
        ),
        RunGraphNode(id: 'ls', type: 'loop-start', parentId: 'loop'),
        RunGraphNode(id: 'inc', type: 'code', parentId: 'loop'),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'loop'),
        RunGraphEdge(id: 'b', source: 'ls', target: 'inc'),
      ],
    );
    final service = MockWorkflowRunService(
      graph: () => graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, loopLength: 3),
    );
    final events = await service.runWorkflowDraft(const WorkflowDraftRunRequest()).toList();
    final names = [
      for (final e in events)
        if (e.json['event'] case final String n when n.startsWith('loop') || n == 'node_started')
          n == 'loop_next' ? 'next ${(e.json['data'] as Map)['index']}' : n,
    ];
    expect(names, [
      'node_started', // start
      'loop_started',
      'node_started', 'node_started', // round 1: loop-start, inc
      'next 1',
      'node_started', 'node_started',
      'next 2',
      'node_started', 'node_started',
      'loop_completed',
    ]);
    final rounds = [
      for (final e in events)
        if (e.json['event'] == 'node_finished' && (e.json['data'] as Map)['node_id'] == 'inc')
          ((e.json['data'] as Map)['execution_metadata'] as Map)['loop_index'],
    ];
    expect(rounds, [0, 1, 2], reason: 'the loop log groups by loop_index and labels it index + 1');
    final done = events.firstWhere((e) => e.json['event'] == 'loop_completed').json['data'] as Map;
    expect(done['outputs'], {'num': 1, 'loop_round': 3});
    expect((done['execution_metadata'] as Map)['completed_reason'], 'loop_completed');
  });

  testWidgets('trigger debug runs listen until the trigger fires', (t) async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'hook', type: 'trigger-webhook'),
        RunGraphNode(id: 'code', type: 'code'),
      ],
      edges: [RunGraphEdge(id: 'a', source: 'hook', target: 'code')],
    );
    final r = _Rig(
      graph: graph,
      scenario: const MockRunScenario(stepDelay: Duration.zero, triggerDelay: Duration(milliseconds: 20)),
    );
    await r.run.handleWorkflowTriggerWebhookRunInWorkflow('hook');
    await t.pump();
    expect(r.store.isListening.value, isTrue);
    expect(r.store.listeningTriggerNodeIds.value, ['hook']);
    expect(r.store.showDebugAndPreviewPanel.value, isTrue);
    await t.pump(const Duration(milliseconds: 40));
    await t.pump();
    expect(r.store.isListening.value, isFalse);
    expect(r.status, WorkflowRunningStatus.succeeded);
    expect(r.transitions['code']!.last, NodeRunningStatus.succeeded);
    expect((r.service.requests.single as WorkflowDraftRunRequest).body, {'node_id': 'hook'});
  });

  test('chatflow: a message streams the answer into the chat, with its workflow process and suggestions', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(id: 'llm', type: 'llm'),
        RunGraphNode(id: 'answer', type: 'answer', data: {'answer': '{{#llm.text#}}'}),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'llm'),
        RunGraphEdge(id: 'b', source: 'llm', target: 'answer'),
      ],
    );
    final r = _Rig(
      graph: graph,
      chat: true,
      scenario: const MockRunScenario(stepDelay: Duration(milliseconds: 1)),
    );
    final chat = DebugChatController(
      run: r.run,
      service: r.service,
      store: r.store,
      config: {
        'opening_statement': 'Hello {{name}}',
        'suggested_questions_after_answer': {'enabled': true},
      },
      formSettings: (
        inputs: {'name': 'Kevin'},
        inputsForm: [
          {'variable': 'name', 'label': 'Name', 'type': 'text-input'},
        ],
      ),
    );
    expect(chat.chatList.single['content'], 'Hello Kevin');
    final contents = <String>[];
    chat.addListener(() {
      final last = chat.chatList.lastOrNull;
      if (last?['isAnswer'] == true && last?['isOpeningStatement'] != true) contents.add(last!['content'] as String);
    });
    expect(
      chat.handleSend({
        'query': 'What is Dify?',
        'inputs': <String, Object?>{},
      }, onGetSuggestedQuestions: chat.defaultSuggestedQuestions),
      isTrue,
    );
    expect(chat.isResponding, isTrue);
    expect(chat.handleSend({'query': 'again'}), isFalse, reason: 'still responding');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();
    final text = const MockRunScenario().llmText;
    expect(chat.isResponding, isFalse);
    final list = chat.chatList;
    expect(list.map((m) => m['isAnswer']), [true, false, true]);
    expect(list[1]['content'], 'What is Dify?');
    expect(list[2]['content'], text);
    expect(list[2]['id'], startsWith('mock-message-'));
    expect((list[2]['workflowProcess'] as Map)['status'], WorkflowRunningStatus.succeeded);
    expect(((list[2]['workflowProcess'] as Map)['tracing'] as List).map((t) => (t as Map)['node_id']), [
      'start',
      'llm',
      'answer',
    ]);
    // The answer grew chunk by chunk.
    expect(contents.where((c) => c.isNotEmpty && c != text), isNotEmpty);
    expect(chat.conversationId, startsWith('mock-conversation-'));
    expect(chat.suggestedQuestions, hasLength(3));
    expect((r.service.requests.single as ChatMessageRequest).query, 'What is Dify?');

    // A follow-up continues the conversation.
    // ChatWrapper sends the conversation id.
    chat.handleSend({'query': 'More?', 'conversation_id': chat.conversationId, 'parent_message_id': list[2]['id']});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await settle();
    expect(chat.chatList, hasLength(5));
    expect((r.service.requests.last as ChatMessageRequest).conversationId, chat.conversationId);
    chat.handleRestart();
    expect(chat.chatList.single['isOpeningStatement'], true);
    chat.dispose();
  });

  test('single node run: running, then succeeded with its result; the Last Run tab reloads', () async {
    final r = _Rig(scenario: const MockRunScenario(stepDelay: Duration(milliseconds: 1)));
    final single = SingleRunController(nodeId: 'code', store: r.store, service: r.service, graph: r.graph, run: r.run)
      // use-last-run's handleSingleRun.
      ..isRunAfterSingleRun = true;
    await single.fetchLastRun();
    expect(single.lastRun, isNull);
    final done = single.handleRun({'x': 1});
    expect(single.runningStatus, NodeRunningStatus.running);
    expect(r.store.nodesWithInspectVars.value.single['isSingRunRunning'], true);
    await done;
    await settle();
    expect(single.runningStatus, NodeRunningStatus.succeeded);
    expect(single.runResult?['status'], NodeRunningStatus.succeeded);
    expect(single.runResult?['inputs'], {'x': 1});
    expect(r.store.nodesWithInspectVars.value.single['isSingRunRunning'], false);
    r.run.invalidAllLastRun();
    await settle();
    expect(single.lastRun?['node_id'], 'code');

    // A failing node.
    r.service.scenario = const MockRunScenario(stepDelay: Duration.zero, failNodeId: 'code');
    expect(await single.handleRun(const {}), isFalse);
    expect(single.runningStatus, NodeRunningStatus.failed);
    single.dispose();
  });

  test('iteration single run: the round results stream into iterationRunResult', () async {
    final r = _Rig();
    final single = SingleRunController(nodeId: 'iter', store: r.store, service: r.service, graph: r.graph, run: r.run)
      ..isRunAfterSingleRun = true;
    await single.handleRun({
      'iter.input_selector': ['a', 'b'],
    });
    await settle();
    expect(single.runningStatus, NodeRunningStatus.succeeded);
    expect(single.iterationRunResult.first['node_id'], 'iter');
    expect(single.iterationRunResult.where((t) => t['node_id'] == 'tool'), hasLength(3));
    expect(single.runResult?['node_id'], 'iter');
    single.dispose();
  });

  test('the canvas binding shows _runningStatus as card statuses', () async {
    final r = _Rig();
    expect(canvasStatusOf({'_runningStatus': NodeRunningStatus.running}), 'running');
    expect(canvasStatusOf({'_runningStatus': NodeRunningStatus.waiting}), 'idle');
    expect(canvasStatusOf(const {}), 'idle');
    r.store.setNodeRunData('a', {'_runningStatus': NodeRunningStatus.exception});
    expect(r.store.nodeRunDataOf('a'), {'_runningStatus': NodeRunningStatus.exception});
    r.store.setNodeRunData('a', {'_runningStatus': null});
    expect(r.store.nodeRunDataOf('a'), isEmpty);
  });

  test('handleWorkflowStartRunInWorkflow runs at once without start inputs, else opens the inputs panel', () async {
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start', data: {'variables': <Object?>[]}),
      ],
    );
    final r = _Rig(graph: graph);
    await r.run.handleWorkflowStartRunInWorkflow();
    expect(r.store.showDebugAndPreviewPanel.value, isTrue);
    expect(r.store.showInputsPanel.value, isFalse);
    expect(r.service.requests, hasLength(1));
    await settle();

    final r2 = _Rig();
    await r2.run.handleWorkflowStartRunInWorkflow();
    expect(r2.store.showInputsPanel.value, isTrue);
    expect(r2.service.requests, isEmpty);
    // Again: the panel is open, so this closes it and clears the run.
    await r2.run.handleWorkflowStartRunInWorkflow();
    expect(r2.store.showDebugAndPreviewPanel.value, isFalse);
  });

  test('listenRunEvents: cancelling the handle stops the callbacks', () async {
    final controller = StreamController<RunEvent>();
    final seen = <String>[];
    final h = listenRunEvents(controller.stream, RunCallbacks(onNodeStarted: (e) => seen.add(e.nodeId!)));
    controller.add(
      RunEvent.fromJson({
        'event': 'node_started',
        'data': {'node_id': 'a'},
      }),
    );
    await settle();
    h.abort();
    controller.add(
      RunEvent.fromJson({
        'event': 'node_started',
        'data': {'node_id': 'b'},
      }),
    );
    await settle();
    expect(seen, ['a']);
    await controller.close();
  });
}
