/// Protocol conformance against a real server. Runs only when `DIFYSF_URL` is set, e.g.
///
///     DIFYSF_URL=http://127.0.0.1:8080 dart test test/conformance_test.dart
///
/// Each test creates its own document, so it is safe to run against a shared server.
@TestOn('vm')
@Timeout(Duration(minutes: 3))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/helpers.dart';

final String? _url = Platform.environment['DIFYSF_URL'];

String _docId() => 'conf-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${Random().nextInt(1 << 20).toRadixString(36)}';

void main() {
  if (_url == null) {
    test('conformance (set DIFYSF_URL to run)', () {}, skip: 'DIFYSF_URL is not set');
    return;
  }
  final base = Uri.parse(_url!);
  late DocsApi api;
  late String doc;
  late HttpTransport t;

  setUp(() async {
    api = DocsApi(base);
    doc = _docId();
    await api.ensure(doc, template: 'example');
    t = HttpTransport(baseUrl: base, docId: doc);
  });
  tearDown(() {
    t.close();
    api.close();
  });

  Future<SubmitResponse> post(String client, List<(int, int, Op)> ops, {int? floor, int? resolveFrom}) =>
      t.submit(
        SubmitRequest(
          client: client,
          floor: floor,
          resolveFrom: resolveFrom,
          ops: [for (final (c, b, o) in ops) OutgoingOp(cseq: c, base: b, op: o)],
        ),
        timeout: const Duration(seconds: 10),
      );

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
      final ghost = HttpTransport(baseUrl: base, docId: 'ghost-${_docId()}');
      await expectLater(
        ghost.submit(const SubmitRequest(client: 'c'), timeout: const Duration(seconds: 5)),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
      ghost.close();
    });

    test('malformed bodies are 400, not 5xx', () async {
      final res = await http.post(base.replace(path: '/v1/docs/$doc/ops'), headers: {'content-type': 'application/json'}, body: '{nope');
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
      final a = await post('cli-a', [(1, 0, const InsertItem('code', ['outputs'], Item('i-a', VString('a')), 'o-result'))]);
      final b = await post('cli-b', [(1, 0, const InsertItem('code', ['outputs'], Item('i-b', VString('b')), 'o-result'))]);
      expect(a.results.single, isA<AckResult>());
      expect(b.results.single, isA<AckResult>());
      final ids = ((await api.snapshot(doc)).doc.nodes['code']!.config['outputs']! as VItems).items.map((i) => i.id).toList();
      expect(ids, ['o-result', 'i-b', 'i-a']);
      final c = await post('cli-c', [(1, 0, const UpdateItem('code', ['outputs'], 'i-a', VString('c')))]);
      expect((c.results.single as RejectResult).reason, isA<Conflict>());
      final removed = await post('cli-c', [(2, 2, const RemoveItem('code', ['outputs'], 'i-a')), (3, 2, const RemoveItem('code', ['outputs'], 'i-a'))]);
      expect(removed.results.map((r) => r.runtimeType), [AckResult, AckResult], reason: 'removing twice is fine');
      final late = await post('cli-c', [(4, 4, const UpdateItem('code', ['outputs'], 'i-a', VString('x')))]);
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
      await expectLater(many('cli-101', 101), throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)));
    });
  });

  group('the event stream', () {
    Future<List<StreamEvent>> read(StreamOpen open, {int? until, Duration timeout = const Duration(seconds: 10)}) async {
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

  group('the client against the server', () {
    test('two sessions converge and a conflict is reported with the winner', () async {
      CollabSession open(String id) => CollabSession(
            clientId: id,
            transport: HttpTransport(baseUrl: base, docId: doc),
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
      final report = await StormRunner(StormConfig(
        url: base,
        doc: doc,
        clients: 6,
        duration: const Duration(seconds: 6),
        ratePerClient: 8,
        seed: 42,
        crashesPerClientPerMinute: 10,
      )).run();
      expect(report.violations, isEmpty);
      expect(report.counts['pending'], isNull);
      expect(report.counts['committed'], greaterThan(50));
    });
  });
}
