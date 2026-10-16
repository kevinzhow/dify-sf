/// The real transport (package:http POST + hand-rolled SSE) against the in-memory protocol server over
/// loopback sockets, with real time and short timeouts.
@TestOn('vm')
@Timeout(Duration(seconds: 60))
library;

import 'dart:async';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing_io.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

const _fast = ClientConfig(streamSilence: 900, reconnectBase: 40, reconnectMax: 300, retransmitAfter: 3000);

Future<void> until(bool Function() cond, {Duration timeout = const Duration(seconds: 15), String? what}) async {
  final end = DateTime.now().add(timeout);
  while (!cond()) {
    if (DateTime.now().isAfter(end)) fail('timed out waiting for ${what ?? 'condition'}');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late HttpFakeServer srv;
  final sessions = <CollabSession>[];

  setUp(() async {
    srv = await HttpFakeServer.start(pingInterval: const Duration(milliseconds: 300));
    srv.doc('d', template: 'empty');
    srv.doc('d').doc
      ..apply(AddNode(node('a')), const Stamp(0, 'genesis'))
      ..apply(AddNode(node('b')), const Stamp(0, 'genesis'));
  });

  tearDown(() async {
    for (final s in sessions) {
      await s.stop();
    }
    sessions.clear();
    await srv.close();
  });

  Future<CollabSession> connect(String id, {DurableStore? store, bool journaled = true, String doc = 'd'}) async {
    final s = CollabSession(
      clientId: id,
      transport: HttpTransport(baseUrl: srv.url, docId: doc),
      store: store,
      journaled: journaled,
      config: _fast,
      tickInterval: const Duration(milliseconds: 25),
      postTimeout: const Duration(milliseconds: 500),
    );
    sessions.add(s);
    await s.start();
    await s.settled().timeout(const Duration(seconds: 10));
    return s;
  }

  test('two clients converge over real HTTP and SSE', () async {
    final a = await connect('alice');
    final b = await connect('bob');
    final events = <ClientEvent>[];
    a.events.listen(events.add);
    a.edit(setPrompt('a', 'hello'));
    b.edit(setPrompt('b', 'world'));
    await until(() => srv.doc('d').head == 2, what: 'both commits');
    await a.settled();
    await b.settled();
    await until(() => a.lastSeq == 2 && b.lastSeq == 2);
    expect(a.view, srv.doc('d').doc);
    expect(b.view, srv.doc('d').doc);
    expect(events.whereType<OpCommitted>(), hasLength(1));
    expect(a.link, LinkState.live);
  });

  test('frames split at arbitrary byte boundaries are reassembled', () async {
    srv.fragmentWrites = true;
    final a = await connect('alice');
    for (var i = 0; i < 20; i++) {
      a.edit(setStr('a', ['k$i'], 'value $i'));
    }
    await a.settled();
    final b = await connect('bob');
    expect(b.view, srv.doc('d').doc);
    expect(b.lastSeq, 20);
  });

  test('a cut stream resumes with Last-Event-ID and misses nothing', () async {
    final a = await connect('alice');
    final b = await connect('bob');
    a.edit(setPrompt('a', 'one'));
    await until(() => b.lastSeq == 1);
    srv.streamResumePoints.clear();
    srv.dropStreams();
    a.edit(setPrompt('a', 'two')); // committed while bob may be reconnecting
    await until(() => b.lastSeq == 2, what: 'bob catches up');
    expect(cfg(b.view, 'a', 'prompt'), 'two');
    expect(srv.streamResumePoints, contains(1), reason: 'bob resumed from lastSeq=1, not from scratch');
    expect(srv.doc('d').replaysServed, greaterThan(0));
  });

  test('a stream that goes silent without closing is detected by the watchdog', () async {
    final a = await connect('alice');
    final b = await connect('bob');
    srv.streamResumePoints.clear();
    srv.stallStreams = true; // half-open: sockets stay up, nothing is written
    a.edit(setPrompt('a', 'unseen'));
    await until(() => srv.doc('d').head == 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(b.lastSeq, 0, reason: 'bob cannot know yet');
    await until(() => srv.streamResumePoints.length >= 2, what: 'bob reconnecting while silence continues');
    expect(b.link, isNot(LinkState.live));
    srv.stallStreams = false;
    await until(() => b.lastSeq == 1, what: 'bob catches up after the stall ends');
    expect(cfg(b.view, 'a', 'prompt'), 'unseen');
    await until(() => b.link == LinkState.live);
  });

  test('POST answers that never arrive: timeout, resend, committed exactly once', () async {
    final a = await connect('alice');
    srv.swallowResponses = true;
    // Keep the stream from confirming the commit so the retransmit path is what resolves the op.
    srv.stallStreams = true;
    a.edit(setPrompt('a', 'x'));
    await until(() => srv.postCount >= 3, what: 'retransmits');
    srv.swallowResponses = false;
    srv.stallStreams = false;
    await a.settled();
    expect(srv.doc('d').log, hasLength(1));
    expect(a.status.pending, 0);
  });

  test('5xx after an uncertain commit is retried and answered from the record', () async {
    final a = await connect('alice');
    srv.failNextPosts = 2;
    final events = <ClientEvent>[];
    a.events.listen(events.add);
    a.edit(setPrompt('a', 'x'));
    a.edit(setPrompt('b', 'y'));
    await a.settled();
    expect(srv.doc('d').log, hasLength(2));
    await until(() => events.whereType<OpCommitted>().length == 2);
  });

  test('a journaled client that restarts resumes its outbox over real HTTP', () async {
    final store = MemoryStore();
    final a = await connect('alice', store: store);
    srv.swallowResponses = true;
    srv.stallStreams = true;
    a.edit(setPrompt('a', 'before crash'));
    await until(() => srv.doc('d').head == 1); // committed, but alice never learns it
    await a.stop(); // "crash"
    srv.swallowResponses = false;
    srv.stallStreams = false;
    final again = await connect('alice', store: store);
    expect(again.status.pending, 0);
    expect(srv.doc('d').log, hasLength(1));
    expect(cfg(again.view, 'a', 'prompt'), 'before crash');
  });

  test('a server that is not there makes submit and stream fail cleanly', () async {
    final dead = await HttpFakeServer.start();
    final url = dead.url;
    await dead.close();
    final t = HttpTransport(baseUrl: url, docId: 'd');
    await expectLater(
      t.submit(const SubmitRequest(client: 'c'), timeout: const Duration(seconds: 2)),
      throwsA(isA<TransportException>()),
    );
    await expectLater(t.openStream(const StreamOpen()).drain<void>(), throwsA(isA<TransportException>()));
  });

  test('document endpoints', () async {
    final api = DocsApi(srv.url);
    expect(await api.healthy(), isTrue);
    final created = await api.create(template: 'empty');
    expect(created.created, isTrue);
    expect((await api.info(created.id))!.head, 0);
    final again = await api.ensure(created.id);
    expect(again.created, isFalse);
    expect(await api.info('nope'), isNull);
    await expectLater(api.ensure('x').then((_) => api.info('x')), completion(isNotNull));
    api.close();
  });
}
