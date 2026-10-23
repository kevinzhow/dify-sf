import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/editor/undo_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// A document edited by "us" through an UndoManager, and by "others" directly.
class _Doc {
  _Doc({this.restore = false});

  /// Undo node deletes with `restoreNode` (protocol 1.6).
  final bool restore;
  final doc = Document(
    nodes: const [
      Node(id: 'a', type: 'start', title: 'A', x: 0, y: 0),
      Node(id: 'b', type: 'llm', title: 'B', x: 300, y: 0),
    ],
    edges: const [Edge(id: 'e1', source: 'a', target: 'b')],
  );
  var seq = 0, ids = 0;
  late final undo = UndoManager(
    doc: () => doc,
    submit: (op) => doc.apply(op, Stamp(++seq, 'me')),
    newId: (p) => '$p-new${++ids}',
    restoreNode: restore ? RestoreNode.new : null,
  );

  void mine(Op op, {HistoryEvent? event}) {
    undo.record(op, event: event);
    doc.apply(op, Stamp(++seq, 'me'));
  }

  void theirs(Op op) => doc.apply(op, Stamp(++seq, 'other'));
}

void main() {
  test('a drag is one step; undo moves back, redo moves again', () {
    final d = _Doc();
    d.undo.begin(HistoryEvent.nodeDragStop, nodeId: 'b');
    d.mine(const MoveNode('b', 320, 10));
    d.mine(const MoveNode('b', 350, 20));
    d.undo.end();
    expect(d.undo.past.length, 1);
    d.undo.undo();
    expect((d.doc.nodes['b']!.x, d.doc.nodes['b']!.y), (300, 0));
    d.undo.redo();
    expect((d.doc.nodes['b']!.x, d.doc.nodes['b']!.y), (350, 20));
  });

  test("undo reverts only our edit; another client's later edit stays", () {
    final d = _Doc();
    d.mine(const SetField('b', TitleKey(), VString('Mine')), event: HistoryEvent.nodeTitleChange);
    d.theirs(const MoveNode('b', 500, 500));
    d.undo.undo();
    expect(d.doc.nodes['b']!.title, 'B');
    expect(d.doc.nodes['b']!.x, 500);
  });

  test('typing a title is one step', () {
    final d = _Doc();
    for (final t in ['M', 'Mi', 'Min', 'Mine']) {
      d.mine(SetField('b', const TitleKey(), VString(t)), event: HistoryEvent.nodeTitleChange);
    }
    expect(d.undo.past.length, 1);
    d.undo.undo();
    expect(d.doc.nodes['b']!.title, 'B');
  });

  test('undoing an edge delete re-creates the edge; adding a node is undone by removing it', () {
    final d = _Doc();
    d.mine(const RemoveEdge('e1'), event: HistoryEvent.edgeDelete);
    d.mine(
      const AddNode(Node(id: 'c', type: 'code', x: 600, y: 0)),
      event: HistoryEvent.nodeAdd,
    );
    d.undo.undo();
    expect(d.doc.nodes.containsKey('c'), isFalse);
    d.undo.undo();
    expect(d.doc.edges.values.where((e) => e.source == 'a' && e.target == 'b'), hasLength(1));
    expect(d.undo.canUndo, isFalse);
    // Redoing the node add needs the node restored (protocol 1.6); without a restore op only the edge can be redone.
    expect(d.undo.future, hasLength(1));
  });

  test('undoing a node delete restores the node with its edges (1.6); redo deletes it again', () {
    final d = _Doc(restore: true);
    final b = d.doc.nodes['b']!;
    d.mine(const RemoveNode('b'), event: HistoryEvent.nodeDelete);
    d.undo.undo();
    expect(d.doc.nodes['b'], b);
    expect(d.doc.edges.keys, ['e1']);
    expect(d.doc.deletedNodes, isEmpty);
    d.undo.redo();
    expect(d.doc.nodes.containsKey('b'), isFalse);
    d.undo.undo();
    expect(d.doc.nodes['b'], b);
    expect(d.doc.edges.keys, ['e1']);
  });

  test('a step whose node another client deleted is skipped', () {
    final d = _Doc();
    d.mine(const SetField('b', TitleKey(), VString('Mine')), event: HistoryEvent.nodeTitleChange);
    d.theirs(const RemoveNode('b'));
    d.undo.undo();
    expect(d.doc.nodes.containsKey('b'), isFalse);
    expect(d.undo.canRedo, isFalse);
  });

  test('a new edit clears redo', () {
    final d = _Doc();
    d.mine(const SetField('b', TitleKey(), VString('X')), event: HistoryEvent.nodeTitleChange);
    d.undo.undo();
    expect(d.undo.canRedo, isTrue);
    d.mine(const MoveNode('a', 5, 5), event: HistoryEvent.nodeDragStop);
    expect(d.undo.canRedo, isFalse);
  });
}
