// The editor's human-input run against a **real server**, on a desktop, with the real HTTP client:
// the editor's own Test Run starts a workflow that pauses at a human-input node, the panel shows the form the server
// served, the test types and presses the form's own action, and the page itself must then reach `succeeded` with the
// run's outputs — the same connection, the same widgets a person uses.
//
//   xvfb-run -a -s "-screen 0 1600x1000x24" flutter test integration_test/human_input_flow_test.dart -d linux
//
// Needs a server of this repository's branch (protocol 1.16) at `DIFYSF_RUNTIME_URL` (default http://127.0.0.1:18080)
// and an account with edit rights (`DIFYSF_EMAIL` / `DIFYSF_PASSWORD`; the account is created when the workspace has no
// owner). The app and the run it makes are deleted at the end.
//
// The second case opens the mailed form page. The server must send through a local capture
// (`COLLAB_MAIL_SMTP_HOST/PORT`, `COLLAB_WEBAPP_BASE_URL`) whose messages this test reads at `DIFYSF_MAILBOX_URL`
// (`DELETE` empties it, `GET` lists what it holds; `test/support/` has a three-line capture in Python). Without it the
// case skips.
import 'dart:convert';
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/auth/auth_controller.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/home_page.dart';
import 'package:dify_sf_app/src/human_input/human_input_form_page.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/settings.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_scope.dart';
import 'package:dify_sf_app/src/workflow_editor/run/server_run_service.dart';
import 'package:dify_sf_app/src/workflow_editor/run/run_types.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store.dart';
import 'package:dify_sf_app/src/workflow_editor/store/workflow_store_scope.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final String _url = Platform.environment['DIFYSF_RUNTIME_URL'] ?? 'http://127.0.0.1:18080';
final String _email = Platform.environment['DIFYSF_EMAIL'] ?? 'e2e-owner@example.test';
final String _password = Platform.environment['DIFYSF_PASSWORD'] ?? 'E2e-throwaway-1';

/// start → human (approve, mailed too) → end. The start node asks for nothing, so Test Run starts the run at once. The
/// email method's recipient carries the link the second case opens (`DIFYSF_MAIL_TO`, a local capturing service).
const _yaml = '''
app:
  mode: workflow
  name: hitl-live-flow
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
        - id: mail
          type: email
          enabled: true
          config:
            subject: Approve from the mail
            body: 'Please approve: {{#url#}}'
            recipients:
              items:
              - {type: external, email: recipient@example.test}
    - id: end
      data:
        title: End
        type: end
        outputs:
        - {variable: reply, value_selector: [human, reply]}
''';

/// Pumps the app for [ms] (the desktop's real clock: an SSE connection needs real time to deliver).
Future<void> settle(WidgetTester t, [int ms = 500]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

String _runStatus(WorkflowStore store) => '${resultOf(store.workflowRunningData.value ?? const {})['status']}';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the editor runs a workflow to a human-input pause and the form\'s own action finishes it on the server', (t) async {
    SharedPreferences.setMockInitialValues({});
    final base = Uri.parse(_url);
    final auth = AuthController.on(server: _url, api: HttpAuthApi(base), store: MemoryTokenStore());
    if (await auth.api.setupStatus() == SetupStatus.notStarted) {
      await auth.install(email: _email, name: 'Human Input Flow', password: _password);
    } else {
      await auth.signIn(email: _email, password: _password);
    }
    final apps = HttpAppsApi(base, auth: auth.session);
    final app = (await apps.importDsl(_yaml)).appId!;
    addTearDown(() async {
      // The app and the run it made go away with the test.
      try {
        await apps.delete(app);
      } on Object {
        // Already gone.
      }
    });

    await t.pumpWidget(
      buildApp(
        AppSettings(serverUrl: _url, journaled: false, lastDoc: app),
        backendFor: (uri) => HttpBackend(uri, auth: auth),
        auth: auth,
        studioPollInterval: null,
      ),
    );
    await settle(t, 2000);

    // Open the app's document in the editor (the backend puts the document in place).
    await (HttpBackend(base, auth: auth)).prepare(app, create: false);
    await t.pumpWidget(
      MaterialApp(
        home: EditorPage(
          backend: HttpBackend(base, auth: auth),
          docId: app,
          journaled: false,
          create: false,
          account: auth.account,
          serverRuntime: ServerWorkflowRuntime(
            api: HttpWorkflowRunApi(base, auth: auth.session),
            singleNodeRun: (await auth.api.systemFeatures()).workflowRuntime!.singleNodeRun,
            draftRun: (await auth.api.systemFeatures()).workflowRuntime!.draftRun,
            humanInput: (await auth.api.systemFeatures()).workflowRuntime!.humanInput,
          ),
        ),
      ),
    );
    for (var i = 0; i < 60 && find.byType(WorkflowCanvas).evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
    expect(find.byType(WorkflowCanvas), findsOneWidget, reason: 'the editor opened the app');

    final scope = WorkflowRunScope.of(t.element(find.byType(WorkflowCanvas)));
    final store = WorkflowStoreScope.of(t.element(find.byType(WorkflowCanvas)));
    expect(scope.service, isA<ServerRunService>(), reason: 'the editor runs on the server');

    // The editor's own Test Run.
    await scope.run.handleWorkflowStartRunInWorkflow();
    for (var i = 0; i < 100 && _runStatus(store) != WorkflowRunningStatus.paused; i++) {
      await settle(t, 200);
    }
    expect(_runStatus(store), WorkflowRunningStatus.paused, reason: 'the run waits at the human node: ${store.workflowRunningData.value}');

    // …the form the server served, in the panel (the panel shows it while the run waits: let it be built first).
    for (var i = 0; i < 50 && find.byType(HumanInputFormList).evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
    expect(find.byType(HumanInputFormList), findsOneWidget, reason: 'the paused run shows its form');
    final button = find.text('Approve it');
    expect(button, findsOneWidget, reason: 'the definition\'s own action is the button');
    await t.enterText(
      find.descendant(of: find.byKey(const Key('content-item-textarea')), matching: find.byType(EditableText)),
      'from the desk',
    );
    await settle(t, 400);
    // The run this pause belongs to: the panel's state carries it (`task_id`/`id` of the paused run).
    final runId = '${store.workflowRunningData.value?['id'] ?? store.workflowRunningData.value?['task_id']}';
    expect(runId, isNotEmpty, reason: 'the paused run has an id: ${store.workflowRunningData.value}');
    await t.tap(button);
    // The run reaches its end. (The panel's own status follows the run once the run history re-read maps it back; the
    // panel answers a finished run with its status once that read lands, so both are allowed here, and the server's
    // record below is the authority.)
    for (var i = 0; i < 150 && !['succeeded', 'failed', 'stopped'].contains(_runStatus(store)); i++) {
      await settle(t, 200);
    }
    // The page's own state, after the page's own submission: the run it followed is over, with the answer it sent.
    expect(_runStatus(store), WorkflowRunningStatus.succeeded, reason: 'the page followed the run to its end: ${store.workflowRunningData.value}');
    expect(resultOf(store.workflowRunningData.value ?? const {})['outputs'], {'reply': 'from the desk'});
    expect(store.workflowRunningData.value?['humanInputFormDataList'], isEmpty, reason: 'the answered form left the panel');
    expect(store.workflowRunningData.value?['humanInputFilledFormDataList'], isNotEmpty,
           reason: 'the panel shows the answer the page submitted: ${store.workflowRunningData.value}');

    // The server's own record agrees with the page.
    final detail = await HttpWorkflowRunApi(base, auth: auth.session).runDetail(app, runId);
    expect(detail['status'], 'succeeded', reason: 'the server finished the run the page answered');
    expect(detail['outputs'], {'reply': 'from the desk'});
  });

  testWidgets('the mailed form page answers the link a local SMTP capture received, and the run ends on the server', (t) async {
    SharedPreferences.setMockInitialValues({});
    final base = Uri.parse(_url);
    final auth = AuthController.on(server: _url, api: HttpAuthApi(base), store: MemoryTokenStore());
    if (await auth.api.setupStatus() == SetupStatus.notStarted) {
      await auth.install(email: _email, name: 'Human Input Flow', password: _password);
    } else {
      await auth.signIn(email: _email, password: _password);
    }
    final apps = HttpAppsApi(base, auth: auth.session);
    final app = (await apps.importDsl(_yaml)).appId!;
    addTearDown(() async {
      try {
        await apps.delete(app);
      } on Object {
        // Already gone.
      }
    });
    // The capture is emptied first (`DELETE` on it): the link this test reads is then certainly the mail this run made.
    final mailboxUrl = Platform.environment['DIFYSF_MAILBOX_URL'];
    if (mailboxUrl != null) {
      final clear = HttpClient();
      final res = await (await clear.openUrl('DELETE', Uri.parse(mailboxUrl))).close();
      await res.drain<void>();
      clear.close();
    }
    // A run that pauses: its pause mails the recipient (the server's SMTP is a local capture; the server is configured
    // with COLLAB_WEBAPP_BASE_URL and the capture's HTTP endpoint at DIFYSF_MAILBOX_URL, e.g. a MailHog UI's API).
    final api = HttpWorkflowRunApi(base, auth: auth.session);
    String runId = '';
    await for (final frame in api.draftRun(app, {'inputs': <String, Object?>{}})) {
      runId = '${frame['workflow_run_id'] ?? runId}';
      if (frame['event'] == 'workflow_paused') break;
    }
    expect(runId, isNotEmpty, reason: 'the run paused and mailed its form');
    final mailbox = Platform.environment['DIFYSF_MAILBOX_URL'];
    if (mailbox == null) {
      markTestSkipped('DIFYSF_MAILBOX_URL is not set (the local SMTP capture the server sends through)');
      return;
    }
    // The recipient's link, from the capture.
    final client = HttpClient();
    String token = '';
    // A decoded body may carry line breaks inside a long link (`/form/c5f1d98d-02\n8d-44…`): whitespace is ignored
    // inside the token.
    // The **newest** mailed link (`/form/<uuid>`): the last message the capture holds is the one this test's run made.
    // Line breaks a rendering may put inside the link are removed before matching.
    final pattern = RegExp(r'/form/([0-9a-f-]{36})');
    for (var i = 0; i < 100 && token.isEmpty; i++) {
      final res = await (await client.getUrl(Uri.parse(mailbox))).close();
      // The capture answers the raw messages; the bodies are base64 (swift-smtp encodes whatever the mail carries),
      // so every value a mail client would decode is decoded here before looking for the link.
      final raw = await res.transform(const SystemEncoding().decoder).join();
      final decoded = <String>[raw];
      for (final match in RegExp(r'[A-Za-z0-9+/]{32,}={0,2}').allMatches(raw)) {
        try {
          decoded.add(utf8.decode(base64.decode(match.group(0)!.replaceAll(RegExp(r'\s'), ''))));
        } on Object {
          // Not base64 after all: the raw text already had it.
        }
      }
      final body = decoded.join('\n');
      final matches = pattern.allMatches(body.replaceAll(RegExp(r'\s'), '')).toList();
      token = matches.isEmpty ? '' : matches.last.group(0)!.substring('/form/'.length);
      if (token.isEmpty) await settle(t, 200);
    }
    client.close();
    expect(token, isNotEmpty, reason: 'the capture holds the mailed link');

    // The page, as a recipient with no account opens it: the real definition (user_actions, rendered content) renders
    // with its button, and the page's own submission resumes the run on the server.
    await t.pumpWidget(MaterialApp(home: HumanInputFormPage(token: token, server: base)));
    for (var i = 0; i < 100 && find.text('Approve it').evaluate().isEmpty; i++) {
      await settle(t, 200);
    }
    expect(find.text('Approve it'), findsOneWidget, reason: 'the mailed definition\'s own action is the button');
    await t.enterText(find.byType(EditableText).first, 'from the mail page');
    await settle(t, 200);
    await t.tap(find.text('Approve it'));
    for (var i = 0; i < 150; i++) {
      await settle(t, 200);
      final detail = await api.runDetail(app, runId);
      if (detail['status'] == 'succeeded') break;
    }
    final detail = await api.runDetail(app, runId);
    expect(detail['status'], 'succeeded', reason: 'the mailed answer resumed the run on the server: $detail');
    expect((detail['outputs'] as Map?)?['reply'], 'from the mail page', reason: '$detail');
  });
}
