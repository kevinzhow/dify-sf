/// Protocol 1.6: restoring a deleted node (undo of a delete). Mirrors `RestoreTests` in the server's CoreTests.swift.
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

Value broken(String n, [String o = 'o']) => VBroken(OutputRef(n, o));
Item out(String id, String name) => Item(id, VMap({'name': VString(name)}));

/// a <- b (b.in refs a), edge a->b, c unrelated; alice deletes a at seq 5.
(Document, Node, List<Edge>) deleted() {
  final a = node('a', {'p': const VString('x')});
  const e = Edge(id: 'e', source: 'a', target: 'b');
  final d = Document(
    nodes: [
      a,
      node('b', {'in': ref('a')}),
      node('c'),
    ],
    edges: [
      e,
      const Edge(id: 'f', source: 'b', target: 'c'),
    ],
  )..apply(const RemoveNode('a'), stamp(5, 'alice'));
  return (d, a, [e]);
}

void main() {
  test('a restore undoes the delete: node, edges, references, and it versions what it wrote', () {
    final (d, a, es) = deleted();
    expect(
      d.validate(RestoreNode(a, es), base: 4, client: 'alice'),
      isNull,
      reason: 'own delete: the base may predate it',
    );
    d.apply(RestoreNode(a, es), stamp(6, 'alice'));
    expect(d.nodes['a'], a);
    expect(d.deletedNodes.containsKey('a'), isFalse);
    expect(d.edges['e'], es.single);
    expect(d.deletedEdges.containsKey('e'), isFalse);
    expect(d.nodes['b']!.config['in'], ref('a'));
    expect(d.integrityProblems, isEmpty);
    expect(d.fieldStamps['a']![const TitleKey()], stamp(6, 'alice'));
    expect(d.fieldStamps['a']![const ConfigKey([])], stamp(6, 'alice'));
    expect(d.fieldStamps['b']![const ConfigKey(['in'])], stamp(6, 'alice'));
    expect(d.touches['a']!['alice'], 6);
    expect(d.touches['b']!['alice'], 6);
    expect(d.validate(RestoreNode(a), base: 6, client: 'alice'), const NodeExists('a'));
  });

  test('refusals', () {
    final (d, a, es) = deleted();
    expect(d.validate(RestoreNode(node('ghost')), base: 5, client: 'x'), const NodeNotFound('ghost'));
    expect(d.validate(RestoreNode(node('b')), base: 5, client: 'x'), const NodeExists('b'));
    expect(
      d.validate(RestoreNode(a, es), base: 4, client: 'bob'),
      const Conflict(node: 'a', field: null, seq: 5, by: 'alice'),
      reason: 'someone else deleted it after the base',
    );
    expect(
      d.validate(RestoreNode(a, es), base: 5, client: 'bob'),
      isNull,
      reason: 'having seen the delete, anyone may',
    );
    expect(d.validate(RestoreNode(a, [...es, ...es]), base: 5, client: 'alice'), const Invalid('edge e listed twice'));
    expect(
      d.validate(
        RestoreNode(a, const [Edge(id: 'f', source: 'b', target: 'c')]),
        base: 5,
        client: 'alice',
      ),
      const Invalid('edge f does not touch node a'),
    );
    expect(
      d.validate(RestoreNode(node('a', {r'$x': const VInt(1)})), base: 5, client: 'alice'),
      const Invalid(r'config key $x is reserved'),
    );
  });

  test('a restore conflicts with an unseen write to a field it would revive', () {
    final d =
        Document(
            nodes: [
              node('a'),
              node('b', {
                'in': VList([ref('a'), ref('c')]),
              }),
              node('c'),
            ],
          )
          ..apply(const RemoveNode('a'), stamp(5, 'alice'))
          ..apply(const RemoveNode('c'), stamp(6, 'bob')); // rewrites b.in again
    expect(
      d.validate(RestoreNode(node('a')), base: 5, client: 'alice'),
      const Conflict(node: 'b', field: ConfigKey(['in']), seq: 6, by: 'bob'),
    );
    expect(d.validate(RestoreNode(node('a')), base: 6, client: 'alice'), isNull);
    d.apply(RestoreNode(node('a')), stamp(7, 'alice'));
    expect(d.nodes['b']!.config['in'], VList([ref('a'), broken('c')]));
  });

  test('a write based on a version before the restore is stale', () {
    final (d, a, es) = deleted();
    d.apply(RestoreNode(a, es), stamp(6, 'alice'));
    expect(
      d.validate(setStr('a', ['p'], 'y'), base: 4, client: 'carol'),
      const Conflict(node: 'a', field: ConfigKey([]), seq: 6, by: 'alice'),
    );
    expect(d.validate(setStr('a', ['new'], 'y'), base: 4, client: 'carol'), isA<Conflict>());
    expect(d.validate(const SetField('a', TitleKey(), VString('t')), base: 4, client: 'carol'), isA<Conflict>());
    expect(
      d.validate(const RemoveNode('a'), base: 4, client: 'carol'),
      const Conflict(node: 'a', field: null, seq: 6, by: 'alice'),
    );
    expect(d.validate(setStr('a', ['p'], 'x'), base: 4, client: 'carol'), isNull, reason: 'same value');
    expect(d.validate(setStr('a', ['p'], 'y'), base: 6, client: 'carol'), isNull, reason: 'saw the restore');
    expect(d.validate(const MoveNode('a', 9, 9), base: 0, client: 'carol'), isNull, reason: 'layout is never stale');
  });

  test('edges that cannot come back are skipped, the rest of the restore holds', () {
    final (d, a, es) = deleted();
    d.apply(const RemoveNode('b'), stamp(6, 'bob')); // the other end of e is gone now
    const fresh = Edge(id: 'g', source: 'a', target: 'c'); // an id the delete did not remove
    expect(d.validate(RestoreNode(a, [...es, fresh]), base: 6, client: 'alice'), isNull);
    d.apply(RestoreNode(a, [...es, fresh]), stamp(7, 'alice'));
    expect(d.nodes.containsKey('a'), isTrue);
    expect(d.edges, isEmpty);
    expect(d.deletedEdges['e'], stamp(5, 'alice'));
    expect(d.integrityProblems, isEmpty);
  });

  test('restored references are live exactly when their target is there', () {
    final d =
        Document(
            nodes: [
              node('a'),
              node('b'),
              node('x', {
                'outputs': VItems([out('i1', 'r')]),
              }),
            ],
          )
          ..apply(const RemoveNode('a'), stamp(1, 'alice'))
          ..apply(const RemoveNode('b'), stamp(2, 'alice'));
    final a = node('a', {
      'b': ref('b'),
      'x': ref('x', 'r'),
      'old': broken('x', 'r'),
      'gone': ref('x', 'gone'),
      'me': ref('a'),
    });
    d.apply(RestoreNode(a), stamp(3, 'alice'));
    final cfg = d.nodes['a']!.config;
    expect(cfg['b'], broken('b'));
    expect(cfg['x'], ref('x', 'r'));
    expect(cfg['old'], ref('x', 'r'));
    expect(cfg['gone'], broken('x', 'gone'));
    expect(cfg['me'], ref('a'));
    expect(d.integrityProblems, isEmpty);
  });

  test('only declared outputs are revived in other nodes', () {
    final d =
        Document(
            nodes: [
              node('a', {
                'outputs': VItems([out('i1', 'r'), out('i2', 's')]),
              }),
              node('b', {'r': ref('a', 'r'), 's': ref('a', 's')}),
            ],
          )
          ..apply(const RemoveItem('a', ['outputs'], 'i2'), stamp(1, 'alice')) // b.s breaks
          ..apply(const RemoveNode('a'), stamp(2, 'alice')) // b.r breaks
          ..apply(
            RestoreNode(
              node('a', {
                'outputs': VItems([out('i1', 'r')]),
              }),
            ),
            stamp(3, 'alice'),
          );
    expect(d.nodes['b']!.config['r'], ref('a', 'r'));
    expect(d.nodes['b']!.config['s'], broken('a', 's'));
    expect(d.integrityProblems, isEmpty);
  });

  test('wire: the op shape the server writes, edges optional, and a restored document keeps the 1.5 shape', () {
    // Byte for byte what CollabCore encodes (WireTests / RestoreTests.wireShape).
    const swift =
        '{"edges":[{"id":"e","source":"n","sourceHandle":"out","target":"m","targetHandle":"in"}],'
        '"node":{"config":{"r":{"\$broken":{"node":"m","output":"o"}}},"id":"n","title":"t","type":"llm","x":1,"y":2},'
        '"t":"restoreNode"}';
    final op = RestoreNode(
      Node(id: 'n', type: 'llm', title: 't', x: 1, y: 2, config: {'r': broken('m')}),
      const [Edge(id: 'e', source: 'n', target: 'm')],
    );
    expect(Op.fromJson(jsonDecode(swift)), op);
    expect(Op.fromJson(jsonDecode(jsonEncode(op.toJson()))), op);
    expect(
      Op.fromJson(jsonDecode('{"t":"restoreNode","node":{"id":"n","type":"llm","title":"","x":0,"y":0,"config":{}}}')),
      const RestoreNode(Node(id: 'n', type: 'llm')),
    );
    final (d, a, es) = deleted();
    d.apply(RestoreNode(a, es), stamp(6, 'alice'));
    expect(
      jsonEncode(d.toJson()),
      contains('{"node":"a","field":{"k":"config","path":[]},"seq":6,"client":"alice"}'),
    );
    expect(Document.fromJson(jsonDecode(jsonEncode(d.toJson()))), d);
  });

  test('a client applies a restore committed by someone else, and its pending stale edit is flagged early', () {
    // The machine replays committed entries with validate(checkConflicts: false) + apply: same result as the server.
    final (d, a, es) = deleted();
    final replica = d.clone();
    expect(replica.validate(RestoreNode(a, es), base: 5, client: 'alice', checkConflicts: false), isNull);
    replica.apply(RestoreNode(a, es), stamp(6, 'alice'));
    d.apply(RestoreNode(a, es), stamp(6, 'alice'));
    expect(replica, d);
    expect(replica.validate(setStr('a', ['p'], 'mine'), base: 4, client: 'carol')!.isStaleBased, isTrue);
  });
}
