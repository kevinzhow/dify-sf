import 'dart:async';

import 'package:collab_client/collab_client.dart' show AppInfo;
import 'package:dify_sf_app/src/app_detail/logs/logs_data.dart';
import 'package:dify_sf_app/src/design/widgets/toast.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/i18n/app_locale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';
import '../members/harness.dart' show settle;

export '../members/harness.dart' show button, buttonMatching, settle, tapButton, testClipboard, useTestClipboard;

/// Dify's log specs' `render`: [child] with Dify's test translator, a toast host, on a 1440 x 900 page.
Future<void> renderLog(
  WidgetTester t,
  Widget child, {
  Size size = const Size(1440, 900),
  Translator? translator,
}) async {
  useDifyTestTranslator();
  if (translator != null) DifyI18n.current = translator;
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(child: child),
      builder: (context, c) => AppLocaleScope(
        locale: AppLocale('en-US'),
        child: Stack(
          fit: StackFit.expand,
          children: [
            c!,
            const DifyToastHost(timeout: Duration.zero),
          ],
        ),
      ),
    ),
  );
  await settle(t);
}

/// `createMockApp`.
AppInfo mockApp({String id = 'test-app-id', String mode = 'workflow', bool site = true}) => AppInfo(
  id: id,
  name: 'Test App',
  mode: mode,
  json: {
    if (site) 'site': {'access_token': 'token', 'app_base_url': 'https://example.com'},
  },
);

/// `createMockWorkflowRun`.
Json mockWorkflowRun({
  String id = 'run-1',
  String? status = 'succeeded',
  double elapsedTime = 1.234,
  int totalTokens = 100,
  String? triggeredFrom = 'app-run',
}) => {
  'id': id,
  'version': '1.0.0',
  'status': status,
  'elapsed_time': elapsedTime,
  'total_tokens': totalTokens,
  'total_price': 0.001,
  'currency': 'USD',
  'total_steps': 5,
  'finished_at': 1710000000,
  'triggered_from': triggeredFrom,
};

/// `createMockWorkflowLog`.
Json mockWorkflowLog({
  String id = 'log-1',
  Json? workflowRun,
  Json? createdByAccount = const {'id': 'account-1', 'name': 'Test User', 'email': 'test@example.com'},
  Json? createdByEndUser,
  int createdAt = 1710000000,
  int? readAt,
}) => {
  'id': id,
  'workflow_run': workflowRun ?? mockWorkflowRun(),
  'created_from': 'web-app',
  'created_by_role': 'account',
  'created_by_account': createdByAccount,
  'created_by_end_user': createdByEndUser,
  'created_at': createdAt,
  'read_at': readAt,
};

/// `createMockLogsResponse`.
Json mockLogsResponse(List<Json> data, [int? total]) => {
  'data': data,
  'has_more': data.length < (total ?? data.length),
  'limit': 10,
  'total': total ?? data.length,
  'page': 1,
};

/// A source answering what the test sets, recording the calls (Dify's mocked `use-log` hooks and services).
class RecordingLogsSource implements AppLogsSource {
  Json? workflowLogsAnswer, chatConversationsAnswer;
  Json? conversation;
  Json? countAnswer = {'count': 10};
  bool countPending = false;
  final messagePages = <Json>[];
  Object? workflowLogsError;

  final workflowLogsCalls = <({String appId, Map<String, Object?> params})>[];
  final chatConversationsCalls = <({String appId, Map<String, Object?> params})>[];
  final chatMessagesCalls = <Map<String, Object?>>[];
  final feedbackCalls = <({String appId, Json body})>[];
  final deletedAnnotations = <({String appId, String id})>[];

  @override
  Future<Json> workflowLogs(String appId, Map<String, Object?> params) async {
    workflowLogsCalls.add((appId: appId, params: params));
    if (workflowLogsError != null) throw workflowLogsError!;
    return workflowLogsAnswer ?? await Completer<Json>().future;
  }

  @override
  Future<Json> workflowRun(String appId, String runId) async => {'id': runId, 'status': 'succeeded'};

  @override
  Future<List<Json>> nodeExecutions(String appId, String runId) async => const [];

  @override
  Future<Json> chatConversations(String appId, Map<String, Object?> params) async {
    chatConversationsCalls.add((appId: appId, params: params));
    return chatConversationsAnswer ?? await Completer<Json>().future;
  }

  @override
  Future<Json> chatConversation(String appId, String conversationId) async =>
      conversation ?? {'id': conversationId, 'created_at': 1710000000};

  @override
  Future<Json> chatMessages(String appId, Map<String, Object?> params) async {
    chatMessagesCalls.add(params);
    return messagePages.isEmpty ? {'data': const <Json>[], 'has_more': false} : messagePages.removeAt(0);
  }

  @override
  Future<Json> annotationsCount(String appId) async {
    if (countPending) return Completer<Json>().future;
    if (countAnswer == null) throw StateError('no count');
    return countAnswer!;
  }

  @override
  Future<void> updateFeedback(String appId, Json body) async => feedbackCalls.add((appId: appId, body: body));

  @override
  Future<void> deleteAnnotation(String appId, String annotationId) async =>
      deletedAnnotations.add((appId: appId, id: annotationId));
}

/// The text of every [Text] / [RichText] on screen.
List<String> allTexts(WidgetTester t) => [
  for (final e in find.byType(RichText).evaluate()) (e.widget as RichText).text.toPlainText(),
];
