import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:test/test.dart';

import 'support/apps_scenario.dart';

/// A clock that moves 1 ms per reading (distinct, ordered times without waiting).
DateTime Function() _ticking() {
  var t = DateTime.utc(2026, 10, 19, 12);
  return () => t = t.add(const Duration(milliseconds: 1));
}

/// One committed op on the `start` node of [server] (what an editor's edit does).
void _commit(FakeServer server, {String client = 'c1', int cseq = 1}) {
  final r = server.submit(
    SubmitRequest(
      client: client,
      ops: [
        OutgoingOp(
          cseq: cseq,
          base: server.head,
          op: SetField('start', const ConfigKey(['desc']), VString('edit $cseq')),
        ),
      ],
    ),
  );
  expect(r.results.single, isA<AckResult>());
}

void main() {
  group('FakeAppsApi', () {
    late FakeAppsApi owner;
    late FakeAppsApi editor;
    late FakeAppsApi viewer;
    setUp(() {
      owner = FakeAppsApi(accountId: 'acc-owner', accountName: 'Olivia', clock: _ticking());
      editor = owner.asAccount('acc-editor', name: 'Eddie', role: AccountRole.editor);
      viewer = owner.asAccount('acc-viewer', name: 'Vic', role: AccountRole.normal);
    });

    test('follows the server\'s rules (the scenario the conformance test runs against a real server)', () async {
      await appsScenario(
        owner: owner,
        editor: editor,
        viewer: viewer,
        ownerName: 'Olivia',
        editorId: 'acc-editor',
        unique: 'fake-apps',
        commitEdit: (id) async => _commit(owner.server(id)),
      );
    });

    test('blank apps get the server\'s seeds; every app has its own document', () async {
      final wf = await owner.create(name: 'Flow', mode: AppModes.workflow);
      final chat = await owner.create(name: 'Chat', mode: AppModes.advancedChat);
      expect(owner.server(wf.id).doc.nodes.keys, ['start']);
      final doc = owner.server(chat.id).doc;
      expect(doc.nodes.keys.toSet(), {'start', 'llm', 'answer'});
      expect(doc.edges, hasLength(2));
      expect(doc.nodes['answer']!.config['answer'], const VString('{{#llm.text#}}'));
      expect(AppRegisters.featuresOf(doc)['retriever_resource'], {'enabled': true});
      expect(identical(owner.server(wf.id), editor.server(wf.id)), isTrue);
      expect(identical(owner.server(wf.id), owner.server(chat.id)), isFalse);
      expect(FakeAppsApi.seedDocument(AppModes.advancedChat).nodes.keys.toSet(), {'start', 'llm', 'answer'});
    });

    test('a commit on the app\'s document bumps "last modified", not updated_by', () async {
      final a = await owner.create(name: 'A', mode: AppModes.workflow);
      final b = await owner.create(name: 'B', mode: AppModes.workflow);
      expect([for (final x in (await owner.list()).data) x.id], [b.id, a.id]);
      _commit(editor.server(a.id));
      final after = await owner.get(a.id);
      expect([for (final x in (await owner.list()).data) x.id], [a.id, b.id]);
      expect(after.updatedBy, 'acc-owner');
      expect(after.updatedTime.isAfter(after.createdTime) || after.updatedAt >= after.createdAt, isTrue);
      owner.touch(b.id, at: DateTime.utc(2030));
      expect((await owner.list()).data.first.id, b.id);
    });

    test('seed populates the list for tests', () async {
      final s = owner.seed(
        name: 'Seeded',
        mode: AppModes.advancedChat,
        createdBy: 'acc-x',
        creatorName: 'Xavier',
        createdAt: DateTime.utc(2025),
        starred: true,
      );
      final got = await owner.get(s.id);
      expect(
        (got.authorName, got.createdBy, got.isStarred, got.mode),
        ('Xavier', 'acc-x', true, AppModes.advancedChat),
      );
      expect(got.createdTime, DateTime.utc(2025));
      expect([for (final x in (await owner.starred()).data) x.id], [s.id]);
      expect(owner.requests['get'], 1);
      expect(owner.requests['starred'], 1);
    });

    test('delete: the document answers 404 app_deleted through a FakeTransport and its streams end', () async {
      final a = await owner.create(name: 'Doomed', mode: AppModes.workflow);
      final server = owner.server(a.id);
      final transport = FakeTransport(server);
      addTearDown(transport.close);
      final events = <StreamEvent>[];
      final done = Completer<void>();
      transport.openStream(const StreamOpen()).listen(events.add, onDone: done.complete, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(events.whereType<SnapshotEvent>(), hasLength(1));
      await owner.delete(a.id);
      await done.future.timeout(const Duration(seconds: 2));
      expect(owner.isDeleted(a.id), isTrue);
      expect(
        () => owner.server(a.id),
        throwsA(isA<TransportException>().having((e) => e.appDeleted, 'deleted', isTrue)),
      );
      await expectLater(
        transport.submit(
          const SubmitRequest(
            client: 'c',
            ops: [
              OutgoingOp(cseq: 1, base: 0, op: SetField('start', ConfigKey(['x']), VString('y'))),
            ],
          ),
          timeout: const Duration(seconds: 2),
        ),
        throwsA(isA<TransportException>().having((e) => e.appDeleted, 'appDeleted', isTrue)),
      );
      await expectLater(
        transport.issueClientId(),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'app_deleted')),
      );
      Object? reopened;
      final again = Completer<void>();
      transport
          .openStream(const StreamOpen())
          .listen((_) {}, onError: (Object e) => reopened = e, onDone: again.complete);
      await again.future.timeout(const Duration(seconds: 2));
      expect(reopened, isA<TransportException>().having((e) => e.statusCode, 'status', 404));
    });

    test('an open session stops for good when its app is deleted', () async {
      final a = await owner.create(name: 'Open', mode: AppModes.workflow);
      final transport = FakeTransport(owner.server(a.id));
      final session = CollabSession(clientId: 'c1', transport: transport, store: MemoryStore());
      await session.start();
      await session.settled().timeout(const Duration(seconds: 5));
      expect(session.appDeleted, isFalse);
      await owner.delete(a.id);
      for (var i = 0; i < 100 && !session.appDeleted; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(session.appDeleted, isTrue);
      expect(session.status.lastError, contains('deleted'));
      // The stream ended, its reconnect got the 404; from then on no retries: no new stream, no POST.
      final opened = transport.streamsOpened, posts = transport.postsReceived;
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(transport.streamsOpened, opened);
      expect(transport.postsReceived, posts);
      await session.stop();
    });

    test('copy: a fresh document with the content at head and its own secret references', () async {
      final a = await owner.create(name: 'Source', mode: AppModes.workflow);
      final src = owner.server(a.id);
      for (var i = 1; i <= 3; i++) {
        _commit(src, cseq: i);
      }
      final secret = src.storeSecret('sk-secret');
      src.doc = Document(
        nodes: src.doc.nodes.values,
        edges: src.doc.edges.values,
        app: {
          AppRegisters.environmentVariables: VItems([
            Item(
              'e1',
              VMap({
                'id': const VString('e1'),
                'name': const VString('key'),
                'value_type': const VString('secret'),
                'value': VString(secret.masked),
                AppRegisters.secretRef: VString(secret.ref),
              }),
            ),
          ]),
        },
      );
      final copy = await owner.copy(a.id, name: 'Copy');
      final dst = owner.server(copy.id);
      expect(dst.head, 0);
      expect(dst.doc.nodes['start']!.config['desc'], const VString('edit 3'));
      final ref = (AppRegisters.variables(dst.doc, AppRegisters.environmentVariables).single)[AppRegisters.secretRef];
      expect(ref, isNot(secret.ref));
      expect(dst.secrets[ref], 'sk-secret');
      // The copy's document takes edits from seq 0 (no stamps of the original's log).
      _commit(dst, cseq: 1);
      expect(await owner.exportDsl(copy.id, includeSecret: true), contains('sk-secret'));
      expect(await owner.exportDsl(copy.id), isNot(contains('sk-secret')));
      owner.secretsKeyMissing = true;
      await expectLater(
        owner.copy(a.id),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'secrets_key_missing')),
      );
    });

    test('the export imports again', () async {
      final chat = await owner.create(name: 'Round trip', mode: AppModes.advancedChat, icon: '🐙');
      final yaml = await owner.exportDsl(chat.id);
      final back = await owner.importDsl(yaml);
      expect(back.completed, isTrue, reason: back.error);
      final again = await owner.get(back.appId!);
      expect((again.name, again.mode, again.icon), ('Round trip', AppModes.advancedChat, '🐙'));
      expect(owner.server(back.appId!).doc.nodes.keys.toSet(), {'start', 'llm', 'answer'});
    });

    test('a pending import expires after 10 minutes', () async {
      var now = DateTime.utc(2026);
      final api = FakeAppsApi(clock: () => now);
      final p = await api.importDsl(appFile(version: '0.9.0'));
      expect(p.pending, isTrue);
      now = now.add(const Duration(minutes: 11));
      await expectLater(
        api.confirmImport(p.id),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 404)),
      );
    });
  });

  group('AppInfo / AppPage / AppImport JSON', () {
    test('parse Dify\'s shapes', () {
      final page = AppPage.fromJson({
        'page': 2,
        'limit': 30,
        'total': 31,
        'has_more': false,
        'data': [
          {
            'id': 'x',
            'name': 'N',
            'description': null,
            'mode': 'advanced-chat',
            'icon_type': 'emoji',
            'icon': '🤖',
            'icon_background': '#FFEAD5',
            'created_at': 1760000000,
            'updated_at': 1760000100,
            'tags': [
              {'id': 't', 'name': 'T', 'type': 'app'},
            ],
            'permission_keys': ['app.acl.edit'],
            'is_starred': true,
            'author_name': 'A',
          },
        ],
      });
      final a = page.data.single;
      expect((page.page, page.limit, page.total, page.hasMore), (2, 30, 31, false));
      expect(
        (a.description, a.isChatflow, a.canEdit, a.isStarred, a.tags.single.name),
        ('', true, true, true, 'T'),
      );
      expect(a.updatedTime, DateTime.utc(2025, 10, 9, 8, 55));
      expect(a.json['author_name'], 'A');
      final i = AppImport.fromJson({
        'id': 'i',
        'status': 'pending',
        'current_dsl_version': '0.7.0',
        'imported_dsl_version': '1.0.0',
      });
      expect((i.pending, i.appId, i.error), (true, null, ''));
    });

    test('AppListQuery repeats list keys', () {
      final q = const AppListQuery(
        page: 2,
        limit: 30,
        name: 'x',
        creatorIds: ['a', 'b'],
        isCreatedByMe: true,
      ).toQuery();
      expect(q, {
        'page': ['2'],
        'limit': ['30'],
        'mode': ['all'],
        'name': ['x'],
        'sort_by': ['last_modified'],
        'creator_ids': ['a', 'b'],
        'is_created_by_me': ['true'],
      });
    });

    test('permission keys by role', () {
      expect(AppPermissionKeys.forRole(AccountRole.owner), hasLength(13));
      expect(AppPermissionKeys.forRole(AccountRole.editor), isNot(contains(AppPermissionKeys.tracingConfig)));
      expect(AppPermissionKeys.forRole(AccountRole.normal), [
        AppPermissionKeys.monitor,
        AppPermissionKeys.accessPointView,
      ]);
      expect(AppPermissionKeys.forRole(AccountRole.datasetOperator), [AppPermissionKeys.accessPointView]);
      expect(AppPermissionKeys.canCreate(AccountRole.editor), isTrue);
      expect(AppPermissionKeys.canCreate(AccountRole.normal), isFalse);
      expect(
        AppPermissionKeys.workspaceKeysForRole(AccountRole.admin),
        contains(AppPermissionKeys.createAndManagement),
      );
    });
  });
}
