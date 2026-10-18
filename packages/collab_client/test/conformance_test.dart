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

  Future<SubmitResponse> post(String client, List<(int, int, Op)> ops, {int? floor, int? resolveFrom}) => t.submit(
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
      final res = await http.post(
        base.replace(path: '/v1/docs/$doc/ops'),
        headers: {'content-type': 'application/json'},
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
        HttpTransport(baseUrl: base, docId: 'ghost-${_docId()}').issueClientId(),
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

    test('1.3 display names: issue named, rename, directory, byName on conflicts', () async {
      final bo = await t.issueClientId(name: 'Bo');
      final anon = await api.issueClientId(doc);
      expect(await api.clientNames(doc), {bo: 'Bo'});
      await post(bo, [(1, 0, setPrompt('llm', 'bo'))]); // seq 1
      await post(anon, [
        (1, 0, setStr('llm', ['model', 'name'], 'anon')),
      ]); // seq 2
      final x = await t.issueClientId();
      final r = await post(x, [
        (1, 0, setPrompt('llm', 'x')),
        (2, 0, setStr('llm', ['model', 'name'], 'x')),
      ]);
      final named = (r.results[0] as RejectResult).reason as Conflict;
      final plain = (r.results[1] as RejectResult).reason as Conflict;
      expect((named.by, named.byName), (bo, 'Bo'));
      expect((plain.by, plain.byName), (anon, null));
      // A name registered later shows up on the retransmitted answer.
      await t.setClientName(anon, 'Ann');
      final again = await post(x, [
        (2, 0, setStr('llm', ['model', 'name'], 'x')),
      ]);
      expect(((again.results.single as RejectResult).reason as Conflict).byName, 'Ann');
      await api.setClientName(doc, bo, 'Bob');
      expect(await api.clientNames(doc), {bo: 'Bob', anon: 'Ann'});
      await expectLater(
        t.issueClientId(name: 'a\nb'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );
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
        final bad = await http.get(base.replace(path: '/v1/docs/$doc/events', query: 'proto=latest'));
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
      final t = HttpTransport(baseUrl: base, docId: id);
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

    test('CORS: preflight answered, headers allowed for local origins, none for foreign ones', () async {
      final pre = http.Request('OPTIONS', base.replace(path: '/v1/docs/$doc/ops'))
        ..headers['Origin'] = 'http://localhost:5555'
        ..headers['Access-Control-Request-Method'] = 'POST'
        ..headers['Access-Control-Request-Headers'] = 'content-type, last-event-id';
      final res = await pre.send();
      expect(res.statusCode, inInclusiveRange(200, 204));
      expect(res.headers['access-control-allow-origin'], 'http://localhost:5555');
      expect(
        res.headers['access-control-allow-headers']!.toLowerCase(),
        allOf(contains('last-event-id'), contains('content-type')),
      );
      expect(res.headers['access-control-allow-methods'], allOf(contains('POST'), contains('PUT'), contains('DELETE')));
      final get = http.Request('GET', base.replace(path: '/v1/docs/$doc'))..headers['Origin'] = 'http://localhost:5555';
      expect((await get.send()).headers['access-control-allow-origin'], 'http://localhost:5555');
      final foreign = http.Request('GET', base.replace(path: '/v1/docs/$doc'))
        ..headers['Origin'] = 'http://evil.example';
      expect((await foreign.send()).headers.containsKey('access-control-allow-origin'), isFalse);
    });

    test('canvas comments: author rules, replies, idempotent resolve, the comments event (no id)', () async {
      final comments = api.comments(doc);
      await api.setClientName(doc, 'cli-a', 'Alice');
      final events = <StreamEvent>[];
      final sub = t.openStream(const StreamOpen(lastEventId: 0)).listen((e) => e is PingEvent ? null : events.add(e));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final c = await comments.create(
        author: 'cli-a',
        x: 120.5,
        y: -40,
        content: 'check',
        mentions: ['cli-b', 'cli-b'],
      );
      expect((c.positionX, c.positionY, c.createdBy, c.createdByName), (120.5, -40.0, 'cli-a', 'Alice'));
      expect(c.mentions.map((m) => m.client), ['cli-b']);
      expect(c.id, hasLength(36));
      await post('cli-a', [(1, 0, setPrompt('llm', 'x'))]);
      final c2 = await comments.create(author: 'cli-b', x: 0, y: 0, content: 'second');
      expect((await comments.list()).map((x) => x.id), [c2.id, c.id]);

      await expectLater(
        comments.update(c.id, author: 'cli-b', x: 1, y: 1),
        throwsA(isA<TransportException>().having((e) => e.notAuthor, 'not_author', isTrue)),
      );
      await expectLater(comments.delete(c.id, author: 'cli-b'), throwsA(isA<TransportException>()));
      final moved = await comments.update(c.id, author: 'cli-a', x: 300, y: 400);
      expect((moved.positionX, moved.content), (300.0, 'check'));
      await expectLater(
        comments.create(author: 'cli-a', x: 0, y: 0, content: 'x' * 1001),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );

      final r = await comments.reply(c.id, author: 'cli-b', content: 'on it', mentions: ['cli-a']);
      expect(r.mentions.single.name, 'Alice');
      await expectLater(
        comments.editReply(c.id, r.id, author: 'cli-a', content: 'mine now'),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 403)),
      );
      expect((await comments.editReply(c.id, r.id, author: 'cli-b', content: 'done')).content, 'done');
      expect((await comments.get(c.id)).replyCount, 1);
      await comments.deleteReply(c.id, r.id, author: 'cli-b');

      final first = await comments.resolve(c.id, author: 'cli-b');
      final again = await comments.resolve(c.id, author: 'cli-a');
      expect((first.resolved, again.resolvedBy, again.resolvedAt), (true, 'cli-b', first.resolvedAt));
      await comments.delete(c.id, author: 'cli-a');
      await expectLater(
        comments.get(c.id),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 404)),
      );
      expect(await comments.clientNames(), containsPair('cli-a', 'Alice'));

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
        transport: HttpTransport(baseUrl: base, docId: doc),
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
      final report = await StormRunner(
        StormConfig(
          url: base,
          doc: doc,
          clients: 6,
          duration: const Duration(seconds: 6),
          ratePerClient: 8,
          seed: 42,
          crashesPerClientPerMinute: 10,
        ),
      ).run();
      expect(report.violations, isEmpty);
      expect(report.counts['pending'], isNull);
      expect(report.counts['committed'], greaterThan(50));
    });
  });
}
