import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/session_factory.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/nodes_panel/core/harness.dart' show chain, difyNode, difyNodes;

/// One collaborator: its own session on the shared [FakeServer].
class _Client {
  _Client(this.demo, this.opened, this.c);
  final DemoBackend demo;
  final OpenedSession opened;
  final EditorController c;

  Node node(String id) => c.doc.nodes[id]!;
  Map<String, Object?> data(String id) => difyDataOf(node(id));

  Future<void> close() async {
    c.dispose();
    await opened.close();
    await demo.dispose();
  }
}

Future<_Client> _join(WidgetTester t, FakeServer server, String clientId) async {
  final demo = DemoBackend(server: server, withBo: false);
  final opened = await demo.openSession('demo', clientId: clientId, journaled: false);
  await opened.session.start();
  final c = EditorController(session: opened.session, docId: 'demo', journaled: false);
  for (var i = 0; i < 50 && !c.ready; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  return _Client(demo, opened, c);
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 10; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

FakeServer _server() => FakeServer(
  initial: Document(
    nodes: difyNodes([
      difyNode('start', 'start', {
        'variables': [
          {'variable': 'query', 'type': 'text-input'},
        ],
      }),
      difyNode('llm', 'llm', {
        'model': {
          'provider': 'p',
          'name': 'm',
          'mode': 'chat',
          'completion_params': {'temperature': 0.7, 'top_p': 0.9},
        },
        'vision': {'enabled': false},
        'context': {'enabled': false, 'variable_selector': <Object?>[]},
        'prompt_template': [
          {'id': 'a', 'role': 'system', 'text': 'A'},
          {'id': 'b', 'role': 'user', 'text': 'B'},
        ],
      }),
      difyNode('code', 'code', {
        'code': '',
        'variables': [
          {'variable': 'x', 'value_selector': <Object?>[]},
          {'variable': 'y', 'value_selector': <Object?>[]},
        ],
      }),
    ]),
    edges: chain(['start', 'llm', 'code']),
  ),
);

/// The ops committed since [from] (server sequence), as `(op, base)`.
List<(Op, int)> _since(FakeServer s, int from) => [
  for (final e in s.log)
    if (e.seq > from) (e.op, e.base),
];

void main() {
  late FakeServer server;
  setUp(() => server = _server());

  testWidgets('a changed nested member is written alone, at its own path', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final head = server.head;
    final d = a.data('llm');
    final model = d['model']! as Map;
    writeInputs(a.c, 'llm', {
      ...d,
      'model': {
        ...model,
        'completion_params': {...model['completion_params']! as Map, 'temperature': 0.2},
      },
      'vision': {'enabled': true},
    });
    await _settle(t);
    expect(
      [for (final (op, _) in _since(server, head)) op],
      [
        SetField('llm', const ConfigKey(['model', 'completion_params', 'temperature']), Value.number(0.2)),
        SetField('llm', const ConfigKey(['vision', 'enabled']), const VBool(true)),
      ],
    );
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('a map losing a member is written whole, that map only', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final head = server.head;
    final d = a.data('llm');
    final model = d['model']! as Map;
    writeInputs(a.c, 'llm', {
      ...d,
      'model': {
        ...model,
        'completion_params': {'temperature': 0.7},
      },
    });
    await _settle(t);
    final ops = _since(server, head);
    expect(ops, hasLength(1));
    final op = ops.single.$1 as SetField;
    expect(op.field, const ConfigKey(['model', 'completion_params']));
    expect(plainOf(op.value), {'temperature': 0.7});
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('a selector naming an existing output becomes a reference; others stay plain lists', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final head = server.head;
    writeInputs(a.c, 'llm', {
      ...a.data('llm'),
      'context': {
        'enabled': false,
        'variable_selector': ['start', 'query'],
      },
    });
    writeInputs(a.c, 'code', {
      ...a.data('code'),
      'variables': [
        {
          'variable': 'x',
          'value_selector': ['sys', 'query'],
        },
        {
          'variable': 'y',
          'value_selector': ['gone', 'x'],
        },
      ],
    });
    await _settle(t);
    final ops = [for (final (op, _) in _since(server, head)) op];
    expect(
      ops.first,
      SetField('llm', const ConfigKey(['context', 'variable_selector']), VRef(OutputRef('start', 'query'))),
    );
    // The keyed list is edited item by item.
    expect(ops.skip(1).map((o) => o.runtimeType), [UpdateItem, UpdateItem]);
    for (final o in ops.skip(1).cast<UpdateItem>()) {
      expect(jsGet(plainOf(o.value), 'value_selector'), isA<List<Object?>>());
      expect((o.value as VMap).entries['value_selector'], isA<VList>());
    }
    // The unchanged reference keeps its form when the map is written again.
    writeInputs(a.c, 'llm', {
      ...a.data('llm'),
      'context': {
        'enabled': true,
        'variable_selector': ['start', 'query'],
      },
    });
    await _settle(t);
    expect((a.node('llm').config['context']! as VMap).entries['variable_selector'], VRef(OutputRef('start', 'query')));
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('keyed lists: update in place, insert after, remove, move as remove + insert', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final items = (a.node('llm').config['prompt_template']! as VItems).items;
    final head = server.head;
    writeInputs(a.c, 'llm', {
      ...a.data('llm'),
      'prompt_template': [
        {'id': 'a', 'role': 'system', 'text': 'A2'},
        {'id': 'c', 'role': 'user', 'text': 'C'},
        {'id': 'b', 'role': 'user', 'text': 'B'},
      ],
    });
    await _settle(t);
    final ops = [for (final (op, _) in _since(server, head)) op];
    expect(ops, hasLength(2));
    expect((ops[0] as UpdateItem).itemId, items[0].id);
    expect((ops[1] as InsertItem).after, items[0].id);
    expect([for (final p in a.data('llm')['prompt_template']! as List) (p as Map)['text']], ['A2', 'C', 'B']);

    // A removal is one op; a move takes the moved item out and puts it back (the protocol has no move).
    final head2 = server.head;
    writeInputs(a.c, 'llm', {
      ...a.data('llm'),
      'prompt_template': [
        {'id': 'b', 'role': 'user', 'text': 'B'},
        {'id': 'a', 'role': 'system', 'text': 'A2'},
      ],
    });
    await _settle(t);
    expect([for (final (op, _) in _since(server, head2)) op.runtimeType], [RemoveItem, RemoveItem, InsertItem]);
    expect([for (final p in a.data('llm')['prompt_template']! as List) (p as Map)['id']], ['b', 'a']);
    expect((a.node('llm').config['prompt_template']! as VItems).items.first.id, items[1].id);
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('every op carries the base it is given (typed text: the version its typing began on)', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final base = a.c.seenVersion;
    writeInputs(a.c, 'code', {...a.data('code'), 'code': 'x'});
    await _settle(t);
    final head = server.head;
    writeInputs(a.c, 'code', {...a.data('code'), 'code': 'xy'}, base: base);
    await _settle(t);
    expect(_since(server, head).single.$2, base);
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('two clients editing different members of the same map both keep their edit', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final b = await _join(t, server, 'bob-00000001');
    // Both compute their next data from what they see now, before either edit arrives.
    final da = a.data('llm'), db = b.data('llm');
    Map<String, Object?> withParam(Map<String, Object?> d, String k, Object v) {
      final model = d['model']! as Map;
      return {
        ...d,
        'model': {
          ...model,
          'completion_params': {...model['completion_params']! as Map, k: v},
        },
      };
    }

    final shownA = a.node('llm'), shownB = b.node('llm');
    writeInputs(a.c, 'llm', withParam(da, 'temperature', 0.2), shown: shownA, base: a.c.seenVersion);
    writeInputs(b.c, 'llm', withParam(db, 'top_p', 0.5), shown: shownB, base: b.c.seenVersion);
    await _settle(t);
    for (final cl in [a, b]) {
      expect((cl.data('llm')['model']! as Map)['completion_params'], {'temperature': 0.2, 'top_p': 0.5});
    }
    expect(server.doc.nodes['llm'], a.node('llm'));

    // The same member edited by both from the same version: the later write conflicts instead of overwriting.
    final v = a.c.seenVersion;
    writeInputs(a.c, 'llm', withParam(a.data('llm'), 'temperature', 0.3), base: v);
    writeInputs(b.c, 'llm', withParam(b.data('llm'), 'temperature', 0.9), base: v);
    await _settle(t);
    for (final cl in [a, b]) {
      expect(((cl.data('llm')['model']! as Map)['completion_params']! as Map)['temperature'], 0.3);
    }
    await a.close();
    await b.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('a stale next does not undo what others did meanwhile (three-way)', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final b = await _join(t, server, 'bob-00000001');
    final shown = a.node('llm');
    final stale = a.data('llm');
    // Bob turns vision on and adds a prompt; Alice's panel has not rebuilt yet.
    writeInputs(b.c, 'llm', {
      ...b.data('llm'),
      'vision': {'enabled': true},
      'prompt_template': [
        ...b.data('llm')['prompt_template']! as List,
        {'id': 'z', 'role': 'user', 'text': 'Z'},
      ],
    });
    await _settle(t);
    // Alice edits the context from her stale data.
    writeInputs(a.c, 'llm', {
      ...stale,
      'context': {'enabled': true, 'variable_selector': <Object?>[]},
    }, shown: shown);
    await _settle(t);
    final d = a.data('llm');
    expect(d['vision'], {'enabled': true});
    expect([for (final p in d['prompt_template']! as List) (p as Map)['id']], ['a', 'b', 'z']);
    expect((d['context']! as Map)['enabled'], true);
    await a.close();
    await b.close();
    await t.pump(const Duration(seconds: 20));
  });

  testWidgets('writeNodeConfig writes only the nested members that changed', (t) async {
    final a = await _join(t, server, 'alice-000001');
    final head = server.head;
    final orig = a.node('llm');
    final next = Node(
      id: orig.id,
      type: orig.type,
      title: orig.title,
      x: orig.x,
      y: orig.y,
      config: {
        ...orig.config,
        'vision': VMap({...(orig.config['vision']! as VMap).entries, 'enabled': const VBool(true)}),
      },
    );
    writeNodeConfig(a.c, orig, next);
    await _settle(t);
    expect(
      [for (final (op, _) in _since(server, head)) op],
      [
        SetField('llm', const ConfigKey(['vision', 'enabled']), const VBool(true)),
      ],
    );
    await a.close();
    await t.pump(const Duration(seconds: 20));
  });
}
