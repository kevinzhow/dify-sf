import 'package:collab_client/collab_client.dart';
import 'package:collab_client/storm.dart';
import 'package:test/test.dart';

void main() {
  final empty = Document(
    nodes: const [Node(id: 'start', type: 'start')],
  );
  final withA = Document(
    nodes: const [
      Node(id: 'start', type: 'start'),
      Node(id: 'a', type: 'code'),
    ],
  );
  Map<String, Object?> move(String node, int x) => {
    'op': {'t': 'moveNode', 'node': node, 'x': x, 'y': 0},
  };

  test('waits for the nodes it needs, then sends its ops in order, then nothing', () {
    final editor = PlanEditor([
      {
        'wait': ['a'],
      },
      move('b', 1),
      move('b', 2),
    ]);
    expect(editor.next(empty), isNull);
    expect(editor.next(empty), isNull);
    expect(editor.next(withA), const MoveNode('b', 1, 0));
    expect(editor.next(empty), const MoveNode('b', 2, 0)); // a wait that passed stays passed
    expect(editor.next(withA), isNull);
    expect(editor.done, isTrue);
  });

  test('sleeps for the given time', () {
    var now = DateTime.utc(2026);
    final editor = PlanEditor([
      {'sleep_ms': 1000},
      move('b', 1),
    ], clock: () => now);
    expect(editor.next(empty), isNull);
    now = now.add(const Duration(milliseconds: 999));
    expect(editor.next(empty), isNull);
    now = now.add(const Duration(milliseconds: 1));
    expect(editor.next(empty), const MoveNode('b', 1, 0));
  });

  test('reports presence steps: only the keys a step names', () {
    final calls = <String>[];
    final editor = PlanEditor(
      [
        {
          'presence': {
            'cursor': [10, 20],
            'drag': {'node': 'a', 'x': 40, 'y': 22},
          },
        },
        {
          'presence': {'drag': null, 'panel': 'a'},
        },
        move('a', 1),
      ],
      onPresence: ({setsCursor = false, cursor, setsDrag = false, drag, setsPanel = false, panel}) => calls.add(
        '${setsCursor ? 'cursor=$cursor ' : ''}${setsDrag ? 'drag=$drag ' : ''}${setsPanel ? 'panel=$panel' : ''}'
            .trim(),
      ),
    );
    expect(editor.next(withA), const MoveNode('a', 1, 0));
    expect(calls, ['cursor=(10.0, 20.0) drag=drag(a, 40.0, 22.0)', 'drag=null panel=a']);
  });
}
