import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:test/test.dart';

import 'support/app_detail_scenario.dart';

/// A clock that moves 1 ms per reading (distinct, ordered times without waiting).
DateTime Function() _ticking() {
  var t = DateTime.utc(2026, 10, 19, 12);
  return () => t = t.add(const Duration(milliseconds: 1));
}

DetailApis _apis(FakeAppsApi apps) => (
  apps: apps,
  access: FakeAccessApi(apps),
  annotations: FakeAnnotationsApi(apps),
  versions: FakeVersionsApi(apps),
  stats: FakeStatsApi(apps: apps),
  logs: FakeLogsApi(apps: apps),
);

void main() {
  late FakeAppsApi owner;
  late FakeAppsApi editor;
  late FakeAppsApi viewer;
  setUp(() {
    owner = FakeAppsApi(accountId: 'acc-owner', accountName: 'Olivia', clock: _ticking());
    editor = owner.asAccount('acc-editor', name: 'Eddie', role: AccountRole.editor);
    viewer = owner.asAccount('acc-viewer', name: 'Vic', role: AccountRole.normal);
  });

  test('the fakes follow the server\'s rules (the scenario the conformance test runs against a real server)', () async {
    final clients = <String, int>{};
    await appDetailScenario(
      owner: _apis(owner),
      editor: _apis(editor),
      viewer: _apis(viewer),
      ownerId: 'acc-owner',
      editorId: 'acc-editor',
      unique: 'fake-detail',
      commitEdit: (id, value) async {
        final server = owner.server(id);
        final client = 'edit-$id';
        final cseq = clients[id] = (clients[id] ?? 0) + 1;
        final r = server.submit(
          SubmitRequest(
            client: client,
            ops: [
              OutgoingOp(
                cseq: cseq,
                base: server.head,
                op: SetField('start', const ConfigKey(['desc']), VString(value)),
              ),
            ],
          ),
        );
        expect(r.results.single, isA<AckResult>());
      },
      newClient: (id) async => owner.server(id).issueClientId(account: 'acc-owner'),
    );
  });

  test('roles of the Access Point follow Dify community edition, quirks included', () async {
    final admin = owner.asAccount('acc-admin', role: AccountRole.admin);
    final ops = owner.asAccount('acc-ops', role: AccountRole.datasetOperator);
    final app = await owner.create(name: 'Roles', mode: AppModes.workflow);
    Future<bool> allowed(Future<Object?> Function() call) async {
      try {
        await call();
        return true;
      } on TransportException catch (e) {
        expect(e.statusCode, 403, reason: e.message);
        return false;
      }
    }

    final expected = {
      AccountRole.owner: (owner, [true, true, true, true, true, true]),
      AccountRole.admin: (admin, [true, true, true, true, true, true]),
      AccountRole.editor: (editor, [true, false, true, false, true, false]),
      AccountRole.normal: (viewer, [false, false, false, false, false, false]),
      AccountRole.datasetOperator: (ops, [false, false, false, false, false, false]),
    };
    for (final MapEntry(key: role, value: (apps, want)) in expected.entries) {
      final access = FakeAccessApi(apps);
      final key = await FakeAccessApi(owner).createApiKey(app.id);
      final got = [
        await allowed(() => access.updateSite(app.id, const AppSiteUpdate(title: 't'))),
        await allowed(() => access.resetAccessToken(app.id)),
        await allowed(() => access.setSiteEnabled(app.id, true)),
        await allowed(() => access.setApiEnabled(app.id, true)),
        await allowed(() => access.listApiKeys(app.id)),
        await allowed(() => access.deleteApiKey(app.id, key.id)),
      ];
      expect(got, want, reason: role);
    }
  });

  test('a fresh app has its site from the start, and the URL follows the origin', () async {
    owner.origin = 'https://difysf.example.com';
    final app = await owner.create(name: 'Site', mode: AppModes.advancedChat);
    expect(app.apiBaseUrl, 'https://difysf.example.com/v1');
    expect(app.site!.webAppUrl(app.mode), 'https://difysf.example.com/chat/${app.site!.accessToken}');
    final other = await owner.create(name: 'Other', mode: AppModes.workflow);
    expect(other.site!.accessToken, isNot(app.site!.accessToken));
  });

  test('createApiKey without a secrets key fails like the server', () async {
    final app = await owner.create(name: 'No key', mode: AppModes.workflow);
    owner.secretsKeyMissing = true;
    await expectLater(
      FakeAccessApi(owner).createApiKey(app.id),
      throwsA(isA<TransportException>().having((e) => e.code, 'code', 'secrets_key_missing')),
    );
  });

  group('AnnotationFiles (Dify\'s files, byte for byte)', () {
    const list = [
      Annotation(id: '1', question: 'plain', answer: 'text'),
      Annotation(id: '2', question: 'with, comma', answer: 'with "quotes"'),
      Annotation(id: '3', question: ' padded', answer: 'line\nbreak'),
    ];

    test('CSV with a BOM, papaparse quoting, CRLF', () {
      expect(
        AnnotationFiles.csv(list),
        '﻿Question,Answer\r\nplain,text\r\n"with, comma","with ""quotes"""\r\n" padded","line\nbreak"',
      );
      expect(AnnotationFiles.csv(list.take(1).toList(), locale: 'zh-Hans'), '﻿问题,答案\r\nplain,text');
    });

    test('JSONL in Dify\'s fine-tuning shape', () {
      expect(
        AnnotationFiles.jsonl(list.take(1).toList()),
        '{"messages": [{"role": "system", "content": ""}, {"role": "user", "content": "plain"}, '
        '{"role": "assistant", "content": "text"}]}',
      );
    });

    test('template and names', () {
      expect(AnnotationFiles.templateCsv(), '﻿question,answer\r\nquestion1,answer1\r\nquestion2,answer2');
      expect(AnnotationFiles.csvName('en-US'), 'annotations-en-US.csv');
      expect(AnnotationFiles.jsonlName('ja-JP'), 'annotations-ja-JP.jsonl');
      expect(AnnotationFiles.templateName('zh-Hans'), 'template-zh-Hans.csv');
    });

    test('the import rules read the export back', () {
      final parsed = AnnotationImportRules.parse(utf8.encode(AnnotationFiles.csv(list)));
      expect(parsed.error, isNull);
      expect(
        [for (final r in parsed.rows) (r.question, r.answer)],
        [
          ('plain', 'text'),
          ('with, comma', 'with "quotes"'),
          ('padded', 'line\nbreak'),
        ],
      );
      final long = AnnotationImportRules.parse(utf8.encode('q,a\n${'x' * 2001},a\n'));
      expect(long.error, 'Question at row 2 is too long. Maximum 2000 characters allowed.');
      expect(AnnotationImportRules.parse(utf8.encode('q,a')).error, 'The CSV file appears to be empty or invalid.');
      final skipped = AnnotationImportRules.parse(utf8.encode('q,a\nnan,x\n,y\nok,fine\n'));
      expect([for (final r in skipped.rows) r.question], ['ok']);
    });
  });

  group('mock statistics and logs (demos, tests, visual cases)', () {
    test('statistics: a deterministic row per day of the range; empty without mock', () async {
      final app = await owner.create(name: 'Stats', mode: AppModes.workflow);
      final empty = FakeStatsApi(apps: owner);
      expect(await empty.statistic(app.id, AppStatistic.workflowDailyRuns), isEmpty);
      final mock = FakeStatsApi(apps: owner, mock: true, clock: () => DateTime(2026, 10, 19, 15));
      final week = await mock.statistic(app.id, AppStatistic.workflowDailyRuns);
      expect(
        [for (final r in week) r.date],
        [
          for (var d = 13; d <= 19; d++) '2026-10-$d',
        ],
      );
      expect(week.every((r) => r.value > 0), isTrue);
      expect(await mock.statistic(app.id, AppStatistic.workflowDailyRuns), [
        for (final r in week) isA<StatisticRow>().having((x) => x.value, 'value', r.value),
      ]);
      final range = await mock.statistic(
        app.id,
        AppStatistic.workflowTokenCosts,
        start: '2026-09-01 00:00',
        end: '2026-09-30 23:59',
      );
      expect(range, hasLength(30));
      final chat = await owner.create(name: 'Chat stats', mode: AppModes.advancedChat);
      final costs = await mock.statistic(chat.id, AppStatistic.tokenCosts);
      expect(costs.first.currency, 'USD');
      expect(costs.first.totalPrice, greaterThan(0));
    });

    test('logs: pages, filters, a run with its node executions, a transcript', () async {
      final wf = await owner.create(name: 'Logs', mode: AppModes.workflow);
      final chat = await owner.create(name: 'Chats', mode: AppModes.advancedChat);
      final logs = FakeLogsApi(apps: owner, mock: true, clock: () => DateTime.utc(2026, 10, 19, 15));
      final page = await logs.workflowLogs(wf.id, const WorkflowLogQuery(limit: 10));
      expect((page.total, page.hasMore, page.data.length), (12, true, 10));
      expect(page.data.first.createdAt, greaterThan(page.data.last.createdAt));
      final failed = await logs.workflowLogs(wf.id, const WorkflowLogQuery(status: WorkflowRunStatus.failed));
      expect(failed.data.every((e) => e.status == WorkflowRunStatus.failed), isTrue);
      expect(failed.total, greaterThan(0));
      final run = await logs.workflowRun(wf.id, page.data.first.runId);
      expect(run['status'], page.data.first.status);
      expect(await logs.workflowRunNodeExecutions(wf.id, page.data.first.runId), hasLength(3));
      final convs = await logs.chatConversations(chat.id);
      expect(convs.total, 12);
      final annotated = await logs.chatConversations(
        chat.id,
        const ChatConversationQuery(annotationStatus: 'annotated'),
      );
      expect(annotated.data.every((c) => c.annotated), isTrue);
      final messages = await logs.chatMessages(chat.id, convs.data.first.id);
      expect(messages.data, hasLength(convs.data.first.messageCount));
      final custom = FakeLogsApi(apps: owner, mock: true, workflowRunOf: (app, run) => {'id': run, 'custom': true});
      expect((await custom.workflowRun(wf.id, page.data.first.runId))['custom'], isTrue);
      expect(await FakeLogsApi(apps: owner).workflowRunNodeExecutions(wf.id, 'unknown'), isEmpty);
    });
  });
}
