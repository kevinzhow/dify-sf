/// Protocol 1.3 display names: the optional `name` of a client id, and `byName` on conflict rejects.
library;

import 'dart:convert';
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:collab_client/testing_io.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'support/helpers.dart';

Document twoNodes() => Document(nodes: [node('a'), node('b')]);

OutgoingOp op(int cseq, int base, Op o) => OutgoingOp(cseq: cseq, base: base, op: o);

void main() {
  group('normalizeDisplayName', () {
    test('trims, turns control characters into spaces, refuses empty names', () {
      expect(normalizeDisplayName('  Bo  '), 'Bo');
      expect(normalizeDisplayName('Bo\nSmith\t'), 'Bo Smith');
      expect(normalizeDisplayName(' \n\t '), isNull);
      expect(normalizeDisplayName(''), isNull);
    });

    test('cuts at 64 UTF-8 bytes without splitting a character', () {
      expect(normalizeDisplayName('x' * 80), 'x' * 64);
      final cut = normalizeDisplayName('你' * 30)!; // 3 bytes each
      expect(utf8.encode(cut).length, 63);
      expect(cut, '你' * 21);
    });
  });

  group('byName on the wire', () {
    test('is parsed when present and omitted when absent', () {
      final named = RejectReason.fromJson(
        jsonDecode('{"type":"conflict","node":"a","field":null,"seq":3,"by":"s-1","byName":"Bo"}'),
      );
      expect((named as Conflict).byName, 'Bo');
      expect(named.toJson()['byName'], 'Bo');
      final plain = RejectReason.fromJson(jsonDecode('{"type":"conflict","node":"a","field":null,"seq":3,"by":"s-1"}'));
      expect((plain as Conflict).byName, isNull);
      expect(plain.toJson().containsKey('byName'), isFalse);
      expect(RejectReason.fromJson(named.toJson()), named);
    });

    test('is presentation only: conflicts that differ only in byName are equal', () {
      const a = Conflict(node: 'a', field: null, seq: 3, by: 's-1');
      const b = Conflict(node: 'a', field: null, seq: 3, by: 's-1', byName: 'Bo');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const Conflict(node: 'a', field: null, seq: 3, by: 's-2', byName: 'Bo')));
    });
  });

  group('fake server', () {
    test('a conflict names its author once the author has a name, also on a retransmit', () {
      final s = FakeServer(initial: twoNodes());
      final bo = s.issueClientId(name: 'Bo');
      final anon = s.issueClientId();
      expect(s.names, {bo: 'Bo'});
      s.submit(SubmitRequest(client: anon, ops: [op(1, 0, setPrompt('a', 'anon'))])); // seq 1
      s.submit(SubmitRequest(client: bo, ops: [op(1, 0, setPrompt('b', 'bo'))])); // seq 2
      final x = s.issueClientId();
      final r = s.submit(SubmitRequest(client: x, ops: [op(1, 0, setPrompt('a', 'x')), op(2, 0, setPrompt('b', 'x'))]));
      expect(((r.results[0] as RejectResult).reason as Conflict).byName, isNull);
      expect(((r.results[1] as RejectResult).reason as Conflict).byName, 'Bo');
      s.setClientName(anon, 'Ann');
      final again = s.submit(SubmitRequest(client: x, ops: [op(1, 0, setPrompt('a', 'x'))], resolveFrom: 1));
      expect(((again.results.single as RejectResult).reason as Conflict).byName, 'Ann');
      expect((again.known!.rejected[1]! as Conflict).byName, 'Ann');
    });
  });

  group('session', () {
    test('a freshly issued id is registered with the name', () async {
      final s = FakeServer(initial: twoNodes());
      final session = CollabSession(
        transport: FakeTransport(s, network: FakeNetwork(random: Random(1))),
        store: MemoryStore(),
        displayName: '  Bo ',
      );
      await session.start();
      expect(session.displayName, 'Bo');
      expect(s.names, {session.clientId: 'Bo'});
      await session.stop();
    });

    test('an id from the caller or the journal is named with PUT /clients/{id}', () async {
      final s = FakeServer(initial: twoNodes());
      final session = CollabSession(
        clientId: 'cli-bo',
        transport: FakeTransport(s, network: FakeNetwork(random: Random(1))),
        store: MemoryStore(),
        displayName: 'Bo',
      );
      await session.start();
      await Future<void>.delayed(Duration.zero);
      expect(s.names, {'cli-bo': 'Bo'});
      await session.stop();
    });

    test('no name: nothing is registered', () async {
      final s = FakeServer(initial: twoNodes());
      final session = CollabSession(
        transport: FakeTransport(s, network: FakeNetwork(random: Random(1))),
        store: MemoryStore(),
      );
      await session.start();
      await Future<void>.delayed(Duration.zero);
      expect(s.names, isEmpty);
      await session.stop();
    });
  });

  group('over HTTP (fake server)', () {
    late HttpFakeServer server;
    late DocsApi api;
    setUp(() async {
      server = await HttpFakeServer.start();
      api = DocsApi(server.url);
      await api.ensure('d', template: 'example');
    });
    tearDown(() async {
      api.close();
      await server.close();
    });

    test('issue with a name, rename, read the directory', () async {
      final t = HttpTransport(baseUrl: server.url, docId: 'd');
      final id = await t.issueClientId(name: 'Bo');
      final anon = await api.issueClientId('d');
      expect(await api.clientNames('d'), {id: 'Bo'});
      await t.setClientName(anon, 'Ann');
      await api.setClientName('d', id, 'Bob');
      expect(await api.clientNames('d'), {id: 'Bob', anon: 'Ann'});
      t.close();
    });

    test('a name the server would refuse is a 400', () async {
      final res = await http.post(
        server.url.replace(path: '/v1/docs/d/clients'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'name': 'a\nb'}),
      );
      expect(res.statusCode, 400);
      await expectLater(
        api.setClientName('d', 'cli-x', 'x' * 65),
        throwsA(isA<TransportException>().having((e) => e.statusCode, 'status', 400)),
      );
    });
  });
}
