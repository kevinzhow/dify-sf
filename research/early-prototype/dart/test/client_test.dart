import 'package:collab_client/client.dart';
import 'package:collab_client/model.dart';
import 'package:test/test.dart';

Document base() => Document([Node('a', 'llm'), Node('b', 'llm')]);
Op setPrompt(String n, String v) => SetField(n, const FieldKey.config(['prompt']), v);

Client synced(String id, {bool journaled = true}) {
  final c = Client(id, journaled: journaled);
  c.receive(Welcome(head: 0, snapshotDoc: base(), snapshotSeq: 0), 0);
  c.connected = true;
  c.sessionOpen = true;
  return c;
}

void main() {
  test('S2: stale pending write is hidden, warned once, then rejected explicitly', () {
    final c = synced('me');
    final (cseq, msgs) = c.edit(setPrompt('a', 'mine'), 0);
    expect(cseq, 1);
    expect(msgs.single, isA<Submit>());
    expect((c.view.nodes['a']!.config['prompt']), 'mine'); // optimistic

    c.receive(Committed([LogEntry(1, 'bob', 1, 0, setPrompt('a', 'theirs'))]), 1);
    expect(c.view.nodes['a']!.config['prompt'], 'theirs'); // newer remote value wins on screen
    expect(c.drainEvents().whereType<ConflictDetected>().length, 1);
    expect(c.unresolvedCount, 1); // still queued until the server's verdict

    c.receive(Rejected(1, const RejectReason('conflict', 'a', 1, 'bob')), 2);
    final ev = c.drainEvents();
    expect(ev.whereType<OpRejected>().single.cseq, 1); // carries the op for "re-apply mine"
    expect(c.unresolvedCount, 0);

    // User deliberately re-applies on top of the latest version: based on seq 1, so it is accepted.
    final (cseq2, _) = c.edit(setPrompt('a', 'mine again'), 3);
    expect(cseq2, 2);
  });

  test('different fields never conflict', () {
    final c = synced('me');
    c.edit(setPrompt('a', 'mine'), 0);
    c.receive(Committed([LogEntry(1, 'bob', 1, 0, SetField('a', const FieldKey.config(['code']), 'x'))]), 1);
    expect(c.drainEvents().whereType<ConflictDetected>(), isEmpty);
    expect(c.view.nodes['a']!.config, {'prompt': 'mine', 'code': 'x'});
  });

  test('S7: remote delete breaks references explicitly and hides pending edits to the node', () {
    final c = synced('me');
    c.edit(SetField('b', const FieldKey.config(['in']), const Ref('a', 'out')), 0);
    c.receive(Committed([LogEntry(1, 'me', 1, 0, SetField('b', const FieldKey.config(['in']), const Ref('a', 'out')))]), 1);
    c.edit(setPrompt('a', 'edit on node about to die'), 2);
    c.receive(Committed([LogEntry(2, 'bob', 1, 1, const RemoveNode('a'))]), 3);
    expect(c.view.nodes.containsKey('a'), isFalse);
    expect(c.view.nodes['b']!.config['in'], isA<BrokenRef>());
    expect(c.view.integrityProblems, isEmpty);
    expect(c.drainEvents().whereType<ConflictDetected>().single.reason.kind, 'nodeDeleted');
  });

  test('S4/S5: buffered out-of-order broadcast, journal restore, lost ops reported', () {
    final c = synced('me');
    c.receive(Committed([LogEntry(2, 'bob', 2, 1, setPrompt('b', '2'))]), 1);
    expect(c.lastSeq, 0); // gap: waits
    c.receive(Committed([LogEntry(1, 'bob', 1, 0, setPrompt('b', '1'))]), 2);
    expect(c.lastSeq, 2);

    c.edit(setPrompt('a', 'x'), 3);
    c.edit(setPrompt('a', 'y'), 3);
    final saved = c.durable;

    // Journaled reload: ops come back and are resent after hello/welcome.
    final r = Client.restoring(saved, journaled: true);
    expect(r.unresolvedCount, 2);
    // Volatile reload: only the cseq range survives, reported lost once the server confirms it never saw them.
    final v = Client.restoring({...saved, 'journal': const <(int, int, Op?)>[]}, journaled: false);
    v.receive(Welcome(head: 2, snapshotDoc: base(), snapshotSeq: 0, entries: [
      LogEntry(1, 'bob', 1, 0, setPrompt('b', '1')),
      LogEntry(2, 'bob', 2, 1, setPrompt('b', '2')),
    ], clientHigh: 2), 5);
    expect(v.drainEvents().whereType<OpLost>().map((e) => e.cseq), [1, 2]);
  });
}
