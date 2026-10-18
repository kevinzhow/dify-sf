// The run visuals of Dify 1.17.1 on the canvas during a mock run in the editor (nodes/_base/node.tsx, node-sections,
// retry-on-node, custom-edge.tsx) and the paused run's human input form: statuses, borders, loaders, waiting
// dimming, loop rounds, the retry row, edge colours (the widgets renderer's strokes and the colours Flutter Scene
// batches them in), then the form shown in the test run panel, submitted through the run service, the run going on.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/canvas/edge_segments.dart';
import 'package:dify_sf_app/src/canvas/renderer_choice.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/debug_chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/mock_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_stream.dart' show runStreamToast;
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../dify_spec/workflow/nodes_panel/core/harness.dart' show difyNode, difyNodes;
import '../../dify_spec/workflow/run/run_harness.dart' show renderRun;
import '../../support/app_fonts.dart';

/// start → code (retries) → loop (loop-start → inner) → human (approve) → end.
Document runDoc() {
  final nodes = difyNodes([
    difyNode('start', 'start', {'variables': <Object?>[]}, 'Start'),
    difyNode('code', 'code', {
      'code': 'def main():\n    return {}',
      'code_language': 'python3',
      'variables': <Object?>[],
      'outputs': <String, Object?>{},
      'retry_config': {'retry_enabled': true, 'max_retries': 3, 'retry_interval': 100},
    }, 'Code'),
    {
      ...difyNode('loop', 'loop', {
        'loop_count': 3,
        'break_conditions': <Object?>[],
        'start_node_id': 'loop-start',
      }, 'Loop'),
      'width': 520,
      'height': 200,
    },
    {
      ...difyNode('loop-start', 'loop-start', {'isInLoop': true}, ''),
      'parentId': 'loop',
      'position': {'x': 24, 'y': 68},
    },
    {
      ...difyNode('inner', 'code', {
        'code': 'def main():\n    return {}',
        'code_language': 'python3',
        'variables': <Object?>[],
        'outputs': <String, Object?>{},
        'isInLoop': true,
        'loop_id': 'loop',
      }, 'Inner'),
      'parentId': 'loop',
      'position': {'x': 140, 'y': 68},
    },
    difyNode('human', 'human-input', {
      'form_content': r'Reason: {{#$output.reason#}}',
      'inputs': [
        {
          'type': 'paragraph',
          'output_variable_name': 'reason',
          'default': {'type': 'constant', 'value': '', 'selector': <Object?>[]},
        },
      ],
      'user_actions': [
        {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
      ],
      'delivery_methods': [
        {'id': 'web', 'type': 'webapp', 'enabled': true},
      ],
      'timeout': 3,
      'timeout_unit': 'day',
    }, 'Human'),
    difyNode('end', 'end', {'outputs': <Object?>[]}, 'End'),
  ]);
  final at = {'start': 0, 'code': 320, 'loop': 640, 'human': 1240, 'end': 1560};
  return Document(
    nodes: [
      for (final n in nodes)
        if (at[n.id] case final x?) n.copyWith(x: x, y: 0) else n,
    ],
    edges: [
      Edge(id: 'e-start-code', source: 'start', target: 'code'),
      Edge(id: 'e-code-loop', source: 'code', target: 'loop'),
      Edge(id: 'e-ls-inner', source: 'loop-start', target: 'inner'),
      Edge(id: 'e-loop-human', source: 'loop', target: 'human'),
      Edge(id: 'e-human-end', source: 'human', target: 'end', sourceHandle: 'approve'),
    ],
  );
}

void main() {
  testWidgets('a mock run on the canvas: waiting, statuses, loaders, retry, loop rounds, edge colours, then the '
      'human input form submitted and the run going on', (t) async {
    await useAppFonts();
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(2000, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    CanvasDefaults.viewport = (40, 200, 0.6);
    addTearDown(() => CanvasDefaults.viewport = null);
    final demo = DemoBackend(server: FakeServer(initial: runDoc()), withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(backend: demo, docId: 'demo', clientId: 'me-abc123', journaled: false),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final canvasState = t.state<WorkflowCanvasState>(find.byType(WorkflowCanvas));
    final graph = canvasState.graph;
    final scope = WorkflowRunScope.of(t.element(find.byType(WorkflowCanvas)));
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    final service = scope.service as MockWorkflowRunService;
    service.scenario = const MockRunScenario(
      stepDelay: Duration(milliseconds: 40),
      pauseNodeIds: {'human'},
      retries: {'code': 1},
      loopLength: 3,
    );
    expect(graph['loop'], isNotNull);
    final codeEdge = graph.edges.firstWhere((e) => e.id == 'e-start-code');
    final opsBefore = demo.server.head;

    // Every status the canvas shows, per node, and the moments worth checking.
    final seen = <String, List<String>>{};
    final last = {for (final n in graph.nodes) n.id: n.status};
    var sawWaitingDim = false, sawSpinner = false, sawRetry = false, sawLoopRound = false, sawGradient = false;
    var sawSceneColours = false;
    for (final n in graph.nodes) {
      n.run.addListener(() {
        if (last[n.id] != n.status) {
          last[n.id] = n.status;
          (seen[n.id] ??= []).add(n.status);
        }
      });
    }

    Future<void> step() async {
      await t.pump(const Duration(milliseconds: 20));
      final end = graph['end']!;
      // `_waitingRun`: the node drawn at 70 %, its edges too (widgets: Opacity; Scene: colours mixed over the canvas).
      if (end.run.value.waiting) {
        final opacity = t.widget<Opacity>(
          find.ancestor(of: find.byKey(const ValueKey('node-end')), matching: find.byType(Opacity)).first,
        );
        if (opacity.opacity == 0.7) {
          final e = graph.edges.firstWhere((e) => e.id == 'e-human-end');
          final stroke = graph.strokeOf(e);
          expect(stroke.opacity, 0.7);
          final colours = edgeSegmentsByColor(graph, [e]).keys;
          expect(colours, [
            Color.alphaBlend(
              DifyColors.workflowLinkLineNormal.withValues(alpha: 0.7),
              DifyColors.workflowCanvasWorkflowBg,
            ),
          ]);
          sawWaitingDim = true;
        }
      }
      // A running node: the accent border, the turning loader in its header (Scene: a loader quad there).
      final code = graph['code']!;
      if (code.run.value.runningStatus == 'running') {
        expect(find.byKey(const Key('status-border-code')), findsOneWidget);
        final spinner = find.descendant(
          of: find.byKey(const ValueKey('node-code')),
          matching: find.byKey(const Key('status-spinner')),
        );
        if (spinner.evaluate().isNotEmpty) {
          sawSpinner = true;
          final rects = const DifyCards().spinners(code, graph);
          expect(rects.first, Rect.fromLTWH(code.rect.right - 1 - 12 - 14, code.rect.top + 1 + 12 + 5, 14, 14));
        }
        // retry-on-node: "Retrying..." with the attempt while it runs again.
        if ((code.run.value.retryIndex ?? 0) > 0) {
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('node-code')),
              matching: find.text(DifyI18n.tr('workflow', 'nodes.common.retry.retrying').toUpperCase()),
            ),
            findsOneWidget,
          );
          expect(
            find.descendant(of: find.byKey(const ValueKey('node-code')), matching: find.text('1/3')),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: find.byKey(const ValueKey('node-code')),
              matching: find.byKey(const Key('retry-spinner')),
            ),
            findsOneWidget,
          );
          expect(const DifyCards().spinners(code, graph), hasLength(2));
          sawRetry = true;
        }
      }
      // The loop's round in its header while it runs.
      final loop = graph['loop']!;
      final round = loop.run.value.loopIndex ?? 0;
      if (loop.run.value.runningStatus == 'running' && round > 0) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('node-loop')),
            matching: find.text(DifyI18n.tr('workflow', 'nodes.loop.currentLoopCount', {'count': round})),
          ),
          findsOneWidget,
        );
        sawLoopRound = true;
      }
      // Finished source, running target: the gradient from the success colour to the running colour.
      final s = graph.strokeOf(codeEdge);
      if (s.isGradient) {
        sawGradient = true;
        expect(s.start, DifyColors.workflowLinkLineSuccessHandle);
        final colours = edgeSegmentsByColor(graph, [codeEdge]).keys.toSet();
        expect(colours, contains(s.start));
        expect(colours, contains(s.end));
        expect(colours.length, greaterThan(2), reason: 'quantised gradient steps in between');
        sawSceneColours = true;
      }
    }

    // The header's Test Run (Dify's handleWorkflowStartRunInWorkflow): no inputs, the run starts, the panel opens.
    scope.run.handleWorkflowStartRunInWorkflow();
    for (var i = 0; i < 200 && runningStatusOf(store.workflowRunningData.value) != WorkflowRunningStatus.paused; i++) {
      await step();
    }
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.paused);
    expect(sawWaitingDim, isTrue, reason: 'waiting nodes and edges dimmed');
    expect(sawSpinner, isTrue, reason: 'the running node turns its loader');
    expect(sawRetry, isTrue, reason: 'the retry row while the node runs again');
    expect(sawLoopRound, isTrue, reason: 'the loop round in the container header');
    expect(sawGradient && sawSceneColours, isTrue, reason: 'run gradients on edges');
    expect(seen['code'], ['running', 'succeeded']);
    expect(seen['loop'], ['running', 'succeeded']);
    expect(graph['human']!.status, 'paused');
    expect(find.byKey(const Key('status-border-human')), findsOneWidget);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('node-human')),
        matching: find.byKey(const Key('status-pause-circle-fill')),
      ),
      findsOneWidget,
    );
    // The end node still waits, dimmed.
    expect(graph['end']!.run.value.waiting, isTrue);

    // The paused run's form in the test run panel's RESULT tab.
    await t.pump(const Duration(milliseconds: 100));
    expect(find.byType(HumanInputFormList), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText)),
      'Looks good',
    );
    await t.tap(find.text('Approve'));
    for (
      var i = 0;
      i < 100 && runningStatusOf(store.workflowRunningData.value) != WorkflowRunningStatus.succeeded;
      i++
    ) {
      await t.pump(const Duration(milliseconds: 40));
    }
    expect(runningStatusOf(store.workflowRunningData.value), WorkflowRunningStatus.succeeded);
    final filled = (store.workflowRunningData.value!['humanInputFilledFormDataList'] as List).single as Map;
    expect(filled['action_id'], 'approve');
    expect(filled['submitted_data'], {'reason': 'Looks good'});
    // A finished run without text shows DETAIL (Dify's WorkflowPreview); RESULT has the filled form.
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.text(DifyI18n.tr('run-log', 'result')));
    await t.pump();
    expect(find.byType(HumanInputFormList), findsNothing);
    expect(find.byType(HumanInputFilledFormList), findsOneWidget);
    expect(seen['human'], ['running', 'paused', 'succeeded']);
    expect(seen['end'], ['running', 'succeeded']);
    expect(graph['end']!.run.value.waiting, isFalse);
    // Both ends finished: success to success.
    final done = graph.strokeOf(graph.edges.firstWhere((e) => e.id == 'e-human-end'));
    expect(
      (done.start, done.end, done.opacity),
      (DifyColors.workflowLinkLineSuccessHandle, DifyColors.workflowLinkLineSuccessHandle, 1.0),
    );
    expect(edgeSegmentsByColor(graph, graph.edges.where((e) => e.id == 'e-human-end')).keys, [
      DifyColors.workflowLinkLineSuccessHandle,
    ]);
    expect(find.byKey(const Key('status-border-end')), findsOneWidget);
    // Run state is local view state: nothing was sent.
    expect(demo.server.head, opsBefore);

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('chatflow preview: a run paused at human input shows the form in the answer; submitting continues it', (
    t,
  ) async {
    runStreamToast = (_) {};
    const graph = StaticRunGraph(
      nodes: [
        RunGraphNode(id: 'start', type: 'start'),
        RunGraphNode(
          id: 'human',
          type: 'human-input',
          title: 'Approval',
          data: {
            'form_content': r'Why? {{#$output.reason#}}',
            'inputs': [
              {
                'type': 'paragraph',
                'output_variable_name': 'reason',
                'default': {'type': 'constant', 'value': '', 'selector': <Object?>[]},
              },
            ],
            'user_actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ],
            'delivery_methods': [
              {'type': 'webapp', 'enabled': false},
            ],
          },
        ),
        RunGraphNode(id: 'answer', type: 'answer', data: {'answer': 'Approved'}),
      ],
      edges: [
        RunGraphEdge(id: 'a', source: 'start', target: 'human'),
        RunGraphEdge(id: 'b', source: 'human', target: 'answer', sourceHandle: 'approve'),
      ],
    );
    final store = WorkflowStore();
    addTearDown(store.dispose);
    final service = MockWorkflowRunService(
      graph: () => graph,
      scenario: const MockRunScenario(stepDelay: Duration(milliseconds: 10), pauseNodeIds: {'human'}),
    );
    final run = WorkflowRunController(store: store, service: service, graph: graph, isChatMode: () => true);
    final chat = DebugChatController(run: run, service: service, store: store, graph: graph);
    addTearDown(chat.dispose);
    await renderRun(
      t,
      ListenableBuilder(
        listenable: chat,
        builder: (context, _) => DebugChat(
          chatList: chat.chatList,
          isResponding: chat.isResponding,
          noChatInput: true,
          onHumanInputFormSubmit: chat.handleSubmitHumanInputForm,
          getHumanInputNodeData: (id) => chat.getHumanInputNodeData(id)?.data,
        ),
      ),
      size: const Size(640, 900),
    );
    chat.handleSend({'query': 'Ship it?', 'inputs': <String, Object?>{}});
    for (var i = 0; i < 100 && find.byType(HumanInputFormList).evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    // answer/index.tsx: the forms in their own bubble, with the node's tips (web app delivery off: debug only).
    expect(find.byKey(const Key('chat-answer-container-humaninput')), findsOneWidget);
    expect(t.widget<HumanInputContentWrapper>(find.byType(HumanInputContentWrapper)).nodeTitle, 'Approval');
    expect(find.text(DifyI18n.tr('workflow', 'common.humanInputWebappTip')), findsOneWidget);
    await t.enterText(
      find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText)),
      'tests pass',
    );
    await t.tap(find.text('Approve'));
    for (var i = 0; i < 100 && (chat.isResponding || find.byType(HumanInputFilledFormList).evaluate().isEmpty); i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(chat.isResponding, isFalse);
    expect(find.byType(HumanInputFormList), findsNothing);
    expect(find.byType(HumanInputFilledFormList), findsOneWidget);
    final answer = chat.chatList.last;
    expect((answer['humanInputFilledFormDataList'] as List).single, containsPair('action_id', 'approve'));
    expect(answer['content'], 'Approved');
    // The response in a second bubble under the forms.
    expect(find.text('Approved'), findsWidgets);
  });

  testWidgets('run updates rebuild only the cards whose run state changed; panning and dimming rebuild none', (
    t,
  ) async {
    t.view.physicalSize = const Size(2000, 800);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    CanvasDefaults.viewport = (40, 200, 0.6);
    addTearDown(() => CanvasDefaults.viewport = null);
    final demo = DemoBackend(server: FakeServer(initial: runDoc()), withBo: false);
    final opened = await demo.openSession('demo', clientId: 'me-abc123', journaled: false);
    await opened.session.start();
    final controller = EditorController(session: opened.session, docId: 'demo', journaled: false);
    for (var i = 0; i < 50 && !controller.ready; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final canvas = CanvasController();
    final cards = _CountingCards();
    await t.pumpWidget(
      MaterialApp(
        home: WorkflowCanvas(
          controller: controller,
          canvas: canvas,
          cards: cards,
          renderer: CanvasRendererKind.widgets,
        ),
      ),
    );
    await t.pump(const Duration(milliseconds: 300));
    expect(cards.builds.keys, containsAll(['start', 'code', 'end']));

    cards.builds.clear();
    canvas.nodeRun.value = {'code': const NodeRunView(runningStatus: 'running')};
    await t.pump();
    expect(cards.builds, {'code': 1});
    expect(find.byKey(const Key('status-border-code')), findsOneWidget);

    // Dimming every node (the run starting) rebuilds no card: the renderer fades them.
    cards.builds.clear();
    canvas.nodeRun.value = {
      for (final id in ['start', 'loop', 'human', 'end']) id: const NodeRunView(waiting: true),
      'code': const NodeRunView(runningStatus: 'running'),
    };
    canvas.edgeRun.value = {'e-human-end': const EdgeRunView(waiting: true)};
    await t.pump();
    expect(cards.builds, isEmpty);
    expect(
      t
          .widget<Opacity>(
            find.ancestor(of: find.byKey(const ValueKey('node-end')), matching: find.byType(Opacity)).first,
          )
          .opacity,
      0.7,
    );

    // Panning rebuilds no card.
    canvas.view.center += const Offset(30, 10);
    await t.pump();
    expect(cards.builds, isEmpty);

    await t.pumpWidget(const SizedBox());
    canvas.dispose();
    controller.dispose();
    await opened.close();
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}

/// Dify's cards, counting how often each card's content is built (its `onPainted`, after each rebuild).
class _CountingCards extends DifyCards {
  _CountingCards();
  final builds = <String, int>{};

  @override
  Widget build(
    BuildContext context,
    CanvasNode node,
    CanvasGraph graph, {
    required bool live,
    VoidCallback? onPainted,
  }) => super.build(
    context,
    node,
    graph,
    live: live,
    onPainted: () {
      builds.update(node.id, (n) => n + 1, ifAbsent: () => 1);
      onPainted?.call();
    },
  );
}
