import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

/// A small Dify workflow file (`app` section, one start node).
String appFile({String name = 'From a file', String mode = AppModes.workflow, String version = '0.7.0'}) =>
    '''
app: {name: "$name", mode: $mode, icon: "🐳", icon_background: "#E0F2FE"}
kind: app
version: $version
workflow:
  environment_variables: []
  conversation_variables: []
  features: {}
  graph:
    nodes:
    - id: s
      data: {type: start, title: Start, variables: []}
    edges: []
''';

Matcher _code(String code, int status) =>
    isA<TransportException>().having((e) => e.code, 'code', code).having((e) => e.statusCode, 'statusCode', status);

/// What the app calls must do, whoever answers them (the in-memory fake or a real server, protocol 1.10).
///
/// Fit for a shared server: every app it creates has [unique] in its name, lists are filtered by it, and it deletes what it
/// created. [owner], [editor] and [viewer] are one workspace seen by its owner (or an admin), an editor and a `normal`
/// member; [ownerName] is the owner's account name, [editorId] the editor's account id. [commitEdit] commits one graph edit
/// to an app's document (an op on its `start` node).
Future<void> appsScenario({
  required AppsApi owner,
  required AppsApi editor,
  required AppsApi viewer,
  required String ownerName,
  required String editorId,
  required String unique,
  required Future<void> Function(String appId) commitEdit,
}) async {
  final created = <String>[];
  AppListQuery mine([AppListQuery q = const AppListQuery()]) => q.copyWith(name: unique);
  Future<List<String>> ids(AppsApi api, [AppListQuery q = const AppListQuery()]) async => [
    for (final a in (await api.list(mine(q))).data) a.id,
  ];

  try {
    // ----- create blank -----
    final a = await owner.create(name: '  $unique Alpha  ', mode: AppModes.workflow, description: 'first');
    created.add(a.id);
    expect(a.name, '$unique Alpha');
    expect(a.mode, AppModes.workflow);
    expect(a.description, 'first');
    expect((a.iconType, a.icon, a.iconBackground), (AppIconTypes.emoji, '🤖', '#FFEAD5'));
    expect(a.authorName, ownerName);
    expect(a.isStarred, isFalse);
    expect(a.tags, isEmpty);
    expect(a.iconUrl, isNull);
    expect(a.canEdit, isTrue);
    expect(a.permissionKeys, AppPermissionKeys.forRole(AccountRole.owner));
    expect(a.createdAt, greaterThan(1700000000));
    expect(a.updatedAt, a.createdAt);
    final b = await editor.create(
      name: '$unique Beta',
      mode: AppModes.advancedChat,
      icon: '🐙',
      iconBackground: '#000000',
    );
    created.add(b.id);
    expect((b.mode, b.icon, b.iconBackground, b.isChatflow), (AppModes.advancedChat, '🐙', '#000000', true));
    expect(b.createdBy, editorId);
    expect(b.permissionKeys, AppPermissionKeys.forRole(AccountRole.editor));
    final c = await owner.create(name: '$unique Gamma', mode: AppModes.workflow);
    created.add(c.id);

    for (final mode in [AppModes.chat, AppModes.agentChat, AppModes.completion]) {
      await expectLater(owner.create(name: 'x', mode: mode), throwsA(_code('unsupported_app_mode', 400)));
    }
    await expectLater(owner.create(name: 'x', mode: 'agent'), throwsA(_code('bad_request', 400)));
    await expectLater(owner.create(name: '   ', mode: AppModes.workflow), throwsA(_code('bad_request', 400)));
    await expectLater(
      owner.create(name: 'x', mode: AppModes.workflow, description: 'd' * 401),
      throwsA(_code('bad_request', 400)),
    );
    await expectLater(
      owner.create(name: 'x', mode: AppModes.workflow, iconType: 'svg'),
      throwsA(_code('bad_request', 400)),
    );

    // ----- list: pages, sorts, filters -----
    final page = await owner.list(mine());
    expect([for (final x in page.data) x.id], [c.id, b.id, a.id]);
    expect((page.total, page.hasMore, page.page, page.limit), (3, false, 1, 20));
    final p1 = await owner.list(mine(const AppListQuery(limit: 2)));
    expect([for (final x in p1.data) x.id], [c.id, b.id]);
    expect((p1.hasMore, p1.total), (true, 3));
    final p2 = await owner.list(mine(const AppListQuery(page: 2, limit: 2)));
    expect([for (final x in p2.data) x.id], [a.id]);
    expect(p2.hasMore, false);
    expect((await owner.list(mine(const AppListQuery(page: 5, limit: 2)))).data, isEmpty);
    expect(await ids(owner, const AppListQuery(sortBy: AppSortBy.earliestCreated)), [a.id, b.id, c.id]);
    expect(await ids(owner, const AppListQuery(sortBy: AppSortBy.recentlyCreated)), [c.id, b.id, a.id]);
    expect(await ids(owner, const AppListQuery(mode: AppModes.advancedChat)), [b.id]);
    expect(await ids(owner, const AppListQuery(mode: AppModes.workflow)), [c.id, a.id]);
    for (final m in [AppModes.chat, AppModes.agentChat, AppModes.completion, 'agent', 'channel']) {
      expect((await owner.list(mine(AppListQuery(mode: m)))).total, 0);
    }
    expect(await ids(owner, AppListQuery(creatorIds: [editorId])), [b.id]);
    expect(await ids(editor, const AppListQuery(isCreatedByMe: true)), [b.id]);
    expect(await ids(owner, const AppListQuery(tagIds: ['ignored'])), [c.id, b.id, a.id]);
    final beta = (await owner.list(AppListQuery(name: '${unique.toUpperCase()} bEtA'))).data;
    expect([for (final x in beta) x.id], [b.id]);
    expect(beta.single.authorName, isNot(ownerName));
    for (final q in [
      const AppListQuery(page: 0),
      const AppListQuery(limit: 0),
      const AppListQuery(limit: 101),
      const AppListQuery(mode: 'bogus'),
      const AppListQuery(sortBy: 'name'),
    ]) {
      await expectLater(owner.list(q), throwsA(_code('bad_request', 400)));
    }

    // ----- last modified: a committed edit, then edit info -----
    await commitEdit(a.id);
    expect(await ids(owner), [a.id, c.id, b.id]);
    final renamed = await editor.update(c.id, name: '$unique Gamma 2', description: 'new');
    expect((renamed.name, renamed.description, renamed.icon), ('$unique Gamma 2', 'new', '🤖'));
    expect(renamed.updatedBy, editorId);
    expect(await ids(owner), [c.id, a.id, b.id]);
    expect(await ids(owner, const AppListQuery(sortBy: AppSortBy.earliestCreated)), [a.id, b.id, c.id]);
    final kept = await owner.update(c.id, name: '$unique Gamma 3', useIconAsAnswerIcon: true, maxActiveRequests: 5);
    expect((kept.description, kept.useIconAsAnswerIcon, kept.maxActiveRequests), ('new', true, 5));
    await expectLater(owner.update(c.id, name: ''), throwsA(_code('bad_request', 400)));
    expect((await viewer.get(c.id)).name, '$unique Gamma 3');

    // ----- read-only members -----
    final seen = await viewer.list(mine());
    expect(seen.total, 3);
    expect(seen.data.first.permissionKeys, AppPermissionKeys.forRole(AccountRole.normal));
    expect(seen.data.first.canEdit, isFalse);
    final forbidden = throwsA(_code('forbidden', 403));
    await expectLater(viewer.create(name: 'x', mode: AppModes.workflow), forbidden);
    await expectLater(viewer.update(a.id, name: 'x'), forbidden);
    await expectLater(viewer.copy(a.id), forbidden);
    await expectLater(viewer.delete(a.id), forbidden);
    await expectLater(viewer.exportDsl(a.id), forbidden);
    await expectLater(viewer.importDsl(appFile()), forbidden);

    // ----- stars (per account) -----
    await owner.star(a.id);
    await owner.star(a.id);
    await owner.star(b.id);
    await viewer.star(c.id);
    final starred = await owner.starred(mine(const AppListQuery(limit: 100)));
    expect([for (final x in starred.data) x.id], [a.id, b.id]);
    expect(starred.data.every((x) => x.isStarred), isTrue);
    expect([for (final x in (await viewer.starred(mine(const AppListQuery(limit: 100)))).data) x.id], [c.id]);
    expect([for (final x in (await owner.list(mine())).data) x.isStarred], [false, true, true]);
    expect((await viewer.get(a.id)).isStarred, false);
    expect(
      [for (final x in (await owner.starred(mine(const AppListQuery(limit: 100, mode: AppModes.workflow)))).data) x.id],
      [a.id],
    );
    await owner.unstar(a.id);
    await owner.unstar(a.id);
    expect([for (final x in (await owner.starred(mine(const AppListQuery(limit: 100)))).data) x.id], [b.id]);

    // ----- import -----
    final imported = await editor.importDsl(appFile(name: '$unique File'));
    expect(
      (imported.status, imported.completed, imported.appMode),
      (AppImportStatus.completed, true, AppModes.workflow),
    );
    expect((imported.currentDslVersion, imported.importedDslVersion, imported.error), ('0.7.0', '0.7.0', ''));
    created.add(imported.appId!);
    final fromFile = await owner.get(imported.appId!);
    expect(
      (fromFile.name, fromFile.icon, fromFile.iconBackground, fromFile.createdBy),
      (
        '$unique File',
        '🐳',
        '#E0F2FE',
        editorId,
      ),
    );
    final older = await owner.importDsl(appFile(name: '$unique Older', version: '0.3.1'));
    expect(older.status, AppImportStatus.completedWithWarnings);
    created.add(older.appId!);
    final pending = await owner.importDsl(
      appFile(name: 'Future', version: '0.9.0'),
      name: '$unique Confirmed',
    );
    expect((pending.pending, pending.appId, pending.importedDslVersion), (true, null, '0.9.0'));
    await expectLater(editor.confirmImport(pending.id), throwsA(_code('not_found', 404)));
    final confirmed = await owner.confirmImport(pending.id);
    expect((confirmed.status, confirmed.id), (AppImportStatus.completed, pending.id));
    created.add(confirmed.appId!);
    expect((await owner.get(confirmed.appId!)).name, '$unique Confirmed');
    await expectLater(owner.confirmImport(pending.id), throwsA(_code('not_found', 404)));
    final failed = await owner.importDsl(appFile(mode: AppModes.chat));
    expect((failed.failed, failed.appId), (true, null));
    expect(failed.error, contains('chat'));
    expect((await owner.importDsl('not: [a workflow')).failed, true);

    // ----- copy -----
    final copy = await editor.copy(b.id, name: '$unique Beta copy');
    created.add(copy.id);
    expect(
      (copy.name, copy.mode, copy.icon, copy.createdBy, copy.isStarred),
      (
        '$unique Beta copy',
        AppModes.advancedChat,
        '🐙',
        editorId,
        false,
      ),
    );
    final plainCopy = await owner.copy(a.id);
    created.add(plainCopy.id);
    expect((plainCopy.name, plainCopy.description), ('$unique Alpha', 'first'));

    // ----- export -----
    final yaml = await editor.exportDsl(c.id);
    expect(yaml, contains('$unique Gamma 3'));
    await expectLater(editor.exportDsl(c.id, includeSecret: true), forbidden);
    expect(await owner.exportDsl(c.id, includeSecret: true), contains('$unique Gamma 3'));

    // ----- delete -----
    await editor.delete(c.id);
    final deleted = throwsA(
      isA<TransportException>()
          .having((e) => e.appDeleted, 'appDeleted', isTrue)
          .having((e) => e.statusCode, 'status', 404),
    );
    await expectLater(owner.get(c.id), deleted);
    await expectLater(owner.update(c.id, name: 'x'), deleted);
    await expectLater(owner.copy(c.id), deleted);
    await expectLater(owner.exportDsl(c.id), deleted);
    await expectLater(owner.star(c.id), deleted);
    await expectLater(owner.delete(c.id), deleted);
    expect((await viewer.starred(mine(const AppListQuery(limit: 100)))).data, isEmpty);
    expect((await owner.list(mine())).data.map((x) => x.id), isNot(contains(c.id)));
    await expectLater(owner.get('no-such-app-$unique'), throwsA(_code('not_found', 404)));
  } finally {
    for (final id in created) {
      try {
        await owner.delete(id);
      } on TransportException {
        // already deleted
      }
    }
  }
  expect((await owner.list(mine())).total, 0);
}
