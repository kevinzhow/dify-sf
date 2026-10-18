/// Canvas comments (docs/protocol.md, "Comments"): the model, the `comments` stream event (no id, ignored by the
/// document machine), the in-memory rules, the HTTP API against the HTTP fake server, and the session's surfacing.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 10), String? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 40, reconnectMax: 300, retransmitAfter: 3000);

void main() {
  group('model', () {
    test('parses the server shape (and Dify epoch seconds)', () {
      final c = Comment.fromJson({
        'id': 'c1',
        'position_x': 412.5,
        'position_y': 180,
        'content': 'gpt-4o?',
        'created_by': 's-a',
        'created_by_name': 'Alice',
        'created_at': '2026-10-18T09:12:03.512Z',
        'updated_at': '2026-10-18T09:12:03.512Z',
        'resolved': true,
        'resolved_by': 's-b',
        'resolved_at': 1700000000,
        'mentions': [
          {'client': 's-b', 'name': 'Bo'},
          {'client': 's-x'},
        ],
        'replies': [
          {
            'id': 'r1',
            'content': 'yes',
            'created_by': 's-b',
            'created_at': '2026-10-18T09:13:00.000Z',
            'updated_at': '2026-10-18T09:13:00.000Z',
            'mentions': <Object?>[],
          },
        ],
        'reply_count': 1,
      });
      expect(c.positionY, 180.0);
      expect(c.createdAt, DateTime.utc(2026, 10, 18, 9, 12, 3, 512));
      expect(c.resolvedAt, DateTime.utc(2023, 11, 14, 22, 13, 20));
      // 1.3-era mentions (`client`) still parse; since 1.8 they are accounts.
      expect(c.mentions, const [CommentMention(account: 's-b', name: 'Bo'), CommentMention(account: 's-x')]);
      expect(c.replies.single.createdByName, isNull);
      expect(c.replyCount, 1);
      expect(Comment.fromJson(c.toJson()).toJson(), c.toJson());
      expect(() => Comment.fromJson({'id': 'x'}), throwsFormatException);
    });

    test('content rule is Dify\'s', () {
      expect(commentContentProblem('ok'), isNull);
      expect(commentContentProblem('  \n'), isNotNull);
      expect(commentContentProblem('字' * 1000), isNull);
      expect(commentContentProblem('a' * 1001), isNotNull);
    });
  });

  group('stream event', () {
    test('event: comments parses, has no id, and unknown actions are tolerated', () {
      final p = SseParser();
      final msgs = p.add(
        'id: 4\nevent: commit\ndata: {"seq":4,"client":"c","cseq":1,"base":3,"op":{"t":"removeEdge","edge":"e"}}\n\n'
        'event: comments\ndata: {"action":"created","comment":"c1"}\n\n'
        'event: comments\ndata: {"action":"teleported","comment":"c2"}\n\n',
      );
      expect(msgs, hasLength(3));
      expect(
        StreamEvent.parse(msgs[1].event, msgs[1].data),
        const CommentsEvent(comment: 'c1', action: CommentsAction.created),
      );
      expect((StreamEvent.parse(msgs[2].event, msgs[2].data)! as CommentsEvent).action, CommentsAction.unknown);
      expect(
        StreamEvent.parse('comments', '{"action":"resync","comment":"x"}'),
        isA<CommentsEvent>().having((e) => e.action, 'action', CommentsAction.unknown),
      );
      expect(() => StreamEvent.parse('comments', '{"action":"created"}'), throwsFormatException);
    });

    test('the machine treats it as liveness only: no state change, no resume point', () {
      final m = ClientMachine(id: 'c', journaled: false);
      m.tick(0);
      final gen = m.generation;
      m.receiveStream(SnapshotEvent(seq: 3, doc: baseDoc()), gen, 1);
      m.receiveStream(const ReadyEvent(3), gen, 2);
      final out = m.receiveStream(const CommentsEvent(comment: 'c1', action: CommentsAction.created), gen, 3);
      expect(out, isEmpty);
      expect(m.lastSeq, 3);
      expect(m.streamReady, isTrue);
    });
  });

  group('in-memory rules (FakeCommentsApi)', () {
    late FakeServer server;
    late FakeCommentsApi api;
    final events = <CommentsEvent>[];
    setUp(() {
      server = FakeServer(initial: baseDoc());
      server.setClientName('alice', 'Alice');
      api = FakeCommentsApi(server);
      events.clear();
      server.comments.addListener(events.add);
    });

    test('author-only edits, anyone resolves (idempotent) and replies, newest first', () async {
      final c1 = await api.create(author: 'alice', x: 1.5, y: 2, content: 'one', mentions: ['bob', 'bob', 'bad id']);
      expect(c1.createdByName, 'Alice');
      expect(c1.mentions.map((m) => m.client), ['bob']);
      final c2 = await api.create(author: 'bob', x: 0, y: 0, content: 'two');
      expect((await api.list()).map((c) => c.id), [c2.id, c1.id]);

      await expectLater(
        api.update(c1.id, author: 'bob', content: 'hijack'),
        throwsA(isA<TransportException>().having((e) => e.notAuthor, 'notAuthor', isTrue)),
      );
      await expectLater(api.update(c1.id, author: 'bob', x: 9, y: 9), throwsA(isA<TransportException>()));
      await expectLater(api.delete(c1.id, author: 'bob'), throwsA(isA<TransportException>()));
      final moved = await api.update(c1.id, author: 'alice', x: 10, y: 20);
      expect((moved.positionX, moved.positionY, moved.content, moved.mentions.length), (10.0, 20.0, 'one', 1));
      expect((await api.update(c1.id, author: 'alice', content: 'uno', mentions: const [])).mentions, isEmpty);
      await expectLater(
        api.create(author: 'alice', x: 0, y: 0, content: '   '),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );

      final r = await api.reply(c1.id, author: 'bob', content: 'on it', mentions: ['alice']);
      expect(r.mentions.single.name, 'Alice');
      await expectLater(api.editReply(c1.id, r.id, author: 'alice', content: 'x'), throwsA(isA<TransportException>()));
      expect((await api.editReply(c1.id, r.id, author: 'bob', content: 'done')).mentions, isEmpty);
      expect((await api.get(c1.id)).replyCount, 1);
      await api.deleteReply(c1.id, r.id, author: 'bob');
      await expectLater(
        api.deleteReply(c1.id, r.id, author: 'bob'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );

      final res1 = await api.resolve(c1.id, author: 'bob');
      final res2 = await api.resolve(c1.id, author: 'alice');
      expect((res1.resolved, res1.resolvedBy, res2.resolvedBy, res2.resolvedAt), (true, 'bob', 'bob', res1.resolvedAt));
      await api.delete(c1.id, author: 'alice');
      expect((await api.list()).map((c) => c.id), [c2.id]);

      expect(events.map((e) => '${e.action.name}:${e.comment == c1.id ? 1 : 2}'), [
        'created:1',
        'created:2',
        'updated:1',
        'updated:1',
        'reply:1',
        'reply:1',
        'reply:1',
        'resolved:1',
        'deleted:1',
      ]);
      expect(server.head, 0); // comments are not in the document's log
    });

    test('an unreachable server fails like a connect error', () async {
      api.network.refused = true;
      await expectLater(api.list(), throwsA(isA<TransportException>()));
    });
  });

  group('over HTTP (HttpCommentsApi + HttpTransport against the HTTP fake server)', () {
    late HttpFakeServer srv;
    final sessions = <CollabSession>[];
    setUp(() async {
      srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300));
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

    Future<CollabSession> connect(String id) async {
      final s = CollabSession(
        clientId: id,
        transport: HttpTransport(baseUrl: srv.url, docId: 'd'),
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

    test('CRUD, 204s and error codes over the wire', () async {
      final docs = DocsApi(srv.url);
      addTearDown(docs.close);
      final api = docs.comments('d');
      final c = await api.create(author: 'alice', x: 3.25, y: -1, content: 'hi');
      expect((await api.get(c.id)).positionX, 3.25);
      await expectLater(
        api.update(c.id, author: 'bob', content: 'no'),
        throwsA(isA<TransportException>().having((e) => (e.statusCode, e.code), 'error', (403, 'not_author'))),
      );
      final r = await api.reply(c.id, author: 'bob', content: 'yo');
      await api.deleteReply(c.id, r.id, author: 'bob');
      expect((await api.resolve(c.id, author: 'bob')).resolvedBy, 'bob');
      await api.delete(c.id, author: 'alice');
      expect(await api.list(), isEmpty);
      await expectLater(api.get(c.id), throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)));
      await expectLater(
        docs.comments('nope').list(),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
    });

    test('the session surfaces comments events and a resync per (re)connect; the resume point is unaffected', () async {
      final a = await connect('alice');
      final b = await connect('bob');
      final seen = <CommentsEvent>[];
      final sub = b.comments.listen(seen.add);
      addTearDown(sub.cancel);

      final c = await a.transport.comments.create(author: a.clientId, x: 1, y: 2, content: 'look');
      await until(
        () => seen.contains(CommentsEvent(comment: c.id, action: CommentsAction.created)),
        what: 'event',
      );
      expect((await b.transport.comments.list()).single.content, 'look');

      a.edit(setPrompt('a', 'x'));
      await a.settled();
      await until(() => b.lastSeq == 1, what: 'commit');
      srv.dropStreams();
      await until(() => seen.where((e) => e.action == CommentsAction.resync).isNotEmpty, what: 'resync');
      // The comments frame had no id: the reconnect resumed from the commit's seq.
      expect(srv.streamResumePoints.last, 1);
    });
  });

  group('session on the in-memory transport', () {
    test('two sessions see each other\'s comment notifications', () async {
      final server = FakeServer(initial: baseDoc());
      CollabSession open(String id) => CollabSession(
        clientId: id,
        transport: FakeTransport(server, network: FakeNetwork(random: Random(3))),
        journaled: false,
      );
      final a = open('alice'), b = open('bob');
      final seenA = <CommentsEvent>[], seenB = <CommentsEvent>[];
      a.comments.listen(seenA.add);
      b.comments.listen(seenB.add);
      await a.start();
      await b.start();
      await until(() => seenA.isNotEmpty && seenB.isNotEmpty, what: 'resync');
      expect(seenA.first.action, CommentsAction.resync);
      final c = await b.transport.comments.create(author: 'bob', x: 0, y: 0, content: 'hey');
      await until(() => seenA.length >= 2 && seenB.length >= 2, what: 'created');
      final r = await a.transport.comments.reply(c.id, author: 'alice', content: 'hi');
      expect(r.createdBy, 'alice');
      await until(() => seenA.length >= 3 && seenB.length >= 3, what: 'events');
      expect(seenA.skip(1).map((e) => e.action), [CommentsAction.created, CommentsAction.reply]);
      expect(seenB.skip(1).map((e) => e.action), [CommentsAction.created, CommentsAction.reply]);
      await a.stop();
      await b.stop();
    });
  });
}
