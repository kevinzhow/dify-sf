/// Protocol 1.1 client ids: server-issued ids kept in the journal, and `clientIdInUse` (two live processes
/// sharing one id) handled by moving to a fresh id and re-creating the unsaved edits.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';
import 'support/world.dart';

Duration sec(int n) => Duration(seconds: n);

Document threeNodes() => Document(nodes: [node('a'), node('b'), node('c')]);

void main() {
  group('the new reject reason', () {
    test('clientIdInUse parses and is a distinct reason, not a generic Invalid', () {
      final r = RejectReason.fromJson(jsonDecode('{"type":"clientIdInUse"}'));
      expect(r, isA<ClientIdInUse>());
      expect(r, isNot(isA<Invalid>()));
      expect(r.name, 'clientIdInUse');
      expect(r.isStaleBased, isFalse);
      expect(RejectReason.fromJson(r.toJson()), r);
      final res = OpResult.fromJson(jsonDecode('{"cseq":3,"status":"reject","reason":{"type":"clientIdInUse"}}'));
      expect((res as RejectResult).reason, const ClientIdInUse());
    });

    test('the fake server answers a duplicate with different content as clientIdInUse and applies nothing', () {
      final s = FakeServer(initial: threeNodes());
      OutgoingOp op(int cseq, int base, Op o) => OutgoingOp(cseq: cseq, base: base, op: o);
      final first = s.submit(SubmitRequest(client: 'x', ops: [op(1, 0, setPrompt('a', 'one'))]));
      expect(first.results.single, isA<AckResult>());
      // Same cseq, other content (another process with the same id).
      final other = s.submit(SubmitRequest(client: 'x', ops: [op(1, 0, setPrompt('a', 'two'))]));
      expect((other.results.single as RejectResult).reason, const ClientIdInUse());
      expect(s.head, 1);
      expect(cfg(s.doc, 'a', 'prompt'), 'one');
      // A byte-identical retransmit is still just the original ack, and a different base counts as different.
      expect(
        (s.submit(SubmitRequest(client: 'x', ops: [op(1, 0, setPrompt('a', 'one'))])).results.single as AckResult).seq,
        1,
      );
      expect(
        (s.submit(SubmitRequest(client: 'x', ops: [op(1, 1, setPrompt('a', 'one'))])).results.single as RejectResult)
            .reason,
        const ClientIdInUse(),
      );
      // Abandoned cseqs (below a floor) have no stored op: notCommitted, as before.
      s.submit(const SubmitRequest(client: 'y', floor: 5));
      expect(
        (s.submit(SubmitRequest(client: 'y', ops: [op(2, 0, setPrompt('a', 'z'))])).results.single as RejectResult)
            .reason,
        const NotCommitted(),
      );
    });

    test('issued ids are unique and well-formed', () {
      final s = FakeServer();
      final ids = {for (var i = 0; i < 50; i++) s.issueClientId()};
      expect(ids, hasLength(50));
      expect(ids, everyElement(matches(RegExp(r'^s-[0-9a-f]{32}$'))));
    });
  });

  group('server-issued ids in the journal', () {
    test('a fresh session asks the server for an id and saves it in its journal; a restart reuses it', () {
      inWorld((w) {
        final bob = w.add('bob', serverIssuedId: true);
        w.settle();
        final id = bob.session.clientId;
        expect(id, matches(RegExp(r'^s-[0-9a-f]{32}$')));
        expect((bob.store.saved)!.id, id, reason: 'persisted before anything is sent');
        bob.edit(setPrompt('a', 'x'));
        w.settle();
        expect(w.server.log.single.client, id, reason: 'ops go out under the issued id');

        bob.crash();
        bob.start();
        w.settle();
        expect(bob.session.clientId, id, reason: 'the journal remembers the id: no new one is requested');
        bob.edit(setPrompt('b', 'y'));
        w.settle();
        expect(w.server.log.map((e) => (e.client, e.cseq)), [(id, 1), (id, 2)]);
      }, initial: threeNodes());
    });

    test('with an id in the journal the session starts without the server (offline restart)', () {
      inWorld((w) {
        final bob = w.add('bob', serverIssuedId: true);
        w.settle();
        final id = bob.session.clientId;
        bob.crash();
        bob.net.refused = true;
        bob.start();
        expect(bob.session.clientId, id);
        bob.net.refused = false;
        w.settle();
      }, initial: threeNodes());
    });

    test('without a journal and without the server, start fails with a TransportException', () {
      inWorld((w) {
        final server = w.server;
        final net = FakeNetwork()..refused = true;
        final session = CollabSession(
          transport: FakeTransport(server, network: net),
          store: MemoryStore(),
        );
        Object? error;
        session.start().catchError((Object e) => error = e);
        w.elapse(sec(1));
        expect(error, isA<TransportException>());
      }, initial: threeNodes());
    });

    test('an explicit id that disagrees with the journal is refused', () {
      inWorld((w) {
        final store = MemoryStore();
        final first = CollabSession(clientId: 'one', transport: FakeTransport(w.server), store: store);
        first.start();
        w.elapse(sec(1));
        final second = CollabSession(clientId: 'two', transport: FakeTransport(w.server), store: store);
        Object? error;
        second.start().catchError((Object e) => error = e);
        w.elapse(sec(1));
        expect(error, isA<StateError>());
      }, initial: threeNodes());
    });
  });

  group('two processes share a client id', () {
    /// Every op the user made ends up committed exactly once (under whichever id) or explicitly rejected.
    void expectNothingLostOrDoubled(World w, List<Participant> ps) {
      for (final p in ps) {
        expect(p.events.whereType<OpLost>(), isEmpty);
        expect(
          p.events.whereType<OpRejected>().where((r) => r.reason is Invalid || r.reason is ClientIdInUse),
          isEmpty,
          reason: 'never surfaced as a generic error',
        );
        expect(p.session.machine.violations, isEmpty);
      }
      expect(w.server.doc.integrityProblems, isEmpty);
    }

    test('the second tab is told clientIdInUse, takes a new id and re-sends its edit', () {
      inWorld((w) {
        final tab1 = w.add('tab1', wireId: 'dup');
        final tab2 = w.add('tab2', wireId: 'dup');
        w.settle();
        tab2.net.dropRequest = 1; // tab1's op gets cseq 1 on the server first
        tab1.edit(setPrompt('a', 'from tab1'));
        tab2.edit(setPrompt('b', 'from tab2'));
        w.elapse(sec(2));
        expect(w.server.log.map((e) => (e.client, e.cseq)), [('dup', 1)]);
        tab2.heal();
        w.settle();

        final replaced = tab2.events.whereType<ClientIdReplaced>().single;
        expect(replaced.oldId, 'dup');
        expect(replaced.newId, matches(RegExp(r'^s-[0-9a-f]{32}$')));
        expect(replaced.renumbered, {1: 1}, reason: 'cseq restarts at 1 under the new id');
        expect(tab2.session.clientId, replaced.newId);
        expect(tab2.store.saved!.id, replaced.newId, reason: 'the new id is in the journal');
        expect(tab1.events.whereType<ClientIdReplaced>(), isEmpty);
        expect(w.server.log.map((e) => (e.client, e.cseq)), [('dup', 1), (replaced.newId, 1)]);
        expect(cfg(w.server.doc, 'a', 'prompt'), 'from tab1');
        expect(cfg(w.server.doc, 'b', 'prompt'), 'from tab2');
        expect(tab2.committed.map((c) => c.cseq), [1], reason: 'reported under its new cseq, once');
        expectNothingLostOrDoubled(w, [tab1, tab2]);
        expect(tab1.session.view, w.server.doc);
        expect(tab2.session.view, w.server.doc);
      }, initial: threeNodes());
    });

    test('several unsaved edits keep their order and their original base; a stale one still conflicts', () {
      inWorld((w) {
        final tab1 = w.add('tab1', wireId: 'dup');
        final tab2 = w.add('tab2', wireId: 'dup');
        w.settle();
        tab2.net.dropRequest = 1;
        tab1.edit(setPrompt('a', 'tab1 wins'));
        tab2.edit(setPrompt('a', 'tab2 loses')); // stale after tab1's commit
        tab2.edit(setPrompt('b', 'b1'));
        tab2.edit(setPrompt('b', 'b2'));
        w.elapse(sec(2));
        tab2.heal();
        w.settle();
        final replaced = tab2.events.whereType<ClientIdReplaced>().single;
        expect(replaced.renumbered.values.toList(), [for (var i = 1; i <= replaced.renumbered.length; i++) i]);
        expect(cfg(w.server.doc, 'a', 'prompt'), 'tab1 wins', reason: 'stale-write protection survives the id change');
        expect(cfg(w.server.doc, 'b', 'prompt'), 'b2');
        expect(tab2.rejected.single.reason, isA<Conflict>());
        expectNothingLostOrDoubled(w, [tab1, tab2]);
      }, initial: threeNodes());
    });

    test('noticed from the stream alone, before the server ever sees the second tab\'s op', () {
      inWorld((w) {
        final tab1 = w.add('tab1', wireId: 'dup');
        final tab2 = w.add('tab2', wireId: 'dup');
        w.settle();
        tab2.net.dropRequest = 1;
        tab2.edit(setPrompt('b', 'from tab2'));
        tab1.edit(setPrompt('a', 'from tab1')); // (dup, 1) with different content than tab2's pending (dup, 1)
        w.elapse(sec(3));
        expect(tab2.events.whereType<ClientIdReplaced>(), hasLength(1), reason: 'content mismatch seen on the stream');
        expect(tab2.events.whereType<OpCommitted>(), isEmpty, reason: 'tab1\'s commit is not reported as tab2\'s');
        tab2.heal();
        w.settle();
        expect(cfg(w.server.doc, 'b', 'prompt'), 'from tab2');
        expect(tab2.committed, hasLength(1));
        expectNothingLostOrDoubled(w, [tab1, tab2]);
      }, initial: threeNodes());
    });

    test('ops whose content was lost in a crash cannot be re-created: reported lost, not guessed', () {
      // A volatile restart left cseqs 1 and 2 abandoned; a new edit (cseq 3) then collides with another process.
      final m = ClientMachine.restore(const ClientDurable(id: 'dup', nextCseq: 3, unresolvedFrom: 1), journaled: false);
      var now = 0;
      final open = m.tick(now).whereType<OpenStreamAction>().single.open;
      m.receiveStream(SnapshotEvent(seq: 5, doc: threeNodes()), open.generation, now);
      m.receiveStream(const ReadyEvent(5), open.generation, now);
      m.edit(setPrompt('a', 'mine'), now, base: 5);
      m.drainEvents();
      // The server rejects cseq 3 as clientIdInUse (and says what it already resolved for the abandoned ones).
      now += 10;
      final requests = m.receiveResponse(
        const SubmitResponse(
          head: 5,
          high: 3,
          results: [RejectResult(3, ClientIdInUse())],
          known: KnownOutcomes(),
        ),
        now,
      );
      expect(m.idCompromised, isTrue);
      expect(requests.whereType<RequestClientIdAction>(), hasLength(1), reason: 'the stream is already caught up');
      expect(m.tick(now += 10), isEmpty, reason: 'asked once, and nothing is sent meanwhile');
      final events = m.drainEvents(); // the abandoned cseqs 1 and 2 were resolved by the same answer
      m.adoptClientId('fresh', now);
      events.addAll(m.drainEvents());
      expect(events.whereType<OpLost>().map((e) => e.cseq), [1, 2]);
      expect(events.whereType<ClientIdReplaced>().single.renumbered, {3: 1});
      expect(m.id, 'fresh');
      expect(m.nextCseq, 2);
      expect(m.durable.id, 'fresh');
      expect(m.durable.unresolvedFrom, 1);
    });
  });

  group('non-monotone bases are legal (protocol 1.1)', () {
    test('a later op may carry an older base: accepted when its register is untouched, refused when stale', () {
      inWorld((w) {
        final alice = w.add('alice');
        final bob = w.add('bob');
        w.settle();
        final early = bob.session.lastSeq;
        alice.edit(setPrompt('a', 'alice'));
        w.settle();
        final late = bob.session.lastSeq;
        expect(late, greaterThan(early));
        // Bob's ops, in cseq order: base `late`, then base `early` (a draft started before alice's edit).
        expect(bob.session.edit(setPrompt('b', 'b-new'), base: late).cseq, 1);
        expect(bob.session.edit(setPrompt('c', 'c-old-draft'), base: early).cseq, 2);
        final stale = bob.session.edit(setPrompt('a', 'bob-old-draft'), base: early);
        expect(stale.refusal, isA<Conflict>());
        w.settle();
        final bases = w.server.log.where((e) => e.client == 'bob').map((e) => e.base).toList();
        expect(bases, [late, early], reason: 'the server took the decreasing bases as they were');
        expect(cfg(w.server.doc, 'c', 'prompt'), 'c-old-draft');
      }, initial: threeNodes());
    });
  });
}
