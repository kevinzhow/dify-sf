// The run panel's human input form on the **server-backed** service (protocol 1.16): the editor is given a
// `ServerWorkflowRuntime` whose API is a fake, so the panel's form is Dify's panel widget fed by the server's
// `human_input_required` payload, its submit goes through `ServerRunService` to the form API, and the run continues on
// the reconnect stream the controller opens at the pause. The live-server counterpart of this path is
// `server_runtime_e2e_test.dart`; this one proves the page itself.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'dart:async';

import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/run/workflow_run.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../dify_spec/workflow/nodes_panel/core/harness.dart' show difyNode, difyNodes;
import '../../support/app_fonts.dart';

/// start → human (approve, one paragraph) → end.
Document humanDoc() => Document(
  nodes: difyNodes([
    difyNode('start', 'start', {'variables': <Object?>[]}, 'Start'),
    difyNode('human', 'human-input', {
      'form_content': r'Approve: {{#$output.reason#}}',
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
    difyNode('end', 'end', {
      'outputs': [
        {'variable': 'reply', 'value_selector': ['human', 'reason']},
      ],
    }, 'End'),
  ]),
  edges: [
    Edge(id: 'e1', source: 'start', target: 'human'),
    Edge(id: 'e2', source: 'human', target: 'end', sourceHandle: 'approve'),
  ],
);

void main() {
  testWidgets('the panel form submits through the server-backed service and the run goes on', (t) async {
    await useAppFonts();
    SharedPreferences.setMockInitialValues({});
    t.view.physicalSize = const Size(1800, 1000);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    CanvasDefaults.viewport = (40, 200, 0.6);
    addTearDown(() => CanvasDefaults.viewport = null);

    final api = FakeWorkflowRunApi();
    var token = '';
    // The draft run pauses at the human node, exactly as the server's stream does (form, then workflow_paused).
    api.draftRunEvents = (appId, runId, body) {
      token = 'form-$runId';
      // The reconnect waits for the answer, as the server's does.
      final gate = Completer<void>();
      api.humanInputGates[runId] = gate;
      api.humanInputForms[token] = {'form_id': 'form-1'};
      api.humanInputFormRuns[token] = runId;
      // What the reconnect (opened by the controller at the pause) delivers once the form is answered.
      api.humanInputEvents[runId] = [
        {
          'event': 'workflow_started',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {'id': runId, 'workflow_id': appId, 'reason': 'resumption', 'created_at': 0},
        },
        {
          'event': 'human_input_form_filled',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {
            'node_id': 'human',
            'node_title': 'Human',
            'action_id': 'approve',
            'submitted_data': {'reason': 'Looks good'},
            'rendered_content': 'Approve: Looks good',
          },
        },
        {
          'event': 'node_finished',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {'id': 'exec-end', 'node_id': 'end', 'node_type': 'end', 'title': 'End', 'index': 3, 'status': 'succeeded'},
        },
        {
          'event': 'workflow_finished',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {
            'id': runId,
            'workflow_id': appId,
            'status': 'succeeded',
            'outputs': {'reply': 'Looks good'},
            'error': null,
            'elapsed_time': 0.1,
            'total_tokens': 0,
            'total_steps': 3,
            'created_at': 0,
            'finished_at': 1,
            'exceptions_count': 0,
            'files': <Object?>[],
          },
        },
      ];
      return [
        {
          'event': 'workflow_started',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {'id': runId, 'workflow_id': appId, 'inputs': body['inputs'], 'created_at': 0, 'reason': 'initial'},
        },
        {
          'event': 'node_started',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {'id': 'exec-start', 'node_id': 'start', 'node_type': 'start', 'title': 'Start', 'index': 1},
        },
        {
          'event': 'human_input_required',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {
            'form_id': 'form-1',
            'node_id': 'human',
            'node_title': 'Human',
            'form_content': r'Approve: {{#$output.reason#}}',
            'inputs': [
              {'type': 'paragraph', 'output_variable_name': 'reason'},
            ],
            'actions': [
              {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
            ],
            'display_in_ui': true,
            'form_token': token,
            'approval_channels': <Object?>[],
            'resolved_default_values': <String, Object?>{},
            'expiration_time': 0,
          },
        },
        {
          'event': 'workflow_paused',
          'workflow_run_id': runId,
          'task_id': runId,
          'data': {'outputs': <String, Object?>{}, 'paused_nodes': ['human'], 'reasons': <Object?>[], 'elapsed_time': 0},
        },
      ];
    };

    final demo = DemoBackend(server: FakeServer(initial: humanDoc()), withBo: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(
          backend: demo,
          docId: 'demo',
          clientId: 'me-abc123',
          journaled: false,
          // The server's runtime, with the fake API underneath: everything above it is the real client.
          serverRuntime: ServerWorkflowRuntime(
            api: api,
            singleNodeRun: const {},
            draftRun: const {'start', 'human-input', 'end'},
            humanInput: true,
          ),
        ),
      ),
    );
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final scope = WorkflowRunScope.of(t.element(find.byType(WorkflowCanvas)));
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    expect(scope.service, isA<ServerRunService>());

    scope.run.handleWorkflowStartRunInWorkflow();
    for (var i = 0; i < 200 && find.byType(HumanInputFormList).evaluate().isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(HumanInputFormList), findsOneWidget, reason: 'the paused run shows the form in the panel');
    expect(token, isNotEmpty);
    expect(resultOf(store.workflowRunningData.value ?? const {})['status'], WorkflowRunningStatus.paused);

    await t.enterText(
      find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText)),
      'Looks good',
    );
    await t.tap(find.text('Approve'));
    for (var i = 0; i < 100 && api.humanInputAnswers.isEmpty; i++) {
      await t.pump(const Duration(milliseconds: 20));
    }
    // The page's submit went to the form API through the server-backed service.
    expect(api.humanInputAnswers[token], {
      'inputs': {'reason': 'Looks good'},
      'action': 'approve',
    });
    // The controller followed the answer on the reconnect stream it opened at the pause: the run ended, the panel shows
    // the filled form.
    for (
      var i = 0;
      i < 200 && resultOf(store.workflowRunningData.value ?? const {})['status'] != WorkflowRunningStatus.succeeded;
      i++
    ) {
      await t.pump(const Duration(milliseconds: 20));
    }
    expect(resultOf(store.workflowRunningData.value ?? const {})['status'], WorkflowRunningStatus.succeeded);
    expect(resultOf(store.workflowRunningData.value ?? const {})['outputs'], {'reply': 'Looks good'});
    expect(api.reconnects.single.continueOnPause, isTrue);
    await t.tap(find.text(DifyI18n.tr('run-log', 'result')));
    await t.pump();
    expect(find.byType(HumanInputFilledFormList), findsOneWidget);

    await t.pumpWidget(const SizedBox());
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  });
}
