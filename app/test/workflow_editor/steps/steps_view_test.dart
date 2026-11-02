// The Steps view (WorkflowStepsView) at 411x914 with gesture-navigation insets: cards, the panel opener, "+"
// insertion through the canvas's operations (one undo step each), the long-press sheet, "continues at", live updates,
// run and checklist markers, read-only, a 300-step workflow, and the standalone preview.
import 'dart:math';

import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/canvas/run_view.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart' show HistoryEvent;
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/context_menu/context_menu.dart';
import 'package:dify_sf_app/src/workflow_editor/node_insertion/insert_block.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/step_insert.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/steps_layout.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';

import '../../../tool/steps_view_preview_main.dart';
import '../../dify_spec/dify_ui/phone_harness.dart';
import '../../dify_spec/workflow/context_menu/harness.dart' as h;
import '../../support/app_fonts.dart';
import 'steps_fixtures.dart';

const _toolbar = 60.0;

Future<h.Harness> _start(WidgetTester t, Document doc) async {
  await t.runAsync(() => DifyI18n.load('en-US'));
  await useAppFonts();
  return h.Harness.start(t, doc.nodes.values.toList(), edges: doc.edges.values.toList());
}

Future<void> _settle(WidgetTester t, [int ms = 600]) async {
  for (var i = 0; i < ms ~/ 100; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// The view as the chrome embeds it: under the store's and the block selector's scopes, edge to edge, with a toolbar
/// of [_toolbar] over its bottom.
Future<void> _pump(
  WidgetTester t,
  h.Harness s, {
  WorkflowMenuOptions options = const WorkflowMenuOptions(),
  ValueChanged<String>? onOpenNode,
}) async {
  phoneView(t, size: const Size(411, 914), padding: gestureInsets);
  await pumpPhoneApp(
    t,
    DifyPage(
      edgeToEdge: true,
      body: WorkflowStoreScope(
        store: s.store,
        child: ListenableBuilder(
          listenable: s.controller,
          builder: (context, child) => BlockSelectorScope(
            data: BlockSelectorData(nodes: [for (final n in s.doc.nodes.values) (id: n.id, type: n.type)]),
            child: child!,
          ),
          child: WorkflowStepsView(
            controller: s.controller,
            canvas: s.canvas,
            options: options,
            bottomInset: _toolbar,
            onOpenNode: onOpenNode,
          ),
        ),
      ),
    ),
    edgeToEdge: true,
  );
  await _settle(t);
}

Finder _card(String id) => find.byKey(ValueKey('step-card-$id'));
Finder _plus(String rowKey) => find.descendant(
  of: find.byKey(ValueKey('step-plus-$rowKey')),
  matching: find.byType(DifyPressable),
);

DifyStepCard _cardWidget(WidgetTester t, String id) => t.widget<DifyStepCard>(_card(id));

/// Picks [type] in the open block selector.
Future<void> _pick(WidgetTester t, String type) async {
  expect(find.byType(BlockSelectorCard), findsOneWidget);
  await t.tap(
    find.descendant(of: find.byType(BlockSelectorCard), matching: find.text(DifyI18n.tr('workflow', 'blocks.$type'))),
  );
  await _settle(t, 1000);
}

Set<(String, String, String)> _edges(h.Harness s) => {
  for (final e in s.doc.edges.values) (e.source, difyHandle(e.sourceHandle), e.target),
};

Node _added(h.Harness s, String type) => s.doc.nodes.values.singleWhere((n) => n.type == type);

/// Scrolls step [id] into view (its row may not be built yet).
Future<void> _show(WidgetTester t, String id) async {
  t.state<WorkflowStepsViewState>(find.byType(WorkflowStepsView)).revealNode(id);
  await _settle(t, 800);
}

void main() {
  test('the preview\'s samples: mockup 2, and every kind of branch meeting where it should', () {
    final mockup = previewDocument('mockup');
    expectWellFormed(mockup, computeStepsLayout(mockup));
    expect(outline(computeStepsLayout(mockup)), [
      'start',
      '+',
      'count',
      '+',
      'check',
      '  [true]',
      '  +',
      '  summarize',
      '  +',
      '  [false]',
      '  +',
      '  empty',
      '  +', //
      '+join', 'end', '+end',
    ]);
    final branches = previewDocument('branches');
    final layout = computeStepsLayout(branches);
    expectWellFormed(branches, layout);
    expect(outline(layout), [
      'start',
      '+',
      'route',
      '  [billing]',
      '  +',
      '  invoice',
      '    [fail-branch]',
      '    +',
      '    notify',
      '    +end',
      '  +',
      '  [tech]',
      '  +',
      '  each',
      '    start',
      '    search',
      '    +',
      '    extract',
      '    +end',
      '  +',
      '  [other]',
      '  add',
      '+join',
      'merge',
      '  [source]',
      '  +',
      '  draft',
      '  +',
      '  [source]',
      '  +',
      '  tone',
      '  +',
      '+join',
      'end',
      '+end',
      '-- not connected',
      'scratch',
      '+end',
    ]);
  });

  testWidgets('mockup 2: cards with the block icon, title and summary; lanes with Dify\'s labels; edge to edge', (
    t,
  ) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    for (final title in const ['Start', 'Count Android', 'Has words?', 'Summarize', 'Say empty', 'End']) {
      expect(find.text(title), findsOneWidget, reason: title);
    }
    expect(find.text('Input: text'), findsOneWidget);
    expect(find.text('Python 3 · Output: python, words'), findsOneWidget);
    expect(find.text('stand-in-chat'), findsOneWidget);
    expect(find.text('Nothing to count'), findsOneWidget);
    expect(find.text('Output: words, python, summary'), findsOneWidget);
    expect(find.text('IF words > 0'), findsOneWidget);
    expect(find.text('ELSE'), findsOneWidget);
    expect(t.takeException(), isNull);
    // Lanes are one level in; the trunk's cards are 16 px from the window's edge.
    expect(t.getTopLeft(_card('start')).dx, 16);
    expect(t.getTopLeft(_card('summarize')).dx, 16 + DifyStepMetrics.indent);
    expect(t.getSize(_card('count')).width, 411 - 32);
    // "+" between the trunk's steps, at each lane's start and end, after the IF block, and after End (Dify offers
    // blocks after End's handle as well).
    expect(find.byType(DifyStepConnector), findsNWidgets(8));
    expect(find.byKey(const ValueKey('step-plus-a:end')), findsOneWidget);
    // Edge to edge: the list's end clears the gesture bar and the toolbar.
    final padding = t.widget<SliverPadding>(find.byType(SliverPadding)).padding.resolve(TextDirection.ltr);
    expect(padding.bottom, 24 + gestureInsets.bottom + _toolbar);
    await s.dispose(t);
  });

  testWidgets('a tap selects the step and opens its settings through the canvas\'s opener (or the one given)', (
    t,
  ) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    await t.tap(_card('count'));
    await t.pump();
    expect(s.controller.selectedNodeId, 'count');
    expect(s.canvas.selection.nodes, {
      s.graph['count']!.slot,
    }, reason: 'the canvas selection follows (handleNodeSelect)');
    expect(_cardWidget(t, 'count').selected, isTrue);
    await s.dispose(t);

    final s2 = await _start(t, previewDocument('mockup'));
    final opened = <String>[];
    await _pump(t, s2, onOpenNode: opened.add);
    await t.tap(_card('summarize'));
    expect(opened, ['summarize']);
    await s2.dispose(t);
  });

  testWidgets('"+" between two steps inserts on that edge: one undo step, the new step selected and revealed', (
    t,
  ) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    await t.tap(_plus('c:start-source-count'));
    await _settle(t);
    await _pick(t, 'template-transform');
    final added = _added(s, 'template-transform');
    expect(_edges(s), containsAll({('start', 'source', added.id), (added.id, 'source', 'count')}));
    expect(s.doc.edges.containsKey('start-source-count'), isFalse);
    expect(s.controller.undo.past, hasLength(1));
    expect(s.controller.selectedNodeId, added.id);
    expect(_card(added.id), findsOneWidget);
    expect(_cardWidget(t, added.id).highlighted, isTrue);
    await _settle(t, 2000);
    expect(_cardWidget(t, added.id).highlighted, isFalse);
    s.controller.undo.undo();
    await _settle(t);
    expect(_card(added.id), findsNothing, reason: 'the list follows undo');
    expect(_edges(s), contains(('start', 'source', 'count')));
    await s.dispose(t);
  });

  testWidgets(
    '"+" after the IF block inserts where its lanes meet: both lanes now lead to the new step, one undo step',
    (
      t,
    ) async {
      final s = await _start(t, previewDocument('mockup'));
      await _pump(t, s);
      await t.tap(_plus('j:end'));
      await _settle(t);
      await _pick(t, 'template-transform');
      final added = _added(s, 'template-transform');
      final edges = _edges(s);
      expect(
        edges,
        containsAll({('summarize', 'source', added.id), ('empty', 'source', added.id), (added.id, 'source', 'end')}),
      );
      expect(edges.where((e) => e.$3 == 'end'), hasLength(1));
      expect(s.controller.undo.past, hasLength(1));
      expect(s.demo.server.doc.edges.values.where((e) => e.target == added.id), hasLength(2), reason: 'sent');
      s.controller.undo.undo();
      await _settle(t);
      expect(_edges(s), containsAll({('summarize', 'source', 'end'), ('empty', 'source', 'end')}));
      expect(s.doc.nodes.containsKey(added.id), isFalse);
      await s.dispose(t);
    },
  );

  testWidgets('an empty lane adds after its handle; a lane\'s last step adds after itself', (t) async {
    final g = Graph()
      ..add('s', 'start')
      ..ifElse('if', ['c1'], title: 'Check')
      ..add('a', 'code', title: 'Lane step')
      ..link('s', 'if')
      ..link('if', 'a', 'c1');
    final s = await _start(t, g.doc);
    await _pump(t, s);
    expect(find.text('Add step'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('step-add-p:if:false')));
    await _settle(t);
    await _pick(t, 'template-transform');
    final first = _added(s, 'template-transform');
    expect(_edges(s), contains(('if', 'false', first.id)));
    expect(find.text('Add step'), findsNothing, reason: 'the ELSE lane has a step now');

    await t.tap(_plus('a:a'));
    await _settle(t);
    await _pick(t, 'llm');
    expect(_edges(s), contains(('a', 'source', _added(s, 'llm').id)));
    expect(s.controller.undo.past, hasLength(2));
    await s.dispose(t);
  });

  testWidgets('a lane\'s first "+" adds a step at the start of the branch', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    await t.tap(_plus('c:check-true-summarize'));
    await _settle(t);
    await _pick(t, 'template-transform');
    final added = _added(s, 'template-transform');
    expect(_edges(s), containsAll({('check', 'true', added.id), (added.id, 'source', 'summarize')}));
    expect(s.doc.edges.containsKey('check-true-summarize'), isFalse);
    expect(s.controller.undo.past, hasLength(1));
    final layout = computeStepsLayout(s.doc);
    final lane = layout.rows.indexWhere((r) => r.kind == StepRowKind.laneHeader && r.handle == 'true');
    expect(layout.rows[lane + 1].kind, StepRowKind.connector);
    expect(layout.rows[lane + 2].nodeId, added.id, reason: 'first in the IF lane');
    expect(t.getTopLeft(_card(added.id)).dy, lessThan(t.getTopLeft(_card('summarize')).dy));
    await s.dispose(t);
  });

  testWidgets('Delete asks first when other steps reference the step, exactly as the node panel\'s Delete', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    expect(s.controller.referencesTo('count'), isNotEmpty, reason: 'the IF and End read its outputs');
    await t.longPress(_card('count'));
    await _settle(t);
    await t.tap(find.text('Delete'));
    await _settle(t);
    expect(find.byKey(const Key('delete-dialog')), findsOneWidget);
    expect(find.textContaining('Count Android'), findsWidgets);
    await t.tap(find.text('Cancel'));
    await _settle(t);
    expect(s.doc.nodes.containsKey('count'), isTrue, reason: 'cancelled');

    await t.longPress(_card('count'));
    await _settle(t);
    await t.tap(find.text('Delete'));
    await _settle(t);
    await t.tap(find.byKey(const Key('confirm-delete')));
    await _settle(t);
    expect(s.doc.nodes.containsKey('count'), isFalse);
    expect(_card('count'), findsNothing);

    // A step nothing references goes at once, as from the panel.
    expect(s.controller.referencesTo('empty'), isEmpty);
    await t.longPress(_card('empty'));
    await _settle(t);
    await t.tap(find.text('Delete'));
    await _settle(t);
    expect(find.byKey(const Key('delete-dialog')), findsNothing);
    expect(s.doc.nodes.containsKey('empty'), isFalse);
    await s.dispose(t);
  });

  testWidgets('without a laid-out canvas, consecutive inserts and duplicates never overlap on the canvas', (t) async {
    // A canvas-like layout: the trunk left to right, the IF's lanes one below the other.
    final g = Graph()
      ..add('s', 'start', y: 0)
      ..add('a', 'code', y: 0)
      ..ifElse('if', ['c1', 'c2'])
      ..add('b', 'llm', y: 0)
      ..chain(['s', 'a', 'if'])
      ..link('if', 'b', 'c1');
    for (final (i, id) in ['s', 'a', 'if', 'b'].indexed) {
      final at = g.nodes.indexWhere((n) => n.id == id);
      g.nodes[at] = Node(id: id, type: g.nodes[at].type, title: id, x: 300 * i, y: 0, config: g.nodes[at].config);
    }
    final s = await _start(t, g.doc);
    s.canvas.graph = null; // the Steps view shown instead of the canvas: nothing measured
    await _pump(t, s);
    final actions = t.state<WorkflowStepsViewState>(find.byType(WorkflowStepsView)).actions;
    Rect box(Node n) => Offset(n.x.toDouble(), n.y.toDouble()) & (actions.sizeOf(n) ?? stepCardSize(n, s.doc));
    void expectNoOverlap(String when) {
      final nodes = s.doc.nodes.values.toList();
      for (var i = 0; i < nodes.length; i++) {
        for (var j = i + 1; j < nodes.length; j++) {
          expect(
            box(nodes[i]).overlaps(box(nodes[j])),
            isFalse,
            reason: '$when: ${nodes[i].title} ${box(nodes[i])} and ${nodes[j].title} ${box(nodes[j])}',
          );
        }
      }
    }

    String rowKey(bool Function(StepRow) test) => computeStepsLayout(s.doc).rows.firstWhere(test).key;
    Future<void> insert(String near, String key, String type) async {
      await _show(t, near);
      final target = key.startsWith('p:') ? find.byKey(ValueKey('step-add-$key')) : _plus(key);
      // The row comes after [near] (not built yet when it is further down).
      await t.scrollUntilVisible(target, 200, scrollable: find.byType(Scrollable).first);
      await t.ensureVisible(target);
      await _settle(t, 200);
      await t.tap(target);
      await _settle(t);
      await _pick(t, type);
    }

    expectNoOverlap('before');
    // Twice after the last step (InsertAfter), twice on one edge (InsertOnEdge), the two empty lanes one after the
    // other (InsertAfter on the IF's handles: below its lowest next step), twice at the start of a lane.
    for (var i = 0; i < 2; i++) {
      final last = s.doc.nodes.values.where((n) => !s.doc.edges.values.any((e) => e.source == n.id)).last;
      await insert(
        last.id,
        rowKey(
          (r) =>
              r.kind == StepRowKind.connector &&
              r.insert?.at is InsertAfter &&
              (r.insert!.at as InsertAfter).nodeId == last.id,
        ),
        'template-transform',
      );
      expectNoOverlap('after the last step, $i');
    }
    for (var i = 0; i < 2; i++) {
      await insert(
        's',
        rowKey(
          (r) =>
              r.kind == StepRowKind.connector &&
              r.insert?.at is InsertOnEdge &&
              s.doc.edges[(r.insert!.at as InsertOnEdge).edgeId]?.source == 's',
        ),
        'code',
      );
      expectNoOverlap('on the first edge, $i');
    }
    await insert('if', 'p:if:c2', 'llm');
    expectNoOverlap('the c2 lane');
    await insert('if', 'p:if:false', 'llm');
    expectNoOverlap('the ELSE lane');
    for (var i = 0; i < 2; i++) {
      await insert(
        'if',
        rowKey(
          (r) =>
              r.kind == StepRowKind.connector &&
              r.insert?.at is InsertOnEdge &&
              s.doc.edges[(r.insert!.at as InsertOnEdge).edgeId]?.sourceHandle == 'c1',
        ),
        'template-transform',
      );
      expectNoOverlap('at the start of the c1 lane, $i');
    }
    // Two duplicates of one step: below it, each below the last.
    final count = s.doc.nodes.length;
    for (var i = 0; i < 2; i++) {
      await _show(t, 'b');
      await t.longPress(_card('b'));
      await _settle(t);
      await t.tap(find.text('Duplicate'));
      await _settle(t, 1500);
      expectNoOverlap('duplicate $i');
    }
    expect(s.doc.nodes.length, count + 2);
    final copies = s.doc.nodes.values.where((n) => n.title.startsWith('b (')).toList();
    expect(copies.map((n) => n.x).toSet(), {s.doc.nodes['b']!.x}, reason: 'straight below the original');
    await s.dispose(t);
  });

  group('a branching block inserted between two steps continues the flow', () {
    /// start → count → end, laid out left to right.
    Graph chain() => Graph()
      ..add('start', 'start')
      ..add('count', 'code', title: 'Count Android')
      ..add('end', 'end', title: 'End')
      ..chain(['start', 'count', 'end']);

    testWidgets('IF/ELSE on an edge: its case and ELSE lead to the next step; one undo step; a collaborator sees it', (
      t,
    ) async {
      final s = await _start(t, chain().doc);
      await _pump(t, s);
      final head = s.demo.server.head;
      await t.tap(_plus('c:count-source-end'));
      await _settle(t);
      await _pick(t, 'if-else');
      final branch = _added(s, 'if-else');
      final edges = _edges(s);
      expect(
        edges,
        containsAll({('count', 'source', branch.id), (branch.id, 'true', 'end'), (branch.id, 'false', 'end')}),
      );
      expect(edges, isNot(contains(('count', 'source', 'end'))));
      final layout = computeStepsLayout(s.doc);
      expect(layout.rows.where((r) => r.kind == StepRowKind.section), isEmpty, reason: 'End is still reached');
      expect(find.text('NOT CONNECTED'), findsNothing);
      expect(outline(layout), [
        'start',
        '+',
        'count',
        '+',
        branch.id,
        '  [true]',
        '  add',
        '  [false]',
        '  add',
        '+join',
        'end',
        '+end',
      ]);
      expect(s.controller.undo.past, hasLength(1));
      expect(s.controller.undo.past.single.event, HistoryEvent.nodeAdd);

      // Another client sees the whole change: the node and its three edges, the old edge gone.
      final bo = CollabSession(
        clientId: 'bo-test',
        transport: FakeTransport(s.demo.server, network: FakeNetwork(random: Random(9))),
        store: MemoryStore(),
      );
      await bo.start();
      for (var i = 0; i < 50 && !bo.view.nodes.containsKey(branch.id); i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      final seen = {for (final e in bo.view.edges.values) (e.source, difyHandle(e.sourceHandle), e.target)};
      expect(
        seen,
        containsAll({('count', 'source', branch.id), (branch.id, 'true', 'end'), (branch.id, 'false', 'end')}),
      );
      expect(seen, isNot(contains(('count', 'source', 'end'))));
      expect(s.demo.server.log.skip(head).map((e) => e.client).toSet(), {'me-abc123'}, reason: 'one client\'s edit');

      s.controller.undo.undo();
      await _settle(t, 1000);
      expect(s.doc.nodes.containsKey(branch.id), isFalse);
      expect(s.doc.edges.values.where((e) => e.source == branch.id || e.target == branch.id), isEmpty);
      expect(_edges(s), contains(('count', 'source', 'end')));
      for (var i = 0; i < 50 && bo.view.nodes.containsKey(branch.id); i++) {
        await t.pump(const Duration(milliseconds: 100));
      }
      expect(bo.view.nodes.containsKey(branch.id), isFalse, reason: 'the undo reaches the collaborator');
      await bo.stop();
      await s.dispose(t);
    });

    testWidgets('a question classifier through "Add step before": every class leads to the step', (t) async {
      final s = await _start(t, chain().doc);
      await _pump(t, s);
      await t.longPress(_card('end'));
      await _settle(t);
      await t.tap(find.text('Add step before'));
      await _settle(t);
      await _pick(t, 'question-classifier');
      final classifier = _added(s, 'question-classifier');
      expect(
        _edges(s),
        containsAll({('count', 'source', classifier.id), (classifier.id, '1', 'end'), (classifier.id, '2', 'end')}),
      );
      expect(computeStepsLayout(s.doc).rows.where((r) => r.kind == StepRowKind.section), isEmpty);
      expect(s.controller.undo.past, hasLength(1));
      s.controller.undo.undo();
      await _settle(t);
      expect(s.doc.nodes.containsKey(classifier.id), isFalse);
      expect(_edges(s), {('start', 'source', 'count'), ('count', 'source', 'end')});
      await s.dispose(t);
    });

    testWidgets('an IF/ELSE where branches meet: the lanes lead to it, its case and ELSE to the next step', (t) async {
      final s = await _start(t, previewDocument('mockup'));
      await _pump(t, s);
      await t.tap(_plus('j:end'));
      await _settle(t);
      await _pick(t, 'if-else');
      final branch = s.doc.nodes.values.singleWhere((n) => n.type == 'if-else' && n.id != 'check');
      expect(
        _edges(s),
        containsAll({
          ('summarize', 'source', branch.id),
          ('empty', 'source', branch.id),
          (branch.id, 'true', 'end'),
          (branch.id, 'false', 'end'),
        }),
      );
      expect(_edges(s).where((e) => e.$3 == 'end').map((e) => e.$1).toSet(), {branch.id});
      expect(s.controller.undo.past, hasLength(1));
      await s.dispose(t);
    });

    testWidgets('a block that continues the flow is inserted exactly as the canvas inserts it', (t) async {
      final s = await _start(t, chain().doc);
      await _pump(t, s);
      await t.tap(_plus('c:count-source-end'));
      await _settle(t);
      await _pick(t, 'llm');
      final llm = _added(s, 'llm');
      expect(_edges(s), {('start', 'source', 'count'), ('count', 'source', llm.id), (llm.id, 'source', 'end')});
      await s.dispose(t);
    });

    testWidgets('the canvas\'s own insertion on an edge keeps Dify\'s behaviour (no edge onward)', (t) async {
      final s = await _start(t, chain().doc);
      s.actions().addNodeAt(const InsertOnEdge('count-source-end'), 'if-else', blockDefaults('if-else'));
      final branch = _added(s, 'if-else');
      expect(_edges(s), {('start', 'source', 'count'), ('count', 'source', branch.id)});
      expect(computeStepsLayout(s.doc).rows.where((r) => r.kind == StepRowKind.section), hasLength(1));
      await s.dispose(t);
    });
  });

  testWidgets('long press: Settings, Run this step, Add step before and after, Duplicate, Delete', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    await t.longPress(_card('count'));
    await _settle(t);
    for (final label in [
      DifyI18n.tr('common', 'operation.settings'),
      DifyI18n.tr('workflow', 'panel.runThisStep'),
      'Add step before',
      'Add step after',
      DifyI18n.tr('common', 'operation.duplicate'),
      DifyI18n.tr('common', 'operation.delete'),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    await t.tap(find.text('Run this step'));
    await _settle(t);
    expect(s.store.pendingSingleRun.value?.nodeId, 'count');
    expect(s.controller.selectedNodeId, 'count');

    await t.longPress(_card('summarize'));
    await _settle(t);
    await t.tap(find.text('Duplicate'));
    await _settle(t, 1500);
    final copy = s.doc.nodes.values.where((n) => n.type == 'llm' && n.id != 'summarize').single;
    expect(find.text('NOT CONNECTED'), findsOneWidget);
    expect(_cardWidget(t, copy.id).highlighted, isTrue, reason: 'the copy is revealed');

    await t.longPress(_card(copy.id));
    await _settle(t);
    await t.tap(find.text('Delete'));
    await _settle(t);
    expect(s.doc.nodes.containsKey(copy.id), isFalse);
    expect(find.text('NOT CONNECTED'), findsNothing);

    await t.longPress(_card('count'));
    await _settle(t);
    await t.tap(find.text('Add step after'));
    await _settle(t);
    await _pick(t, 'template-transform');
    expect(_edges(s), contains(('count', 'source', _added(s, 'template-transform').id)));

    await t.longPress(_card('summarize'));
    await _settle(t);
    await t.tap(find.text('Add step before'));
    await _settle(t);
    await _pick(t, 'code');
    final before = s.doc.nodes.values.singleWhere((n) => n.type == 'code' && n.id != 'count');
    expect(_edges(s), containsAll({('check', 'true', before.id), (before.id, 'source', 'summarize')}));

    await _show(t, 'end');
    await t.longPress(_card('end'));
    await _settle(t);
    expect(find.text('Add step before'), findsNothing, reason: 'two incoming edges: ambiguous');
    await t.tap(find.text('Cancel'));
    await _settle(t);

    await _show(t, 'start');
    await t.longPress(_card('start'));
    await _settle(t);
    // As the canvas's node menu: Start is never copied; in a workflow it may be deleted (not in a chatflow).
    expect(find.text('Duplicate'), findsNothing);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Add step before'), findsNothing, reason: 'nothing leads to Start');
    await t.tap(find.text('Settings'));
    await _settle(t);
    expect(s.controller.selectedNodeId, 'start');
    await s.dispose(t);
  });

  testWidgets('"continues at" scrolls to the step and highlights it', (t) async {
    final g = Graph()
      ..add('s', 'start', y: 0)
      ..add('t', 'trigger-webhook', y: 9000, title: 'Webhook');
    final chain = ['s', for (var i = 0; i < 20; i++) 'n$i'];
    for (var i = 0; i < 20; i++) {
      g.add('n$i', 'code', title: 'Step $i', y: 100 + i * 100);
    }
    g
      ..chain(chain)
      ..link('t', 'n1');
    final s = await _start(t, g.doc);
    await _pump(t, s);
    final link = find.text('Continues at Step 1');
    await t.scrollUntilVisible(link, 300, scrollable: find.byType(Scrollable).first);
    await _settle(t);
    expect(_card('n1'), findsNothing, reason: 'Step 1 is far above');
    await t.tap(link);
    await _settle(t, 1000);
    expect(_card('n1'), findsOneWidget);
    final card = t.getRect(_card('n1'));
    expect(card.top, greaterThanOrEqualTo(gestureInsets.top));
    expect(card.bottom, lessThanOrEqualTo(914 - gestureInsets.bottom - _toolbar));
    expect(_cardWidget(t, 'n1').highlighted, isTrue);
    await s.dispose(t);
  });

  testWidgets('live updates: an edit elsewhere appears, and the steps on screen stay where they are', (t) async {
    final g = Graph()..add('s', 'start', y: 0);
    final chain = ['s', for (var i = 0; i < 20; i++) 'n$i'];
    for (var i = 0; i < 20; i++) {
      g.add('n$i', 'code', title: 'Step $i', y: 100 + i * 100);
    }
    g.chain(chain);
    final s = await _start(t, g.doc);
    await _pump(t, s);
    await t.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await _settle(t);
    final visible = ['n10', 'n11', 'n12', 'n13'].firstWhere((id) => _card(id).evaluate().isNotEmpty);
    final before = t.getTopLeft(_card(visible)).dy;
    // Somebody inserts a step near the top (a graph change that does not touch this user's selection) and renames
    // one on screen.
    s.controller.applyGraphChange(
      event: HistoryEvent.nodeAdd,
      addNodes: const [Node(id: 'x', type: 'llm', title: 'Inserted', y: 50)],
      removeEdges: const ['s-source-n0'],
      addEdges: const [
        Edge(id: 's-x', source: 's', target: 'x'),
        Edge(id: 'x-n0', source: 'x', target: 'n0'),
      ],
    );
    s.controller.setTitle(visible, 'Renamed', base: s.controller.seenVersion);
    await _settle(t);
    expect(t.getTopLeft(_card(visible)).dy, moreOrLessEquals(before, epsilon: 1));
    expect(find.text('Renamed'), findsOneWidget);
    await t.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await _settle(t);
    expect(find.text('Inserted'), findsOneWidget);
    await s.dispose(t);
  });

  testWidgets('run markers (mockup 7): succeeded, running, failed and waiting steps', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    s.canvas.nodeRun.value = const {
      'start': NodeRunView(runningStatus: 'succeeded'),
      'count': NodeRunView(runningStatus: 'succeeded'),
      'check': NodeRunView(runningStatus: 'failed'),
      'summarize': NodeRunView(runningStatus: 'running'),
      'end': NodeRunView(waiting: true),
    };
    await _settle(t, 300);
    expect(find.byKey(const ValueKey('step-status-succeeded')), findsNWidgets(2));
    expect(find.byKey(const ValueKey('step-status-failed')), findsOneWidget);
    expect(find.byKey(const ValueKey('step-status-running')), findsOneWidget);
    expect(_cardWidget(t, 'count').statusColor, DifyColors.stateSuccessSolid);
    expect(_cardWidget(t, 'check').statusColor, DifyColors.stateDestructiveSolid);
    expect(_cardWidget(t, 'summarize').statusColor, DifyColors.stateAccentSolid);
    expect((_cardWidget(t, 'end').dimmed, _cardWidget(t, 'end').chevron), (true, true));
    expect(_cardWidget(t, 'count').chevron, isFalse, reason: 'the status icon takes the chevron\'s place');
    s.canvas.nodeRun.value = const {};
    await _settle(t, 300);
    expect(find.byKey(const ValueKey('step-status-succeeded')), findsNothing);
    await s.dispose(t);
  });

  testWidgets('a checklist problem marks the step red with its message', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    await _pump(t, s);
    s.store.checklistItems.value = [
      {
        'id': 'summarize',
        'type': 'llm',
        'title': 'Summarize',
        'errorMessages': ['Model is not configured'],
        'canNavigate': true,
      },
    ];
    await _settle(t, 300);
    expect(find.text('Model is not configured'), findsOneWidget);
    expect(find.descendant(of: _card('summarize'), matching: find.byKey(const ValueKey('step-issue'))), findsOneWidget);
    expect(_cardWidget(t, 'summarize').statusColor, DifyColors.stateDestructiveSolid);
    s.store.checklistItems.value = const [];
    await _settle(t, 300);
    expect(find.text('stand-in-chat'), findsOneWidget);
    await s.dispose(t);
  });

  testWidgets('read-only: no "+", and the sheet only opens the settings', (t) async {
    final s = await _start(t, previewDocument('mockup'));
    s.store.canvasReadOnly.value = true;
    await _pump(t, s);
    expect(find.descendant(of: find.byType(DifyStepConnector), matching: find.byType(DifyPressable)), findsNothing);
    await t.longPress(_card('count'));
    await _settle(t);
    expect(find.text('Settings'), findsOneWidget);
    for (final label in ['Run this step', 'Add step after', 'Duplicate', 'Delete']) {
      expect(find.text(label), findsNothing, reason: label);
    }
    await s.dispose(t);
  });

  testWidgets('300 steps: built lazily, scrolled through without errors, the last step revealed', (t) async {
    final g = bigGraph(300);
    final s = await _start(t, g.doc);
    final watch = Stopwatch()..start();
    await _pump(t, s);
    expect(find.byType(DifyStepCard).evaluate().length, lessThan(40), reason: 'only what is on screen is built');
    for (var i = 0; i < 10; i++) {
      await t.fling(find.byType(Scrollable).first, const Offset(0, -2000), 4000);
      await _settle(t, 300);
    }
    expect(t.takeException(), isNull);
    t.state<WorkflowStepsViewState>(find.byType(WorkflowStepsView)).revealNode('end', highlight: true);
    await _settle(t, 1500);
    expect(_card('end'), findsOneWidget);
    expect(_cardWidget(t, 'end').highlighted, isTrue);
    t.state<WorkflowStepsViewState>(find.byType(WorkflowStepsView)).revealNode('start');
    await _settle(t, 1500);
    expect(_card('start'), findsOneWidget);
    watch.stop();
    expect(watch.elapsed, lessThan(const Duration(seconds: 60)));
    await s.dispose(t);
  });

  testWidgets('the standalone preview shows the sample, switches samples, and simulates a run', (t) async {
    await t.runAsync(() => DifyI18n.load('en-US'));
    phoneView(t, size: const Size(411, 914), padding: gestureInsets);
    await t.pumpWidget(const StepsPreviewApp());
    await _settle(t, 1500);
    expect(find.text('Count Android'), findsOneWidget);
    await t.tap(find.bySemanticsLabel('Simulated run'));
    await _settle(t, 300);
    expect(find.byKey(const ValueKey('step-status-succeeded')), findsWidgets);
    await t.tap(find.bySemanticsLabel('Next sample'));
    await _settle(t, 1500);
    expect(find.text('Route request'), findsOneWidget);
    expect(find.text('Fail Branch'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 20));
  });
}
