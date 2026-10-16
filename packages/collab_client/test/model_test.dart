import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

void main() {
  group('document rules', () {
    test('a stale write is refused, the newer value kept', () {
      final d = Document(nodes: [node('a')])..apply(setPrompt('a', 'new'), stamp(5, 'bob'));
      expect(d.validate(setPrompt('a', 'old'), base: 3, client: 'alice'), isA<Conflict>());
      expect(d.validate(setPrompt('a', 'ok'), base: 5, client: 'alice'), isNull);
      // Bob is never in conflict with his own earlier write.
      expect(d.validate(setPrompt('a', 'again'), base: 3, client: 'bob'), isNull);
      // A different field never conflicts.
      expect(d.validate(setStr('a', ['code'], 'x'), base: 3, client: 'alice'), isNull);
      final c = d.validate(setPrompt('a', 'old'), base: 3, client: 'alice')! as Conflict;
      expect((c.node, c.seq, c.by), ('a', 5, 'bob'));
      expect(c.field, const ConfigKey(['prompt']));
    });

    test('a stale write of the current value is accepted and changes nothing', () {
      final d = Document(nodes: [node('a')])..apply(setPrompt('a', 'same'), stamp(5, 'bob'));
      expect(d.validate(setPrompt('a', 'same'), base: 3, client: 'alice'), isNull);
      // No-op: must not re-stamp the register (a reader of version 5 is not made stale by it).
      final e = d.clone()..apply(setPrompt('a', 'same'), stamp(9, 'alice'));
      expect(e, d);
      expect(e.validate(setPrompt('a', 'next'), base: 5, client: 'carol'), isNull);
      // Titles follow the same rule.
      d.apply(const SetField('a', TitleKey(), VString('T')), stamp(6, 'bob'));
      expect(d.validate(const SetField('a', TitleKey(), VString('T')), base: 0, client: 'alice'), isNull);
      expect(d.validate(const SetField('a', TitleKey(), VString('U')), base: 0, client: 'alice'), isA<Conflict>());
    });

    test('regression (formal model, REPORT 5.3): an accepted equal-value stale write takes no stamp, so it cannot '
        'exempt the same client\'s next write', () {
      // c1 sends f1:=v1 then f1:=v2 (both base 0); c2's f1:=v1 is sequenced first.
      final d = Document(nodes: [node('a')])..apply(setPrompt('a', 'v1'), stamp(1, 'c2'));
      final first = setPrompt('a', 'v1');
      final second = setPrompt('a', 'v2');
      expect(d.validate(first, base: 0, client: 'c1'), isNull, reason: 'equal value: accepted');
      d.apply(first, stamp(2, 'c1'));
      expect(
        d.fieldStamps['a']![const ConfigKey(['prompt'])],
        stamp(1, 'c2'),
        reason: 'stamp stays the earlier writer\'s',
      );
      expect(d.touches['a'], {'c2': 1}, reason: 'and c1 is not "touched" either');
      expect(d.validate(second, base: 0, client: 'c1'), isA<Conflict>().having((c) => c.by, 'by', 'c2'));
      // The same holds for titles, list items and removing an already removed item.
      d.apply(const SetField('a', TitleKey(), VString('T')), stamp(3, 'c2'));
      d.apply(const SetField('a', TitleKey(), VString('T')), stamp(4, 'c1'));
      expect(d.validate(const SetField('a', TitleKey(), VString('U')), base: 0, client: 'c1'), isA<Conflict>());
      d
        ..apply(ins('a', 'x'), stamp(5, 'c2'))
        ..apply(const UpdateItem('a', ['outs'], 'x', VString('x')), stamp(6, 'c1')); // equal value
      expect(d.validate(const UpdateItem('a', ['outs'], 'x', VString('y')), base: 0, client: 'c1'), isA<Conflict>());
      d
        ..apply(const RemoveItem('a', ['outs'], 'x'), stamp(7, 'c2'))
        ..apply(const RemoveItem('a', ['outs'], 'x'), stamp(8, 'c1')); // already removed
      expect(d.deletedItems['x'], stamp(7, 'c2'));
      expect(d.fieldStamps['a']![const ItemKey(['outs'], 'x')], stamp(7, 'c2'));
    });

    test('overlapping paths conflict, siblings do not', () {
      final d = Document(nodes: [node('a')])..apply(setStr('a', ['model', 'name'], 'x'), stamp(2, 'bob'));
      expect(d.validate(setStr('a', ['model'], 'y'), base: 1, client: 'alice'), isA<Conflict>());
      expect(d.validate(setStr('a', ['model', 'name', 'deep'], 'y'), base: 1, client: 'alice'), isNotNull);
      expect(d.validate(setStr('a', ['model', 'temp'], 'y'), base: 1, client: 'alice'), isNull);
    });

    test('moves are last-writer-wins and never stale; a drag does not block a delete', () {
      final d = Document(nodes: [node('a')])..apply(const MoveNode('a', 1, 1), stamp(5, 'bob'));
      expect(d.validate(const MoveNode('a', 2, 2), base: 0, client: 'alice'), isNull);
      d.apply(const MoveNode('a', 2, 2), stamp(6, 'alice'));
      expect(d.nodes['a']!.x, 2);
      expect(d.validate(const RemoveNode('a'), base: 0, client: 'carol'), isNull);
    });

    test('deleting a node breaks references explicitly and removes its edges', () {
      final r = ref('a');
      final d = Document(
        nodes: [
          node('a'),
          node('b', {
            'in': r,
            'deep': VMap({
              'l': VList([r, const VInt(1)]),
            }),
            'items': VItems([Item('i', r)]),
          }),
        ],
        edges: const [
          Edge(id: 'e', source: 'a', target: 'b'),
        ],
      )..apply(const RemoveNode('a'), stamp(1, 'x'));
      const broken = OutputRef('a', 'o');
      expect(d.nodes['b']!.config['in'], const VBroken(broken));
      expect(d.nodes['b']!.config['items'], const VItems([Item('i', VBroken(broken))]));
      expect(
        d.nodes['b']!.config['deep'],
        const VMap({
          'l': VList([VBroken(broken), VInt(1)]),
        }),
      );
      expect(d.edges, isEmpty);
      expect(d.integrityProblems, isEmpty);
      expect(d.deletedNodes.containsKey('a'), isTrue);
      expect(d.deletedEdges.containsKey('e'), isTrue);
      expect(d.referencesTo('a').map((r) => (r.node, r.broken)), [('b', true), ('b', true), ('b', true)]);
    });

    test('dangling and broken references cannot be written', () {
      final d = Document(nodes: [node('a')]);
      expect(
        d.validate(SetField('a', const ConfigKey(['r']), ref('ghost')), base: 0, client: 'x'),
        isA<DanglingReference>(),
      );
      expect(
        d.validate(const SetField('a', ConfigKey(['r']), VBroken(OutputRef('a', 'o'))), base: 0, client: 'x'),
        isA<Invalid>(),
      );
    });

    test('ids are never reused', () {
      final d = Document(nodes: [node('a')])..apply(const RemoveNode('a'), stamp(1, 'x'));
      expect(d.validate(AddNode(node('a')), base: 1, client: 'x'), const NodeExists('a'));
      expect(d.validate(setPrompt('a', 'x'), base: 1, client: 'x'), const NodeDeleted('a'));
      expect(d.validate(setPrompt('zzz', 'x'), base: 1, client: 'x'), const NodeNotFound('zzz'));
    });

    test('deleting conflicts with an unseen write to a field that references the node', () {
      final d = baseDoc()..apply(SetField('b', const ConfigKey(['in']), ref('a')), stamp(4, 'bob'));
      expect(d.validate(const RemoveNode('a'), base: 3, client: 'alice'), isA<Conflict>());
      expect(d.validate(const RemoveNode('a'), base: 4, client: 'alice'), isNull);
    });

    test('deleting conflicts with any unseen content change of the node, not with a move', () {
      final d = baseDoc()
        ..apply(const MoveNode('a', 9, 9), stamp(2, 'bob'))
        ..apply(setPrompt('a', 'x'), stamp(3, 'bob'));
      final c = d.validate(const RemoveNode('a'), base: 1, client: 'alice')! as Conflict;
      expect(c.field, isNull);
      expect(c.by, 'bob');
    });

    test('edges: endpoints must exist, duplicates and ids are checked', () {
      final d = baseDoc()..apply(const AddEdge(Edge(id: 'e1', source: 'a', target: 'b')), stamp(1, 'x'));
      expect(
        d.validate(
          const AddEdge(Edge(id: 'e2', source: 'a', target: 'b')),
          base: 1,
          client: 'y',
        ),
        const DuplicateEdge('e1'),
      );
      expect(
        d.validate(
          const AddEdge(Edge(id: 'e1', source: 'b', target: 'a')),
          base: 1,
          client: 'y',
        ),
        const EdgeExists('e1'),
      );
      expect(
        d.validate(
          const AddEdge(Edge(id: 'e3', source: 'a', target: 'zz')),
          base: 1,
          client: 'y',
        ),
        const NodeNotFound('zz'),
      );
      expect(d.validate(const RemoveEdge('nope'), base: 1, client: 'y'), const EdgeNotFound('nope'));
      d.apply(const RemoveEdge('e1'), stamp(2, 'x'));
      expect(
        d.validate(
          const AddEdge(Edge(id: 'e1', source: 'a', target: 'b')),
          base: 2,
          client: 'y',
        ),
        const EdgeExists('e1'),
      );
    });
  });

  group('keyed lists', () {
    test('different items never conflict, the same item does', () {
      final d = Document(nodes: [node('a')])..apply(ins('a', 'x'), stamp(1, 'bob'));
      expect(d.validate(ins('a', 'y'), base: 0, client: 'alice'), isNull);
      d.apply(ins('a', 'y'), stamp(2, 'alice'));
      expect(d.validate(const UpdateItem('a', ['outs'], 'y', VInt(1)), base: 0, client: 'alice'), isNull);
      expect(d.validate(const UpdateItem('a', ['outs'], 'x', VInt(2)), base: 0, client: 'carol'), isA<Conflict>());
    });

    test('insert order follows the anchor; a missing anchor appends', () {
      final d = Document(nodes: [node('a')])
        ..apply(ins('a', '1'), stamp(1, 'x'))
        ..apply(ins('a', '2', after: '1'), stamp(2, 'x'))
        ..apply(ins('a', '3', after: '1'), stamp(3, 'y')) // concurrent insert after the same anchor
        ..apply(ins('a', '0'), stamp(4, 'y')); // at the front
      expect(outIds(d, 'a'), ['0', '1', '3', '2']);
      d
        ..apply(const RemoveItem('a', ['outs'], '1'), stamp(5, 'x'))
        ..apply(ins('a', '9', after: '1'), stamp(6, 'y')); // anchor gone: append
      expect(outIds(d, 'a'), ['0', '3', '2', '9']);
    });

    test('remove and update rules', () {
      final d = Document(nodes: [node('a')])
        ..apply(ins('a', 'x'), stamp(1, 'bob'))
        ..apply(const RemoveItem('a', ['outs'], 'x'), stamp(2, 'bob'));
      // Removing again: the intended end state holds already, success.
      expect(d.validate(const RemoveItem('a', ['outs'], 'x'), base: 0, client: 'alice'), isNull);
      expect(
        d.validate(const UpdateItem('a', ['outs'], 'x', VInt(1)), base: 2, client: 'alice'),
        const ItemDeleted('x'),
      );
      expect(d.validate(const RemoveItem('a', ['outs'], 'nope'), base: 2, client: 'alice'), const ItemNotFound('nope'));
      expect(d.validate(ins('a', 'x'), base: 2, client: 'alice'), const ItemExists('x'));
    });

    test('a whole-list replace is stale-protected against item inserts', () {
      final d = Document(nodes: [node('a')])..apply(ins('a', 'x'), stamp(1, 'bob'));
      expect(
        d.validate(const SetField('a', ConfigKey(['outs']), VItems([])), base: 0, client: 'alice'),
        isA<Conflict>(),
      );
    });

    test('rewriting an ancestor prunes the stamps of its descendants', () {
      final d = Document(nodes: [node('a')])
        ..apply(ins('a', 'x'), stamp(1, 'bob'))
        ..apply(const SetField('a', ConfigKey(['outs']), VItems([])), stamp(2, 'bob'));
      // Rewriting an ancestor prunes descendant stamps.
      expect(d.fieldStamps['a']!.keys, [
        const ConfigKey(['outs']),
      ]);
    });
  });

  group('wire format', () {
    test('values use natural JSON', () {
      final v = VMap({
        'a': const VInt(1),
        'b': const VList([VNull(), VBool(true), VString('s')]),
        'r': ref('n'),
        'i': const VItems([Item('x', VInt(2))]),
      });
      expect(
        jsonEncode(canonical(v.toJson())),
        r'{"a":1,"b":[null,true,"s"],"i":{"$items":[{"id":"x","value":2}]},"r":{"$ref":{"node":"n","output":"o"}}}',
      );
      expect(Value.fromJson(jsonDecode(jsonEncode(v.toJson()))), v);
      expect(() => Value.fromJson(jsonDecode('1.5')), throwsFormatException);
      expect(() => Value.fromJson(jsonDecode(r'{"$weird":1}')), throwsFormatException);
    });

    test('ops round trip and have a stable shape', () {
      final ops = <Op>[
        const AddNode(Node(id: 'n', type: 'llm', title: 't', x: 1, y: 2, config: {'p': VString('x')})),
        const RemoveNode('n'),
        const MoveNode('n', 3, 4),
        const SetField('n', TitleKey(), VString('t')),
        const SetField('n', ConfigKey(['a', 'b']), VInt(1)),
        const AddEdge(Edge(id: 'e', source: 'a', target: 'b')),
        const RemoveEdge('e'),
        ins('n', 'i', after: 'j'),
        ins('n', 'k'),
        const RemoveItem('n', ['outs'], 'i'),
        const UpdateItem('n', ['outs'], 'i', VNull()),
      ];
      for (final op in ops) {
        expect(Op.fromJson(jsonDecode(jsonEncode(op.toJson()))), op);
      }
      expect(jsonEncode(canonical(const MoveNode('n', 3, 4).toJson())), '{"node":"n","t":"moveNode","x":3,"y":4}');
      expect(
        jsonEncode(canonical(ins('n', 'i').toJson())),
        '{"after":null,"item":{"id":"i","value":"i"},"node":"n","path":["outs"],"t":"insertItem"}',
      );
    });

    test('reject reasons round trip', () {
      final reasons = <RejectReason>[
        const Conflict(node: 'n', field: ItemKey(['outs'], 'i'), seq: 3, by: 'c'),
        const Conflict(node: 'n', field: null, seq: 3, by: 'c'),
        const NodeDeleted('n'),
        const NodeNotFound('n'),
        const NodeExists('n'),
        const EdgeNotFound('e'),
        const EdgeExists('e'),
        const DuplicateEdge('e'),
        const DanglingReference('n'),
        const ItemNotFound('i'),
        const ItemDeleted('i'),
        const ItemExists('i'),
        const Invalid('why'),
        const NotCommitted(),
        const ClientIdInUse(),
      ];
      for (final r in reasons) {
        expect(RejectReason.fromJson(jsonDecode(jsonEncode(r.toJson()))), r);
      }
    });

    test('document snapshots keep stamps and are encoded deterministically', () {
      final d = Document(nodes: [node('a'), node('b')])
        ..apply(setStr('a', ['p'], 'v'), stamp(1, 'c'))
        ..apply(ins('a', 'i'), stamp(2, 'c'))
        ..apply(const RemoveItem('a', ['outs'], 'i'), stamp(3, 'd'))
        ..apply(const AddEdge(Edge(id: 'e', source: 'a', target: 'b')), stamp(4, 'd'))
        ..apply(const RemoveNode('b'), stamp(5, 'd'));
      final back = Document.fromJson(jsonDecode(jsonEncode(d.toJson())));
      expect(back, d);
      expect(jsonEncode(back.toJson()), jsonEncode(d.toJson()));
    });

    test('the example template matches the documented shape', () {
      final d = Templates.example();
      expect(d.nodes.keys.toSet(), {'start', 'llm', 'code', 'answer'});
      expect(d.edges.length, 3);
      expect(d.integrityProblems, isEmpty);
      expect(d.nodes['code']!.config['outputs'], isA<VItems>());
    });

    test('stream events parse', () {
      const e = LogEntry(seq: 7, client: 'c', cseq: 2, base: 5, op: RemoveEdge('e'));
      final parsed = StreamEvent.parse('commit', jsonEncode(e.toJson()))! as CommitEvent;
      expect(parsed.entry, e);
      expect((StreamEvent.parse('ready', '{"head":3}')! as ReadyEvent).head, 3);
      final snap =
          StreamEvent.parse(
                'snapshot',
                jsonEncode({
                  'seq': 4,
                  'doc': Templates.example().toJson(),
                  'committed': {'2': 3},
                }),
              )!
              as SnapshotEvent;
      expect(snap.seq, 4);
      expect(snap.committed, {2: 3});
      expect(StreamEvent.parse('future-event', '{}'), isNull);
    });
  });
}

/// Recursively sorts map keys (the server's canonical output) so strings can be compared.
Object? canonical(Object? j) => switch (j) {
  final Map<String, Object?> m => {for (final k in m.keys.toList()..sort()) k: canonical(m[k])},
  final List<Object?> l => [for (final x in l) canonical(x)],
  _ => j,
};
