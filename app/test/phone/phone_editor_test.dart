// The workflow editor on a phone (batch 3a): the app bar, the Steps | Canvas switch, the toolbar, the canvas's
// selection bars, touch insertion and connection, select mode, the overflow sheet and Android back, at 411x914 and
// 360x780 with the system bars' insets; the desktop layout at 640 and 1440 px stays as it was.
import 'dart:async';

import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/edge_curve.dart';
import 'package:dify_sf_app/src/canvas/workflow_canvas.dart';
import 'package:dify_sf_app/src/demo/demo_backend.dart';
import 'package:dify_sf_app/src/design/dify_theme.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/editor/editor_controller.dart';
import 'package:dify_sf_app/src/editor/editor_page.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/dify_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/header/workflow_header.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/workflow_node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_controller.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/phone_editor_frame.dart';
import 'package:dify_sf_app/src/workflow_editor/phone/steps_view_slot.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/header/view_history.dart';
import 'package:dify_sf_app/src/workflow_editor/steps/workflow_steps_view.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/app_fonts.dart';
import 'phone_harness.dart';

/// The editor on the demo document (Start → "Answer the question" (LLM) → "Post-process" (code) → Answer), on
/// its own or pushed over a page (to see back leave it).
class _Editor {
  _Editor(this.t, this.demo);
  final WidgetTester t;
  final DemoBackend demo;
  final nav = GlobalKey<NavigatorState>();

  EditorController get c => t.widget<DifyWorkflowEditor>(find.byType(DifyWorkflowEditor)).controller;
  Finder get canvasFinder => find.byType(WorkflowCanvas, skipOffstage: false);
  CanvasController get canvas => t.state<WorkflowCanvasState>(canvasFinder).canvas;
  WorkflowStore get store => WorkflowStoreScope.of(t.element(canvasFinder));
  PhoneEditorController get phone => PhoneEditorScope.read(t.element(find.byType(PhoneEditorFrame)))!;

  /// Where node [id]'s card is on screen ([at]: a point of its canvas rectangle, the middle by default).
  Offset node(String id, [Offset Function(Rect r)? at]) {
    final n = canvas.graph![id]!;
    return t.getTopLeft(canvasFinder) + canvas.view.toScreen((at ?? (r) => r.center)(n.rect));
  }

  /// The middle of edge [id] on screen.
  Offset edge(String id) {
    final e = c.doc.edges[id]!;
    final g = canvas.graph!;
    final pts = edgeCurve(g[e.source]!.outPortFor(e.sourceHandle), g[e.target]!.inPort);
    return t.getTopLeft(canvasFinder) + canvas.view.toScreen(pts[pts.length ~/ 2]);
  }

  Future<void> showCanvas() async {
    await t.tap(find.text('Canvas'));
    await settle(t, 600);
  }

  /// Taps a block row of the open block picker.
  Future<void> pick(String title) async {
    final row = find.descendant(of: find.byType(BlockSelectorCard), matching: find.text(title)).first;
    await t.ensureVisible(row);
    await t.pump();
    await t.tap(row);
    await settle(t, 800);
  }

  Future<void> dispose() async {
    await unmount(t);
    await demo.dispose();
    await t.pump(const Duration(seconds: 20));
  }
}

Future<_Editor> _pump(
  WidgetTester t, {
  Size size = const Size(411, 914),
  EdgeInsets insets = gestureInsets,
  StepsViewBuilder? steps,
  bool pushed = false,
}) async {
  phoneWindow(t, size: size, insets: insets);
  final e = _Editor(t, DemoBackend(withBo: false));
  Widget editor() => EditorPage(
    backend: e.demo,
    docId: 'demo',
    clientId: 'phone-editor',
    journaled: false,
    stepsView: steps,
  );
  await t.pumpWidget(
    DifyApplication(
      theme: difyTheme(),
      edgeToEdge: true,
      navigatorKey: e.nav,
      home: pushed ? const DifyPage(edgeToEdge: true, body: SizedBox.expand(key: ValueKey('home'))) : editor(),
    ),
  );
  if (pushed) unawaited(e.nav.currentState!.push(difyPageRoute<void>(edgeToEdge: true, builder: (_) => editor())));
  await settle(t, 2000);
  return e;
}

String _tw(String key) => DifyI18n.tr('workflow', key);

/// dify-sf's own phone editor strings (assets/extension_i18n, namespace `phone-editor`).
String _tp(String key, [Map<String, Object?> params = const {}]) => DifyI18n.tr('phone-editor', key, params);

void main() {
  setUpAll(() async {
    await DifyI18n.load('en-US');
    await useAppFonts();
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final w in phoneWindows) {
    testWidgets('${w.name}: one-line app bar, Steps | Canvas, toolbar; no floating desktop chrome', (t) async {
      final e = await _pump(t, size: w.size, insets: w.insets);
      expect(t.takeException(), isNull);
      expect(find.byType(PhoneEditorFrame), findsOneWidget);
      // The app bar paints under the status bar; its 56 px row starts below it.
      final bar = t.getRect(find.byKey(const ValueKey('phone-editor-app-bar')));
      expect(bar.top, 0);
      expect(bar.height, DifyTopAppBar.height + w.insets.top);
      expect(t.getRect(find.byKey(const ValueKey('phone-run'))).top, greaterThanOrEqualTo(w.insets.top));
      expect(find.byKey(const ValueKey('phone-editor-more')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-view-switch')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-issues')), findsOneWidget);
      // Steps by default: the Steps view.
      expect(e.phone.view, PhoneEditorView.steps);
      expect(find.byType(WorkflowStepsView), findsOneWidget);
      // The toolbar reaches the bottom edge; its actions and the Add button stay above the system bar.
      final toolbar = t.getRect(find.byKey(const ValueKey('phone-toolbar')));
      expect(toolbar.bottom, w.size.height);
      expect(
        t.getRect(find.byKey(const ValueKey('phone-add'))).bottom,
        lessThanOrEqualTo(w.size.height - w.insets.bottom),
      );
      for (final label in [_tw('common.undo'), _tw('common.redo'), _tp('note'), _tp('versions')]) {
        expect(t.getRect(find.text(label)).bottom, lessThanOrEqualTo(w.size.height - w.insets.bottom), reason: label);
      }
      // No floating desktop chrome.
      for (final type in [WorkflowControl, WorkflowOperator, HeaderInNormal, WorkflowMiniMap, ZoomInOut, UndoRedo]) {
        expect(find.byType(type, skipOffstage: false), findsNothing, reason: '$type');
      }

      await e.showCanvas();
      expect(t.takeException(), isNull);
      expect(e.phone.view, PhoneEditorView.canvas);
      expect(find.byType(WorkflowCanvas), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-canvas-mode')), findsOneWidget);
      expect(find.byKey(const ValueKey('phone-canvas-fit')), findsOneWidget);
      // The canvas lies between the view switch and the toolbar.
      final canvas = t.getRect(find.byType(WorkflowCanvas));
      expect(canvas.top, greaterThan(bar.bottom));
      expect(canvas.bottom, t.getRect(find.byKey(const ValueKey('phone-toolbar'))).top);
      await e.dispose();
    });
  }

  testWidgets('the chosen view is stored per app and comes back', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(PhoneEditorController.storageKey('demo')), 'canvas');
    await e.dispose();

    final again = await _pump(t);
    expect(again.phone.view, PhoneEditorView.canvas);
    expect(find.byType(WorkflowCanvas), findsOneWidget);
    await t.tap(find.text('Steps'));
    await settle(t, 400);
    expect((await SharedPreferences.getInstance()).getString(PhoneEditorController.storageKey('demo')), 'steps');
    await again.dispose();
  });

  testWidgets('the Steps slot gets a working host', (t) async {
    StepsViewHost? host;
    final e = await _pump(
      t,
      steps: (context, h) {
        host = h;
        return const SizedBox.expand(key: ValueKey('my-steps'));
      },
    );
    expect(find.byKey(const ValueKey('my-steps')), findsOneWidget);
    // The insets are taken by the bars around it.
    expect(MediaQuery.paddingOf(t.element(find.byKey(const ValueKey('my-steps')))), EdgeInsets.zero);
    expect(host!.controller, same(e.c));
    host!.openSettings('code');
    await settle(t, 600);
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    expect(e.c.selectedNodeId, 'code');
    expect(await systemBack(t), isTrue);
    expect(find.byType(WorkflowNodePanel), findsNothing);
    await e.dispose();
  });

  testWidgets('Steps view: Run this step from the long press opens the step\'s panel, which takes the request', (
    t,
  ) async {
    final e = await _pump(t);
    final card = find.byKey(const ValueKey('step-card-code'));
    await t.ensureVisible(card);
    await settle(t, 300);
    await t.longPress(card);
    await settle(t, 600);
    await t.tap(find.text(DifyI18n.tr('workflow', 'panel.runThisStep')));
    await settle(t, 800);
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    expect(e.store.pendingSingleRun.value, isNull, reason: 'the panel consumed the run request');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('Steps view: Add with no step selected continues the flow (connected, not a free spot)', (t) async {
    final e = await _pump(t);
    expect(e.phone.view, PhoneEditorView.steps);
    expect(e.c.selectedNodeId, isNull);
    final before = e.c.doc.nodes.keys.toSet();
    await t.tap(find.byKey(const ValueKey('phone-add')));
    await settle(t, 800);
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    await e.pick('Template');
    final added = e.c.doc.nodes.keys.toSet().difference(before).single;
    final edges = e.c.doc.edges.values;
    expect(edges.where((x) => x.target == added), isNotEmpty, reason: 'connected after the flow\'s last step');
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('toolbar: Add places the picked block at a free spot in view (no ghost); Note, Undo, Redo', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    final before = e.c.doc.nodes.keys.toSet();
    await t.tap(find.byKey(const ValueKey('phone-add')));
    await settle(t, 800);
    // The block picker is a bottom sheet; its search does not take focus (no keyboard).
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    expect(t.testTextInput.isVisible, isFalse);
    await e.pick('Template');
    expect(find.byType(BlockSelectorCard), findsNothing);
    final added = e.c.doc.nodes.keys.toSet().difference(before).single;
    expect(e.store.candidateNode.value, isNull, reason: 'no node follows the finger');
    expect(e.c.selectedNodeId, added);
    final rect = e.canvas.graph![added]!.rect;
    final view = Rect.fromPoints(
      e.canvas.view.toCanvas(Offset.zero),
      e.canvas.view.toCanvas(e.canvas.view.viewport.bottomRight(Offset.zero)),
    );
    expect(view.contains(rect.topLeft) && view.contains(rect.bottomRight), isTrue, reason: '$rect in $view');
    for (final id in before) {
      expect(e.canvas.graph![id]!.visual.overlaps(rect), isFalse, reason: 'overlaps $id');
    }
    // Selected: its selection bar replaces the toolbar; back clears the selection and brings the toolbar back.
    expect(find.byKey(const ValueKey('phone-node-bar')), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(find.byKey(const ValueKey('phone-toolbar')), findsOneWidget);

    // Note: a note at a free spot, one undo step.
    final count = e.c.doc.nodes.length;
    await t.tap(find.text(_tp('note')));
    await settle(t, 600);
    expect(e.c.doc.nodes.length, count + 1);
    final note = e.c.selectedNodeId!;
    expect(await systemBack(t), isTrue);
    await t.tap(find.text(_tw('common.undo')));
    await settle(t, 400);
    expect(e.c.doc.nodes.containsKey(note), isFalse);
    await t.tap(find.text(_tw('common.redo')));
    await settle(t, 400);
    expect(e.c.doc.nodes.containsKey(note), isTrue);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the selection bar: Settings, Run step, Add next, Connect…, Duplicate, Delete', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tapAt(e.node('code'));
    await settle(t, 600);
    expect(e.c.selectedNodeId, 'code');
    final bar = find.byKey(const ValueKey('phone-node-bar'));
    expect(bar, findsOneWidget);
    expect(find.descendant(of: bar, matching: find.text('Post-process')), findsOneWidget);
    // Selecting does not open the panel.
    expect(find.byType(WorkflowNodePanel), findsNothing);

    await t.tap(find.byKey(const ValueKey('phone-node-settings')));
    await settle(t, 600);
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    expect(e.phone.settingsNodeId, 'code');
    // The panel takes the area under the app bar: the canvas is not squeezed beside it.
    final panels = t.getRect(find.byKey(const ValueKey('phone-panels')));
    expect(panels.width, 411);
    expect(panels.top, t.getRect(find.byKey(const ValueKey('phone-editor-app-bar'))).bottom);
    expect(await systemBack(t), isTrue);
    expect(find.byType(WorkflowNodePanel), findsNothing);
    expect(e.c.selectedNodeId, 'code', reason: 'back closed the panel, the selection stays');

    await t.tap(find.byKey(const ValueKey('phone-node-run')));
    await settle(t, 600);
    expect(e.phone.settingsNodeId, 'code', reason: 'the single run happens in the panel');
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    expect(await systemBack(t), isTrue);

    // Add next: the picker names the anchor; the block is inserted after it and selected.
    final before = e.c.doc.nodes.keys.toSet();
    await t.tap(find.byKey(const ValueKey('phone-node-add-next')));
    await settle(t, 800);
    expect(find.text(DifyI18n.tr('phone-editor', 'addAfter', {'name': 'Post-process'})), findsOneWidget);
    await e.pick('Template');
    final added = e.c.doc.nodes.keys.toSet().difference(before).single;
    expect(e.c.doc.edges.values.any((x) => x.source == 'code' && x.target == added), isTrue);
    expect(e.c.selectedNodeId, added);

    // Connect…: the LLM to Answer, picked from the list.
    await t.tapAt(e.node('llm'));
    await settle(t, 600);
    expect(e.c.selectedNodeId, 'llm');
    await t.tap(find.byKey(const ValueKey('phone-node-connect')));
    await settle(t, 800);
    expect(find.byKey(const ValueKey('phone-connect-answer')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-connect-llm')), findsNothing, reason: 'not to itself');
    expect(find.byKey(const ValueKey('phone-connect-code')), findsNothing, reason: 'already connected');
    await t.tap(find.byKey(const ValueKey('phone-connect-answer')));
    await settle(t, 600);
    expect(e.c.doc.edges.values.any((x) => x.source == 'llm' && x.target == 'answer'), isTrue);

    // Duplicate and Delete.
    final n = e.c.doc.nodes.length;
    await t.tap(find.byKey(const ValueKey('phone-node-duplicate')));
    await settle(t, 800);
    expect(e.c.doc.nodes.length, n + 1);
    await t.tapAt(e.node(added));
    await settle(t, 600);
    expect(e.c.selectedNodeId, added);
    await t.tap(find.byKey(const ValueKey('phone-node-delete')));
    await settle(t, 600);
    expect(e.c.doc.nodes.containsKey(added), isFalse);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('the settings panel keeps clear of the gesture bar and of the keyboard', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tapAt(e.node('code'));
    await settle(t, 600);
    await t.tap(find.byKey(const ValueKey('phone-node-settings')));
    await settle(t, 600);
    expect(t.getRect(find.byType(WorkflowNodePanel)).bottom, lessThanOrEqualTo(914 - gestureInsets.bottom));
    openKeyboard(t);
    await settle(t, 600);
    expect(t.takeException(), isNull);
    expect(t.getRect(find.byType(WorkflowNodePanel)).bottom, lessThanOrEqualTo(914 - 300));
    closeKeyboard(t);
    await settle(t, 600);
    expect(t.getRect(find.byType(WorkflowNodePanel)).bottom, lessThanOrEqualTo(914 - gestureInsets.bottom));
    await e.dispose();
  });

  testWidgets('a tap on an edge selects it: Insert step, Delete connection', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tapAt(e.edge('e-llm-code'));
    await settle(t, 800);
    expect(e.c.selectedEdgeId, 'e-llm-code');
    expect(find.byKey(const ValueKey('phone-edge-bar')), findsOneWidget);
    final before = e.c.doc.nodes.keys.toSet();
    await t.tap(find.byKey(const ValueKey('phone-edge-insert')));
    await settle(t, 800);
    await e.pick('Template');
    final added = e.c.doc.nodes.keys.toSet().difference(before).single;
    final edges = e.c.doc.edges.values;
    expect(edges.any((x) => x.source == 'llm' && x.target == added), isTrue);
    expect(edges.any((x) => x.source == added && x.target == 'code'), isTrue);
    expect(edges.any((x) => x.source == 'llm' && x.target == 'code'), isFalse);

    // The new node is selected (its "+" takes taps around its handle): clear the selection first.
    expect(e.c.selectedNodeId, added);
    expect(await systemBack(t), isTrue);
    final edge = edges.firstWhere((x) => x.source == added && x.target == 'code').id;
    await t.tapAt(e.edge(edge));
    await settle(t, 800);
    expect(e.c.selectedEdgeId, edge);
    await t.tap(find.byKey(const ValueKey('phone-edge-delete')));
    await settle(t, 400);
    expect(e.c.doc.edges.containsKey(edge), isFalse);
    await e.dispose();
  });

  testWidgets('the phone run history sheet opens without an inherited lookup in initState', (t) async {
    final e = await _pump(t);
    unawaited(showRunHistorySheet(t.element(find.byType(PhoneEditorFrame))));
    await settle(t, 800);
    expect(t.takeException(), isNull);
    expect(await systemBack(t), isTrue);
    await settle(t, 400);
    await e.dispose();
  });

  testWidgets('zoomed out, a tap on a card selects that card, not its neighbour\'s enlarged handle area', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    e.canvas.zoomTo(.25);
    await settle(t, 400);
    // The point 3 px inside the left edge of the card after llm: within llm's 44 px finger area at 25 %.
    final code = e.canvas.graph!['code']!.rect;
    final p = e.node('code', (r) => Offset(r.left, r.center.dy)) + const Offset(3, 0);
    expect(code.width * e.canvas.view.scale, greaterThan(6));
    await t.tapAt(p);
    await settle(t, 600);
    expect(e.c.selectedNodeId, 'code');
    expect(e.c.selectedEdgeId, isNull);
    expect(find.byKey(const ValueKey('phone-node-bar')), findsOneWidget);
    await e.dispose();
  });

  testWidgets('the selected node\'s large "+": a tap adds the next node', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tapAt(e.node('llm'));
    await settle(t, 600);
    final plus = find.byWidgetPredicate(
      (w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('phone-plus-llm'),
    );
    expect(plus, findsOneWidget);
    expect(t.getSize(plus), const Size(28, 28));
    await t.tapAt(t.getCenter(plus));
    await settle(t, 800);
    expect(find.byType(BlockSelectorCard), findsOneWidget);
    expect(find.text(DifyI18n.tr('phone-editor', 'addAfter', {'name': 'Answer the question'})), findsOneWidget);
    final before = e.c.doc.nodes.keys.toSet();
    await e.pick('Template');
    final added = e.c.doc.nodes.keys.toSet().difference(before).single;
    expect(e.c.doc.edges.values.any((x) => x.source == 'llm' && x.target == added), isTrue);
    await e.dispose();
  });

  testWidgets('select mode: one finger draws a box; the group bar deletes, duplicates, organizes', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.tap(find.byKey(const ValueKey('phone-canvas-mode')));
    await settle(t, 300);
    expect(e.phone.selectMode, isTrue);
    expect(e.canvas.touchSelect.value, isTrue);
    final llm = e.canvas.graph!['llm']!.rect, code = e.canvas.graph!['code']!.rect;
    final top = e.canvas.view.toScreen(Offset(0, llm.top)).dy - 60;
    final from = t.getTopLeft(e.canvasFinder) + Offset(e.canvas.view.toScreen(llm.topLeft).dx - 8, top);
    final to = t.getTopLeft(e.canvasFinder) + e.canvas.view.toScreen(code.bottomRight) + const Offset(8, 20);
    final g = await t.startGesture(from);
    for (var i = 1; i <= 10; i++) {
      await g.moveTo(Offset.lerp(from, to, i / 10)!);
      await t.pump(const Duration(milliseconds: 16));
    }
    await g.up();
    await settle(t, 600);
    final ids = {for (final s in e.canvas.selection.nodes) e.canvas.graph!.slots[s]!.id};
    expect(ids, {'llm', 'code'});
    expect(find.byKey(const ValueKey('phone-group-bar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('phone-group-organize')));
    await settle(t, 600);
    expect(find.text(_tw('operator.alignLeft')), findsOneWidget);
    expect(await systemBack(t), isTrue);
    await t.tap(find.byKey(const ValueKey('phone-group-delete')));
    await settle(t, 600);
    expect(e.c.doc.nodes.containsKey('llm'), isFalse);
    expect(e.c.doc.nodes.containsKey('code'), isFalse);
    await e.dispose();
  });

  testWidgets('a long press on a node opens its actions as a sheet', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    await t.longPressAt(e.node('code'));
    await settle(t, 800);
    expect(e.c.selectedNodeId, 'code');
    for (final label in [
      DifyI18n.tr('common', 'operation.settings'),
      _tw('panel.runThisStep'),
      _tp('addNext'),
      _tp('connect'),
      _tw('common.duplicate'),
      DifyI18n.tr('common', 'operation.delete'),
    ]) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    await t.tap(find.text(DifyI18n.tr('common', 'operation.settings')).last);
    await settle(t, 800);
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    await e.dispose();
  });

  testWidgets('the overflow sheet holds the header\'s and the canvas tools\' actions', (t) async {
    final e = await _pump(t);
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    for (final label in [
      _tw('common.versionHistory'),
      _tw('panel.checklist'),
      _tw('env.envPanelTitle'),
      _tw('globalVar.title'),
      _tw('debug.variableInspect.title'),
      _tw('panel.organizeBlocks'),
      _tp('zoom'),
      _tw('common.exportImage'),
      _tw('changeHistory.title'),
      _tp('connectionDetails'),
    ]) {
      expect(find.textContaining(label), findsOneWidget, reason: label);
    }
    // The variable inspect panel opens as a page; back closes it.
    await t.tap(find.text(_tw('debug.variableInspect.title')));
    await settle(t, 800);
    expect(e.store.showVariableInspectPanel.value, isTrue);
    expect(find.byKey(const ValueKey('phone-variable-inspect')), findsOneWidget);
    expect(await systemBack(t), isTrue);
    expect(e.store.showVariableInspectPanel.value, isFalse);

    // Version history: the canvas browses versions with the restoring bars; back leaves it.
    await t.tap(find.text(_tp('versions')));
    await settle(t, 800);
    expect(e.store.isRestoring.value, isTrue);
    expect(find.byKey(const ValueKey('phone-restoring-bar')), findsOneWidget);
    expect(find.byKey(const ValueKey('phone-restore')), findsOneWidget);
    expect(await systemBack(t), isTrue, reason: 'closes the version list');
    expect(e.store.isRestoring.value, isTrue);
    expect(await systemBack(t), isTrue, reason: 'leaves the versions');
    expect(e.store.isRestoring.value, isFalse);
    expect(find.byKey(const ValueKey('phone-toolbar')), findsOneWidget);

    // The checklist chip opens the checklist.
    await t.tap(find.byKey(const ValueKey('phone-issues')));
    await settle(t, 800);
    expect(find.textContaining(_tw('panel.checklist')), findsWidgets);
    expect(await systemBack(t), isTrue);
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  testWidgets('Android back: the sheet, the panel, the selection, select mode, then the editor', (t) async {
    final e = await _pump(t, pushed: true);
    await e.showCanvas();
    await t.tapAt(e.node('code'));
    await settle(t, 600);
    await t.tap(find.byKey(const ValueKey('phone-node-settings')));
    await settle(t, 600);
    await t.tap(find.byKey(const ValueKey('phone-editor-more')));
    await settle(t, 800);
    expect(find.byType(Scrollable), findsWidgets);

    expect(await systemBack(t), isTrue, reason: 'the sheet');
    expect(find.text(_tp('connectionDetails')), findsNothing);
    expect(find.byType(WorkflowNodePanel), findsOneWidget);
    expect(await systemBack(t), isTrue, reason: 'the panel');
    expect(find.byType(WorkflowNodePanel), findsNothing);
    expect(e.c.selectedNodeId, 'code');
    expect(await systemBack(t), isTrue, reason: 'the selection');
    expect(e.c.selectedNodeId, isNull);
    expect(find.byKey(const ValueKey('phone-toolbar')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('phone-canvas-mode')));
    await settle(t, 300);
    expect(await systemBack(t), isTrue, reason: 'select mode');
    expect(e.phone.selectMode, isFalse);
    expect(await systemBack(t), isTrue, reason: 'the editor');
    expect(find.byType(EditorPage), findsNothing);
    expect(find.byKey(const ValueKey('home')), findsOneWidget);
    await e.dispose();
  });

  testWidgets('rotating to landscape keeps the canvas and shows the desktop editor', (t) async {
    final e = await _pump(t);
    await e.showCanvas();
    final state = t.state<WorkflowCanvasState>(e.canvasFinder);
    t.view.physicalSize = const Size(914, 411);
    t.view.padding = const FakeViewPadding(left: 32, right: 48);
    t.view.viewPadding = const FakeViewPadding(left: 32, right: 48);
    await settle(t, 800);
    expect(find.byType(PhoneEditorFrame), findsNothing);
    expect(find.byType(HeaderInNormal), findsOneWidget);
    expect(t.state<WorkflowCanvasState>(e.canvasFinder), same(state), reason: 'the canvas kept its state');
    t.view.physicalSize = const Size(411, 914);
    t.view.padding = const FakeViewPadding(top: 32, bottom: 24);
    t.view.viewPadding = const FakeViewPadding(top: 32, bottom: 24);
    await settle(t, 800);
    expect(find.byType(PhoneEditorFrame), findsOneWidget);
    expect(t.state<WorkflowCanvasState>(e.canvasFinder), same(state));
    expect(t.takeException(), isNull);
    await e.dispose();
  });

  for (final size in const [Size(640, 844), Size(1440, 900)]) {
    testWidgets('${size.width.toInt()} px: the desktop editor, without the phone layout', (t) async {
      final e = await _pump(t, size: size, insets: EdgeInsets.zero);
      expect(find.byType(PhoneEditorFrame), findsNothing);
      expect(find.byType(PhoneEditorScope), findsNothing);
      expect(find.byType(HeaderInNormal), findsOneWidget);
      expect(find.byType(WorkflowControl), findsOneWidget);
      expect(find.byType(WorkflowOperator), findsOneWidget);
      // Selecting a node opens its panel at once, as before.
      e.c.selectNode('code');
      await settle(t, 600);
      expect(find.byType(WorkflowNodePanel), findsOneWidget);
      expect(t.takeException(), isNull);
      await e.dispose();
    });
  }
}
