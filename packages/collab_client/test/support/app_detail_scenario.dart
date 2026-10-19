import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

Matcher _code(String code, int status) =>
    isA<TransportException>().having((e) => e.code, 'code', code).having((e) => e.statusCode, 'statusCode', status);

/// One workspace member's view of the app detail APIs (protocol 1.11).
typedef DetailApis = ({
  AppsApi apps,
  AccessApi access,
  AnnotationsApi annotations,
  VersionsApi versions,
  StatsApi stats,
  LogsApi logs,
});

/// What the app detail pages' calls must do, whoever answers them (the in-memory fakes or a real server, protocol 1.11).
///
/// Fit for a shared server: the apps it creates have [unique] in their names and are deleted at the end. [owner], [editor]
/// and [viewer] are the workspace's owner (or an admin), an editor and a `normal` member; [ownerId] / [editorId] their
/// account ids. [commitEdit] commits one graph edit to an app's document: the `start` node's `desc` becomes [value].
/// [newClient] gives the owner a fresh client id on an app's document (its next cseq is 1).
Future<void> appDetailScenario({
  required DetailApis owner,
  required DetailApis editor,
  required DetailApis viewer,
  required String ownerId,
  required String editorId,
  required String unique,
  required Future<void> Function(String appId, String value) commitEdit,
  required Future<String> Function(String appId) newClient,
}) async {
  final created = <String>[];
  try {
    final w = await owner.apps.create(name: '$unique Flow', mode: AppModes.workflow);
    created.add(w.id);
    final c = await owner.apps.create(name: '$unique Chat', mode: AppModes.advancedChat);
    created.add(c.id);

    // ----- Access Point: the site -----
    final site = w.site!;
    expect(site.accessToken, matches(RegExp(r'^[A-Za-z0-9]{16}$')));
    expect(site.json['code'], site.accessToken);
    expect(site.title, '$unique Flow');
    expect((site.icon, site.iconBackground), ('🤖', '#FFEAD5'));
    expect(AppSiteLanguages.all, contains(site.defaultLanguage));
    expect(site.customizeTokenStrategy, CustomizeTokenStrategy.notAllow);
    expect((site.showWorkflowSteps, site.promptPublic, site.customDisclaimer), (true, false, ''));
    expect(site.appBaseUrl, startsWith('http'));
    expect(site.webAppUrl(AppModes.workflow), '${site.appBaseUrl}/workflow/${site.accessToken}');
    expect(c.site!.webAppUrl(AppModes.advancedChat), contains('/chat/'));
    expect(c.site!.accessToken, isNot(site.accessToken));
    expect((w.enableSite, w.enableApi), (true, true));
    expect(w.apiBaseUrl, endsWith('/v1'));
    // Every member reads the app with its site.
    expect((await viewer.apps.get(w.id)).site!.accessToken, site.accessToken);

    final updated = await editor.access.updateSite(
      w.id,
      const AppSiteUpdate(
        title: 'Web title',
        description: 'about',
        defaultLanguage: 'zh-Hans',
        chatColorTheme: '#1C64F2',
        chatColorThemeInverted: true,
        privacyPolicy: 'https://example.com/privacy',
        inputPlaceholder: 'Ask me',
        customDisclaimer: 'Be nice',
        showWorkflowSteps: false,
        useIconAsAnswerIcon: true,
      ),
    );
    expect(updated.title, 'Web title');
    expect(updated.description, 'about');
    expect(updated.defaultLanguage, 'zh-Hans');
    expect((updated.chatColorTheme, updated.chatColorThemeInverted), ('#1C64F2', true));
    expect(updated.privacyPolicy, 'https://example.com/privacy');
    expect((updated.inputPlaceholder, updated.customDisclaimer), ('Ask me', 'Be nice'));
    expect((updated.showWorkflowSteps, updated.useIconAsAnswerIcon), (false, true));
    expect(updated.accessToken, site.accessToken);
    // Unchanged members keep their value.
    final again = await owner.access.updateSite(w.id, const AppSiteUpdate(copyright: '© me'));
    expect((again.title, again.copyright, again.defaultLanguage), ('Web title', '© me', 'zh-Hans'));
    expect((await owner.apps.get(w.id)).site!.title, 'Web title');
    for (final bad in [
      const AppSiteUpdate(defaultLanguage: 'xx-XX'),
      const AppSiteUpdate(chatColorTheme: 'blue'),
      const AppSiteUpdate(privacyPolicy: 'ftp://example.com'),
      AppSiteUpdate(customDisclaimer: 'd' * 513),
      AppSiteUpdate(inputPlaceholder: 'p' * 65),
      const AppSiteUpdate(customizeTokenStrategy: 'sometimes'),
    ]) {
      await expectLater(
        owner.access.updateSite(w.id, bad),
        throwsA(_code('bad_request', 400)),
        reason: '${bad.toJson()}',
      );
    }
    await owner.access.updateSite(w.id, AppSiteUpdate(customDisclaimer: 'd' * 512, inputPlaceholder: 'p' * 64));
    await expectLater(
      viewer.access.updateSite(w.id, const AppSiteUpdate(title: 'x')),
      throwsA(_code('forbidden', 403)),
    );

    // Regenerate: owner and admin only (Dify's quirk: the editor sees the button and gets 403).
    await expectLater(editor.access.resetAccessToken(w.id), throwsA(_code('forbidden', 403)));
    final reset = await owner.access.resetAccessToken(w.id);
    expect(reset.accessToken, matches(RegExp(r'^[A-Za-z0-9]{16}$')));
    expect(reset.accessToken, isNot(site.accessToken));
    expect((await editor.apps.get(w.id)).site!.accessToken, reset.accessToken);

    // Switches: the site for editors, the API for owner and admin only.
    expect((await editor.access.setSiteEnabled(w.id, false)).enableSite, isFalse);
    expect((await viewer.apps.get(w.id)).enableSite, isFalse);
    await expectLater(viewer.access.setSiteEnabled(w.id, true), throwsA(_code('forbidden', 403)));
    expect((await editor.access.setSiteEnabled(w.id, true)).enableSite, isTrue);
    await expectLater(editor.access.setApiEnabled(w.id, false), throwsA(_code('forbidden', 403)));
    final off = await owner.access.setApiEnabled(w.id, false);
    expect((off.enableApi, off.enableSite), (false, true));
    expect((await owner.access.setApiEnabled(w.id, true)).enableApi, isTrue);

    // ----- Access Point: keys -----
    await expectLater(viewer.access.listApiKeys(w.id), throwsA(_code('forbidden', 403)));
    expect(await editor.access.listApiKeys(w.id), isEmpty);
    final k1 = await editor.access.createApiKey(w.id);
    expect(k1.token, matches(RegExp(r'^app-[A-Za-z0-9]{24}$')));
    expect((k1.type, k1.lastUsedAt, k1.unreadable), ('app', null, false));
    expect(k1.createdAt, greaterThan(1700000000));
    expect(k1.maskedToken, '${k1.token.substring(0, 3)}...${k1.token.substring(8)}');
    final listed = await owner.access.listApiKeys(w.id);
    expect([for (final k in listed) (k.id, k.token)], [(k1.id, k1.token)]);
    await expectLater(viewer.access.createApiKey(w.id), throwsA(_code('forbidden', 403)));
    final more = [for (var i = 0; i < 9; i++) await owner.access.createApiKey(w.id)];
    expect({k1.token, for (final k in more) k.token}, hasLength(10));
    await expectLater(owner.access.createApiKey(w.id), throwsA(_code('max_keys_exceeded', 400)));
    expect([for (final k in await owner.access.listApiKeys(w.id)) k.id], [k1.id, for (final k in more) k.id]);
    await expectLater(editor.access.deleteApiKey(w.id, k1.id), throwsA(_code('forbidden', 403)));
    await expectLater(owner.access.deleteApiKey(w.id, 'no-such-key'), throwsA(_code('not_found', 404)));
    await owner.access.deleteApiKey(w.id, k1.id);
    expect(await owner.access.listApiKeys(w.id), hasLength(9));
    expect((await owner.access.createApiKey(w.id)).token, isNot(k1.token));
    await expectLater(owner.access.listApiKeys('no-such-app'), throwsA(_code('not_found', 404)));

    // A copy gets a new site (the copy's name, a new code) and no keys.
    final copy = await owner.apps.copy(w.id, name: '$unique Copy');
    created.add(copy.id);
    expect(copy.site!.title, '$unique Copy');
    expect(copy.site!.accessToken, isNot(reset.accessToken));
    expect(await owner.access.listApiKeys(copy.id), isEmpty);

    // ----- Annotations (chatflows only) -----
    await expectLater(owner.annotations.list(w.id), throwsA(_code('app_not_found', 404)));
    await expectLater(viewer.annotations.list(c.id), throwsA(_code('forbidden', 403)));
    expect(await viewer.annotations.count(c.id), 0);
    expect((await owner.annotations.list(c.id)).data, isEmpty);
    await expectLater(owner.annotations.create(c.id, question: '', answer: 'a'), throwsA(_code('bad_request', 400)));
    await expectLater(owner.annotations.create(c.id, question: 'q', answer: ''), throwsA(_code('bad_request', 400)));
    final a1 = await owner.annotations.create(c.id, question: 'What is dify-sf?', answer: 'A collaborative editor');
    final a2 = await editor.annotations.create(c.id, question: 'Who wrote it?', answer: 'Several "agents", in Swift');
    final a3 = await owner.annotations.create(c.id, question: 'Multi\nline?', answer: 'Yes, with, commas');
    expect((a1.question, a1.answer, a1.hitCount), ('What is dify-sf?', 'A collaborative editor', 0));
    expect(a1.createdAt, greaterThan(1700000000));
    var page = await owner.annotations.list(c.id);
    expect([for (final a in page.data) a.id], [a3.id, a2.id, a1.id]);
    expect((page.total, page.page, page.limit, page.hasMore), (3, 1, 20, false));
    page = await owner.annotations.list(c.id, limit: 2);
    expect([for (final a in page.data) a.id], [a3.id, a2.id]);
    expect((page.total, page.hasMore), (3, true));
    page = await owner.annotations.list(c.id, page: 2, limit: 2);
    expect([for (final a in page.data) a.id], [a1.id]);
    expect(page.hasMore, isFalse);
    page = await owner.annotations.list(c.id, keyword: 'SWIFT');
    expect([for (final a in page.data) a.id], [a2.id]);
    expect(page.total, 1);
    final edited = await editor.annotations.update(c.id, a1.id, question: 'What is it?', answer: 'An editor');
    expect((edited.id, edited.question, edited.answer), (a1.id, 'What is it?', 'An editor'));
    await expectLater(
      owner.annotations.update(c.id, 'no-such-annotation', question: 'q', answer: 'a'),
      throwsA(_code('not_found', 404)),
    );
    await expectLater(
      owner.annotations.update(c.id, a1.id, question: '', answer: 'a'),
      throwsA(_code('bad_request', 400)),
    );
    expect(await owner.annotations.count(c.id), 3);
    expect((await owner.annotations.hitHistories(c.id, a1.id)).data, isEmpty);
    await expectLater(owner.annotations.hitHistories(c.id, 'no-such-annotation'), throwsA(_code('not_found', 404)));

    // Export -> Dify's CSV -> clear -> import: the same annotations come back.
    final exported = await owner.annotations.export(c.id);
    expect([for (final a in exported) a.id], [a3.id, a2.id, a1.id]);
    final csv = AnnotationFiles.csv(exported);
    expect(csv, startsWith('﻿Question,Answer\r\n'));
    expect(csv, contains('"Several ""agents"", in Swift"'));
    final jsonl = AnnotationFiles.jsonl(exported).split('\n');
    expect(jsonl, hasLength(3));
    expect(jsonDecode(jsonl.last), {
      'messages': [
        {'role': 'system', 'content': ''},
        {'role': 'user', 'content': 'What is it?'},
        {'role': 'assistant', 'content': 'An editor'},
      ],
    });
    await owner.annotations.clearAll(c.id);
    expect(await owner.annotations.count(c.id), 0);
    final job = await owner.annotations.batchImport(c.id, utf8.encode(csv), filename: 'annotations-en-US.csv');
    expect((job.refused, job.recordCount), (false, 3));
    var status = await owner.annotations.batchImportStatus(c.id, job.jobId!);
    expect(status.jobStatus, AnnotationJobStatus.completed);
    expect(status.done && !status.failed, isTrue);
    final back = await owner.annotations.export(c.id);
    expect({for (final a in back) (a.question, a.answer)}, {for (final a in exported) (a.question, a.answer)});
    await expectLater(owner.annotations.batchImportStatus(c.id, 'no-such-job'), throwsA(_code('bad_request', 400)));
    // Dify's refusals are answers.
    final template = await owner.annotations.batchImport(c.id, utf8.encode(AnnotationFiles.templateCsv()));
    expect(template.recordCount, 2);
    final headerOnly = await owner.annotations.batchImport(c.id, utf8.encode('question,answer\n'));
    expect(headerOnly.refused, isTrue);
    expect(headerOnly.errorMsg, contains('at least 1 valid annotation record'));
    final oneColumn = await owner.annotations.batchImport(c.id, utf8.encode('question\nq1\n'));
    expect(oneColumn.errorMsg, contains('at least 2 columns'));
    await expectLater(
      owner.annotations.batchImport(c.id, utf8.encode(csv), filename: 'a.txt'),
      throwsA(_code('bad_request', 400)),
    );
    expect(await owner.annotations.count(c.id), 5);
    final two = [for (final a in (await owner.annotations.list(c.id, limit: 2)).data) a.id];
    await owner.annotations.deleteMany(c.id, two);
    expect(await owner.annotations.count(c.id), 3);
    final one = (await owner.annotations.list(c.id)).data.first.id;
    await owner.annotations.delete(c.id, one);
    await expectLater(owner.annotations.delete(c.id, one), throwsA(_code('not_found', 404)));
    await owner.annotations.clearAll(c.id);
    expect(await owner.annotations.count(c.id), 0);

    // The reply setting is stored; the jobs complete at once.
    expect((await owner.annotations.setting(c.id)).enabled, isFalse);
    final enable = await editor.annotations.enableReply(
      c.id,
      scoreThreshold: 0.9,
      embeddingProviderName: 'langgenius/openai/openai',
      embeddingModelName: 'text-embedding-3-small',
    );
    status = await editor.annotations.replyStatus(c.id, 'enable', enable.jobId!);
    expect(status.jobStatus, AnnotationJobStatus.completed);
    var setting = await owner.annotations.setting(c.id);
    expect((setting.enabled, setting.scoreThreshold), (true, 0.9));
    expect(
      (setting.embeddingProviderName, setting.embeddingModelName),
      (
        'langgenius/openai/openai',
        'text-embedding-3-small',
      ),
    );
    setting = await owner.annotations.updateSetting(c.id, setting.id!, scoreThreshold: 0.95);
    expect(setting.scoreThreshold, 0.95);
    await expectLater(
      owner.annotations.updateSetting(c.id, 'no-such-setting', scoreThreshold: 0.8),
      throwsA(_code('not_found', 404)),
    );
    final disable = await owner.annotations.disableReply(c.id);
    expect((await owner.annotations.replyStatus(c.id, 'disable', disable.jobId!)).done, isTrue);
    expect((await owner.annotations.setting(c.id)).enabled, isFalse);

    // ----- Publish and versions -----
    await expectLater(viewer.versions.published(w.id), throwsA(_code('forbidden', 403)));
    expect(await owner.versions.published(w.id), isNull);
    expect((await owner.versions.list(w.id)).items, isEmpty);
    await expectLater(owner.versions.publish(w.id, markedName: 'n' * 21), throwsA(_code('bad_request', 400)));
    await expectLater(owner.versions.publish(w.id, markedComment: 'c' * 101), throwsA(_code('bad_request', 400)));
    await commitEdit(w.id, 'one');
    final p1 = await owner.versions.publish(w.id, markedName: 'v1', markedComment: 'first');
    expect((p1.result, p1.createdAt > 1700000000), ('success', true));
    var published = (await owner.versions.published(w.id))!;
    expect((published.versionNumber, published.markedName, published.markedComment), (1, 'v1', 'first'));
    expect((published.createdBy!.id, published.isDraft), (ownerId, false));
    expect(published.version, matches(RegExp(r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(\.\d{6})?$')));
    String startDesc(WorkflowVersion v) {
      final nodes = v.graph['nodes']! as List<Object?>;
      final start = nodes.cast<Map<String, Object?>>().firstWhere((n) => n['id'] == 'start');
      return (start['data']! as Map<String, Object?>)['desc']! as String;
    }

    expect(startDesc(published), 'one');
    final v1 = published;
    await commitEdit(w.id, 'two');
    await editor.versions.publish(w.id);
    published = (await owner.versions.published(w.id))!;
    final v2 = published;
    expect((v2.versionNumber, v2.markedName, v2.createdBy!.id, startDesc(v2)), (2, '', editorId, 'two'));

    // Preview one version (its document) and export it (Dify's `export?workflow_id=`).
    final detail = await editor.versions.get(w.id, v1.id);
    expect((detail.id, detail.versionNumber, startDesc(detail)), (v1.id, 1, 'one'));
    expect((detail.document!.nodes['start']!.config['desc']! as VString).value, 'one');
    final draftDetail = await editor.versions.get(w.id, w.id);
    expect(
      (draftDetail.isDraft, (draftDetail.document!.nodes['start']!.config['desc']! as VString).value),
      (true, 'two'),
    );
    await expectLater(editor.versions.get(w.id, 'no-such-version'), throwsA(_code('not_found', 404)));
    final v1File = await editor.versions.exportDsl(w.id, v1.id);
    expect((v1File.contains('one'), v1File.contains('two'), v1File.contains('$unique Flow')), (true, false, true));
    await expectLater(editor.versions.exportDsl(w.id, v1.id, includeSecret: true), throwsA(_code('forbidden', 403)));
    await expectLater(owner.versions.exportDsl(w.id, 'no-such-version'), throwsA(_code('not_found', 404)));
    expect(await owner.versions.exportDsl(w.id, v1.id, includeSecret: true), isNotEmpty);

    var list = await owner.versions.list(w.id);
    expect([for (final v in list.items) v.id], [w.id, v2.id, v1.id]);
    expect((list.items.first.isDraft, list.items.first.versionNumber, list.hasMore), (true, null, false));
    expect(startDesc(list.items.first), 'two');
    expect([for (final v in (await owner.versions.list(w.id, namedOnly: true)).items) v.id], [v1.id]);
    expect([for (final v in (await editor.versions.list(w.id, userId: editorId)).items) v.id], [v2.id]);
    await expectLater(owner.versions.list(w.id, userId: editorId), throwsA(_code('forbidden', 403)));
    list = await owner.versions.list(w.id, page: 2, limit: 1);
    expect([for (final v in list.items) v.id], [v2.id]);
    expect(list.hasMore, isTrue);
    list = await owner.versions.list(w.id, page: 3, limit: 1);
    expect([for (final v in list.items) v.id], [v1.id]);
    expect(list.hasMore, isFalse);

    final renamed = await owner.versions.update(w.id, v1.id, markedName: 'renamed');
    expect((renamed.markedName, renamed.markedComment, renamed.versionNumber), ('renamed', 'first', 1));
    await expectLater(owner.versions.update(w.id, v1.id), throwsA(_code('bad_request', 400)));
    await expectLater(
      owner.versions.update(w.id, 'no-such-version', markedName: 'x'),
      throwsA(_code('not_found', 404)),
    );
    await expectLater(owner.versions.update(w.id, v1.id, markedName: 'n' * 21), throwsA(_code('bad_request', 400)));

    await expectLater(owner.versions.delete(w.id, v2.id), throwsA(_code('bad_request', 400)), reason: 'published');
    await expectLater(owner.versions.delete(w.id, w.id), throwsA(_code('bad_request', 400)), reason: 'the draft');
    await expectLater(owner.versions.delete(w.id, 'no-such-version'), throwsA(_code('not_found', 404)));
    await commitEdit(w.id, 'three');
    await owner.versions.publish(w.id, markedName: 'v3');
    final v3 = (await owner.versions.published(w.id))!;
    expect(v3.versionNumber, 3);
    await owner.versions.delete(w.id, v2.id);
    expect([for (final v in (await owner.versions.list(w.id)).items) v.id], [w.id, v3.id, v1.id]);
    await commitEdit(w.id, 'four');
    await owner.versions.publish(w.id);
    expect((await owner.versions.published(w.id))!.versionNumber, 4, reason: 'numbers are never reused');

    // Restore v1 into the draft through the replacement path.
    await expectLater(
      owner.versions.restore(w.id, w.id, await newClient(w.id), cseq: 1),
      throwsA(_code('bad_request', 400)),
    );
    final restored = await owner.versions.restore(w.id, v1.id, await newClient(w.id), cseq: 1);
    expect((restored.ops > 0, restored.replayed), (true, false));
    final draft = (await owner.versions.list(w.id)).items.first;
    expect((draft.isDraft, startDesc(draft)), (true, 'one'));
    expect((await owner.versions.published(w.id))!.versionNumber, 4, reason: 'restoring does not publish');
    expect((await owner.apps.get(w.id)).name, '$unique Flow', reason: 'restoring keeps the app row');

    // ----- Statistics and logs: empty until a runtime exists -----
    for (final stat in AppStatistic.forMode(AppModes.workflow)) {
      expect(await viewer.stats.statistic(w.id, stat, start: '2026-10-01 00:00', end: '2026-10-19 23:59'), isEmpty);
    }
    for (final stat in AppStatistic.forMode(AppModes.advancedChat)) {
      expect(await viewer.stats.statistic(c.id, stat), isEmpty);
    }
    await expectLater(
      owner.stats.statistic(w.id, AppStatistic.averageSessionInteractions),
      throwsA(_code('app_not_found', 404)),
    );
    await expectLater(
      owner.stats.statistic(c.id, AppStatistic.workflowAverageInteractions),
      throwsA(_code('app_not_found', 404)),
    );
    await expectLater(
      owner.stats.statistic(c.id, AppStatistic.averageResponseTime),
      throwsA(_code('app_not_found', 404)),
    );
    await expectLater(
      owner.stats.statistic(w.id, AppStatistic.workflowDailyRuns, start: '2026/10/01'),
      throwsA(_code('bad_request', 400)),
    );
    await expectLater(
      owner.stats.statistic(w.id, AppStatistic.workflowDailyRuns, start: '2026-10-19 00:00', end: '2026-10-01 00:00'),
      throwsA(_code('bad_request', 400)),
    );
    final logs = await viewer.logs.workflowLogs(w.id, const WorkflowLogQuery(status: 'succeeded', page: 1, limit: 10));
    expect((logs.total, logs.hasMore, logs.data.length, logs.limit), (0, false, 0, 10));
    await expectLater(owner.logs.workflowLogs(c.id), throwsA(_code('app_not_found', 404)));
    await expectLater(
      owner.logs.workflowRun(w.id, 'f0e1d2c3-0000-4000-8000-000000000000'),
      throwsA(_code('not_found', 404)),
    );
    expect(await owner.logs.workflowRunNodeExecutions(w.id, 'f0e1d2c3-0000-4000-8000-000000000000'), isEmpty);
    final chats = await owner.logs.chatConversations(c.id, const ChatConversationQuery(annotationStatus: 'annotated'));
    expect((chats.total, chats.data.length), (0, 0));
    await expectLater(viewer.logs.chatConversations(c.id), throwsA(_code('forbidden', 403)));
    await expectLater(owner.logs.chatConversations(w.id), throwsA(_code('app_not_found', 404)));
    await expectLater(
      owner.logs.chatConversation(c.id, 'f0e1d2c3-0000-4000-8000-000000000000'),
      throwsA(_code('not_found', 404)),
    );
    await expectLater(
      owner.logs.chatMessages(c.id, 'f0e1d2c3-0000-4000-8000-000000000000'),
      throwsA(_code('not_found', 404)),
    );

    // ----- A deleted app -----
    await owner.apps.delete(copy.id);
    created.remove(copy.id);
    await expectLater(owner.access.listApiKeys(copy.id), throwsA(_code('app_deleted', 404)));
    await expectLater(owner.versions.published(copy.id), throwsA(_code('app_deleted', 404)));
  } finally {
    for (final id in created) {
      try {
        await owner.apps.delete(id);
      } on TransportException {
        // Already gone.
      }
    }
  }
}
