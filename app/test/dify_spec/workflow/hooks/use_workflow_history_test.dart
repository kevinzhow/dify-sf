// dify-spec: web/app/components/workflow/hooks/__tests__/use-workflow-history.spec.tsx
//
// useWorkflowHistory is the editor's UndoManager: a step records its event and node (Dify's
// workflowHistoryEvent / workflowHistoryEventMeta) with the ops that revert it (dify-sf keeps inverse ops of its own
// edits, not graph snapshots, so others' edits survive an undo); historyLabel is getHistoryLabel; the manager's
// listeners are the registered undo / redo callbacks.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:dify_sf_app/src/workflow_editor/operator/view_workflow_history.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

UndoManager _history(Document doc) {
  var seq = 0, ids = 0;
  return UndoManager(
    doc: () => doc,
    submit: (op) => doc.apply(op, Stamp(++seq, 'me')),
    newId: (p) => '$p-new${++ids}',
  );
}

void main() {
  group('useWorkflowHistory', () {
    test('stores the latest workflow graph snapshot for supported events', () {
      final doc = Document();
      final history = _history(doc);
      history.begin(HistoryEvent.nodeAdd, nodeTitle: 'Start', nodeType: 'start');
      const add = AddNode(Node(id: 'node-1', type: 'start', title: 'Start', x: 0, y: 0));
      history.record(add);
      doc.apply(add, const Stamp(1, 'me'));
      history.end();
      final step = history.past.single;
      expect(step.event, HistoryEvent.nodeAdd);
      expect((step.nodeTitle, step.nodeType), ('Start', 'start'));
      // Undo brings the graph back to before the step.
      history.undo();
      expect(doc.nodes, isEmpty);
    });

    test('returns translated labels and falls back for unsupported events', () {
      useDifyTestTranslator();
      expect(historyLabel(HistoryEvent.nodeDelete), matches(RegExp(r'(?:^|\.)changeHistory\.nodeDelete(?=$|:)')));
      expect(historyLabel(HistoryEvent.edgeSourceHandleChange), 'Unknown Event');
    });

    test('runs registered undo and redo callbacks', () {
      final doc = Document(
        nodes: const [Node(id: 'a', type: 'code', title: 'A', x: 0, y: 0)],
      );
      final history = _history(doc);
      history.begin(HistoryEvent.nodeDragStop, nodeId: 'a');
      history.record(const MoveNode('a', 10, 10));
      doc.apply(const MoveNode('a', 10, 10), const Stamp(1, 'me'));
      history.end();
      var calls = 0;
      history.addListener(() => calls++);
      history.undo();
      expect(doc.nodes['a']!.x, 0);
      expect(calls, greaterThan(0));
      final afterUndo = calls;
      history.redo();
      expect(doc.nodes['a']!.x, 10);
      expect(calls, greaterThan(afterUndo));
    });
  });
}
