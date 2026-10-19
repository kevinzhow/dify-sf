// The app detail Logs page through the shell's page interface (detail_page_slot.dart): workflow and chatflow logs on
// mock data, the real run panel and transcript in the drawers, admin feedback, the empty state's links, and
// collab_client's FakeLogsApi behind the page's LogsApi adapter.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart' show FakeLogsApi;
import 'package:dify_sf_app/src/app_detail/detail_page_slot.dart';
import 'package:dify_sf_app/src/app_detail/logs/log_widgets.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:dify_sf_app/src/app_detail/logs/logs_page.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/chat.dart' show ChatAnswerFeedback, ChatFeedbackDialog;
import 'package:flutter/semantics.dart' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/app_log/harness.dart';

void main() {
  late List<(AppDetailPageId, Map<String, String>)> navigations;
  setUp(() => navigations = []);

  AppDetailContext detailFor(
    AppInfo app, {
    Map<Type, Object> services = const {},
    Map<String, String> query = const {},
  }) => AppDetailContext(
    app: ValueNotifier(app),
    apps: _NoApps(),
    navigate: (page, {query = const {}}) => navigations.add((page, query)),
    refreshApp: () async {},
    query: query,
    services: services,
  );

  Future<void> renderPage(WidgetTester t, AppDetailContext detail) =>
      renderLog(t, Builder(builder: (context) => buildLogsPage(context, detail)));

  AppInfo app(String mode, {List<String> keys = const [], bool site = false}) => AppInfo(
    id: 'app-1',
    name: 'Demo',
    mode: mode,
    permissionKeys: keys,
    json: {
      if (site) 'site': {'access_token': 'tok', 'app_base_url': 'https://apps.example.com'},
    },
  );

  Finder rows() => find.byType(LogTableRow);

  testWidgets('workflow logs: mock rows, the run drawer with the real run panel, replay opens the editor', (t) async {
    final source = MockAppLogsSource(now: DateTime(2026, 10, 19, 12));
    await renderPage(t, detailFor(app('workflow'), services: {AppLogsSource: source}));
    expect(find.text('app-log.workflowTitle'), findsOneWidget);
    expect(rows(), findsNWidgets(appPageLimit));
    expect(find.byType(LogPagination), findsOneWidget);
    await t.tap(rows().first);
    await settle(t);
    expect(find.byKey(const ValueKey('log-drawer')), findsOneWidget);
    // RunPanel's RESULT tab shows the run's outputs (the first mock run succeeded).
    expect(find.textContaining('Collaborative editing lets several people', findRichText: true), findsWidgets);
    await tapButton(t, 'app-log.runDetail.testWithParams');
    expect(navigations.single.$1, AppDetailPageId.workflow);
    expect(navigations.single.$2, {'replayRunId': 'run-0'});
  });

  testWidgets('chatflow logs: conversation drawer from ?conversation_id=, transcript, clearing the admin feedback', (
    t,
  ) async {
    final source = MockAppLogsSource(now: DateTime(2026, 10, 19, 12));
    await renderPage(
      t,
      detailFor(app('advanced-chat'), services: {AppLogsSource: source}, query: {'conversation_id': 'conversation-1'}),
    );
    expect(find.byKey(const ValueKey('conversation-detail')), findsOneWidget);
    expect(find.textContaining('how do i reset my password?', findRichText: true), findsWidgets);
    final like = buttonMatching('app-log.table.header.adminRate: app-log.detail.operation.like');
    expect(like, findsWidgets);
    final node = like.evaluate().first;
    node.owner!.performAction(node.id, SemanticsAction.tap);
    await settle(t);
    // The mock's first answer already has the admin's like: the pressed button clears it (rating null).
    expect(source.feedbackCalls.single, {'message_id': 'message-1-0', 'rating': null});
  });

  testWidgets('chatflow logs: a dislike asks what went wrong first (Provide Feedback), Cancel saves nothing', (
    t,
  ) async {
    final source = MockAppLogsSource(now: DateTime(2026, 10, 19, 12));
    await renderPage(
      t,
      detailFor(app('advanced-chat'), services: {AppLogsSource: source}, query: {'conversation_id': 'conversation-0'}),
    );
    Future<void> dislike() async {
      final b = buttonMatching('app-log.table.header.adminRate: app-log.detail.operation.dislike');
      final node = b.evaluate().first;
      node.owner!.performAction(node.id, SemanticsAction.tap);
      await settle(t);
    }

    await dislike();
    expect(find.byType(ChatFeedbackDialog), findsOneWidget);
    expect(find.text('common.feedback.title'), findsOneWidget);
    await t.tap(find.text('common.operation.cancel'));
    await settle(t);
    expect(find.byType(ChatFeedbackDialog), findsNothing);
    expect(source.feedbackCalls, isEmpty);

    await dislike();
    await t.enterText(
      find.descendant(of: find.byKey(const ValueKey('chat-feedback-content')), matching: find.byType(EditableText)),
      'wrong answer',
    );
    await t.tap(find.byKey(const ValueKey('chat-feedback-submit')));
    await settle(t);
    expect(find.byType(ChatFeedbackDialog), findsNothing);
    expect(source.feedbackCalls.single, {'message_id': 'message-0-0', 'rating': 'dislike', 'content': 'wrong answer'});
    // The pressed dislike now shows the admin's feedback with its text (operation.tsx buildFeedbackTooltip).
    expect(buttonMatching('app-log.table.header.adminRate: app-log.detail.operation.dislike'), findsWidgets);
    expect(
      ChatAnswerFeedback.tooltip({'rating': 'dislike', 'content': 'wrong answer'}, 'Admin'),
      'Admin: app-log.detail.operation.dislike - wrong answer',
    );
  });

  testWidgets('empty logs: "Is anyone there?" links test to the editor and share to Access Point', (t) async {
    await renderPage(t, detailFor(app('workflow', keys: AppPermissionKeys.forRole('owner'))));
    expect(find.text('app-log.table.empty.element.title'), findsOneWidget);
    expect(t.widget<LogEmptyElement>(find.byType(LogEmptyElement)).testPath, '/app/app-1/workflow');
    t.widget<LogEmptyElement>(find.byType(LogEmptyElement)).onTest!();
    t.widget<LogEmptyElement>(find.byType(LogEmptyElement)).onShare!();
    expect(navigations.map((n) => n.$1), [AppDetailPageId.workflow, AppDetailPageId.accessPoint]);
  });

  testWidgets('a normal member\'s test link goes to Overview (getRedirectionPath)', (t) async {
    await renderPage(t, detailFor(app('advanced-chat', keys: AppPermissionKeys.forRole('normal'), site: true)));
    final empty = t.widget<LogEmptyElement>(find.byType(LogEmptyElement));
    expect(empty.testPath, '/app/app-1/overview');
    expect(empty.shareUrl, 'https://apps.example.com/chat/tok');
  });

  testWidgets('collab_client LogsApi: FakeLogsApi(mock: true) fills the workflow logs', (t) async {
    final logs = FakeLogsApi(mock: true, clock: () => DateTime.now());
    await renderPage(t, detailFor(app('workflow'), services: {LogsApi: logs}));
    expect(rows(), findsWidgets);
  });
}

class _NoApps implements AppsApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
