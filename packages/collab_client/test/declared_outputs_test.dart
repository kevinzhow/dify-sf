/// Protocol 1.4: a node's declared outputs (the item ids of its `outputs` keyed list) are part of reference
/// integrity. Mirrors the server's DeclaredOutputTests.
library;

import 'package:collab_client/collab_client.dart';
import 'package:test/test.dart';

import 'support/helpers.dart';

const _out = VMap({'type': VString('string')});

Document doc() => Document(
  nodes: [
    const Node(
      id: 'code1',
      type: 'code',
      config: {
        'outputs': VItems([Item('result', _out), Item('extra', _out)]),
      },
    ),
    const Node(
      id: 'code2',
      type: 'code',
      config: {
        'variables': VItems([Item('a', VRef(OutputRef('code1', 'result')))]),
      },
    ),
    const Node(id: 'llm1', type: 'llm'),
  ],
);

Op setRef(String n, String to, String o) => UpdateItem(n, const ['variables'], 'a', VRef(OutputRef(to, o)));
const removeResult = RemoveItem('code1', ['outputs'], 'result');

void main() {
  test('a reference to a missing declared output is refused; nodes without declared outputs accept any name', () {
    final d = doc();
    expect(d.validate(setRef('code2', 'code1', 'nope'), base: 0, client: 'b'), const DanglingReference('code1'));
    expect(d.validate(setRef('code2', 'code1', 'extra'), base: 0, client: 'b'), isNull);
    expect(d.validate(setRef('code2', 'llm1', 'text'), base: 0, client: 'b'), isNull);
  });

  test('removing an output turns references to it into broken markers', () {
    final d = doc()..apply(removeResult, stamp(1, 'a'));
    final vars = d.nodes['code2']!.config['variables']! as VItems;
    expect(vars.items.single.value, const VBroken(OutputRef('code1', 'result')));
    expect(d.integrityProblems, isEmpty);
    expect(d.validate(setRef('code2', 'code1', 'result'), base: 0, client: 'b'), const DanglingReference('code1'));
  });

  test('a stale removal conflicts with a newer reference to that output', () {
    final d = doc()..apply(setRef('code2', 'code1', 'extra'), stamp(1, 'b'));
    const removeExtra = RemoveItem('code1', ['outputs'], 'extra');
    expect(d.validate(removeExtra, base: 0, client: 'a'), isA<Conflict>());
    expect(d.validate(removeExtra, base: 1, client: 'a'), isNull);
  });

  test('outputs are referenced by name; renaming an output breaks references to the old name', () {
    final d = Document(
      nodes: [
        const Node(
          id: 'code',
          type: 'code',
          config: {
            'outputs': VItems([
              Item('o-1', VMap({'name': VString('result')})),
            ]),
          },
        ),
        const Node(id: 'ans', type: 'answer', config: {'answer': VRef(OutputRef('code', 'result'))}),
      ],
    );
    expect(d.integrityProblems, isEmpty);
    expect(
      d.validate(const SetField('ans', ConfigKey(['answer']), VRef(OutputRef('code', 'o-1'))), base: 0, client: 'b'),
      const DanglingReference('code'),
    );
    d.apply(const UpdateItem('code', ['outputs'], 'o-1', VMap({'name': VString('answer_text')})), stamp(1, 'a'));
    expect(d.nodes['ans']!.config['answer'], const VBroken(OutputRef('code', 'result')));
    expect(d.integrityProblems, isEmpty);
  });

  test('integrity reports a reference to a missing output', () {
    final d = Document(
      nodes: [
        const Node(id: 'code1', type: 'code', config: {'outputs': VItems([])}),
        const Node(
          id: 'code2',
          type: 'code',
          config: {
            'variables': VItems([Item('a', VRef(OutputRef('code1', 'result')))]),
          },
        ),
      ],
    );
    expect(d.integrityProblems.any((p) => p.contains('code1.result')), isTrue);
  });
}
