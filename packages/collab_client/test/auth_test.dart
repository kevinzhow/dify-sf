/// Accounts (protocol 1.8): AuthSession (sign-in, restore, refresh once on 401, sign-out), the token stores, and the
/// transports' bearer tokens against the in-memory accounts server (FakeAccounts) and the HTTP fake server with accounts.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/helpers.dart';

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 40, reconnectMax: 300, retransmitAfter: 3000);

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Matcher _status(int status, [String? code]) => isA<TransportException>()
    .having((e) => e.statusCode, 'status', status)
    .having((e) => code == null || e.code == code, 'code $code', isTrue);

void main() {
  group('AuthSession on FakeAccounts', () {
    late FakeAccounts accounts;
    late MemoryTokenStore store;
    AuthSession session() => AuthSession(api: FakeAuthApi(accounts), store: store, server: 'srv');
    setUp(() {
      accounts = FakeAccounts();
      store = MemoryTokenStore();
    });

    test('install, sign-in, restore, logout', () async {
      final auth = session();
      expect(await auth.api.setupStatus(), SetupStatus.notStarted);
      expect(await auth.restore(), isFalse);
      final owner = await auth.setup(email: 'Olivia@example.com', name: 'Olivia', password: 'owner-pass-1');
      expect((owner.role, owner.canEdit, owner.isPrivileged), (AccountRole.owner, true, true));
      expect(await auth.api.setupStatus(), SetupStatus.finished);
      await expectLater(
        auth.api.setup(email: 'x@example.com', name: 'X', password: 'x-pass-123'),
        throwsA(_status(409, 'setup_done')),
      );
      expect(store.tokens['srv'], auth.tokens);

      // A restart: the saved tokens sign in again.
      final again = session();
      expect(await again.restore(), isTrue);
      expect(again.currentAccount?.email, 'Olivia@example.com');

      // Another sign-in (another device) is a separate session: a logout ends only its own.
      final device = AuthSession(api: FakeAuthApi(accounts), store: MemoryTokenStore());
      await device.login(email: 'olivia@example.com', password: 'owner-pass-1');
      await again.logout();
      expect((again.isSignedIn, store.tokens['srv']), (false, null));
      expect(await session().restore(), isFalse);
      await expectLater(auth.account(), throwsA(_status(401))); // same session as `again`
      expect((await device.account()).name, 'Olivia');
    });

    test('wrong password and unknown email are one answer; Dify\'s rate limit locks the email', () async {
      accounts.addMember(email: 'o@example.com', password: 'owner-pass-1');
      final auth = session();
      Future<TransportException> attempt(String email, String pw) async {
        try {
          await auth.login(email: email, password: pw);
        } on TransportException catch (e) {
          return e;
        }
        fail('signed in');
      }

      final wrong = await attempt('o@example.com', 'nope-pass-1');
      final unknown = await attempt('nobody@example.com', 'nope-pass-1');
      expect((wrong.statusCode, wrong.code, wrong.message), (unknown.statusCode, unknown.code, unknown.message));
      expect(wrong.code, 'invalid_credentials');
      for (var i = 0; i < 5; i++) {
        await attempt('o@example.com', 'nope-pass-1');
      }
      expect((await attempt('o@example.com', 'owner-pass-1')).code, 'login_rate_limited');
    });

    test('a 401 refreshes once (one refresh for many callers) and repeats the call', () async {
      accounts.addMember(email: 'o@example.com', password: 'owner-pass-1');
      final auth = session();
      await auth.login(email: 'o@example.com', password: 'owner-pass-1');
      final before = auth.tokens!;
      accounts.expireAccessTokens();
      final results = await Future.wait([auth.account(), auth.members(), auth.account()]);
      expect(results, hasLength(3));
      expect(accounts.refreshes, 1);
      expect(auth.tokens, isNot(before));
      expect(store.tokens['srv'], auth.tokens);
      // Rotation: the old refresh token is spent.
      await expectLater(auth.api.refresh(before.refreshToken), throwsA(_status(401, 'unauthorized')));
    });

    test('a refused refresh signs out', () async {
      accounts.addMember(email: 'o@example.com', password: 'owner-pass-1');
      final auth = session();
      await auth.login(email: 'o@example.com', password: 'owner-pass-1');
      final signedOut = auth.signedOut.first;
      accounts.revokeAll();
      await expectLater(auth.account(), throwsA(_status(401)));
      await signedOut.timeout(const Duration(seconds: 2));
      expect((auth.isSignedIn, auth.currentAccount, store.tokens['srv']), (false, null, null));
    });

    test('an unreachable server keeps the session', () async {
      accounts.addMember(email: 'o@example.com', password: 'owner-pass-1');
      final net = FakeNetwork();
      final auth = AuthSession(
        api: FakeAuthApi(accounts, network: net),
        store: store,
        server: 'srv',
      );
      await auth.login(email: 'o@example.com', password: 'owner-pass-1');
      accounts.expireAccessTokens();
      net.refused = true;
      await expectLater(auth.account(), throwsA(isA<TransportException>()));
      expect(auth.isSignedIn, isTrue);
      expect(
        await AuthSession(
          api: FakeAuthApi(accounts, network: net),
          store: store,
          server: 'srv',
        ).restore(),
        isTrue,
      );
    });

    test('members, invitations, roles, activation', () async {
      final auth = session();
      await auth.setup(email: 'o@example.com', name: 'Olivia', password: 'owner-pass-1');
      final results = await auth.invite(emails: ['bo@example.com', 'bad', 'o@example.com'], role: AccountRole.editor);
      expect(results.map((r) => r.status), ['success', 'failed', 'already_member']);
      final token = results.first.token!;
      expect(results.first.url, startsWith('/activate?email=bo%40example.com&token='));
      final check = await auth.api.checkInvitation(token);
      expect(
        (check.isValid, check.email, check.workspaceName, check.needsSetup),
        (
          true,
          'bo@example.com',
          "Olivia's Workspace",
          true,
        ),
      );
      expect((await auth.members()).map((m) => (m.email, m.role, m.status)), [
        ('o@example.com', 'owner', 'active'),
        ('bo@example.com', 'editor', 'pending'),
      ]);
      final bo = AuthSession(api: FakeAuthApi(accounts), store: MemoryTokenStore());
      await expectLater(
        bo.activate(token: token, name: 'Bo', password: 'weak'),
        throwsA(_status(400, 'invalid_password')),
      );
      final account = await bo.activate(token: token, name: 'Bo', password: 'bo-pass-123');
      expect((account.name, account.role), ('Bo', 'editor'));
      expect((await auth.api.checkInvitation(token)).isValid, isFalse);
      await expectLater(bo.invite(emails: ['z@example.com'], role: 'normal'), throwsA(_status(403, 'forbidden')));
      final owner = (await auth.members()).first;
      await expectLater(auth.removeMember(owner.id), throwsA(_status(400, 'cannot_operate_self')));
      await expectLater(auth.updateRole(account.id, AccountRole.owner), throwsA(_status(400, 'invalid_role')));
      await auth.updateRole(account.id, AccountRole.normal);
      expect((await bo.account()).canEdit, isFalse);
      await auth.removeMember(account.id);
      await expectLater(bo.account(), throwsA(_status(401)));
    });
  });

  group('token stores', () {
    test('a file per server, owner-only, cleared at sign-out', () async {
      final dir = await Directory.systemTemp.createTemp('tokens');
      addTearDown(() => dir.delete(recursive: true));
      final store = TokenStore.platform(directory: dir.path);
      const t = AuthTokens(accessToken: 'a1', refreshToken: 'r1');
      expect(await store.read('http://127.0.0.1:8080'), isNull);
      await store.write('http://127.0.0.1:8080', t);
      await store.write('http://other:1', const AuthTokens(accessToken: 'a2', refreshToken: 'r2'));
      expect(await store.read('http://127.0.0.1:8080'), t);
      final files = dir.listSync().whereType<File>().toList();
      expect(files, hasLength(2));
      if (Platform.isLinux || Platform.isMacOS) {
        for (final f in files) {
          expect(f.statSync().mode & 0x1ff, 0x180, reason: '0600'); // rw-------
        }
      }
      await store.clear('http://127.0.0.1:8080');
      expect(await store.read('http://127.0.0.1:8080'), isNull);
      expect((await store.read('http://other:1'))?.accessToken, 'a2');
    });
  });

  group('transports with accounts (HTTP fake server)', () {
    late HttpFakeServer srv;
    late FakeAccounts accounts;
    final sessions = <CollabSession>[];

    setUp(() async {
      accounts = FakeAccounts();
      srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300), accounts: accounts);
      srv.doc('d', template: 'empty');
      srv.doc('d').doc.apply(AddNode(node('a')), const Stamp(0, 'genesis'));
    });
    tearDown(() async {
      for (final s in sessions) {
        await s.stop();
      }
      sessions.clear();
      await srv.close();
    });

    Future<AuthSession> signIn(String email, {String role = AccountRole.editor, String name = 'User'}) async {
      if (accounts.byEmail(email) == null) accounts.addMember(email: email, name: name, role: role);
      final auth = AuthSession(api: HttpAuthApi(srv.url), store: MemoryTokenStore(), server: '${srv.url}');
      await auth.login(email: email, password: 'password-1');
      return auth;
    }

    Future<CollabSession> connect(AuthSession auth, {String? clientId}) async {
      final s = CollabSession(
        clientId: clientId,
        transport: HttpTransport(baseUrl: srv.url, docId: 'd', auth: auth),
        journaled: false,
        config: _fast,
        tickInterval: const Duration(milliseconds: 25),
        postTimeout: const Duration(milliseconds: 500),
      );
      sessions.add(s);
      await s.start();
      await s.settled().timeout(const Duration(seconds: 10));
      return s;
    }

    test('every request needs the bearer token; the session syncs with it', () async {
      final anonymous = DocsApi(srv.url);
      addTearDown(anonymous.close);
      await expectLater(anonymous.snapshot('d'), throwsA(_status(401, 'unauthorized')));
      await expectLater(anonymous.issueClientId('d'), throwsA(_status(401)));
      final res = await http.get(srv.url.replace(path: '/v1/docs/d/events'));
      expect(res.statusCode, 401);

      final olivia = await signIn('o@example.com', role: AccountRole.owner, name: 'Olivia');
      final s = await connect(olivia);
      expect(s.clientId, startsWith('s-'));
      s.edit(setPrompt('a', 'hello'));
      await s.settled();
      expect(srv.doc('d').head, 1);
      final docs = DocsApi(srv.url, auth: olivia);
      addTearDown(docs.close);
      expect((await docs.snapshot('d')).seq, 1);
      expect(await docs.clientDirectory('d'), {
        s.clientId: ClientIdentity(account: olivia.currentAccount!.id, name: 'Olivia'),
      });
      expect(await docs.clientNames('d'), {s.clientId: 'Olivia'});
    });

    test('an expired access token is refreshed once and the POST repeated (body intact)', () async {
      final olivia = await signIn('o@example.com', role: AccountRole.owner);
      final s = await connect(olivia);
      accounts.expireAccessTokens();
      s.edit(setPrompt('a', 'after expiry'));
      await s.settled().timeout(const Duration(seconds: 10));
      expect(srv.doc('d').doc.nodes['a']!.config['prompt'], const VString('after expiry'));
      expect(accounts.refreshes, 1);
      expect(olivia.isSignedIn, isTrue);
    });

    test('the stream takes ?access_token= too', () async {
      final olivia = await signIn('o@example.com', role: AccountRole.owner);
      final t = HttpTransport(baseUrl: srv.url, docId: 'd', auth: olivia, accessTokenInQuery: true);
      addTearDown(t.close);
      final first = await t
          .openStream(const StreamOpen(client: null, lastEventId: null, from: null))
          .firstWhere(
            (e) => e is ReadyEvent,
          );
      expect(first, isA<ReadyEvent>());
      final raw = await http.Client().send(
        http.Request(
          'GET',
          srv.url.replace(path: '/v1/docs/d/events', queryParameters: {'access_token': olivia.accessToken}),
        ),
      );
      expect(raw.statusCode, 200);
      srv.dropStreams();
    });

    test('read-only roles cannot post ops; another account\'s client id is refused', () async {
      final normal = await signIn('n@example.com', role: AccountRole.normal);
      final t = HttpTransport(baseUrl: srv.url, docId: 'd', auth: normal);
      addTearDown(t.close);
      final viewer = await connect(normal); // reads and streams work
      expect(viewer.hasState, isTrue);
      final refused = t.submit(
        SubmitRequest(
          client: viewer.clientId,
          ops: [OutgoingOp(cseq: 1, base: 0, op: setPrompt('a', 'no'))],
        ),
        timeout: const Duration(seconds: 2),
      );
      await expectLater(refused, throwsA(isA<TransportException>().having((e) => e.forbidden, 'forbidden', isTrue)));

      final ed = await signIn('ed@example.com');
      final edSession = await connect(ed);
      final other = await signIn('other@example.com');
      final t2 = HttpTransport(baseUrl: srv.url, docId: 'd', auth: other);
      addTearDown(t2.close);
      await expectLater(
        t2.submit(
          SubmitRequest(
            client: edSession.clientId,
            ops: [OutgoingOp(cseq: 1, base: 0, op: setPrompt('a', 'x'))],
          ),
          timeout: const Duration(seconds: 2),
        ),
        throwsA(_status(403, 'forbidden')),
      );
      expect(srv.doc('d').head, 0);
    });

    test('comments belong to the account, from any of its clients; mentions are members', () async {
      final laptop = await signIn('o@example.com', role: AccountRole.owner, name: 'Olivia');
      final phone = await signIn('o@example.com');
      final bo = await signIn('bo@example.com', name: 'Bo');
      final a = await connect(laptop);
      final b = await connect(phone);
      expect(a.clientId, isNot(b.clientId));
      final boId = bo.currentAccount!.id;
      final c = await a.transport.comments.create(x: 1, y: 2, content: 'from the laptop', mentions: [boId, 'nobody']);
      expect((c.createdBy, c.createdByName), (laptop.currentAccount!.id, 'Olivia'));
      expect(c.mentions, [CommentMention(account: boId, name: 'Bo')]);
      final edited = await b.transport.comments.update(c.id, content: 'edited on the phone');
      expect(edited.content, 'edited on the phone');
      final boApi = DocsApi(srv.url, auth: bo).comments('d');
      await expectLater(boApi.update(c.id, content: 'mine?'), throwsA(_status(403, 'not_author')));
      expect((await boApi.mentionUsers()).map((u) => u.name).toSet(), {'Olivia', 'Bo'});
      final dir = await a.transport.comments.clientDirectory();
      expect(dir[a.clientId], dir[b.clientId]);
      // A read-only member reads but does not write comments.
      final viewer = await signIn('v@example.com', role: AccountRole.normal);
      final viewerApi = DocsApi(srv.url, auth: viewer).comments('d');
      expect(await viewerApi.list(), hasLength(1));
      await expectLater(viewerApi.create(x: 0, y: 0, content: 'hi'), throwsA(_status(403, 'forbidden')));
    });

    test('accounts over HTTP: invite, activate, sign in with the new password', () async {
      final api = HttpAuthApi(srv.url);
      addTearDown(api.close);
      expect(await api.setupStatus(), SetupStatus.notStarted);
      final owner = AuthSession(api: api);
      await owner.setup(email: 'o@example.com', name: 'Olivia', password: 'owner-pass-1');
      final link = (await owner.invite(emails: ['cy@example.com'], role: AccountRole.normal)).single;
      final check = await api.checkInvitation(link.token!);
      expect((check.isValid, check.email), (true, 'cy@example.com'));
      final cy = AuthSession(api: api);
      expect((await cy.activate(token: link.token!, name: 'Cy', password: 'cy-pass-123')).role, AccountRole.normal);
      await cy.logout();
      expect((await cy.login(email: 'cy@example.com', password: 'cy-pass-123')).name, 'Cy');
      await cy.updatePassword(password: 'cy-pass-123', newPassword: 'cy-pass-456', repeatNewPassword: 'cy-pass-456');
      expect((await cy.updateName('Cyrus')).name, 'Cyrus');
      await expectLater(
        api.login(email: 'cy@example.com', password: 'cy-pass-123'),
        throwsA(_status(401, 'invalid_credentials')),
      );
    });
  });

  group('in-memory transport with accounts', () {
    test('sessions sign in, read-only members only read, byName is the account name', () async {
      final accounts = FakeAccounts();
      final server = FakeServer(initial: baseDoc(), accounts: accounts);
      accounts
        ..addMember(email: 'o@example.com', name: 'Olivia', role: AccountRole.owner)
        ..addMember(email: 'n@example.com', name: 'Nora', role: AccountRole.normal);
      Future<AuthSession> auth(String email) async {
        final a = AuthSession(api: FakeAuthApi(accounts));
        await a.login(email: email, password: 'password-1');
        return a;
      }

      final olivia = await auth('o@example.com');
      final nora = await auth('n@example.com');
      CollabSession open(AuthSession a) => CollabSession(
        transport: FakeTransport(
          server,
          network: FakeNetwork(random: Random(3)),
          auth: a,
        ),
        journaled: false,
      );
      final o = open(olivia), n = open(nora);
      await o.start();
      await n.start();
      await o.settled();
      o.edit(setPrompt('a', 'by olivia'));
      await o.settled();
      expect(server.head, 1);
      await until(() => n.lastSeq == 1, what: 'nora sees it');
      // Nora's write is refused (403): final, not retried; nothing reaches the log and the edit comes back rejected.
      final refusal = n.events.firstWhere((e) => e is OpRejected);
      n.edit(setPrompt('b', 'by nora'));
      expect((await refusal as OpRejected).reason, const Forbidden());
      expect(server.head, 1);
      expect(n.status.lastError, contains('403'));
      expect(n.editsForbidden, isTrue);
      // The directory names accounts; a stale write's conflict notice carries the account name.
      expect(server.directory()[o.clientId], {'account': olivia.currentAccount!.id, 'name': 'Olivia'});
      expect(server.nameOf(o.clientId), 'Olivia');
      // An expired token is refreshed by the transport.
      accounts.expireAccessTokens();
      o.edit(setPrompt('a', 'again'));
      await o.settled();
      expect(server.head, 2);
      // Without a token: 401.
      final anonymous = FakeTransport(server);
      await expectLater(anonymous.issueClientId(), throwsA(_status(401)));
      await o.stop();
      await n.stop();
    });
  });
}
