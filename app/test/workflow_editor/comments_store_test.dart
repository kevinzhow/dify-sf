import 'dart:async';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/workflow_editor/comments/comments_store.dart';
import 'package:flutter_test/flutter_test.dart';

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 20, reconnectMax: 100, retransmitAfter: 3000);

Future<void> until(bool Function() cond, {String? what, Duration timeout = const Duration(seconds: 10)}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late FakeServer server;
  final sessions = <CollabSession>[];
  final stores = <CommentsStore>[];

  setUp(() => server = FakeServer());
  tearDown(() async {
    for (final s in stores) {
      s.dispose();
    }
    stores.clear();
    for (final s in sessions) {
      await s.stop();
    }
    sessions.clear();
  });

  /// A session (named [name]) with its store, connected to the shared in-memory server.
  Future<(CollabSession, CommentsStore, FakeNetwork)> join(String id, String name) async {
    final net = FakeNetwork(random: Random(id.hashCode))
      ..minLatency = const Duration(milliseconds: 1)
      ..maxLatency = const Duration(milliseconds: 3);
    final s = CollabSession(
      clientId: id,
      transport: FakeTransport(server, network: net),
      journaled: false,
      config: _fast,
      tickInterval: const Duration(milliseconds: 10),
      displayName: name,
    );
    sessions.add(s);
    await s.start();
    await s.settled();
    final store = CommentsStore.forSession(s);
    stores.add(store);
    await until(() => store.loaded, what: 'first list');
    return (s, store, net);
  }

  test('two clients see each other\'s comments and replies (refetch on the stream\'s comments event)', () async {
    final (_, a, _) = await join('alice', 'Alice');
    final (_, b, _) = await join('bob', 'Bob');
    final created = await a.create(x: 10, y: 20, content: 'Should this be gpt-4o?', mentions: ['bob']);
    expect(a.comments.single.id, created.id, reason: 'the author sees it at once');
    await until(() => b.comments.length == 1, what: 'bob sees it');
    final seen = b.comments.single;
    expect((seen.content, seen.createdBy, seen.createdByName), ('Should this be gpt-4o?', 'alice', 'Alice'));
    expect(seen.mentions.single.name, 'Bob');
    expect(b.isAuthor(seen), isFalse);
    expect(a.isAuthor(a.comments.single), isTrue);

    await b.reply(created.id, content: 'yes', mentions: ['alice']);
    expect(b.byId(created.id)!.replies.single.content, 'yes');
    await until(() => a.byId(created.id)?.replyCount == 1, what: 'alice sees the reply');
    await b.resolve(created.id);
    await until(() => a.byId(created.id)?.resolved ?? false, what: 'alice sees it resolved');
    expect(a.byId(created.id)!.resolvedBy, 'bob');
    await a.delete(created.id);
    await until(() => b.comments.isEmpty, what: 'bob sees the delete');
    expect(a.names, {'alice': 'Alice', 'bob': 'Bob'}, reason: 'mention candidates: the /clients directory');
  });

  test('a non-author edit, move or delete is refused and surfaces an error; a refused move goes back', () async {
    final (_, a, _) = await join('alice', 'Alice');
    final (_, b, _) = await join('bob', 'Bob');
    final c = await a.create(x: 1, y: 2, content: 'mine');
    await until(() => b.comments.length == 1, what: 'bob sees it');
    final failures = <CommentsFailure>[];
    final sub = b.failures.listen(failures.add);
    addTearDown(sub.cancel);

    await expectLater(
      b.update(c.id, content: 'hijacked'),
      throwsA(isA<TransportException>().having((e) => e.notAuthor, 'notAuthor', isTrue)),
    );
    expect(b.lastError!.notAuthor, isTrue);
    expect(b.lastError!.action, 'update');
    expect(b.byId(c.id)!.content, 'mine');

    // Optimistic move (as Dify): the pin moves at once ...
    final move = b.move(c.id, 500, 600);
    expect((b.byId(c.id)!.positionX, b.byId(c.id)!.positionY), (500.0, 600.0));
    // ... and goes back when the server refuses.
    await expectLater(move, throwsA(isA<TransportException>()));
    expect((b.byId(c.id)!.positionX, b.byId(c.id)!.positionY), (1.0, 2.0));
    await expectLater(b.delete(c.id), throwsA(isA<TransportException>()));
    await Future<void>.delayed(Duration.zero); // broadcast delivery
    expect(failures.map((f) => (f.action, f.notAuthor)), [('update', true), ('move', true), ('delete', true)]);
    b.clearError();
    expect(b.lastError, isNull);

    // The author's move sticks, on both sides.
    await a.move(c.id, 30, 40);
    await until(() => b.byId(c.id)?.positionX == 30, what: 'bob sees the move');
    expect(server.comments.get(c.id)['position_y'], 40.0);
  });

  test('after a reconnect the store refetches what it missed while disconnected', () async {
    final (_, a, _) = await join('alice', 'Alice');
    final (bob, b, bNet) = await join('bob', 'Bob');
    bNet.refused = true;
    bNet.cutStreams();
    await until(() => bob.link != LinkState.live, what: 'bob offline');
    final c = await a.create(x: 0, y: 0, content: 'while you were away');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(b.comments, isEmpty, reason: 'the notification was lost');
    bNet.refused = false;
    await until(() => b.comments.any((x) => x.id == c.id), what: 'refetch after the reconnect');
  });

  test('refreshes coalesce, and a pending move survives a refetch', () async {
    final (_, a, _) = await join('alice', 'Alice');
    final c = await a.create(x: 1, y: 1, content: 'pin');
    final api = FakeCommentsApi(server);
    final events = StreamController<CommentsEvent>();
    final store = CommentsStore(api: api, events: events.stream, clientId: () => 'alice');
    stores.add(store);
    await until(() => store.loaded, what: 'loaded');
    final before = api.requests;
    await Future.wait([store.refresh(), store.refresh(), store.refresh()]);
    expect(api.requests - before, 2, reason: 'one running, one more for the calls that came meanwhile');

    final move = store.move(c.id, 9, 9);
    await store.refresh(); // the server still has (1, 1) while the move is in flight
    expect(store.byId(c.id)!.positionX, 9);
    await move;
    expect(store.byId(c.id)!.positionX, 9);
    events.add(const CommentsEvent.resync());
    await until(() => !store.loading);
    expect(store.byId(c.id)!.positionX, 9);
    await events.close();
  });
}
