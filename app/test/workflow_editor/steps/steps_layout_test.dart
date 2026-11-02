// The Steps view's layout (document -> rows): the repo's Dify workflow files and synthetic graphs (linear, IF/ELSE
// with a join, nested IF, question classifier, parallel branches, fail branch, containers, cross-lane links, cycles,
// unconnected nodes, two entries). Every step node appears exactly once.
import 'dart:io';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/cards/dify_cards.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/clipboard.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/steps_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

import 'steps_fixtures.dart';

Object? _plain(Object? y) => switch (y) {
  final YamlMap m => {for (final e in m.entries) '${e.key}': _plain(e.value)},
  final YamlList l => [for (final e in l) _plain(e)],
  _ => y,
};

/// The repo's Dify workflow files (`kind: app`).
List<File> _dslFiles() => [
  for (final dir in const ['../tool/visual/fixtures', '../server/Tests/CollabTests/Fixtures/dify', '../e2e/cases'])
    if (Directory(dir).existsSync())
      for (final f in Directory(dir).listSync().whereType<File>())
        if ((f.path.endsWith('.yml') || f.path.endsWith('.yaml')) && f.readAsStringSync().contains('kind: app')) f,
]..sort((a, b) => a.path.compareTo(b.path));

/// A Dify workflow file as the importer stores it: nodes through [nodeFromDify], edges with Dify's handle names.
/// [_dsl] for other tests in this folder.
Document dslForTest(File f) => _dsl(f);

Document _dsl(File f) {
  final yaml = _plain(loadYaml(f.readAsStringSync()))! as Map<String, Object?>;
  final graph = ((yaml['workflow']! as Map)['graph']! as Map).cast<String, Object?>();
  var doc = Document();
  final nodes = <Node>[];
  for (final n in (graph['nodes']! as List).cast<Map<String, Object?>>()) {
    nodes.add(nodeFromDify(n, doc, id: n['id']! as String));
    doc = Document(nodes: nodes);
  }
  return Document(
    nodes: nodes,
    edges: [
      for (final e in (graph['edges'] as List? ?? const []).cast<Map<String, Object?>>())
        Edge(
          id: e['id']! as String,
          source: e['source']! as String,
          sourceHandle: e['sourceHandle'] as String? ?? 'source',
          target: e['target']! as String,
          targetHandle: e['targetHandle'] as String? ?? 'target',
        ),
    ],
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the repo\'s workflow files', () {
    final files = _dslFiles();

    test('there are enough of them', () => expect(files.length, greaterThanOrEqualTo(20)));

    for (final f in files) {
      test('${f.uri.pathSegments.last}: every step once, rows well formed, handles as the canvas draws them', () {
        final doc = _dsl(f);
        final layout = computeStepsLayout(doc);
        expectWellFormed(doc, layout);
        for (final n in doc.nodes.values) {
          if (isNoteNode(n)) continue;
          expect(
            stepHandlesOf(n),
            const DifyCards().layoutOf(n, doc).sources.keys.toList(),
            reason: '${n.id} (${n.type})',
          );
        }
      });
    }

    test('conditional_hello_branching: IF/ELSE lanes, each to its own end', () {
      final doc = _dsl(File('../tool/visual/fixtures/conditional_hello_branching_workflow.yml'));
      final rows = outline(computeStepsLayout(doc));
      expect(rows.where((r) => r.trim().startsWith('[')), hasLength(2), reason: rows.join('\n'));
      expect(rows.where((r) => r.contains('→')), isEmpty, reason: rows.join('\n'));
    });

    test('loops and iterations put their children in their bodies', () {
      for (final name in const [
        'increment_loop_with_break_condition_workflow.yml',
        'array_iteration_formatting_workflow.yml',
      ]) {
        final doc = _dsl(File('../tool/visual/fixtures/$name'));
        final layout = computeStepsLayout(doc);
        final containers = doc.nodes.values.where((n) => n.type == 'loop' || n.type == 'iteration');
        expect(containers, isNotEmpty, reason: name);
        for (final c in containers) {
          final at = layout.rowOfNode(c.id)!;
          final body = layout.rows.skip(at + 1).takeWhile((r) => r.rails.any((x) => x.ownerId == c.id)).toList();
          expect(body.first.kind, StepRowKind.bodyStart, reason: name);
          final children = doc.nodes.values.where((n) => CanvasChild.parentOf(n) == c.id).map((n) => n.id).toSet();
          expect({for (final r in body) ?r.representedNode}, children, reason: name);
        }
      }
    });
  });

  test('handles as the canvas draws them, for every block type, with and without a fail branch', () {
    final g = Graph()
      ..ifElse('if', ['c1', 'c2'])
      ..classifier('qc', ['k1', 'k2', 'k3'])
      ..add(
        'hi',
        'human-input',
        config: {
          'user_actions': VList([
            VMap({'id': const VString('approve'), 'title': const VString('Approve')}),
          ]),
        },
      );
    for (final type in const [
      'start', 'end', 'answer', 'llm', 'agent', 'code', 'template-transform', 'http-request', 'tool', //
      'knowledge-retrieval', 'parameter-extractor', 'variable-aggregator', 'assigner', 'document-extractor',
      'list-operator', 'iteration', 'loop', 'loop-end', 'trigger-webhook', 'trigger-schedule', 'datasource-empty',
    ]) {
      g
        ..add('n-$type', type)
        ..add('f-$type', type, config: failBranch);
    }
    final doc = g.doc;
    for (final n in doc.nodes.values) {
      expect(stepHandlesOf(n), const DifyCards().layoutOf(n, doc).sources.keys.toList(), reason: n.id);
    }
    expect(stepHandlesOf(doc.nodes['f-code']!), ['source', 'fail-branch']);
    expect(stepHandlesOf(doc.nodes['f-template-transform']!), ['source']);
  });

  group('synthetic graphs', () {
    test('linear: steps with a "+" on each edge and after the last', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('a', 'code')
        ..add('b', 'llm')
        ..add('e', 'end')
        ..chain(['s', 'a', 'b', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s', '+', 'a', '+', 'b', '+', 'e', '+end']);
      final plus = layout.rows[1].insert!.at as InsertOnEdge;
      expect(plus.edgeId, 's-source-a');
      expect((layout.rows.last.insert!.at as InsertAfter).nodeId, 'e');
      expect(layout.rows[layout.rowOfNode('a')!].insert!.at, isA<InsertOnEdge>(), reason: "a's Add step after");
    });

    test('IF/ELSE with a join: two lanes, then one "+" that inserts on every lane\'s edge into the join', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if', ['c1'])
        ..add('a', 'code')
        ..add('b', 'code')
        ..add('j', 'llm')
        ..add('e', 'end')
        ..link('s', 'if')
        ..link('if', 'a', 'c1')
        ..link('if', 'b', 'false')
        ..chain(['a', 'j'])
        ..chain(['b', 'j', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'if',
        '  [c1]',
        '  +',
        '  a',
        '  +',
        '  [false]',
        '  +',
        '  b',
        '  +',
        '+join',
        'j',
        '+',
        'e',
        '+end',
      ]);
      final join = layout.rows[layout.rowOfNode('j')! - 1].insert!;
      expect((join.at as InsertOnEdge).edgeId, 'a-source-j');
      expect(join.retarget, ['b-source-j']);
      expect(layout.rows[layout.rowOfNode('if')!].insert, join, reason: "the IF's Add step after: after the block");
      final lane = layout.rows[layout.rowOfNode('a')! - 2];
      expect((lane.lane, lane.laneIndex, lane.nodeId), (StepLaneKind.ifCase, 0, 'if'));
      // The lane's first "+" adds at the start of the branch, on the edge from its handle.
      expect((layout.rows[layout.rowOfNode('a')! - 1].insert!.at as InsertOnEdge).edgeId, 'if-c1-a');
      // "Add step before": on a step's only incoming edge; none for an entry or a join (two incoming edges).
      expect((layout.rows[layout.rowOfNode('a')!].before!.at as InsertOnEdge).edgeId, 'if-c1-a');
      expect((layout.rows[layout.rowOfNode('e')!].before!.at as InsertOnEdge).edgeId, 'j-source-e');
      expect(layout.rows[layout.rowOfNode('s')!].before, isNull);
      expect(layout.rows[layout.rowOfNode('j')!].before, isNull);
    });

    test('a nested IF in a lane closes at the outer join', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if1', ['c1'])
        ..ifElse('if2', ['d1'])
        ..add('a', 'code')
        ..add('b', 'code')
        ..add('c', 'code')
        ..add('j', 'end')
        ..link('s', 'if1')
        ..link('if1', 'if2', 'c1')
        ..link('if1', 'c', 'false')
        ..link('if2', 'a', 'd1')
        ..link('if2', 'b', 'false')
        ..chain(['a', 'j'])
        ..chain(['b', 'j'])
        ..chain(['c', 'j']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'if1',
        '  [c1]',
        '  +',
        '  if2',
        '    [d1]',
        '    +',
        '    a',
        '    +',
        '    [false]',
        '    +',
        '    b',
        '    +',
        '  [false]',
        '  +',
        '  c',
        '  +',
        '+join',
        'j',
        '+end',
      ]);
      expect(layout.rows[layout.rowOfNode('j')! - 1].insert!.retarget, hasLength(2));
    });

    test('a question classifier with 3 classes; a class straight to the join is an empty lane on that edge', () {
      final g = Graph()
        ..add('s', 'start')
        ..classifier('qc', ['k1', 'k2', 'k3'])
        ..add('a', 'code')
        ..add('b', 'code')
        ..add('e', 'end')
        ..link('s', 'qc')
        ..link('qc', 'a', 'k1')
        ..link('qc', 'b', 'k2')
        ..link('qc', 'e', 'k3')
        ..chain(['a', 'e'])
        ..chain(['b', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'qc',
        '  [k1]',
        '  +',
        '  a',
        '  +',
        '  [k2]',
        '  +',
        '  b',
        '  +',
        '  [k3]',
        '  add',
        '+join',
        'e',
        '+end',
      ]);
      final empty = layout.rows.firstWhere((r) => r.kind == StepRowKind.addStep);
      expect((empty.insert!.at as InsertOnEdge).edgeId, 'qc-k3-e');
      expect(layout.rows.where((r) => r.kind == StepRowKind.laneHeader).map((r) => r.laneIndex), [0, 1, 2]);
    });

    test('an IF/ELSE with an unconnected ELSE: the connected case is a lane (the ELSE ends the run, so no join)', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if', ['c1'])
        ..add('a', 'code')
        ..add('b', 'code')
        ..link('s', 'if')
        ..link('if', 'a', 'c1')
        ..chain(['a', 'b']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s', '+', 'if', '  [c1]', '  +', '  a', '  +', '  b', '  +end', '  [false]', '  add']);
    });

    test('an unconnected IF/ELSE shows its cases as empty lanes that add after their handle', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if', ['c1', 'c2'])
        ..link('s', 'if');
      final layout = computeStepsLayout(g.doc);
      expect(outline(layout), ['s', '+', 'if', '  [c1]', '  add', '  [c2]', '  add', '  [false]', '  add']);
      expect(
        [
          for (final r in layout.rows)
            if (r.kind == StepRowKind.addStep) (r.insert!.at as InsertAfter).sourceHandle,
        ],
        ['c1', 'c2', 'false'],
      );
    });

    test('parallel branches from one handle: PARALLEL lanes until they meet', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('a', 'llm', y: 0)
        ..add('b', 'llm', y: 200)
        ..add('j', 'variable-aggregator')
        ..add('e', 'end')
        ..link('s', 'a')
        ..link('s', 'b')
        ..chain(['a', 'j'])
        ..chain(['b', 'j', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '  [source]',
        '  +',
        '  a',
        '  +',
        '  [source]',
        '  +',
        '  b',
        '  +',
        '+join',
        'j',
        '+',
        'e',
        '+end',
      ]);
      expect(
        layout.rows.where((r) => r.kind == StepRowKind.laneHeader).map((r) => (r.lane, r.laneIndex)),
        [(StepLaneKind.parallel, 0), (StepLaneKind.parallel, 1)],
      );
    });

    test('a fail branch hangs under its node; the normal path goes on; rejoining it is a link', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('h', 'http-request', config: failBranch)
        ..add('h2', 'code', config: failBranch)
        ..add('f', 'answer')
        ..add('n', 'code')
        ..add('e', 'end')
        ..chain(['s', 'h', 'n', 'h2', 'e'])
        ..link('h', 'f', 'fail-branch')
        ..chain(['f', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'h',
        '  [fail-branch]',
        '  +',
        '  f',
        '  +',
        '  → e',
        '+',
        'n',
        '+',
        'h2',
        '  [fail-branch]',
        '  add',
        '+',
        'e',
        '+end',
      ]);
      final empty = layout.rows.firstWhere((r) => r.kind == StepRowKind.addStep);
      expect(
        ((empty.insert!.at as InsertAfter).nodeId, (empty.insert!.at as InsertAfter).sourceHandle),
        (
          'h2',
          'fail-branch',
        ),
      );
    });

    test('a fail branch that ends on its own does not keep the lanes around it from meeting', () {
      final g = Graph()
        ..add('s', 'start')
        ..classifier('qc', ['k1', 'k2'])
        ..add('h', 'http-request', config: failBranch)
        ..add('oops', 'answer')
        ..add('b', 'code')
        ..add('m', 'variable-aggregator')
        ..add('e', 'end')
        ..link('s', 'qc')
        ..link('qc', 'h', 'k1')
        ..link('qc', 'b', 'k2')
        ..link('h', 'oops', 'fail-branch')
        ..chain(['h', 'm'])
        ..chain(['b', 'm', 'e']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'qc',
        '  [k1]',
        '  +',
        '  h',
        '    [fail-branch]',
        '    +',
        '    oops',
        '    +end',
        '  +',
        '  [k2]',
        '  +',
        '  b',
        '  +',
        '+join',
        'm',
        '+',
        'e',
        '+end',
      ]);
    });

    test('iteration and loop: bodies from their start nodes, one level deeper; an empty body adds after its start', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('it', 'iteration')
        ..add('is', 'iteration-start', parent: 'it')
        ..add('x', 'code', parent: 'it')
        ..add('y', 'llm', parent: 'it')
        ..add('lp', 'loop')
        ..add('ls', 'loop-start', parent: 'lp')
        ..add('z', 'code', parent: 'lp')
        ..add('le', 'loop-end', parent: 'lp')
        ..add('it2', 'iteration')
        ..add('is2', 'iteration-start', parent: 'it2')
        ..add('e', 'end')
        ..chain(['s', 'it', 'lp', 'it2', 'e'])
        ..chain(['is', 'x', 'y'])
        ..chain(['ls', 'z', 'le']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'it',
        '  start',
        '  x',
        '  +',
        '  y',
        '  +end',
        '+',
        'lp',
        '  start',
        '  z',
        '  +',
        '  le',
        '+',
        'it2',
        '  start(empty)',
        '+',
        'e',
        '+end',
      ]);
      expect(layout.rows[layout.rowOfNode('is')!].rails.single, const StepRail('it', null, StepLaneKind.body));
      expect((layout.rows[layout.rowOfNode('is2')!].insert!.at as InsertAfter).nodeId, 'is2');
    });

    test('an edge across lanes: the step is shown once, the other lane continues at it', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if', ['c1'])
        ..add('a', 'code', y: 100)
        ..add('x', 'end', y: 100)
        ..add('b', 'code', y: 200)
        ..add('y', 'end', y: 300)
        ..link('s', 'if')
        ..link('if', 'a', 'c1')
        ..link('if', 'b', 'false')
        ..chain(['a', 'x'])
        ..chain(['b', 'y'])
        ..link('b', 'a');
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'if',
        '  [c1]',
        '  +',
        '  a',
        '  +',
        '  x',
        '  +end',
        '  [false]',
        '  +',
        '  b',
        '    [source]',
        '    add',
        '    → a',
        '    [source]',
        '    +',
        '    y',
        '    +end',
      ]);
    });

    test('a second incoming edge from another entry continues at the step', () {
      final g = Graph()
        ..add('s', 'start', y: 0)
        ..add('t', 'trigger-webhook', y: 300)
        ..add('a', 'code')
        ..add('e', 'end')
        ..chain(['s', 'a', 'e'])
        ..link('t', 'a');
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s', '+', 'a', '+', 'e', '+end', '~', 't', '+', '→ a']);
    });

    test('a cycle (the document allows one): the back edge is a link', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('a', 'code')
        ..add('b', 'code')
        ..chain(['s', 'a', 'b', 'a']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s', '+', 'a', '+', 'b', '+', '→ a']);
    });

    test('nodes no entry reaches come last under "Not connected", as flows', () {
      final g = Graph()
        ..add('s', 'start', y: 0)
        ..add('a', 'code', y: 0)
        ..add('x', 'code', y: 100)
        ..add('y', 'llm', y: 100)
        ..add('z', 'answer', y: 200)
        ..add('note', 'custom-note', rfType: 'custom-note')
        ..chain(['s', 'a'])
        ..chain(['x', 'y']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s', '+', 'a', '+end', '-- not connected', 'x', '+', 'y', '+end', '~', 'z', '+end']);
      expect(layout.rowOfNode('note'), isNull, reason: 'notes are not steps');
    });

    test('two Start nodes: two flows, one after the other', () {
      final g = Graph()
        ..add('s1', 'start', y: 0)
        ..add('s2', 'start', y: 400)
        ..add('a', 'code')
        ..add('b', 'code')
        ..chain(['s1', 'a'])
        ..chain(['s2', 'b']);
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), ['s1', '+', 'a', '+end', '~', 's2', '+', 'b', '+end']);
    });

    test('without an entry node the flows start at the nodes nothing leads to (a snippet)', () {
      final g = Graph()
        ..add('a', 'code')
        ..add('b', 'code')
        ..chain(['a', 'b']);
      expect(outline(computeStepsLayout(g.doc)), ['a', '+', 'b', '+end']);
    });

    test('an edge from a handle the node no longer declares is a lane of its own', () {
      final g = Graph()
        ..add('s', 'start')
        ..ifElse('if', ['c1'])
        ..add('a', 'code')
        ..add('b', 'code')
        ..link('s', 'if')
        ..link('if', 'a', 'c1')
        ..link('if', 'b', 'removed-case');
      final layout = computeStepsLayout(g.doc);
      expectWellFormed(g.doc, layout);
      expect(outline(layout), [
        's',
        '+',
        'if',
        '  [c1]',
        '  +',
        '  a',
        '  +end',
        '  [false]',
        '  add',
        '  [removed-case]',
        '  +',
        '  b',
        '  +end',
      ]);
    });

    test('dify-sf\'s own handle names (out/in) are the default handle', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('a', 'code')
        ..link('s', 'a', 'out');
      expect(outline(computeStepsLayout(g.doc)), ['s', '+', 'a', '+end']);
    });

    test('300 nodes: a long chain with branches and containers lays out once each, quickly', () {
      final g = bigGraph(300);
      final watch = Stopwatch()..start();
      final layout = computeStepsLayout(g.doc);
      watch.stop();
      expectWellFormed(g.doc, layout);
      expect(g.doc.nodes.length, greaterThanOrEqualTo(300));
      expect(watch.elapsedMilliseconds, lessThan(1000));
    });
  });

  group('memoised per document revision', () {
    test('moves and title edits reuse the layout; a new edge or a config change computes it again', () {
      final g = Graph()
        ..add('s', 'start')
        ..add('a', 'code')
        ..add('b', 'code')
        ..chain(['s', 'a']);
      final cache = StepsLayoutCache();
      final first = cache.layoutOf(g.doc);
      expect(identical(cache.layoutOf(g.doc), first), isTrue);
      final moved = g.doc.clone()..apply(const MoveNode('a', 50, 50), const Stamp(1, 'x'));
      expect(identical(cache.layoutOf(moved), first), isTrue);
      final titled = moved.clone()..apply(const SetField('a', TitleKey(), VString('A')), const Stamp(2, 'x'));
      expect(identical(cache.layoutOf(titled), first), isTrue);
      expect(cache.computations, 1);
      final linked = titled.clone()
        ..apply(const AddEdge(Edge(id: 'a-b', source: 'a', target: 'b')), const Stamp(3, 'x'));
      final second = cache.layoutOf(linked);
      expect(identical(second, first), isFalse);
      expect(outline(second), ['s', '+', 'a', '+', 'b', '+end']);
      final configured = linked.clone()
        ..apply(const SetField('b', ConfigKey(['code_language']), VString('python3')), const Stamp(4, 'x'));
      cache.layoutOf(configured);
      expect(cache.computations, 3);
    });
  });
}

/// A container's child (the parent named in the node's React Flow extras).
abstract final class CanvasChild {
  static String? parentOf(Node n) => switch (n.config['_dify_node']) {
    VMap(:final entries) => switch (entries['parentId']) {
      VString(:final value) when value.isNotEmpty => value,
      _ => null,
    },
    _ => null,
  };
}
