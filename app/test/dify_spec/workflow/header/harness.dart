import 'dart:async';
import 'dart:ui';

import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/canvas/canvas_graph.dart';
import 'package:dify_sf_app/src/workflow_editor/header/header_data.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

/// Dify's `renderWorkflowComponent`: [w] inside a fresh workflow store (set up by [initialStoreState]) and the
/// header's [data] and [canvas], at the top-left of a page with room for popups.
Future<WorkflowStore> renderWorkflowComponent(
  WidgetTester t,
  Widget w, {
  void Function(WorkflowStore store)? initialStoreState,
  WorkflowHeaderData data = const WorkflowHeaderData(),
  CanvasController? canvas,
  Size size = const Size(2400, 1200),
  bool testTranslator = true,
}) async {
  if (testTranslator) useDifyTestTranslator();
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final store = WorkflowStore();
  addTearDown(store.dispose);
  initialStoreState?.call(store);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: Align(
          alignment: Alignment.topLeft,
          child: Padding(
            padding: const EdgeInsets.all(240),
            child: WorkflowStoreScope(
              store: store,
              child: WorkflowHeaderScope(data: data, canvas: canvas, child: w),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return store;
}

/// Lets popups finish their transitions.
Future<void> settle(WidgetTester t) async {
  await t.pump();
  // Mount controlled portals and start their ticker before advancing time.
  await t.pump();
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
}

/// A canvas holding [nodes] (ids), with [selected] selected.
CanvasController canvasWith(List<String> nodes, {String? selected}) {
  final c = CanvasController();
  final g = CanvasGraph(
    layoutOf: (_, _, {run = NodeRunView.idle, selected = false}) =>
        const CardLayout(card: Rect.fromLTWH(0, 0, 240, 80)),
  );
  g.sync(
    Document(
      nodes: [for (final (i, id) in nodes.indexed) Node(id: id, type: 'code', title: id, x: i * 300, y: 0)],
    ),
  );
  c.graph = g;
  if (selected != null) c.selection.selectNodes([g[selected]!.slot]);
  return c;
}

/// Whether the control named [label] is enabled (`toBeDisabled` / `toBeEnabled`).
bool isEnabled(WidgetTester t, Pattern label) {
  final sem = t.getSemantics(find.bySemanticsLabel(label).first);
  return sem.getSemanticsData().flagsCollection.isEnabled == Tristate.isTrue;
}

/// A future that never completes (a query still loading).
Future<T> pending<T>() => Completer<T>().future;

/// All the text on screen, in order (`container.textContent`).
String textContent(WidgetTester t) => find.byType(Text).evaluate().map((e) => (e.widget as Text).data ?? '').join(' ');

/// Whether what [f] finds is (part of) a button.
bool isButton(WidgetTester t, Finder f) => t.getSemantics(f).getSemanticsData().flagsCollection.isButton;
