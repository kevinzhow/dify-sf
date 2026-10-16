/// Protocol scenarios S1-S8 (see the prototype report) played through the real driver (CollabSession) over an
/// in-memory server and a simulated network, in fake time.
library;

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';
import 'support/world.dart';

Duration sec(int n) => Duration(seconds: n);
Duration ms(int n) => Duration(milliseconds: n);

Document threeNodes() => Document(nodes: [node('a'), node('b'), node('c')]);

/// Everyone who is running sees exactly the server's document (I3), with version metadata.
void expectConverged(World w) {
  for (final p in w.participants.values.where((p) => p.running)) {
    expect(p.session.confirmed, w.server.doc, reason: '${p.id} confirmed');
    expect(p.session.view, w.server.doc, reason: '${p.id} view');
    expect(p.session.lastSeq, w.server.head, reason: '${p.id} lastSeq');
    expect(p.session.machine.violations, isEmpty);
  }
}

/// Server-side facts: how many log entries did [client] commit?
int committedBy(World w, String client) => w.server.log.where((e) => e.client == client).length;

void main() {
  group('S1 two users, no overlap', () {
    test('different nodes and different fields of one node all commit', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          alice.edit(setPrompt('a', 'A'));
          bob.edit(setPrompt('b', 'B'));
          alice.edit(setStr('c', ['model', 'name'], 'm1'));
          bob.edit(setStr('c', ['model', 'temp'], 't1'));
          alice.edit(const MoveNode('a', 10, 20));
          bob.edit(const SetField('a', TitleKey(), VString('bob title')));
          w.settle();
          expect(alice.rejected, isEmpty);
          expect(bob.rejected, isEmpty);
          expect(alice.committed.length, 3);
          expect(bob.committed.length, 3);
          expect(alice.warnings, isEmpty);
          final d = w.server.doc;
          expect(cfg(d, 'a', 'prompt'), 'A');
          expect(cfg(d, 'b', 'prompt'), 'B');
          expect(cfg(d, 'c', 'model'), {'name': 'm1', 'temp': 't1'});
          expect((d.nodes['a']!.x, d.nodes['a']!.title), (10, 'bob title'));
          expectConverged(w);
        }, initial: threeNodes()));
  });

  group('S2 two users, same field', () {
    test('the second writer is told explicitly, sees the winning value, can re-apply', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          // Bob's POSTs are lost, so his edit stays pending while Alice's commits.
          bob.net.dropRequest = 1;
          bob.edit(setPrompt('a', 'bob'));
          alice.edit(setPrompt('a', 'alice'));
          w.elapse(sec(3));

          // Early warning arrives through the stream, before any verdict; the winning value is on screen.
          expect(bob.warnings, hasLength(1));
          final warn = bob.warnings.single;
          expect(warn.reason, isA<Conflict>());
          expect((warn.reason as Conflict).by, 'alice');
          expect(cfg(bob.session.view, 'a', 'prompt'), 'alice');
          expect(bob.rejected, isEmpty);
          expect(bob.session.status.pending, 1);

          bob.heal();
          w.settle();
          expect(bob.rejected, hasLength(1));
          final lost = bob.rejected.single;
          expect(lost.op, setPrompt('a', 'bob')); // the op comes back so the UI can offer "re-apply"
          expect(lost.reason, isA<Conflict>());
          expect(bob.warnings, hasLength(1), reason: 'warned once only');
          expect(cfg(w.server.doc, 'a', 'prompt'), 'alice');

          // Re-apply on the latest version: based on the new lastSeq, it succeeds.
          bob.edit(lost.op);
          w.settle();
          expect(cfg(w.server.doc, 'a', 'prompt'), 'bob');
          expect(bob.rejected, hasLength(1));
          expectConverged(w);
        }, initial: threeNodes()));

    test('whoever is sequenced first wins (reverse order)', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          alice.net.dropRequest = 1;
          alice.edit(setPrompt('a', 'alice'));
          bob.edit(setPrompt('a', 'bob'));
          w.elapse(sec(3));
          alice.heal();
          w.settle();
          expect(alice.rejected.single.reason, isA<Conflict>());
          expect(bob.rejected, isEmpty);
          expect(cfg(w.server.doc, 'a', 'prompt'), 'bob');
          expectConverged(w);
        }, initial: threeNodes()));

    test('overlapping paths conflict, sibling paths merge', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(setStr('a', ['model'], 'whole'));
          bob.edit(setStr('a', ['other', 'x'], 'x'));
          alice.edit(setStr('a', ['model', 'name'], 'n'));
          alice.edit(setStr('a', ['other', 'y'], 'y'));
          w.elapse(sec(2));
          bob.heal();
          w.settle();
          expect(bob.rejected, hasLength(1));
          expect(bob.rejected.single.op, setStr('a', ['model'], 'whole'));
          expect(cfg(w.server.doc, 'a', 'model'), {'name': 'n'});
          expect(cfg(w.server.doc, 'a', 'other'), {'x': 'x', 'y': 'y'});
          expectConverged(w);
        }, initial: threeNodes()));

    test('a stale write of the value that is already there is accepted', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(setPrompt('a', 'same'));
          alice.edit(setPrompt('a', 'same'));
          w.elapse(sec(2));
          expect(bob.warnings, isEmpty, reason: 'same value: nothing to warn about');
          bob.heal();
          w.settle();
          expect(bob.rejected, isEmpty);
          expect(bob.committed, hasLength(1));
          expectConverged(w);
        }, initial: threeNodes()));

    test('thirty users writing the same value all succeed', () => inWorld((w) {
          final users = [for (var i = 0; i < 30; i++) w.add('u$i', seed: i)];
          w.settle();
          for (final u in users) {
            u.net.dropRequest = 1; // everybody is based on the same version
            u.edit(setPrompt('a', 'same'));
          }
          for (final u in users) {
            u.heal();
          }
          w.settle();
          expect(users.expand((u) => u.rejected), isEmpty);
          expect(users.expand((u) => u.committed), hasLength(30));
          expectConverged(w);
        }, initial: threeNodes()));
  });

  group('S3 a stale tab comes back', () {
    void staleTab(World w) {
      final alice = w.add('alice');
      final bob = w.add('bob');
      w.settle();
      bob.net.partitioned = true; // laptop lid closed
      w.elapse(sec(2));
      // Bob edits offline: a conflicting prompt, a move, a delete of a node that alice changed, a fresh node.
      bob.edit(setPrompt('a', 'bob prompt'));
      bob.edit(const MoveNode('b', 500, 500));
      bob.edit(const RemoveNode('c'));
      bob.edit(const SetField('d', ConfigKey(['note']), VString('offline note')));
      expect(bob.session.status.pending, 4);
      expect(cfg(bob.session.view, 'a', 'prompt'), 'bob prompt', reason: 'optimistic');
      // Meanwhile alice works a lot.
      alice.edit(setPrompt('a', 'alice prompt'));
      alice.edit(const SetField('c', TitleKey(), VString('alice title')));
      for (var i = 0; i < 20; i++) {
        alice.edit(MoveNode('a', i, i));
        w.elapse(ms(100));
      }
      w.elapse(sec(5));
      bob.net.partitioned = false;
      bob.session.networkAvailable();
      w.settle();

      final reasons = {for (final r in bob.rejected) r.op: r.reason};
      expect(reasons[setPrompt('a', 'bob prompt')], isA<Conflict>());
      expect(reasons[const RemoveNode('c')], isA<Conflict>(), reason: 'deleting would destroy alice\'s unseen work');
      expect(bob.rejected, hasLength(2));
      expect(bob.committed, hasLength(2)); // the move and the untouched node
      final d = w.server.doc;
      expect(cfg(d, 'a', 'prompt'), 'alice prompt');
      expect(d.nodes.containsKey('c'), isTrue);
      expect((d.nodes['b']!.x, d.nodes['b']!.y), (500, 500));
      expect(cfg(d, 'd', 'note'), 'offline note');
      expectConverged(w);
    }

    test('catching up from the log', () => inWorld(staleTab, initial: Document(nodes: [node('a'), node('b'), node('c'), node('d')])));

    test('joining by snapshot after compaction', () => inWorld(staleTab,
        initial: Document(nodes: [node('a'), node('b'), node('c'), node('d')]), maxReplay: 5));
  });

  group('S4 bad networks', () {
    test('request lost before the server: resent, committed once', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(setPrompt('a', 'x'));
          w.elapse(sec(35));
          expect(w.server.log, isEmpty);
          expect(bob.session.status.pending, 1);
          bob.heal();
          w.settle();
          expect(w.server.log, hasLength(1));
          expect(bob.committed, hasLength(1));
          expectConverged(w);
        }, initial: threeNodes()));

    test('server committed but the ack was lost: the retransmit is answered from the record', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net
            ..dropResponse = 1
            ..blockStreams = true; // so the commit does not reach bob through the stream either
          bob.edit(setPrompt('a', 'x'));
          w.elapse(sec(25));
          expect(w.server.log, hasLength(1), reason: 'committed on the first POST already');
          expect(bob.transport.postsReceived, greaterThan(1), reason: 'client retransmitted');
          bob.heal();
          w.settle();
          expect(w.server.log, hasLength(1), reason: 'never applied twice');
          expect(bob.committed.single.seq, 1);
          expectConverged(w);
        }, initial: threeNodes()));

    test('503 after an uncertain commit: the retry gets the original outcome', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net
            ..serverError = 1
            ..commitBefore503 = 1;
          bob.edit(setPrompt('a', 'x'));
          w.elapse(sec(20));
          bob.heal();
          w.settle();
          expect(w.server.log, hasLength(1));
          expect(bob.committed, hasLength(1));
        }, initial: threeNodes()));

    test('40% loss both ways, resets and jitter: everything arrives once, in order', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          for (final p in [alice, bob]) {
            p.net
              ..dropRequest = 0.4
              ..dropResponse = 0.4
              ..maxLatency = const Duration(milliseconds: 800);
          }
          for (var i = 0; i < 20; i++) {
            alice.edit(MoveNode('a', i, i));
            bob.edit(setStr('b', ['k$i'], 'v$i'));
            w.elapse(ms(700));
            if (i % 5 == 0) {
              alice.net.cutStreams();
              bob.net.cutStreams();
            }
          }
          alice.heal();
          bob.heal();
          w.settle();
          expect(alice.committed, hasLength(20));
          expect(bob.committed, hasLength(20));
          expect(committedBy(w, 'bob'), 20);
          final cseqs = w.server.log.where((e) => e.client == 'bob').map((e) => e.cseq).toList();
          expect(cseqs, [for (var i = 1; i <= 20; i++) i]);
          expectConverged(w);
        }, initial: threeNodes()));

    test('a half-open stream (peer gone, socket "open") is detected by the silence watchdog', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.partitioned = true; // no error, no bytes: the dangerous kind
          alice.edit(setPrompt('a', 'while bob is gone'));
          w.elapse(sec(20));
          expect(bob.session.link, LinkState.live, reason: 'bob cannot know yet');
          w.elapse(sec(15)); // 30 s of silence
          expect(bob.session.link, isNot(LinkState.live));
          bob.net.partitioned = false;
          w.settle();
          expect(cfg(bob.session.view, 'a', 'prompt'), 'while bob is gone');
          expectConverged(w);
        }, initial: threeNodes()));

    test('a lost stream event (hole) makes the client reconnect from lastSeq', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.holeRate = 0.5;
          for (var i = 0; i < 20; i++) {
            alice.edit(setStr('a', ['k$i'], 'v$i'));
            w.elapse(ms(300));
          }
          bob.net.holeRate = 0;
          w.settle();
          expect(bob.session.machine.violations, isEmpty);
          expectConverged(w);
        }, initial: threeNodes()));

    test('the server is unreachable for a while: edits are kept, then sent', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net.refused = true;
          bob.net.cutStreams();
          bob.edit(setPrompt('a', 'x'));
          bob.edit(setPrompt('b', 'y'));
          w.elapse(sec(60));
          expect(bob.session.link, LinkState.offline);
          expect(bob.session.status.pending, 2);
          bob.net.refused = false;
          bob.session.networkAvailable();
          w.settle();
          expect(bob.committed, hasLength(2));
          expect(bob.session.link, LinkState.live);
        }, initial: threeNodes()));
  });

  group('S5 crashes', () {
    test('journaled: the outbox survives a crash and is resent', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net.partitioned = true;
          bob.edit(setPrompt('a', '1'));
          bob.edit(setPrompt('b', '2'));
          bob.edit(const MoveNode('c', 5, 5));
          w.elapse(sec(1));
          bob.crash();
          bob.heal();
          bob.start();
          w.settle();
          expect(bob.committed, hasLength(3));
          expect(bob.lost, isEmpty);
          expect(cfg(w.server.doc, 'b', 'prompt'), '2');
          expectConverged(w);
        }, initial: threeNodes()));

    test('volatile: unsaved edits are reported lost, explicitly', () => inWorld((w) {
          final bob = w.add('bob', journaled: false);
          w.settle();
          bob.net.partitioned = true;
          bob.edit(setPrompt('a', '1'));
          bob.edit(setPrompt('b', '2'));
          w.elapse(sec(1));
          bob.crash();
          bob.heal();
          bob.start();
          w.settle();
          expect(bob.committed, isEmpty);
          expect(bob.lost.map((l) => l.cseq), [1, 2]);
          expect(w.server.log, isEmpty);
          expect(w.server.doc, threeNodes());
          // The floor was honoured: new edits flow normally with fresh cseqs.
          bob.edit(setPrompt('c', '3'));
          w.settle();
          expect(bob.committed.single.cseq, 3);
          expectConverged(w);
        }, initial: threeNodes()));

    for (final journaled in [true, false]) {
      test('${journaled ? 'journaled' : 'volatile'}: committed but never acked before the crash is reported saved',
          () => inWorld((w) {
                final bob = w.add('bob', journaled: journaled);
                w.settle();
                bob.net
                  ..dropResponse = 1
                  ..blockStreams = true;
                bob.edit(setPrompt('a', '1'));
                w.elapse(sec(2));
                expect(w.server.log, hasLength(1));
                expect(bob.committed, isEmpty);
                bob.crash();
                bob.heal();
                bob.start();
                w.settle();
                expect(bob.committed.map((c) => c.cseq), [1]);
                expect(bob.lost, isEmpty);
                expect(w.server.log, hasLength(1));
                expectConverged(w);
              }, initial: threeNodes()));
    }

    for (final journaled in [true, false]) {
      test('${journaled ? 'journaled' : 'volatile'}: fast edits then reload', () => inWorld((w) {
            final bob = w.add('bob', journaled: journaled);
            w.settle();
            for (var i = 1; i <= 3; i++) {
              bob.edit(setStr('a', ['k$i'], 'v$i'));
            }
            w.elapse(ms(30)); // first POST is in flight / committed
            for (var i = 4; i <= 10; i++) {
              bob.edit(setStr('a', ['k$i'], 'v$i'));
            }
            w.elapse(ms(1));
            bob.crash(); // "closed the tab"
            bob.start();
            w.settle();
            final saved = bob.committed.map((c) => c.cseq).toList();
            final lost = bob.lost.map((c) => c.cseq).toList();
            expect([...saved, ...lost]..sort(), [for (var i = 1; i <= 10; i++) i], reason: 'every op has one fate');
            final onServer = w.server.log.where((e) => e.client == 'bob').map((e) => e.cseq).toList();
            expect(saved, onServer, reason: 'saved == what the server really has');
            if (journaled) {
              expect(lost, isEmpty, reason: 'write-ahead journal: nothing lost');
            } else {
              expect(saved, [for (var i = 1; i <= saved.length; i++) i], reason: 'saved ops form a prefix');
            }
            expectConverged(w);
          }, initial: threeNodes()));
    }
  });

  group('S7 delete versus edit and references', () {
    test('a stale delete is refused and the other edit survives; after refresh the delete works', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(const RemoveNode('a'));
          alice.edit(setPrompt('a', 'precious'));
          w.elapse(sec(2));
          expect(bob.warnings.single.reason, isA<Conflict>());
          bob.heal();
          w.settle();
          expect(bob.rejected.single.reason, isA<Conflict>());
          expect(cfg(w.server.doc, 'a', 'prompt'), 'precious');
          bob.edit(const RemoveNode('a'));
          w.settle();
          expect(w.server.doc.nodes.containsKey('a'), isFalse);
          expectConverged(w);
        }, initial: threeNodes()));

    test('editing a node that was deleted meanwhile is an explicit error', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(setPrompt('a', 'late'));
          alice.edit(const RemoveNode('a'));
          w.elapse(sec(2));
          bob.heal();
          w.settle();
          expect(bob.rejected.single.reason, const NodeDeleted('a'));
          expect(bob.warnings.single.reason, const NodeDeleted('a'));
          expectConverged(w);
        }, initial: threeNodes()));

    test('deleting a referenced node leaves explicit broken markers and removes edges', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.edit(SetField('b', const ConfigKey(['in']), ref('a', 'text')));
          bob.edit(const AddEdge(Edge(id: 'e1', source: 'a', target: 'b')));
          w.settle();
          alice.edit(const RemoveNode('a'));
          w.settle();
          for (final p in [alice, bob]) {
            expect(p.session.view.nodes['b']!.config['in'], const VBroken(OutputRef('a', 'text')));
            expect(p.session.view.edges, isEmpty);
            expect(p.session.view.integrityProblems, isEmpty);
          }
          // Nobody can write a new reference to it any more.
          bob.edit(SetField('c', const ConfigKey(['in']), ref('a')));
          w.flush();
          expect(bob.events.whereType<LocalInvalid>().single.reason, const DanglingReference('a'));
          expectConverged(w);
        }, initial: threeNodes()));

    test('a reference to a concurrently deleted node is rejected', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(SetField('b', const ConfigKey(['in']), ref('a')));
          alice.edit(const RemoveNode('a'));
          w.elapse(sec(2));
          bob.heal();
          w.settle();
          expect(bob.rejected.single.reason, anyOf(const DanglingReference('a'), isA<Conflict>()));
          expect(w.server.doc.integrityProblems, isEmpty);
          expectConverged(w);
        }, initial: threeNodes()));

    test('double delete and an edge to a deleted node', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(const AddEdge(Edge(id: 'e9', source: 'a', target: 'c')));
          bob.edit(const RemoveNode('a'));
          alice.edit(const RemoveNode('a'));
          w.elapse(sec(2));
          bob.heal();
          w.settle();
          expect(bob.rejected.map((r) => r.reason), [const NodeDeleted('a'), const NodeDeleted('a')]);
          expectConverged(w);
        }, initial: threeNodes()));
  });

  group('keyed lists', () {
    test('two users add and edit different items of one list, nothing conflicts', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          alice.edit(ins('a', 'i1'));
          bob.edit(ins('a', 'i2'));
          w.settle();
          alice.edit(const UpdateItem('a', ['outs'], 'i1', VString('A')));
          bob.edit(const UpdateItem('a', ['outs'], 'i2', VString('B')));
          alice.edit(ins('a', 'i3', after: 'i1'));
          w.settle();
          expect(alice.rejected, isEmpty);
          expect(bob.rejected, isEmpty);
          expect(outIds(w.server.doc, 'a'), hasLength(3));
          expectConverged(w);
        }, initial: threeNodes()));

    test('editing an item someone else removed is refused explicitly', () => inWorld((w) {
          final alice = w.add('alice');
          final bob = w.add('bob');
          w.settle();
          alice.edit(ins('a', 'i1'));
          w.settle();
          bob.net.dropRequest = 1;
          bob.edit(const UpdateItem('a', ['outs'], 'i1', VString('late')));
          alice.edit(const RemoveItem('a', ['outs'], 'i1'));
          w.elapse(sec(2));
          bob.heal();
          w.settle();
          expect(bob.rejected.single.reason, const ItemDeleted('i1'));
          expectConverged(w);
        }, initial: threeNodes()));
  });

  group('client rules', () {
    test('an edit that is invalid locally never becomes an op', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          final cseq = bob.edit(setPrompt('ghost', 'x'));
          expect(cseq, isNull);
          w.flush();
          expect(bob.events.whereType<LocalInvalid>().single.reason, const NodeNotFound('ghost'));
          expect(bob.session.machine.nextCseq, 1);
        }, initial: threeNodes()));

    test('batches are limited and a single POST is outstanding', () => inWorld((w) {
          final bob = w.add('bob');
          w.settle();
          bob.net.partitioned = true;
          for (var i = 0; i < 120; i++) {
            bob.edit(setStr('a', ['k$i'], 'v'));
          }
          bob.net.partitioned = false;
          bob.session.networkAvailable();
          w.settle();
          expect(bob.committed, hasLength(120));
          expect(bob.transport.postsReceived, greaterThanOrEqualTo(3)); // 50 + 50 + 20
          expectConverged(w);
        }, initial: threeNodes()));
  });
}
