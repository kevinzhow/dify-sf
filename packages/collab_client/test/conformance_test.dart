/// Protocol conformance against a real server. Runs only when `DIFYSF_URL` is set, e.g.
///
///     DIFYSF_URL=http://127.0.0.1:8080 dart test test/conformance_test.dart
///
/// Each test creates its own document, so it is safe to run against a shared server. Protocol 1.8: it signs in as
/// `DIFYSF_EMAIL` / `DIFYSF_PASSWORD` (default: a test account, installed as the owner on a fresh server; on a server
/// set up by someone else, pass the owner's or an admin's credentials) and invites an editor and a read-only member.
///
/// Model providers (protocol 1.9): credential checks go to a stub provider this test serves on `DIFYSF_STUB_HOST`
/// (default 127.0.0.1; the server must reach it, e.g. a server on the host network), never to a real provider. Set
/// `DIFYSF_MODELS_VALIDATE=false` for a server running with `COLLAB_MODELS_VALIDATE=false`.
///
/// Apps (protocol 1.10): the Studio page's calls (`AppsApi`, the same scenario as the in-memory fake's unit test); the apps it
/// creates carry a unique name and are deleted again.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/apps_scenario.dart';
import 'support/helpers.dart';
import 'support/model_providers_scenario.dart';

final String? _url = Platform.environment['DIFYSF_URL'];

final String _email = Platform.environment['DIFYSF_EMAIL'] ?? 'conformance@example.com';
final String _password = Platform.environment['DIFYSF_PASSWORD'] ?? 'conformance-pass-1';

String _docId() =>
    'conf-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(1 << 20).toRadixString(36)}';

void main() {
  if (_url == null) {
    test('conformance (set DIFYSF_URL to run)', () {}, skip: 'DIFYSF_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);
  late DocsApi api;
  late String doc;
  late HttpTransport t;
  // Protocol 1.8: the owner (or an admin) this run signs in as, an editor and a read-only (`normal`) member.
  late AuthSession owner;
  late AuthSession editor;
  late AuthSession viewer;

  Future<AuthSession> member(String role) async {
    final email = 'conf-$role-${_docId()}@example.com';
    final link = (await owner.invite(emails: [email], role: role)).single;
    final s = AuthSession(api: HttpAuthApi(base));
    await s.activate(
      token: link.token!,
      name: 'Conf ${role[0].toUpperCase()}${role.substring(1)}',
      password: 'member-pass-1',
    );
    return s;
  }

  setUpAll(() async {
    owner = AuthSession(api: HttpAuthApi(base));
    if (await owner.api.setupStatus() == SetupStatus.notStarted) {
      await owner.setup(email: _email, name: 'Conformance', password: _password);
    } else {
      await owner.login(email: _email, password: _password);
    }
    expect(owner.currentAccount!.isPrivileged, isTrue, reason: 'sign in as the owner or an admin (DIFYSF_EMAIL)');
    editor = await member(AccountRole.editor);
    viewer = await member(AccountRole.normal);
  });

  setUp(() async {
    api = DocsApi(base, auth: owner);
    doc = _docId();
    await api.ensure(doc, template: 'example');
    t = HttpTransport(baseUrl: base, docId: doc, auth: owner);
  });
  tearDown(() {
    t.close();
    api.close();
  });

  Future<SubmitResponse> post(String client, List<(int, int, Op)> ops, {int? floor, int? resolveFrom}) => t.submit(
    SubmitRequest(
      client: client,
      floor: floor,
      resolveFrom: resolveFrom,
      ops: [for (final (c, b, o) in ops) OutgoingOp(cseq: c, base: b, op: o)],
    ),
    timeout: const Duration(seconds: 10),
  );

  group('accounts (1.8)', () {
    test('setup is done; sign-in answers the same for unknown emails and wrong passwords', () async {
      expect(await owner.api.setupStatus(), SetupStatus.finished);
      await expectLater(
        owner.api.setup(email: 'x@example.com', name: 'X', password: 'x-pass-123'),
        throwsA(isA<TransportException>().having((e) => (e.statusCode, e.code), 'error', (409, 'setup_done'))),
      );
      Future<TransportException> refused(String email, String password) async {
        try {
          await owner.api.login(email: email, password: password);
        } on TransportException catch (e) {
          return e;
        }
        fail('signed in');
      }

      final unknown = await refused('nobody-${_docId()}@example.com', 'wrong-pass-1');
      final wrong = await refused(viewer.currentAccount!.email, 'wrong-pass-1');
      expect((unknown.statusCode, unknown.code, unknown.message), (wrong.statusCode, wrong.code, wrong.message));
      expect(wrong.code, 'invalid_credentials');
    });

    test('no token is 401 everywhere but setup, login, refresh, activation and health', () async {
      final anonymous = DocsApi(base);
      addTearDown(anonymous.close);
      expect(await anonymous.healthy(), isTrue);
      await expectLater(
        anonymous.snapshot(doc),
        throwsA(isA<TransportException>().having((e) => e.unauthorized, '401', isTrue)),
      );
      for (final path in ['/v1/docs/$doc/events', '/v1/docs/$doc/clients', '/v1/account', '/v1/workspace/members']) {
        expect((await http.get(base.replace(path: path))).statusCode, 401, reason: path);
      }
      expect(
        (await http.get(
          base.replace(path: '/v1/docs/$doc/snapshot'),
          headers: {'authorization': 'Bearer nope'},
        )).statusCode,
        401,
      );
      expect((await HttpAuthApi(base).checkInvitation('nope')).isValid, isFalse);
    });

    test('refresh rotates; logout revokes the session only', () async {
      final s = AuthSession(api: HttpAuthApi(base));
      await s.login(email: _email, password: _password);
      final old = s.tokens!;
      expect(await s.refresh(), isTrue);
      expect(s.tokens, isNot(old));
      await expectLater(
        s.api.refresh(old.refreshToken),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 401)),
      );
      final current = s.tokens!;
      await s.logout();
      await expectLater(
        s.api.account(current.accessToken),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 401)),
      );
      expect((await owner.account()).id, isNotEmpty); // another session of the same account
    });

    test('roles: read-only members read and stream but cannot write; secrets only for the privileged', () async {
      final view = HttpTransport(baseUrl: base, docId: doc, auth: viewer);
      addTearDown(view.close);
      final id = await view.issueClientId();
      await expectLater(
        view.submit(
          SubmitRequest(
            client: id,
            ops: [OutgoingOp(cseq: 1, base: 0, op: setPrompt('llm', 'no'))],
          ),
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<TransportException>().having((e) => e.forbidden, 'forbidden', isTrue)),
      );
      final events = await view.openStream(StreamOpen(client: id)).firstWhere((e) => e is ReadyEvent);
      expect(events, isA<ReadyEvent>());
      final viewerDocs = DocsApi(base, auth: viewer);
      addTearDown(viewerDocs.close);
      expect((await viewerDocs.snapshot(doc)).seq, 0);
      expect(await viewerDocs.exportDifyDsl(doc), contains('graph'));
      await expectLater(
        viewerDocs.ensure('conf-ro-${_docId()}'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 403)),
      );
      await expectLater(
        viewerDocs.storeSecret(doc, 'x'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 403)),
      );
      final editorDocs = DocsApi(base, auth: editor);
      addTearDown(editorDocs.close);
      await expectLater(
        editorDocs.exportDifyDsl(doc, includeSecret: true),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 403)),
      );
      expect(await api.exportDifyDsl(doc, includeSecret: true), contains('graph'));
      // The event stream also takes the token as ?access_token= (for the browser's EventSource).
      final q = HttpTransport(baseUrl: base, docId: doc, auth: viewer, accessTokenInQuery: true);
      addTearDown(q.close);
      expect(await q.openStream(const StreamOpen()).firstWhere((e) => e is ReadyEvent), isA<ReadyEvent>());
    });

    test('a role changed mid-session: the batch is refused (403), its ops come back rejected(forbidden) and nothing '
        'more is sent; promoted back, the session resumes with a floor', () async {
      final m = await member(AccountRole.editor);
      final s = CollabSession(
        transport: HttpTransport(baseUrl: base, docId: doc, auth: m),
        store: MemoryStore(),
      );
      await s.start();
      await s.settled();
      s.edit(setPrompt('llm', 'saved'));
      await s.settled();
      expect((await api.info(doc))!.head, 1);

      await owner.updateRole(m.currentAccount!.id, AccountRole.normal);
      final verdict = s.events.firstWhere((e) => e is OpRejected);
      s.edit(setPrompt('llm', 'refused'));
      expect((await verdict.timeout(const Duration(seconds: 20)) as OpRejected).reason, const Forbidden());
      expect(s.editsForbidden, isTrue);
      expect(s.pending, isEmpty);
      expect(s.edit(setPrompt('llm', 'again')).refusal, const Forbidden());
      await Future<void>.delayed(const Duration(seconds: 1));
      expect((await api.info(doc))!.head, 1);

      await owner.updateRole(m.currentAccount!.id, AccountRole.editor);
      s.allowEdits(); // the floor skips cseq 2, which the server never handled
      s.edit(setPrompt('llm', 'back'));
      await s.settled().timeout(const Duration(seconds: 20));
      final snap = await api.snapshot(doc);
      expect((snap.seq, cfg(snap.doc, 'llm', 'prompt')), (2, 'back'));
      await s.stop();
    });
  });

  group('document endpoints', () {
    test('healthz, create, ensure, info, snapshot', () async {
      expect(await api.healthy(), isTrue);
      final created = await api.create(template: 'empty');
      expect(created.head, 0);
      final info = await api.info(created.id);
      expect(info!.id, created.id);
      expect((await api.ensure(created.id)).created, isFalse);
      expect(await api.info('no-such-doc-${_docId()}'), isNull);
      final snap = await api.snapshot(created.id);
      expect(snap.seq, 0);
      expect(snap.doc.nodes.keys, ['start']);
      final example = await api.snapshot(doc);
      expect(example.doc.nodes.keys.toSet(), {'start', 'llm', 'code', 'answer'});
      expect(example.doc.integrityProblems, isEmpty);
    });

    test('posting to an unknown document is a 404', () async {
      final ghost = HttpTransport(baseUrl: base, docId: 'ghost-${_docId()}', auth: owner);
      await expectLater(
        ghost.submit(const SubmitRequest(client: 'c'), timeout: const Duration(seconds: 5)),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
      ghost.close();
    });

    test('malformed bodies are 400, not 5xx', () async {
      final res = await http.post(
        base.replace(path: '/v1/docs/$doc/ops'),
        headers: {'content-type': 'application/json', 'authorization': 'Bearer ${owner.accessToken}'},
        body: '{nope',
      );
      expect(res.statusCode, 400);
      expect((jsonDecode(res.body) as Map<String, Object?>)['error'], isA<Map<String, Object?>>());
    });
  });

  group('submitting ops', () {
    test('ack with a global seq; retransmits return the same ack and apply nothing twice', () async {
      final r1 = await post('cli-a', [(1, 0, setPrompt('llm', 'one'))]);
      expect(r1.results.single, isA<AckResult>());
      final seq = (r1.results.single as AckResult).seq;
      expect(seq, 1);
      final r2 = await post('cli-a', [(1, 0, setPrompt('llm', 'one'))]);
      expect((r2.results.single as AckResult).seq, seq);
      expect(r2.head, 1);
      expect((await api.snapshot(doc)).seq, 1);
    });

    test('a gap is reported, not processed', () async {
      final r = await post('cli-gap', [(3, 0, setPrompt('llm', 'x'))]);
      expect(r.results.single, isA<GapResult>().having((g) => g.expected, 'expected', 1));
      expect(r.head, 0);
    });

    test('a rejected op consumes its cseq and a retransmit gets the original reason', () async {
      final first = await post('cli-r', [(1, 0, setPrompt('ghost', 'x'))]);
      expect((first.results.single as RejectResult).reason, const NodeNotFound('ghost'));
      expect(first.high, 1);
      final again = await post('cli-r', [(1, 0, setPrompt('ghost', 'x')), (2, 0, setPrompt('llm', 'ok'))]);
      expect((again.results[0] as RejectResult).reason, const NodeNotFound('ghost'));
      expect(again.results[1], isA<AckResult>());
    });

    test('stale write: conflict names the winner; same value is accepted; own writes never conflict', () async {
      await post('cli-bob', [(1, 0, setPrompt('llm', 'bob'))]); // seq 1
      final alice = await post('cli-alice', [
        (1, 0, setPrompt('llm', 'alice')), // stale, different value
        (2, 0, setPrompt('llm', 'bob')), // stale, same value as present
        (3, 0, setStr('llm', ['model', 'name'], 'x')), // different register
      ]);
      final c = (alice.results[0] as RejectResult).reason as Conflict;
      expect((c.node, c.by, c.seq), ('llm', 'cli-bob', 1));
      expect(c.field, const ConfigKey(['prompt']));
      expect(alice.results[1], isA<AckResult>(), reason: 'same-value rule');
      expect(alice.results[2], isA<AckResult>());
      final bobAgain = await post('cli-bob', [(2, 0, setPrompt('llm', 'bob2'))]);
      expect(bobAgain.results.single, isA<AckResult>(), reason: 'a client never conflicts with itself');
    });

    test('layout is last-writer-wins and never stale', () async {
      await post('cli-a', [(1, 0, const MoveNode('llm', 1, 1))]);
      final r = await post('cli-b', [(1, 0, const MoveNode('llm', 2, 2))]);
      expect(r.results.single, isA<AckResult>());
      expect((await api.snapshot(doc)).doc.nodes['llm']!.x, 2);
    });

    test('keyed lists: concurrent inserts and item edits do not conflict', () async {
      final a = await post('cli-a', [
        (1, 0, const InsertItem('code', ['outputs'], Item('i-a', VString('a')), 'o-result')),
      ]);
      final b = await post('cli-b', [
        (1, 0, const InsertItem('code', ['outputs'], Item('i-b', VString('b')), 'o-result')),
      ]);
      expect(a.results.single, isA<AckResult>());
      expect(b.results.single, isA<AckResult>());
      final ids = ((await api.snapshot(doc)).doc.nodes['code']!.config['outputs']! as VItems).items
          .map((i) => i.id)
          .toList();
      expect(ids, ['o-result', 'i-b', 'i-a']);
      final c = await post('cli-c', [
        (1, 0, const UpdateItem('code', ['outputs'], 'i-a', VString('c'))),
      ]);
      expect((c.results.single as RejectResult).reason, isA<Conflict>());
      final removed = await post('cli-c', [
        (2, 2, const RemoveItem('code', ['outputs'], 'i-a')),
        (3, 2, const RemoveItem('code', ['outputs'], 'i-a')),
      ]);
      expect(removed.results.map((r) => r.runtimeType), [AckResult, AckResult], reason: 'removing twice is fine');
      final late = await post('cli-c', [
        (4, 4, const UpdateItem('code', ['outputs'], 'i-a', VString('x'))),
      ]);
      expect((late.results.single as RejectResult).reason, const ItemDeleted('i-a'));
    });

    test('deleting a referenced node breaks references explicitly; dangling references are refused', () async {
      await post('cli-a', [(1, 0, const RemoveNode('llm'))]);
      final snap = await api.snapshot(doc);
      expect(snap.doc.nodes['code']!.config['inputs'], const VBroken(OutputRef('llm', 'text')));
      expect(snap.doc.nodes['code']!.config['inputs'], isA<VBroken>());
      expect(snap.doc.edges.keys, ['e-code-answer']);
      expect(snap.doc.integrityProblems, isEmpty);
      final r = await post('cli-a', [
        (2, 1, SetField('answer', const ConfigKey(['x']), ref('llm'))),
        (3, 1, setPrompt('llm', 'zombie')),
        (4, 1, const AddNode(Node(id: 'llm', type: 'llm'))),
      ]);
      expect((r.results[0] as RejectResult).reason, const DanglingReference('llm'));
      expect((r.results[1] as RejectResult).reason, const NodeDeleted('llm'));
      expect((r.results[2] as RejectResult).reason, const NodeExists('llm'));
    });

    test('a base from the future is refused', () async {
      final r = await post('cli-a', [(1, 99, setPrompt('llm', 'x'))]);
      expect((r.results.single as RejectResult).reason, isA<Invalid>());
    });

    test('floor abandons lost ops; resolveFrom reports their fate', () async {
      await post('cli-v', [(1, 0, setPrompt('llm', 'one'))]);
      await post('cli-v', [(2, 0, setPrompt('code', 'rejected'))]); // committed; and a rejected one next:
      await post('cli-v', [(3, 0, setPrompt('ghost', 'x'))]);
      final r = await post('cli-v', [], floor: 6, resolveFrom: 1);
      expect(r.high, 5);
      expect(r.known!.committed.keys.toSet(), {1, 2});
      expect(r.known!.rejected.keys.toSet(), {3});
      // 4 and 5 were abandoned: neither committed nor rejected. A late arrival is notCommitted.
      final late = await post('cli-v', [(4, 0, setPrompt('llm', 'late'))]);
      expect((late.results.single as RejectResult).reason, const NotCommitted());
      final next = await post('cli-v', [(6, 0, setPrompt('llm', 'six'))]);
      expect(next.results.single, isA<AckResult>());
    });

    test('100 ops per request are accepted, 101 are a 400', () async {
      Future<SubmitResponse> many(String client, int n) =>
          post(client, [for (var i = 1; i <= n; i++) (i, 0, MoveNode('llm', i, i))]);
      final ok = await many('cli-100', 100);
      expect(ok.results.whereType<AckResult>(), hasLength(100));
      await expectLater(
        many('cli-101', 101),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );
    });
  });

  group('protocol 1.1 to 1.7', () {
    test('POST /clients issues unique client ids (404 for an unknown document)', () async {
      final ids = {for (var i = 0; i < 5; i++) await t.issueClientId()};
      expect(ids, hasLength(5));
      expect(ids, everyElement(matches(RegExp(r'^s-[0-9a-f]{32}$'))));
      expect(await api.issueClientId(doc), matches(RegExp(r'^s-')));
      await expectLater(
        HttpTransport(baseUrl: base, docId: 'ghost-${_docId()}', auth: owner).issueClientId(),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('a (client, cseq) reused for a different op is clientIdInUse and applies nothing', () async {
      final id = await t.issueClientId();
      final first = await post(id, [(1, 0, setPrompt('llm', 'one'))]);
      expect(first.results.single, isA<AckResult>());
      final other = await post(id, [(1, 0, setPrompt('llm', 'two'))]);
      expect((other.results.single as RejectResult).reason, const ClientIdInUse());
      final otherBase = await post(id, [(1, 1, setPrompt('llm', 'one'))]);
      expect(
        (otherBase.results.single as RejectResult).reason,
        const ClientIdInUse(),
        reason: 'base is part of the fingerprint',
      );
      final again = await post(id, [(1, 0, setPrompt('llm', 'one'))]);
      expect((again.results.single as AckResult).seq, 1, reason: 'a genuine retransmit is still the original ack');
      expect((await api.snapshot(doc)).seq, 1);
    });

    test('1.8 client ids belong to accounts: directory, byName, foreign ids refused', () async {
      final mine = await t.issueClientId(name: 'ignored');
      final ed = HttpTransport(baseUrl: base, docId: doc, auth: editor);
      addTearDown(ed.close);
      final theirs = await ed.issueClientId();
      final me = owner.currentAccount!, them = editor.currentAccount!;
      expect(await api.clientDirectory(doc), {
        mine: ClientIdentity(account: me.id, name: me.name),
        theirs: ClientIdentity(account: them.id, name: them.name),
      });
      expect(await api.clientNames(doc), {mine: me.name, theirs: them.name});
      await post(mine, [(1, 0, setPrompt('llm', 'mine'))]); // seq 1
      // A stale write by the editor: the conflict names the owner's account.
      final r = await ed.submit(
        SubmitRequest(
          client: theirs,
          ops: [OutgoingOp(cseq: 1, base: 0, op: setPrompt('llm', 'theirs'))],
        ),
        timeout: const Duration(seconds: 10),
      );
      final c = (r.results.single as RejectResult).reason as Conflict;
      expect((c.by, c.byName), (mine, me.name));
      // Someone else's client id: the whole batch is 403, nothing applied.
      await expectLater(
        ed.submit(
          SubmitRequest(
            client: mine,
            ops: [OutgoingOp(cseq: 2, base: 1, op: setPrompt('llm', 'impostor'))],
          ),
          timeout: const Duration(seconds: 10),
        ),
        throwsA(isA<TransportException>().having((e) => e.forbidden, 'forbidden', isTrue)),
      );
      // A self-chosen id belongs to the first account that uses it (PUT /clients binds it).
      final chosen = 'conf-tab-${_docId()}';
      await ed.setClientName(chosen, 'ignored');
      await expectLater(
        t.setClientName(chosen, 'mine?'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 's', 403)),
      );
      expect((await api.clientDirectory(doc))[chosen]?.account, them.id);
      expect((await api.snapshot(doc)).seq, 1);
    });

    test('1.4 declared outputs: a ref to a missing output is refused; removing an output breaks refs to it', () async {
      // example template: code.outputs = [o-result {name: result}], answer.answer = ref(code.result)
      final bad = await post('cli-o', [
        (1, 0, const SetField('answer', ConfigKey(['answer']), VRef(OutputRef('code', 'nope')))),
      ]);
      expect((bad.results.single as RejectResult).reason, const DanglingReference('code'));
      final rm = await post('cli-o', [
        (2, 0, const RemoveItem('code', ['outputs'], 'o-result')),
      ]);
      expect(rm.results.single, isA<AckResult>());
      final snap = (await api.snapshot(doc)).doc;
      expect(snap.nodes['answer']!.config['answer'], const VBroken(OutputRef('code', 'result')));
      expect(snap.integrityProblems, isEmpty);
    });

    test(
      '1.6 restore: undo of a delete brings back node, edges and references; only the deleter may restore',
      () async {
        final before = (await api.snapshot(doc)).doc;
        final llm = before.nodes['llm']!;
        final edges = [
          for (final e in before.edges.values)
            if (e.source == 'llm' || e.target == 'llm') e,
        ]..sort((a, b) => a.id.compareTo(b.id));
        expect(edges.map((e) => e.id), ['e-llm-code', 'e-start-llm']);
        expect(
          (await post('cli-r', [(1, 0, const RemoveNode('llm'))])).results.single,
          isA<AckResult>().having((a) => a.seq, 'seq', 1),
        );
        final gone = (await api.snapshot(doc)).doc;
        expect(gone.nodes['code']!.config['inputs'], const VBroken(OutputRef('llm', 'text')));
        // Only the deleter may undo a delete: anyone else gets notDeleter, whatever their base ...
        final other = await post('cli-s', [(1, 0, RestoreNode(llm, edges)), (2, 1, RestoreNode(llm, edges))]);
        expect(
          [for (final r in other.results) (r as RejectResult).reason],
          [
            const NotDeleter('llm', 'cli-r'),
            const NotDeleter('llm', 'cli-r'),
          ],
        );
        // ... the deleter can (the same base as its delete: an undo pressed right away).
        final undo = await post('cli-r', [(2, 0, RestoreNode(llm, edges))]);
        expect(undo.results.single, isA<AckResult>().having((a) => a.seq, 'seq', 2));
        final back = (await api.snapshot(doc)).doc;
        expect(back.nodes['llm'], llm);
        expect(back.edges, before.edges);
        expect(back.deletedNodes, isEmpty);
        expect(back.deletedEdges, isEmpty);
        expect(back.nodes['code']!.config['inputs'], const VRef(OutputRef('llm', 'text')));
        expect(back.integrityProblems, isEmpty);
        // The client's own replay of the log gives the server's document, version metadata included.
        final replay = Templates.example()
          ..apply(const RemoveNode('llm'), const Stamp(1, 'cli-r'))
          ..apply(RestoreNode(llm, edges), const Stamp(2, 'cli-r'));
        expect(replay, back);
        // A write based on a version before the restore is stale: it names the restore.
        final late = await post('cli-s', [
          (3, 0, const SetField('llm', ConfigKey(['prompt']), VString('stale'))),
        ]);
        expect(
          (late.results.single as RejectResult).reason,
          const Conflict(node: 'llm', field: ConfigKey([]), seq: 2, by: 'cli-r'),
        );
        // A second restore: the node exists.
        final again = await post('cli-r', [(3, 2, RestoreNode(llm, edges))]);
        expect((again.results.single as RejectResult).reason, const NodeExists('llm'));
      },
    );

    test(
      '1.6 restore: streams without proto=1.6 never carry it (snapshot instead of replay, live stream ended)',
      () async {
        Future<List<StreamEvent>> catchUp(StreamOpen open) async {
          final out = <StreamEvent>[];
          await for (final e in t.openStream(open).timeout(const Duration(seconds: 10))) {
            if (e is PingEvent) continue;
            out.add(e);
            if (e is ReadyEvent) break;
          }
          return out;
        }

        final answer = (await api.snapshot(doc)).doc.nodes['answer']!;
        const edge = Edge(id: 'e-code-answer', source: 'code', target: 'answer');
        await post('cli-r', [(1, 0, const RemoveNode('answer'))]);

        // Live: a 1.5 stream (no proto) and a 1.6 stream are open when the restore commits.
        final old = <StreamEvent>[], current = <StreamEvent>[];
        var oldEnded = false;
        final oldSub = t
            .openStream(const StreamOpen(lastEventId: 1, proto: null))
            .listen(
              (e) => e is PingEvent ? null : old.add(e),
              onDone: () => oldEnded = true,
              onError: (_) => oldEnded = true,
            );
        final curSub = t
            .openStream(const StreamOpen(lastEventId: 1))
            .listen((e) => e is PingEvent ? null : current.add(e));
        await Future<void>.delayed(const Duration(milliseconds: 500));
        expect(old.whereType<ReadyEvent>(), hasLength(1));
        expect(
          (await post('cli-r', [
            (2, 1, RestoreNode(answer, const [edge])),
          ])).results.single,
          isA<AckResult>().having((a) => a.seq, 'seq', 2),
        );
        for (var i = 0; i < 40 && !(oldEnded && current.whereType<CommitEvent>().isNotEmpty); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        await oldSub.cancel();
        await curSub.cancel();
        expect(oldEnded, isTrue, reason: 'the server ends a 1.5 stream instead of sending it the restore');
        expect(old.whereType<CommitEvent>(), isEmpty);
        expect(current.whereType<CommitEvent>().single.entry.op, RestoreNode(answer, const [edge]));

        // Catch-up: the range (0, 2] contains the restore.
        final oldResume = await catchUp(const StreamOpen(lastEventId: 0, proto: null));
        expect(oldResume.first, isA<SnapshotEvent>().having((s) => s.seq, 'seq', 2));
        expect((oldResume.first as SnapshotEvent).doc.nodes['answer'], answer);
        final oldUpToDate = await catchUp(const StreamOpen(lastEventId: 2, proto: null));
        expect(oldUpToDate, hasLength(1), reason: 'nothing to replay: only ready');
        final newResume = await catchUp(const StreamOpen(lastEventId: 0));
        expect(newResume.whereType<CommitEvent>().map((c) => c.entry.op), [
          const RemoveNode('answer'),
          RestoreNode(answer, const [edge]),
        ]);
        final older = await catchUp(const StreamOpen(lastEventId: 0, proto: '1.5'));
        expect(older.first, isA<SnapshotEvent>(), reason: 'proto below 1.6 counts as old');
        final bad = await http.get(
          base.replace(path: '/v1/docs/$doc/events', query: 'proto=latest'),
          headers: {'authorization': 'Bearer ${owner.accessToken}'},
        );
        expect(bad.statusCode, 400);
      },
    );

    test('1.5 numbers: a fractional value is stored and served as a double', () async {
      final r = await post('cli-n', [
        (1, 0, const SetField('llm', ConfigKey(['temperature']), VDouble(0.7))),
      ]);
      expect(r.results.single, isA<AckResult>());
      expect((await api.snapshot(doc)).doc.nodes['llm']!.config['temperature'], const VDouble(0.7));
      // on the wire 2.0 is just the number 2: stored and served as an int (one representation per number)
      final whole = await post('cli-n', [
        (2, 1, const SetField('llm', ConfigKey(['temperature']), VDouble(2.0))),
      ]);
      expect(whole.results.single, isA<AckResult>());
      expect((await api.snapshot(doc)).doc.nodes['llm']!.config['temperature'], const VInt(2));
    });

    test('1.5 Dify workflow files: import creates the document, export renders its current state', () async {
      const dsl = '''
app:
  mode: workflow
  name: conformance import
kind: app
version: 0.3.1
workflow:
  features: {}
  graph:
    edges:
    - id: s-c
      source: s
      sourceHandle: source
      target: c
      targetHandle: target
      type: custom
    nodes:
    - id: s
      type: custom
      position: {x: 80, y: 282.5}
      data: {type: start, title: Start, variables: [{variable: q, label: q, type: text-input}]}
    - id: c
      type: custom
      position: {x: 384, y: 282}
      data:
        type: code
        title: Code
        code: "def main(q): return {'result': q}"
        variables: [{variable: q, value_selector: [s, q]}]
        outputs: {result: {type: string, children: null}}
        temperature_like: 0.7
''';
      final id = 'dsl-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      final created = await api.importDifyDsl(dsl, id: id);
      expect(created.created, isTrue);
      expect(
        (await api.importDifyDsl(dsl, id: id)).created,
        isFalse,
        reason: 'a retried import leaves the document alone',
      );
      final snap = (await api.snapshot(id)).doc;
      expect(snap.nodes.keys.toSet(), {'s', 'c'});
      expect(snap.nodes['c']!.config['temperature_like'], const VDouble(0.7));
      final vars = snap.nodes['c']!.config['variables']! as VItems;
      expect(vars.items.single.id, 'q');
      expect((vars.items.single.value as VMap).entries['value_selector'], const VRef(OutputRef('s', 'q')));
      // edit, then export
      final t = HttpTransport(baseUrl: base, docId: id, auth: owner);
      final r = await t.submit(
        const SubmitRequest(
          client: 'cli-dsl',
          ops: [OutgoingOp(cseq: 1, base: 0, op: SetField('c', TitleKey(), VString('Renamed')))],
        ),
        timeout: const Duration(seconds: 10),
      );
      t.close();
      expect(r.results.single, isA<AckResult>());
      Map<String, Object?> m(Object? x) => x! as Map<String, Object?>;
      final out = await api.exportDifyDslJson(id);
      expect(m(out['app'])['name'], 'conformance import');
      final nodes = (m(m(out['workflow'])['graph'])['nodes']! as List<Object?>).map(m).toList();
      final c = m(nodes.firstWhere((n) => n['id'] == 'c')['data']);
      expect(c['title'], 'Renamed');
      expect(m(c['outputs']).keys, ['result']);
      expect(m((c['variables']! as List<Object?>).single)['value_selector'], ['s', 'q']);
      expect(m(nodes.firstWhere((n) => n['id'] == 's')['position'])['y'], 282.5);
      expect(await api.exportDifyDsl(id), contains('conformance import'));
    });

    test('Dify app metadata: mode and variables of an imported file, secrets masked; defaults otherwise', () async {
      const dsl = '''
app: {mode: advanced-chat, name: conformance meta}
kind: app
version: 0.3.1
workflow:
  environment_variables:
  - {id: e1, name: api_key, value: not-for-clients, value_type: secret}
  - {id: e2, name: region, value: eu, value_type: string}
  conversation_variables:
  - {id: c1, name: str, selector: [conversation, str], value: default, value_type: string}
  features: {opening_statement: hi}
  graph:
    edges: []
    nodes:
    - id: s
      data: {type: start, title: Start, variables: []}
''';
      final id = 'meta-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
      await api.importDifyDsl(dsl, id: id);
      final m = await api.meta(id);
      expect(m.appMode, 'advanced-chat');
      expect(m.appName, 'conformance meta');
      // 1.7: a secret is served masked (Dify's formatSecret), never in plaintext nor with its reference.
      expect(
        {for (final v in m.environmentVariables) v['name']: v['value']},
        {
          'api_key': 'not-fo************ts',
          'region': 'eu',
        },
      );
      expect(m.environmentVariables.every((v) => !v.containsKey('secret_ref')), isTrue);
      expect(m.conversationVariables.single['name'], 'str');
      expect(m.raw['features'], {'opening_statement': 'hi'});
      expect(m.raw.containsKey('workflow'), isFalse, reason: 'no graph');
      final plain = await api.meta(doc);
      expect((plain.appMode, plain.appName), ('workflow', doc), reason: 'not imported: the export defaults');
      expect([...plain.environmentVariables, ...plain.conversationVariables], isEmpty);
      await expectLater(
        api.meta(_docId()),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('1.7 app registers: variables are edited with item ops on \$app; secrets stay on the server', () async {
      const app = Document.appNode;
      const env = [AppRegisters.environmentVariables];
      // A secret typed in the panel: stored aside, the document only gets the mask and the reference.
      final (:ref, :masked) = await api.storeSecret(doc, 'sk-typed-in-the-panel');
      expect(ref, matches(RegExp(r'^sec-[0-9a-f]{32}$')));
      expect(masked, AppRegisters.maskSecret('sk-typed-in-the-panel'));
      Value v(String id, String value, {String type = 'string', String? secretRef}) => Value.of({
        'id': id,
        'name': id,
        'value': value,
        'value_type': type,
        'description': '',
        'secret_ref': ?secretRef,
      });
      final r = await post('cli-v', [
        (1, 0, InsertItem(app, env, Item('k', v('k', masked, type: 'secret', secretRef: ref)), null)),
        (2, 0, InsertItem(app, env, Item('r', v('r', 'eu')), 'k')),
        (3, 0, const SetField(app, ConfigKey(['features', 'opening_statement']), VString('hi'))),
      ]);
      expect([for (final x in r.results) (x as AckResult).seq], [1, 2, 3]);
      // Concurrent edits of different variables both commit; a stale edit of the same one is a conflict.
      final b = await post('cli-w', [(1, 2, UpdateItem(app, env, 'r', v('r', 'us')))]);
      expect(b.results.single, isA<AckResult>());
      final stale = await post('cli-v', [(4, 2, UpdateItem(app, env, 'r', v('r', 'jp')))]);
      expect(
        (stale.results.single as RejectResult).reason,
        const Conflict(node: app, field: ItemKey(env, 'r'), seq: 4, by: 'cli-w'),
      );
      // Everything else naming $app is invalid.
      final bad = await post('cli-v', [
        (5, 4, const RemoveNode(app)),
        (6, 4, const SetField(app, TitleKey(), VString('t'))),
        (7, 4, const AddNode(Node(id: r'$x', type: 'llm'))),
        (8, 4, const SetField(app, ConfigKey(['features', 'r']), VRef(OutputRef('llm', 'text')))),
      ]);
      expect([for (final x in bad.results) (x as RejectResult).reason.name], everyElement('invalid'));
      // The client's replay equals the server's document; the snapshot never holds the plaintext.
      final snap = await api.snapshot(doc);
      expect(jsonEncode(snap.doc.toJson()), isNot(contains('sk-typed-in-the-panel')));
      expect(AppRegisters.variables(snap.doc, AppRegisters.environmentVariables).map((x) => x['value']), [
        masked,
        'us',
      ]);
      // Meta follows the document (mask, no reference); export blanks secrets unless include_secret.
      final meta = await api.meta(doc);
      expect(meta.environmentVariables.map((x) => x['value']), [masked, 'us']);
      expect(meta.environmentVariables.every((x) => !x.containsKey('secret_ref')), isTrue);
      expect(meta.raw['features'], {'opening_statement': 'hi'});
      List<Object?> exportedEnv(Map<String, Object?> dsl) =>
          (dsl['workflow']! as Map<String, Object?>)['environment_variables']! as List<Object?>;
      final plain = exportedEnv(await api.exportDifyDslJson(doc));
      expect(plain.map((x) => (x! as Map<String, Object?>)['value']), ['', 'us']);
      final full = exportedEnv(await api.exportDifyDslJson(doc, includeSecret: true));
      expect(full.map((x) => (x! as Map<String, Object?>)['value']), ['sk-typed-in-the-panel', 'us']);
      expect([...plain, ...full].every((x) => !(x! as Map<String, Object?>).containsKey('secret_ref')), isTrue);
      expect(await api.exportDifyDsl(doc, includeSecret: true), contains('sk-typed-in-the-panel'));
      // A 1.6 stream never carries a $app write: its catch-up becomes a snapshot.
      final old = <StreamEvent>[];
      await for (final e
          in t.openStream(const StreamOpen(lastEventId: 0, proto: '1.6')).timeout(const Duration(seconds: 10))) {
        if (e is PingEvent) continue;
        old.add(e);
        if (e is ReadyEvent) break;
      }
      expect(old.first, isA<SnapshotEvent>());
      expect((old.first as SnapshotEvent).doc, snap.doc);
    });

    test('replacing a document from a Dify file: ops of the caller, retries replayed, fresh ids, refusals', () async {
      const seed = '''
app: {mode: workflow, name: conformance seed}
kind: app
version: 0.3.1
workflow:
  graph:
    nodes:
    - {id: seed, data: {type: start, title: Seed, variables: []}, position: {x: 0, y: 0}}
    edges: []
''';
      const file = r'''
app: {mode: workflow, name: conformance replaced}
kind: app
version: 0.3.1
workflow:
  environment_variables:
  - {id: e1, name: api_key, value: sk-conformance-secret, value_type: secret}
  features: {opening_statement: hi}
  graph:
    nodes:
    - {id: start, data: {type: start, title: Start, variables: [{variable: q, type: text-input, label: q}]}, position: {x: 0, y: 0}}
    - id: code
      position: {x: 300, y: 0}
      data: {type: code, title: Code, code: x, outputs: {result: {type: string}}, variables: [{variable: q, value_selector: [start, q]}]}
    - id: llm
      position: {x: 600.5, y: 0}
      data: {type: llm, title: LLM, prompt_template: [{id: p1, role: user, text: 'Say {{#code.result#}}'}], context: {enabled: true, variable_selector: [code, result]}}
    - {id: end, position: {x: 900, y: 0}, data: {type: end, title: End, outputs: [{variable: out, value_selector: [llm, text]}]}}
    edges:
    - {id: start-source-code-target, source: start, target: code, sourceHandle: source, targetHandle: target}
    - {id: code-source-llm-target, source: code, target: llm, sourceHandle: source, targetHandle: target}
    - {id: llm-source-end-target, source: llm, target: end, sourceHandle: source, targetHandle: target}
''';
      final id = 'rep-${_docId()}';
      await api.importDifyDsl(seed, id: id);
      final client = await api.issueClientId(id);
      final r = await api.replaceDocument(id, file, client, cseq: 1);
      expect(
        (r.head, r.nextCseq, r.nodes, r.edges, r.replayed, r.status),
        (
          r.ops,
          r.ops + 1,
          4,
          3,
          false,
          'completed-with-warnings',
        ),
      );
      expect((r.importedDslVersion, r.currentDslVersion), ('0.3.1', '0.7.0'));
      expect(r.renamedNodes, isEmpty);
      final d = (await api.snapshot(id)).doc;
      expect(d.nodes.keys.toSet(), {'start', 'code', 'llm', 'end'});
      expect(d.deletedNodes.keys, ['seed']);
      expect(
        (d.nodes['llm']!.config['context']! as VMap).entries['variable_selector'],
        const VRef(OutputRef('code', 'result')),
      );
      expect(jsonEncode(d.toJson()), isNot(contains('sk-conformance-secret')));
      expect(await api.exportDifyDsl(id, includeSecret: true), contains('sk-conformance-secret'));
      expect((await api.meta(id)).appName, 'conformance replaced');
      // Retries are replayed; the same file again is no op; a cseq ahead is refused.
      final again = await api.replaceDocument(id, file, client, cseq: 1);
      expect((again.replayed, again.ops, again.nextCseq), (true, r.ops, r.nextCseq));
      expect((await api.replaceDocument(id, file, client, cseq: r.nextCseq)).ops, 0);
      await expectLater(
        api.replaceDocument(id, file, client, cseq: r.nextCseq + 1),
        throwsA(isA<TransportException>().having((e) => e.code, 'code', 'outstanding_ops')),
      );
      // A deleted node comes back under a fresh id; references and edges follow.
      final tr = HttpTransport(baseUrl: base, docId: id, auth: owner);
      final del = await tr.submit(
        SubmitRequest(
          client: 'cli-rep-del',
          ops: [OutgoingOp(cseq: 1, base: r.head, op: const RemoveNode('llm'))],
        ),
        timeout: const Duration(seconds: 10),
      );
      tr.close();
      expect(del.results.single, isA<AckResult>());
      final back = await api.replaceDocument(id, file, client, cseq: r.nextCseq);
      final fresh = back.renamedNodes['llm']!;
      expect(back.renamedEdges['llm-source-end-target'], '$fresh-source-end-target');
      final after = (await api.snapshot(id)).doc;
      final out = (after.nodes['end']!.config['outputs']! as VItems).items.single.value as VMap;
      expect(out.entries['value_selector'], VRef(OutputRef(fresh, 'text')));
      // Refusals: a version to confirm, a mode that does not fit, a read-only member.
      final newer = file.replaceFirst('version: 0.3.1', 'version: 0.9.0');
      await expectLater(
        api.replaceDocument(id, newer, client, cseq: back.nextCseq),
        throwsA(isA<DslVersionUnconfirmed>().having((e) => e.importedVersion, 'imported', '0.9.0')),
      );
      final chat = file.replaceFirst('type: end', 'type: answer');
      await expectLater(
        api.replaceDocument(id, chat, client, cseq: back.nextCseq),
        throwsA(isA<TransportException>().having((e) => e.message, 'message', startsWith('Import Failed'))),
      );
      final viewerApi = DocsApi(base, auth: viewer);
      await expectLater(
        viewerApi.replaceDocument(id, file, 'cli-viewer-rep', cseq: 1),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 403)),
      );
      viewerApi.close();
    });

    test('CollabSession.replaceDocument against the server: others see commits and conflict with it', () async {
      const file = '''
app: {mode: workflow, name: conformance session}
kind: app
version: 0.7.0
workflow:
  graph:
    nodes:
    - {id: start, data: {type: start, title: Begin, variables: []}, position: {x: 0, y: 0}}
    - {id: l1, data: {type: llm, title: Ask, prompt: hello}, position: {x: 300, y: 0}}
    edges:
    - {id: start-l1, source: start, target: l1, sourceHandle: source, targetHandle: target}
''';
      CollabSession open(AuthSession who) => CollabSession(
        transport: HttpTransport(baseUrl: base, docId: doc, auth: who),
        store: MemoryStore(),
      );
      final a = open(owner);
      final b = open(editor);
      await a.start();
      await b.start();
      await Future.wait([a.settled(), b.settled()]);
      final seen = b.lastSeq;
      a.edit(setPrompt('llm', 'before the replacement'));
      final r = await a.replaceDocument((id, cseq) => api.replaceDocument(doc, file, id, cseq: cseq));
      expect(r.status, 'completed');
      expect(a.lastSeq, greaterThanOrEqualTo(r.head));
      expect(a.view.nodes.keys.toSet(), {'start', 'l1'}); // the example's start node is kept (its title rewritten)
      expect(a.machine.nextCseq, r.nextCseq);
      a.edit(const SetField('l1', TitleKey(), VString('Ask again')));
      await a.settled();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(b.view, a.view);
      // A write based on what Bob saw before the replacement, to a register it wrote: a conflict naming Olivia's client.
      final staleStart = b.edit(const SetField('start', TitleKey(), VString('Bob')), base: seen);
      expect(staleStart.refusal, isA<Conflict>().having((c) => c.by, 'by', a.clientId));
      await a.stop();
      await b.stop();
    });

    test('CORS: preflight answered, headers allowed for local origins, none for foreign ones', () async {
      final pre = http.Request('OPTIONS', base.replace(path: '/v1/docs/$doc/ops'))
        ..headers['Origin'] = 'http://localhost:5555'
        ..headers['Access-Control-Request-Method'] = 'POST'
        ..headers['Access-Control-Request-Headers'] = 'content-type, authorization, last-event-id';
      final res = await pre.send();
      expect(res.statusCode, inInclusiveRange(200, 204));
      expect(res.headers['access-control-allow-origin'], 'http://localhost:5555');
      expect(
        res.headers['access-control-allow-headers']!.toLowerCase(),
        allOf(contains('last-event-id'), contains('content-type'), contains('authorization')),
      );
      expect(res.headers['access-control-allow-methods'], allOf(contains('POST'), contains('PUT'), contains('DELETE')));
      final get = http.Request('GET', base.replace(path: '/v1/docs/$doc'))..headers['Origin'] = 'http://localhost:5555';
      expect((await get.send()).headers['access-control-allow-origin'], 'http://localhost:5555');
      final foreign = http.Request('GET', base.replace(path: '/v1/docs/$doc'))
        ..headers['Origin'] = 'http://evil.example';
      expect((await foreign.send()).headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('canvas comments: accounts as authors, replies, idempotent resolve, the comments event (no id)', () async {
      final comments = api.comments(doc); // the owner's
      final edComments = DocsApi(base, auth: editor).comments(doc);
      final me = owner.currentAccount!, ed = editor.currentAccount!;
      final events = <StreamEvent>[];
      final sub = t.openStream(const StreamOpen(lastEventId: 0)).listen((e) => e is PingEvent ? null : events.add(e));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final c = await comments.create(x: 120.5, y: -40, content: 'check', mentions: [ed.id, ed.id, 'not-a-member']);
      expect((c.positionX, c.positionY, c.createdBy, c.createdByName), (120.5, -40.0, me.id, me.name));
      expect(c.mentions, [CommentMention(account: ed.id, name: ed.name)]);
      expect(c.id, hasLength(36));
      await post('cli-a', [(1, 0, setPrompt('llm', 'x'))]);
      final c2 = await edComments.create(x: 0, y: 0, content: 'second');
      expect((await comments.list()).map((x) => x.id), [c2.id, c.id]);
      expect((await comments.mentionUsers()).map((u) => u.id), containsAll([me.id, ed.id]));

      await expectLater(
        edComments.update(c.id, x: 1, y: 1),
        throwsA(isA<TransportException>().having((e) => e.notAuthor, 'not_author', isTrue)),
      );
      await expectLater(edComments.delete(c.id), throwsA(isA<TransportException>()));
      final moved = await comments.update(c.id, x: 300, y: 400);
      expect((moved.positionX, moved.content), (300.0, 'check'));
      await expectLater(
        comments.create(x: 0, y: 0, content: 'x' * 1001),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );
      // A read-only member reads, but does not write.
      final viewerComments = DocsApi(base, auth: viewer).comments(doc);
      expect(await viewerComments.list(), hasLength(2));
      await expectLater(
        viewerComments.reply(c.id, content: 'me too'),
        throwsA(isA<TransportException>().having((e) => e.forbidden, 'forbidden', isTrue)),
      );

      final r = await edComments.reply(c.id, content: 'on it', mentions: [me.id]);
      expect(r.mentions.single.name, me.name);
      await expectLater(
        comments.editReply(c.id, r.id, content: 'mine now'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 403)),
      );
      expect((await edComments.editReply(c.id, r.id, content: 'done')).content, 'done');
      expect((await comments.get(c.id)).replyCount, 1);
      await edComments.deleteReply(c.id, r.id);

      final first = await edComments.resolve(c.id);
      final again = await comments.resolve(c.id);
      expect((first.resolved, again.resolvedBy, again.resolvedAt), (true, ed.id, first.resolvedAt));
      await comments.delete(c.id);
      await expectLater(
        comments.get(c.id),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );

      await Future<void>.delayed(const Duration(milliseconds: 500));
      await sub.cancel();
      final notes = events.whereType<CommentsEvent>().map((e) => '${e.action.name}:${e.comment == c.id ? 1 : 2}');
      expect(notes, [
        'created:1',
        'created:2',
        'updated:1',
        'reply:1',
        'reply:1',
        'reply:1',
        'resolved:1',
        'deleted:1',
      ]);
      // The commit kept seq 1 (comments take no seq) and the stream stayed gapless around the notifications.
      expect(events.whereType<CommitEvent>().map((e) => e.entry.seq), [1]);
      final snap = await api.snapshot(doc);
      expect(snap.seq, 1);
    });

    test('bases may decrease from one op to the next', () async {
      final id = await t.issueClientId();
      await post('cli-other', [(1, 0, const MoveNode('llm', 1, 1))]);
      final r = await post(id, [
        (1, 1, setPrompt('code', 'based on 1')),
        (2, 0, setPrompt('answer', 'based on 0')),
      ]);
      expect(r.results.map((x) => x.runtimeType), [AckResult, AckResult]);
    });

    test(
      '1.2: an accepted equal-value stale write is a pure no-op for conflict tracking (the formal-model trace)',
      () async {
        // c2 writes f := v1 first. c1 then sends f := v1 (equal: accepted, must not take the stamp) and f := v2
        // (still stale: must be refused, naming c2). Both with base 0.
        final c1 = await t.issueClientId();
        final c2 = await t.issueClientId();
        final first = await post(c2, [(1, 0, setPrompt('llm', 'v1'))]);
        expect(first.results.single, isA<AckResult>());
        final r = await post(c1, [(1, 0, setPrompt('llm', 'v1')), (2, 0, setPrompt('llm', 'v2'))]);
        expect(r.results[0], isA<AckResult>(), reason: 'equal value: accepted');
        final reason = (r.results[1] as RejectResult).reason;
        expect(reason, isA<Conflict>().having((c) => c.by, 'by', c2), reason: 'c1 must not be exempted by the no-op');
        final snap = await api.snapshot(doc);
        expect(cfg(snap.doc, 'llm', 'prompt'), 'v1');
        expect(
          snap.doc.fieldStamps['llm']![const ConfigKey(['prompt'])],
          Stamp(1, c2),
          reason: 'stamp is still the first writer\'s',
        );
        expect(snap.doc.touches['llm']!.containsKey(c1), isFalse, reason: 'c1 is not "touched" by the no-op');
        expect(snap.doc.touches['llm']![c2], 1);
        // The same for titles and list items.
        await post(c2, [(2, 2, const SetField('code', TitleKey(), VString('T')))]);
        final t2 = await post(c1, [
          (3, 0, const SetField('code', TitleKey(), VString('T'))),
          (4, 0, const SetField('code', TitleKey(), VString('U'))),
        ]);
        expect(t2.results[0], isA<AckResult>());
        expect((t2.results[1] as RejectResult).reason, isA<Conflict>());
      },
    );

    test('two processes sharing one id: the second moves to a new id and its edit lands exactly once', () async {
      final shared = await t.issueClientId();
      CollabSession open() => CollabSession(
        clientId: shared,
        transport: HttpTransport(baseUrl: base, docId: doc, auth: owner),
        store: MemoryStore(),
      );
      final a = open();
      final b = open();
      await a.start();
      await b.start();
      await Future.wait([a.settled(), b.settled()]);
      final bEvents = <ClientEvent>[];
      b.events.listen(bEvents.add);
      a.edit(setPrompt('llm', 'from a'));
      await a.settled();
      b.edit(setPrompt('code', 'from b')); // (shared, 1) already holds a's op
      await b.settled().timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(bEvents.whereType<ClientIdReplaced>(), hasLength(1));
      expect(b.clientId, isNot(shared));
      expect(bEvents.whereType<OpRejected>(), isEmpty);
      final snap = await api.snapshot(doc);
      expect(cfg(snap.doc, 'llm', 'prompt'), 'from a');
      expect(cfg(snap.doc, 'code', 'prompt'), 'from b');
      expect(a.view, snap.doc);
      expect(b.view, snap.doc);
      await a.stop();
      await b.stop();
    });
  });

  group('the event stream', () {
    Future<List<StreamEvent>> read(
      StreamOpen open, {
      int? until,
      Duration timeout = const Duration(seconds: 10),
    }) async {
      final out = <StreamEvent>[];
      await for (final e in t.openStream(open).timeout(timeout)) {
        if (e is PingEvent) continue;
        out.add(e);
        if (e is ReadyEvent) break;
      }
      return out;
    }

    test('no Last-Event-ID: snapshot then ready', () async {
      await post('cli-a', [(1, 0, setPrompt('llm', 'x'))]);
      final events = await read(const StreamOpen());
      expect(events.first, isA<SnapshotEvent>().having((s) => s.seq, 'seq', 1));
      expect(events.last, isA<ReadyEvent>().having((r) => r.head, 'head', 1));
    });

    test('resume replays exactly the missing commits; a snapshot carries our committed cseqs', () async {
      for (var i = 1; i <= 5; i++) {
        await post('cli-a', [(i, 0, MoveNode('llm', i, i))]);
      }
      final replay = await read(const StreamOpen(lastEventId: 2));
      expect(replay.whereType<CommitEvent>().map((c) => c.entry.seq), [3, 4, 5]);
      expect(replay.whereType<CommitEvent>().map((c) => c.entry.client).toSet(), {'cli-a'});
      expect(replay.last, isA<ReadyEvent>());
      final snap = await read(const StreamOpen(client: 'cli-a', from: 3));
      expect((snap.first as SnapshotEvent).committed, {3: 3, 4: 4, 5: 5});
      final upToDate = await read(const StreamOpen(lastEventId: 5));
      expect(upToDate, hasLength(1), reason: 'only ready');
    });

    test('Last-Event-ID beyond the head (server lost data) yields a snapshot', () async {
      final events = await read(const StreamOpen(lastEventId: 500));
      expect(events.first, isA<SnapshotEvent>().having((s) => s.seq, 'seq', 0));
    });

    test('live commits arrive in order after ready, and keep-alive pings come within ~12 s', () async {
      final events = <StreamEvent>[];
      var pinged = false;
      final sub = t.openStream(const StreamOpen()).listen((e) {
        if (e is PingEvent) {
          pinged = true;
        } else {
          events.add(e);
        }
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      for (var i = 1; i <= 3; i++) {
        await post('cli-a', [(i, 0, MoveNode('llm', i, i))]);
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(events.whereType<CommitEvent>().map((c) => c.entry.seq), [1, 2, 3]);
      expect(events.indexWhere((e) => e is ReadyEvent), lessThan(events.indexWhere((e) => e is CommitEvent)));
      await Future<void>.delayed(const Duration(seconds: 11));
      await sub.cancel();
      expect(pinged, isTrue, reason: 'the server sends bytes at least every ~10 s');
    });
  });

  group('model providers (1.9)', () {
    late HttpServer stub;
    setUpAll(() async {
      stub = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      stub.listen((req) async {
        final key =
            req.headers.value('x-api-key') ??
            (req.headers.value('authorization')?.startsWith('Bearer ') == true
                ? req.headers.value('authorization')!.substring(7)
                : null);
        await req.drain<void>();
        final path = req.uri.path;
        final ok = key != null && key.startsWith('sk-good');
        req.response.headers.contentType = ContentType.json;
        if (path == '/oaic/models') {
          req.response.statusCode = 404;
          req.response.write('{"detail":"Not Found"}');
        } else if (path == '/v1/models' || path == '/oaic/chat/completions') {
          req.response.statusCode = ok ? 200 : 401;
          req.response.write(ok ? '{"data":[]}' : '{"error":{"message":"Incorrect API key provided"}}');
        } else {
          req.response.statusCode = 404;
        }
        await req.response.close();
      });
    });
    tearDownAll(() => stub.close(force: true));

    test('the editor\'s and the settings page\'s calls against the server', () async {
      final host = Platform.environment['DIFYSF_STUB_HOST'] ?? '127.0.0.1';
      final ownerApi = HttpModelProvidersApi(base, auth: owner);
      final viewerApi = HttpModelProvidersApi(base, auth: viewer);
      try {
        await modelProvidersScenario(
          ownerApi,
          viewerApi,
          unique: _docId(),
          stubBase: 'http://$host:${stub.port}',
          validates: Platform.environment['DIFYSF_MODELS_VALIDATE'] != 'false',
        );
      } finally {
        ownerApi.close();
        viewerApi.close();
      }
    });
  });

  group('apps (1.10)', () {
    String unique() => 'apps-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

    test('the Studio page\'s calls against the server', () async {
      final o = HttpAppsApi(base, auth: owner),
          e = HttpAppsApi(base, auth: editor),
          v = HttpAppsApi(base, auth: viewer);
      try {
        await appsScenario(
          owner: o,
          editor: e,
          viewer: v,
          ownerName: owner.currentAccount!.name,
          editorId: editor.currentAccount!.id,
          unique: unique(),
          commitEdit: (id) async {
            final edit = HttpTransport(baseUrl: base, docId: id, auth: owner);
            try {
              final client = await edit.issueClientId();
              final r = await edit.submit(
                SubmitRequest(
                  client: client,
                  ops: [
                    const OutgoingOp(cseq: 1, base: 0, op: SetField('start', ConfigKey(['desc']), VString('edited'))),
                  ],
                ),
                timeout: const Duration(seconds: 10),
              );
              expect(r.results.single, isA<AckResult>());
            } finally {
              edit.close();
            }
          },
        );
      } finally {
        o.close();
        e.close();
        v.close();
      }
    });

    test('deleting an app ends its streams and its document answers 404 app_deleted', () async {
      final apps = HttpAppsApi(base, auth: owner);
      final docs = DocsApi(base, auth: owner);
      final app = await apps.create(name: '${unique()} doomed', mode: AppModes.advancedChat);
      final stream = HttpTransport(baseUrl: base, docId: app.id, auth: owner);
      try {
        final ready = Completer<void>(), ended = Completer<void>();
        stream
            .openStream(const StreamOpen())
            .listen(
              (ev) {
                if (ev is ReadyEvent && !ready.isCompleted) ready.complete();
              },
              onError: (Object _) {},
              onDone: ended.complete,
            );
        await ready.future.timeout(const Duration(seconds: 10));
        expect((await docs.snapshot(app.id)).doc.nodes.keys.toSet(), {'start', 'llm', 'answer'});
        await apps.delete(app.id);
        await ended.future.timeout(const Duration(seconds: 10));
        final gone = throwsA(isA<TransportException>().having((x) => x.appDeleted, 'appDeleted', isTrue));
        await expectLater(docs.snapshot(app.id), gone);
        await expectLater(docs.meta(app.id), gone);
        await expectLater(docs.issueClientId(app.id), gone);
        await expectLater(apps.get(app.id), gone);
      } finally {
        stream.close();
        apps.close();
        docs.close();
      }
    });
  });

  group('the client against the server', () {
    test('two sessions converge and a conflict is reported with the winner', () async {
      CollabSession open(String id) => CollabSession(
        clientId: id,
        transport: HttpTransport(baseUrl: base, docId: doc, auth: owner),
        store: MemoryStore(),
      );
      final a = open('cli-s1');
      final b = open('cli-s2');
      await a.start();
      await b.start();
      await Future.wait([a.settled(), b.settled()]);
      final events = <ClientEvent>[];
      b.events.listen(events.add);
      final startedAt = b.lastSeq;
      a.edit(setPrompt('llm', 'from a'));
      await a.settled();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(cfg(b.view, 'llm', 'prompt'), 'from a');
      final t2 = b.edit(setPrompt('llm', 'from b'), base: startedAt);
      expect(t2.refusal, isA<Conflict>());
      b.edit(setPrompt('llm', 'from b again'));
      await b.settled();
      expect(cfg(a.view, 'llm', 'prompt'), anyOf('from a', 'from b again'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(a.view, b.view);
      expect(a.view, (await api.snapshot(doc)).doc);
      await a.stop();
      await b.stop();
    });

    test('a short storm with crashes holds every guarantee', () async {
      final report = await StormRunner(
        StormConfig(
          url: base,
          doc: doc,
          clients: 6,
          duration: const Duration(seconds: 6),
          ratePerClient: 8,
          seed: 42,
          crashesPerClientPerMinute: 10,
          auth: owner,
        ),
      ).run();
      expect(report.violations, isEmpty);
      expect(report.counts['pending'], isNull);
      expect(report.counts['committed'], greaterThan(50));
    });
  });
}
