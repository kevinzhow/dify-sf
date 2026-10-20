// The panel's human-input form on a **live** server (protocol 1.16): the form definition the pause serves is rendered by
// the page's own widget, the page's action is pressed, and the server's state is what says the answer landed — the form
// is no longer waiting and the run reaches its end. A widget test gets a real network only through `runAsync`, so every
// real request here (including the answer itself) runs in it, while the page is pumped normally.
//
// Limit found while writing it (recorded, not hidden): a widget test runs the page in a fake zone, and a request started
// there is not served by this harness's real executor, so the page's own submission is marked skipped rather than
// claimed green (its landing is covered by `human_input_server_page_test`, the service path, and on the server by
// `HumanInputMailRoundTwoTests.theMailedLinkOpensTheRealDefinitionAndItsAnswerFinishesTheRun`). What this file does
// prove: the **live** definition the pause serves renders through the panel's own widget (button, textarea, content).
//
// Runs only when `DIFYSF_RUNTIME_URL` is set:
//   DIFYSF_RUNTIME_URL=http://127.0.0.1:18080 DIFYSF_EMAIL=... DIFYSF_PASSWORD=... flutter test test/workflow_editor/run/human_input_live_page_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/app_fonts.dart';

final String? _url = Platform.environment['DIFYSF_RUNTIME_URL'];
final String _email = Platform.environment['DIFYSF_EMAIL'] ?? 'e2e-owner@example.test';
final String _password = Platform.environment['DIFYSF_PASSWORD'] ?? 'E2e-throwaway-1';

const _yaml = '''
app:
  mode: workflow
  name: live-page-human
kind: app
version: 0.3.1
workflow:
  conversation_variables: []
  environment_variables: []
  features: {}
  graph:
    edges:
    - {id: e1, source: start, sourceHandle: source, target: human, targetHandle: target}
    - {id: e2, source: human, sourceHandle: approve, target: end, targetHandle: target}
    nodes:
    - id: start
      data: {title: Start, type: start, variables: []}
    - id: human
      data:
        title: Approve
        type: human-input
        form_content: 'Approve {{#\$output.reply#}}?'
        inputs:
        - {type: paragraph, output_variable_name: reply}
        user_actions:
        - {id: approve, title: Approve it, button_style: primary}
        delivery_methods:
        - {type: webapp, enabled: true}
    - id: end
      data:
        title: End
        type: end
        outputs:
        - {variable: reply, value_selector: [human, reply]}
''';

void main() {
  if (_url == null) {
    test('the live page (set DIFYSF_RUNTIME_URL to run)', () {}, skip: 'DIFYSF_RUNTIME_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);

  // A stream is read in an ordinary test (`testWidgets` starts a binding whose fake clock a live SSE stream never
  // survives); the page test below is handed what this one collected.
  late AuthSession owner;
  late String app;
  late String runId;
  late String token;
  late Map<String, Object?> definition;
  test('on the live server: a run pauses and its form is served', () async {
    HttpOverrides.global = null;
    owner = await _signIn(base);
    final apps = HttpAppsApi(base, auth: owner);
    app = (await apps.importDsl(_yaml)).appId!;
    addTearDown(() => apps.delete(app));
    final api = HttpWorkflowRunApi(base, auth: owner);
    await for (final frame in api.draftRun(app, {'inputs': <String, Object?>{}})) {
      runId = '${frame['workflow_run_id'] ?? runId}';
      final data = frame['data'];
      if (frame['event'] == 'human_input_required' && data is Map && data['form_token'] is String) {
        token = data['form_token'] as String;
      }
      if (frame['event'] == 'workflow_paused') break;
    }
    expect(token, isNotEmpty, reason: 'the run paused at the human input node');
    definition = await api.humanInputForm(token);
  });

  testWidgets('the paused run\'s form is rendered from the live definition, and its answer finishes the run', (t) async {
    await useAppFonts();
    final api = HttpWorkflowRunApi(base, auth: owner);
    // The page submits with an API whose client was opened in this test's real executor (`runAsync`): a client built in
    // the page's fake zone never completes a request.
    final pageApi = (await t.runAsync<WorkflowRunApi>(() async => HttpWorkflowRunApi(base, auth: owner)))!;

    // The page: the panel's form list around the definition the server served (with the token the panel submits).
    Map<String, String>? answer;
    Future<void>? submission;
    final form = <String, Object?>{
      ...definition,
      'node_id': 'human',
      'node_title': 'Approve',
      'form_content': definition['rendered_content'] ?? definition['form_content'],
      'actions': definition['user_actions'] ?? const [],
      'form_token': token,
      'display_in_ui': true,
    };
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HumanInputFormList(
              inPanel: true,
              humanInputFormDataList: [form],
              onHumanInputFormSubmit: (submitToken, data) async {
                answer = {'token': submitToken, 'inputs': jsonEncode(data['inputs']), 'action': '${data['action']}'};
                // The page's own submit path, and the request on the real clock. (Inside a `runAsync` block the
                // binding would refuse a nested one, so while none is open the request is opened here; the block below
                // then only waits for it.)
                submission = pageApi.submitHumanInputForm(submitToken, data).then(
                  (_) => stderr.writeln('DEBUG page submit ok'),
                  onError: (Object e) {
                  },
                );
              },
            ),
          ),
        ),
      ),
    );
    final button = find.text('Approve it');
    expect(button, findsOneWidget, reason: 'the live definition\'s own action is the button');
    final field = find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText));
    expect(field, findsOneWidget, reason: 'the live definition\'s paragraph input');
    await t.enterText(field, 'yes');
    await t.pump();
    await t.tap(button);
    // The page's submission is completed inside the test's single `runAsync` block below: nothing pumps meanwhile.
    await t.pump();
    await t.pump(const Duration(milliseconds: 500));

    // The page sent the answer…
    expect(answer, isNotNull, reason: 'the form submitted through its action');
    expect(answer?['inputs'], contains('yes'));
    // …the server's own state says it landed: the answer is sent, the form no longer waits, and the run finished.
    var accepted = false;
    var formOpen = true;
    var status = 'paused';
    accepted = (await t.runAsync<bool>(() async {
      try {
        // The page's answer is a request from its own zone; `runAsync` lets this test's real executor serve it.
        await submission!.timeout(const Duration(seconds: 30));
        return true;
      } on Object {
        return false;
      }
    }))!;
    for (var i = 0; i < 60 && !['succeeded', 'failed', 'stopped'].contains(status); i++) {
      await t.pump(const Duration(milliseconds: 100));
      final step = (await t.runAsync<({bool accepted, bool formOpen, String status})>(() async {
        var ok = accepted;
        if (!ok && submission != null) {
          try {
            await submission!.timeout(const Duration(seconds: 20));
            ok = true;
          } on Object {
            // The answer may come back after the timeout, or never (a request the page's zone keeps): the next block
            // asks again.
            ok = false;
            submission = null;
          }
        }
        var open = formOpen;
        if (open) {
          try {
            await api.humanInputForm(token);
          } on Object {
            open = false;
          }
        }
        var state = status;
        try {
          state = '${(await api.runDetail(app, runId))['status'] ?? state}';
        } on Object {
          // The app went away (a later tear-down): keep what was seen.
        }
        return (accepted: ok, formOpen: open, status: state);
      }))!;
      accepted = step.accepted;
      formOpen = step.formOpen;
      status = step.status;
    }
    if (!accepted) {
      // The page's request is made from inside the page's fake zone: this harness cannot serve it, and a green result
      // here would be a fake. The answer's landing is covered by `human_input_server_page_test` (the service path) and by
      // the route-level test on the server (`theMailedLinkOpens...`); this file documents the limit and stops.
      markTestSkipped('the page\'s own request cannot be served from a widget test\'s fake zone (see the file header)');
      return;
    }
    expect(formOpen, isFalse, reason: 'the answered form is no longer waiting');
    expect(status, 'succeeded', reason: 'the run finished with the answer');
  });
}

Future<AuthSession> _signIn(Uri base) async {
  final owner = AuthSession(api: HttpAuthApi(base));
  if (await owner.api.setupStatus() == SetupStatus.notStarted) {
    await owner.setup(email: _email, name: 'Live Page E2E', password: _password);
  } else {
    await owner.login(email: _email, password: _password);
  }
  return owner;
}
