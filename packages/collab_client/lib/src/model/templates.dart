import 'document.dart';
import 'ops.dart';
import 'value.dart';

/// Seed documents, identical to the server's `example` and `empty` templates (used by the fake server and
/// by tests; a real server creates its own).
abstract final class Templates {
  static Document? named(String? name) => switch (name ?? 'example') {
    'example' => example(),
    'empty' => empty(),
    _ => null,
  };

  static Document _seed(List<Op> ops) {
    final doc = Document();
    // Genesis stamps use seq 0, which is never greater than any base, so they can never conflict.
    for (final op in ops) {
      doc.apply(op, const Stamp(0, 'genesis'));
    }
    return doc;
  }

  static Document empty() => _seed([
    const AddNode(Node(id: 'start', type: 'start', title: 'Start', x: 80, y: 120)),
  ]);

  /// start -> llm -> code -> answer, with variable references and a keyed list (the code node's outputs).
  static Document example() {
    Value ref(String n, String o) => VRef(OutputRef(n, o));
    Value item(String name, String type) => VMap({'name': VString(name), 'type': VString(type)});
    return _seed([
      AddNode(
        Node(
          id: 'start',
          type: 'start',
          title: 'Start',
          x: 80,
          y: 120,
          config: {
            'variables': VItems([Item('v-query', item('query', 'string'))]),
          },
        ),
      ),
      AddNode(
        Node(
          id: 'llm',
          type: 'llm',
          title: 'Answer the question',
          x: 380,
          y: 120,
          config: {
            'model': const VMap({'provider': VString('openai'), 'name': VString('gpt-4o')}),
            'prompt': const VString('Answer briefly: {{#start.query#}}'),
            'context': ref('start', 'query'),
          },
        ),
      ),
      AddNode(
        Node(
          id: 'code',
          type: 'code',
          title: 'Post-process',
          x: 680,
          y: 120,
          config: {
            'language': const VString('python3'),
            'code': const VString("def main(text):\n    return {'result': text.strip()}"),
            'inputs': ref('llm', 'text'),
            'outputs': VItems([Item('o-result', item('result', 'string'))]),
          },
        ),
      ),
      AddNode(
        Node(
          id: 'answer',
          type: 'answer',
          title: 'Answer',
          x: 980,
          y: 120,
          config: {
            'answer': ref('code', 'result'),
          },
        ),
      ),
      const AddEdge(Edge(id: 'e-start-llm', source: 'start', target: 'llm')),
      const AddEdge(Edge(id: 'e-llm-code', source: 'llm', target: 'code')),
      const AddEdge(Edge(id: 'e-code-answer', source: 'code', target: 'answer')),
    ]);
  }
}
