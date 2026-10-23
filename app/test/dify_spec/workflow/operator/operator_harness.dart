import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/canvas/canvas_controller.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/operator.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// [w] at the top-left of a page (a canvas-sized area), with [store] as the editor's store.
Future<void> pumpWithStore(WidgetTester t, WorkflowStore store, Widget w, {Alignment align = Alignment.center}) async {
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Material(
        child: WorkflowStoreScope(
          store: store,
          child: Align(alignment: align, child: w),
        ),
      ),
    ),
  );
  await t.pump();
}

/// A canvas whose viewport is laid out (800×600) at [scale], counting the zoom buttons' calls.
class TestCanvas extends CanvasController {
  TestCanvas({double scale = 1}) {
    view
      ..viewport = const Size(800, 600)
      ..scale = scale;
  }
  int zoomIns = 0, zoomOuts = 0;

  @override
  void zoomIn() {
    zoomIns++;
    super.zoomIn();
  }

  @override
  void zoomOut() {
    zoomOuts++;
    super.zoomOut();
  }
}

/// An undo history over a small document, with [past] steps done and the last [future] of them undone.
class TestHistory extends UndoManager {
  TestHistory._(Document d)
    : _d = d,
      super(doc: () => d, submit: (op) => d.apply(op, Stamp(++_seq, 'me')), newId: (p) => '$p-${++_seq}');

  factory TestHistory({int past = 0, int future = 0}) {
    final h = TestHistory._(
      Document(
        nodes: const [
          Node(id: 'a', type: 'start', title: 'Start', x: 0, y: 0),
          Node(id: 'b', type: 'llm', title: 'LLM', x: 300, y: 0),
        ],
        edges: const [],
      ),
    );
    for (var i = 0; i < past + future; i++) {
      h.move('b', 300 + 10 * (i + 1));
    }
    for (var i = 0; i < future; i++) {
      h.undo();
    }
    return h;
  }

  final Document _d;
  static int _seq = 0;

  /// One user move of node [id], recorded as Dify's NodeDragStop.
  void move(String id, int x) {
    const event = HistoryEvent.nodeDragStop;
    final op = MoveNode(id, x, 0);
    record(op, event: event);
    _d.apply(op, Stamp(++_seq, 'me'));
  }

  bool get listening => hasListeners;
}

/// The [OperatorButton] or other pressable named [label].
Finder pressable(String label) => find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == label);

/// Gives keyboard focus to the button named [label] (like `element.focus()`); returns whether it took it.
Future<bool> focusButton(WidgetTester t, String label) async {
  final node = Focus.of(t.element(find.descendant(of: pressable(label), matching: find.byType(MouseRegion)).last));
  node.requestFocus();
  await t.pump();
  return node.hasPrimaryFocus;
}
