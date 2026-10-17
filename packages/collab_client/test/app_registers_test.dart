/// Protocol 1.7: document-level registers (`$app`: Dify's environment variables, conversation variables, features).
/// Mirrors `AppRegisterTests` in the server's CoreTests.swift (same cases, same reject messages, same wire bytes).
library;

import 'dart:convert';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

const app = Document.appNode;
const env = ['environment_variables'];

Value variable(String id, String v) => VMap({'id': VString(id), 'name': VString(id), 'value': VString(v)});
Op insVar(String id, {String v = '1', String? after}) => InsertItem(app, env, Item(id, variable(id, v)), after);
Op updVar(String id, String v) => UpdateItem(app, env, id, variable(id, v));

/// The document `AppRegisterTests.fixture` encodes, byte for byte as CollabCore writes it (sorted keys).
const swiftFixture =
    r'{"app":{"environment_variables":{"$items":[{"id":"x","value":{"id":"x","name":"x","value":"1"}}]},'
    r'"features":{"a":true,"b":1}},"deletedEdges":{},"deletedItems":{"y":{"client":"bob","seq":4}},"deletedNodes":{},'
    r'"edges":[],"fieldStamps":[{"client":"alice","field":{"k":"config","path":["features"]},"node":"$app","seq":2},'
    r'{"client":"alice","field":{"id":"x","k":"item","path":["environment_variables"]},"node":"$app","seq":1},'
    r'{"client":"bob","field":{"id":"y","k":"item","path":["environment_variables"]},"node":"$app","seq":4}],'
    r'"nodes":[{"config":{},"id":"a","title":"","type":"llm","x":0,"y":0}],"touches":[]}';

/// JSON with every map's keys sorted (the server's canonical form).
String canonical(Object? json) {
  Object? sort(Object? v) => switch (v) {
    final Map<String, Object?> m => {for (final k in m.keys.toList()..sort()) k: sort(m[k])},
    final List<Object?> l => [for (final x in l) sort(x)],
    _ => v,
  };
  return jsonEncode(sort(json));
}

void main() {
  test('item ops work on the app node', () {
    final d = Document(nodes: [node('a')]);
    expect(d.validate(insVar('x'), base: 0, client: 'alice'), isNull);
    d
      ..apply(insVar('x'), stamp(1, 'alice'))
      ..apply(insVar('y', after: 'x'), stamp(2, 'alice'));
    expect(d.app['environment_variables'], VItems([Item('x', variable('x', '1')), Item('y', variable('y', '1'))]));
    d
      ..apply(updVar('y', '2'), stamp(3, 'bob'))
      ..apply(const RemoveItem(app, env, 'x'), stamp(4, 'bob'));
    expect(d.app['environment_variables'], VItems([Item('y', variable('y', '2'))]));
    expect(d.deletedItems['x'], stamp(4, 'bob'));
    expect(d.fieldStamps[app]![const ItemKey(env, 'y')], stamp(3, 'bob'));
    expect(d.fieldStamps[app]![const ItemKey(env, 'x')], stamp(4, 'bob'));
    expect(d.touches[app], isNull, reason: 'no touches: nothing can delete \$app');
    expect(d.nodes[app], isNull);
    expect(d.validate(updVar('x', '3'), base: 4, client: 'alice'), const ItemDeleted('x'));
    expect(d.validate(insVar('x'), base: 4, client: 'alice'), const ItemExists('x'));
    expect(d.validate(const RemoveItem(app, env, 'x'), base: 0, client: 'alice'), isNull);
    expect(d.validate(updVar('ghost', '3'), base: 4, client: 'alice'), const ItemNotFound('ghost'));
    expect(d.integrityProblems, isEmpty);
  });

  test('config writes work on the app node', () {
    final d = Document();
    const f = SetField(app, ConfigKey(['features', 'opening_statement']), VString('hi'));
    expect(d.validate(f, base: 0, client: 'alice'), isNull);
    d.apply(f, stamp(1, 'alice'));
    expect(d.app['features'], const VMap({'opening_statement': VString('hi')}));
    expect(
      d.validate(const SetField(app, ConfigKey(['features', 'opening_statement', 'x']), VInt(1)), base: 1, client: 'a'),
      isA<Invalid>(),
    );
    expect(
      d.validate(const SetField(app, ConfigKey([r'$k']), VInt(1)), base: 1, client: 'alice'),
      const Invalid('reserved key in path'),
    );
  });

  test('stale writes conflict, different variables do not', () {
    final d = Document()
      ..apply(insVar('x'), stamp(1, 'alice'))
      ..apply(insVar('y'), stamp(2, 'alice'))
      ..apply(updVar('x', 'A'), stamp(3, 'alice'))
      ..apply(const SetField(app, ConfigKey(['features', 'a']), VInt(1)), stamp(4, 'alice'));
    expect(d.validate(updVar('y', 'B'), base: 2, client: 'bob'), isNull);
    const c = Conflict(node: app, field: ItemKey(env, 'x'), seq: 3, by: 'alice');
    expect(d.validate(updVar('x', 'B'), base: 2, client: 'bob'), c);
    expect(d.validate(const RemoveItem(app, env, 'x'), base: 2, client: 'bob'), c);
    // Same-value rule (1.2): no conflict, and a pure no-op.
    expect(d.validate(updVar('x', 'A'), base: 2, client: 'bob'), isNull);
    final before = d.clone();
    d.apply(updVar('x', 'A'), stamp(5, 'bob'));
    expect(d, before);
    // Overlap rules.
    expect(d.validate(const SetField(app, ConfigKey(env), VItems([])), base: 2, client: 'bob'), c);
    expect(
      d.validate(const SetField(app, ConfigKey(['features']), VMap({})), base: 2, client: 'bob'),
      const Conflict(node: app, field: ConfigKey(['features', 'a']), seq: 4, by: 'alice'),
    );
    expect(d.validate(const SetField(app, ConfigKey(['features', 'b']), VInt(2)), base: 2, client: 'bob'), isNull);
    expect(d.validate(updVar('x', 'again'), base: 2, client: 'alice'), isNull, reason: 'own writes never conflict');
    expect(d.validate(insVar('z'), base: 0, client: 'bob'), isNull);
  });

  test('everything else naming the app node is invalid (same messages as the Swift core)', () {
    final d = Document(nodes: [node('a')])..apply(const RemoveNode('a'), stamp(1, 'alice'));
    final d2 = Document(nodes: [node('a'), node('b')]);
    expect(
      d2.validate(const RemoveNode(app), base: 0, client: 'c'),
      const Invalid(r'removeNode is not allowed on $app'),
    );
    expect(
      d2.validate(const MoveNode(app, 1, 1), base: 0, client: 'c'),
      const Invalid(r'moveNode is not allowed on $app'),
    );
    expect(
      d2.validate(const SetField(app, TitleKey(), VString('t')), base: 0, client: 'c'),
      const Invalid(r'title is not allowed on $app'),
    );
    expect(
      d2.validate(
        const AddEdge(Edge(id: 'e', source: app, target: 'a')),
        base: 0,
        client: 'c',
      ),
      const Invalid(r'edge endpoint is not allowed on $app'),
    );
    expect(
      d2.validate(
        const AddEdge(Edge(id: 'e', source: 'a', target: app)),
        base: 0,
        client: 'c',
      ),
      const Invalid(r'edge endpoint is not allowed on $app'),
    );
    expect(
      d2.validate(
        const AddNode(Node(id: app, type: 'llm')),
        base: 0,
        client: 'c',
      ),
      const Invalid(r'node id $app is reserved (ids starting with $)'),
    );
    expect(
      d2.validate(
        const AddNode(Node(id: r'$x', type: 'llm')),
        base: 0,
        client: 'c',
      ),
      const Invalid(r'node id $x is reserved (ids starting with $)'),
    );
    expect(
      d.validate(
        const RestoreNode(Node(id: r'$x', type: 'llm')),
        base: 1,
        client: 'alice',
      ),
      const Invalid(r'node id $x is reserved (ids starting with $)'),
    );
    final r = ref('b');
    expect(
      d2.validate(SetField(app, const ConfigKey(['features', 'r']), r), base: 0, client: 'c'),
      const Invalid(r'references are not allowed in $app'),
    );
    expect(
      d2.validate(InsertItem(app, env, Item('v', VMap({'s': r})), null), base: 0, client: 'c'),
      const Invalid(r'references are not allowed in $app'),
    );
    expect(
      d2.validate(
        const SetField(app, ConfigKey(['features', 'r']), VBroken(OutputRef('b', 'o'))),
        base: 0,
        client: 'c',
      ),
      const Invalid('brokenRef is server-written only'),
    );
    expect(
      d2.validate(const SetField(r'$other', ConfigKey(['p']), VInt(1)), base: 0, client: 'c'),
      const NodeNotFound(r'$other'),
    );
    final d3 = d2.clone()
      ..apply(const SetField(app, TitleKey(), VString('t')), stamp(1, 'c'))
      ..apply(const RemoveNode(app), stamp(2, 'c'))
      ..apply(const AddEdge(Edge(id: 'e', source: app, target: 'a')), stamp(3, 'c'));
    expect(d3, d2);
  });

  test('wire: the op shape, the 1.7 snapshot shape (cross-implementation fixture), stream gating', () {
    expect(
      canonical(insVar('x').toJson()),
      r'{"after":null,"item":{"id":"x","value":{"id":"x","name":"x","value":"1"}},"node":"$app",'
      r'"path":["environment_variables"],"t":"insertItem"}',
    );
    final d = Document(nodes: [node('a')]);
    expect(jsonEncode(d.toJson()), isNot(contains('"app"')), reason: 'without app registers: the 1.6 shape');
    d
      ..apply(insVar('x'), stamp(1, 'alice'))
      ..apply(const SetField(app, ConfigKey(['features']), VMap({'b': VInt(1), 'a': VBool(true)})), stamp(2, 'alice'))
      ..apply(insVar('y'), stamp(3, 'alice'))
      ..apply(const RemoveItem(app, env, 'y'), stamp(4, 'bob'));
    expect(canonical(d.toJson()), swiftFixture);
    expect(Document.fromJson(jsonDecode(swiftFixture)), d);
    expect(Document.fromJson(jsonDecode(jsonEncode(d.toJson()))), d);
    expect(
      () => Document.fromJson(
        jsonDecode(
          '{"nodes":[],"edges":[],"app":[],"deletedNodes":{},"deletedEdges":{},"deletedItems":{},"fieldStamps":[],'
          '"touches":[]}',
        ),
      ),
      throwsFormatException,
    );
    expect(insVar('x').touchesApp && updVar('x', '1').touchesApp && const RemoveItem(app, env, 'x').touchesApp, isTrue);
    expect(const SetField(app, ConfigKey(['f']), VInt(1)).touchesApp, isTrue);
    expect(setStr('a', ['p'], 'x').touchesApp, isFalse);
    expect(StreamCompat.streamCarries(insVar('x'), '1.7') && StreamCompat.streamCarries(insVar('x'), '2.0'), isTrue);
    expect(StreamCompat.streamCarries(insVar('x'), '1.6') || StreamCompat.streamCarries(insVar('x'), null), isFalse);
    expect(StreamCompat.streamCarries(setStr('a', ['p'], 'x'), '1.6'), isTrue);
    expect(StreamCompat.streamCarries(const RestoreNode(Node(id: 'a', type: 'llm')), null), isFalse);
    expect(StreamCompat.parse('1.6'), (1, 6));
    expect(StreamCompat.parse('1.6.1') ?? StreamCompat.parse('1.') ?? StreamCompat.parse('-1.6'), isNull);
    expect(protocolVersion, '1.7');
  });

  test("the mask is Dify's formatSecret, like the server's", () {
    expect(AppRegisters.maskSecret('123456789'), '123456************89');
    expect(AppRegisters.maskSecret('sk-not-for-clients'), 'sk-not************ts');
    expect(AppRegisters.maskSecret('12345678'), '*' * 20);
    expect(AppRegisters.maskSecret(''), '*' * 20);
  });

  test('fake server: secrets are stored aside; older streams get a snapshot instead of an \$app commit', () {
    final server = FakeServer(initial: baseDoc());
    final (:ref, :masked) = server.storeSecret('sk-typed-in-the-panel');
    expect(ref, matches(RegExp(r'^sec-[0-9a-f]{32}$')));
    expect(masked, 'sk-typ************el');
    expect(server.secrets[ref], 'sk-typed-in-the-panel');
    final item = Item(
      'e1',
      VMap({
        'id': const VString('e1'),
        'value': VString(masked),
        'value_type': const VString('secret'),
        'secret_ref': VString(ref),
      }),
    );
    final r = server.submit(
      SubmitRequest(
        client: 'alice',
        ops: [
          OutgoingOp(cseq: 1, base: 0, op: setPrompt('a', 'x')),
          OutgoingOp(cseq: 2, base: 0, op: InsertItem(app, env, item, null)),
        ],
      ),
    );
    expect([for (final x in r.results) (x as AckResult).seq], [1, 2]);
    expect(jsonEncode(server.doc.toJson()), isNot(contains('sk-typed-in-the-panel')));
    // 1.7 replays; 1.6 and older get a snapshot when the range holds the $app write, a replay otherwise.
    expect(server.catchUp(lastEventId: 0).first, isA<CommitEvent>());
    expect(server.catchUp(lastEventId: 0, proto: '1.6').first, isA<SnapshotEvent>());
    expect(server.catchUp(lastEventId: 0, proto: null).first, isA<SnapshotEvent>());
    expect(server.catchUp(lastEventId: 2, proto: '1.6').first, isA<ReadyEvent>());
  });
}
