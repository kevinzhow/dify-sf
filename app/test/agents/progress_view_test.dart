import 'package:dify_sf_app/src/agents/canvas_progress.dart';
import 'package:dify_sf_app/src/agents/inline_checks.dart';
import 'package:dify_sf_app/src/agents/progress_image.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_events.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/run_events/run_event_harness.dart';

Map<String, Object?> log(int event, String kind, Map<String, Object?> data) => {
  'node_id': 'n1',
  'message_id': 'remote:$event',
  'label': kind,
  'status': 'success',
  'metadata': {'event': kind},
  'data': data,
};

void main() {
  setUpAll(() => DifyI18n.load('en-US'));
  test('profile maxima reject invalid node limits and old defaults remain 50', () {
    expect(InlineAgentChecks.validTurnLimit({}), isTrue);
    expect(
      InlineAgentChecks.validTurnLimit({
        'limits': {'max_turns': 200},
        '_max_turns_max': 200,
      }),
      isTrue,
    );
    for (final value in [0, -1, 201, 1001, 1.5, '200', true]) {
      expect(
        InlineAgentChecks.validTurnLimit({
          'limits': {'max_turns': value},
          '_max_turns_max': 200,
        }),
        isFalse,
      );
    }
    expect(InlineAgentChecks.validTurnLimit({'_max_turns_max': 10}), isFalse);
    expect(
      InlineAgentChecks.validTurnLimit({
        'limits': {'max_turns': 50, 'image': 'arbitrary'},
      }),
      isFalse,
    );
  });
  test('replayed and older log events do not double count model calls', () {
    final started = AgentProgressView.advance(null, log(1, 'run_started', {'max_turns': 200}));
    final called = AgentProgressView.advance(started, log(2, 'model_call', {'invocation_id': 'one'}));
    expect(called!.calls, 1);
    expect(called.maximum, 200);
    expect(AgentProgressView.advance(called, log(2, 'model_call', {'invocation_id': 'one'})), called);
    expect(AgentProgressView.advance(called, log(1, 'run_started', {'max_turns': 50})), called);
    final tool = AgentProgressView.advance(
      called,
      log(3, 'tool_call', {
        'name': 'shell',
        'phase': 'started',
        'input': {'script': 'render_fixture.sh\necho done'},
      }),
    );
    expect(tool!.summary, 'shell: render_fixture.sh');
    expect(tool.calls, 1);
    expect(NodeRunView.fromRunData({'_agentProgress': tool.json}).agentProgress, tool);
  });
  test('commentary, current plan step and retries reach the running canvas', () {
    var view = AgentProgressView.advance(null, log(1, 'model_call', {'call_index': 7}));
    view = AgentProgressView.advance(view, log(2, 'commentary', {'text': 'Checking the render'}));
    expect(view?.summary, 'Checking the render');
    view = AgentProgressView.advance(view, log(3, 'plan', {'plan': [
      {'step': 'Prepare', 'status': 'completed'},
      {'step': 'Render', 'status': 'in_progress'},
    ]}));
    expect(view?.summary, 'Render');
    view = AgentProgressView.advance(view, log(4, 'model_retry', {'message': 'The model stream was interrupted'}));
    expect(view?.summary, 'The model stream was interrupted');
    expect(view?.calls, 7);
  });
  test('untrusted upload receipts and remote image URLs never become previews', () {
    for (final file in [
      {'upload_id': 'unknown', 'url': 'https://external.invalid/track.png'},
      {'dify_model_identity': '__dify__file__', 'mime_type': 'image/svg+xml', 'url': 'https://console.invalid/a.svg'},
      {'dify_model_identity': '__dify__file__', 'mime_type': 'image/png', 'url': 'javascript:alert(1)'},
      {
        'dify_model_identity': '__dify__file__',
        'mime_type': 'image/png',
        'url': 'https://user:pass@console.invalid/a.png',
      },
    ]) {
      final view = AgentProgressView.advance(null, log(1, 'progress', {'caption': 'Test', 'file': file}));
      expect(view?.image, isNull);
    }
  });
  test('live content changes do not invalidate captured node textures at the same height', () {
    final first = NodeRunView(agentProgress: AgentProgressView.advance(null, log(1, 'thought', {'text': 'First'})));
    final second = NodeRunView(
      agentProgress: AgentProgressView.advance(first.agentProgress, log(2, 'thought', {'text': 'Second'})),
    );
    expect(first, isNot(second));
    expect(first.forCard, second.forCard);
    final image = AgentProgressView.advance(
      second.agentProgress,
      log(3, 'progress', {
        'caption': 'Preview',
        'file': {
          'dify_model_identity': '__dify__file__',
          'mime_type': 'image/png',
          'url': 'https://console.invalid/files/fixture.png',
          'filename': 'fixture.png',
        },
      }),
    );
    expect(image!.height, greaterThan(second.agentProgress!.height));
    expect(NodeRunView(agentProgress: image).forCard, isNot(second.forCard));
    expect(image.image?['name'], 'fixture.png');
  });
  test('the workflow event stream updates local preview state and clears it for the next run', () {
    final h = RunEventHarness(
      workflowRunningData: baseRunningData({
        'tracing': [
          {'node_id': 'n1', 'execution_metadata': <String, Object?>{}},
        ],
      }),
    );
    addTearDown(h.dispose);
    final graphBefore = h.graph.nodes.map((n) => n.id).toList();
    h.events.handleWorkflowAgentLog(
      AgentLogEvent({
        'data': log(1, 'run_started', {'max_turns': 200}),
      }),
    );
    h.events.handleWorkflowAgentLog(
      AgentLogEvent({
        'data': log(2, 'model_call', {'invocation_id': 'one'}),
      }),
    );
    expect(NodeRunView.fromRunData(h.node('n1')).agentProgress?.calls, 1);
    expect(h.graph.nodes.map((n) => n.id), graphBefore);
    expect((h.tracing.first['execution_metadata'] as Map)['agent_log'], hasLength(2));
    h.events.clearNodesRunningStatus();
    expect(h.node('n1')['_agentProgress'], isNull);
  });
  test('terminal metadata restores progress and keeps partial completion explicit', () {
    final view = AgentProgressView.finished(null, {
      'agent_log': [
        log(1, 'run_started', {'max_turns': 200}),
        log(2, 'model_call', {'invocation_id': 'one'}),
      ],
      'agent_partial': {'reason': 'max_turns', 'notice_call_index': 198},
    });
    expect(view?.partialReason, 'max_turns');
    expect(view?.maximum, 200);
    expect(view?.calls, 1);
    expect(AgentProgressView.parse(view!.json), view);
  });
  testWidgets('canvas preview opens a live history dialog and shows new entries while it stays open', (t) async {
    final h = RunEventHarness(
      workflowRunningData: baseRunningData({
        'tracing': [
          {'node_id': 'n1', 'execution_metadata': <String, Object?>{}},
        ],
      }),
    );
    addTearDown(h.dispose);
    final started = log(1, 'run_started', {'max_turns': 200});
    h.events.handleWorkflowAgentLog(AgentLogEvent({'data': started}));
    final progress = NodeRunView.fromRunData(h.node('n1')).agentProgress!;
    await t.pumpWidget(
      MaterialApp(
        home: WorkflowStoreScope(
          store: h.store,
          child: Center(
            child: SizedBox(
              width: 240,
              height: progress.height,
              child: AgentCanvasProgress(nodeId: 'n1', progress: progress),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Model calls 0 / 200'), findsOneWidget);
    await t.tap(find.widgetWithText(DifyButton, 'Agent activity'));
    await t.pumpAndSettle();
    expect(find.byType(DifyDialogSurface), findsOneWidget);
    expect(find.text('RUN_STARTED'), findsOneWidget);
    h.events.handleWorkflowAgentLog(
      AgentLogEvent({
        'data': log(2, 'tool_call', {'name': 'shell', 'phase': 'started'}),
      }),
    );
    await t.pumpAndSettle();
    expect(find.text('TOOL_CALL'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
  testWidgets('image failures show a placeholder and enlargement remains a normal dialog', (t) async {
    await t.pumpWidget(
      const MaterialApp(
        home: Center(
          child: SizedBox(
            width: 216,
            child: AgentProgressImage(
              url: 'https://console.invalid/fixture.png',
              caption: 'Fixture preview',
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Progress image is unavailable or expired.'), findsOneWidget);
    final pressable = find.byType(DifyPressable).first;
    await t.tap(pressable);
    await t.pumpAndSettle();
    expect(find.byType(DifyDialogSurface), findsOneWidget);
    expect(find.text('Fixture preview'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
