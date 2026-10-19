import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/panel_fields/harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Node node(String id, String type, {String title = '', int x = 0, Map<String, Object?> config = const {}}) => Node(
  id: id,
  type: type,
  title: title,
  x: x,
  config: {for (final e in config.entries) e.key: Value.fromJson(e.value)},
);

final start = node(
  'start',
  'start',
  title: 'User Input',
  config: {
    'variables': [
      {'variable': 'question', 'type': 'text-input'},
      {'variable': 'doc', 'type': 'file'},
    ],
  },
);
final code = node(
  'code',
  'code',
  title: 'Code',
  x: 300,
  config: {
    'outputs': {
      'result': {'type': 'string'},
      'data': {'type': 'object'},
    },
  },
);

Future<void> hover(WidgetTester t, Finder f) async {
  final mouse = await t.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(t.getCenter(f));
  await t.pumpAndSettle();
}

void main() {
  group('VarScope', () {
    test('of: groups the upstream nodes like toNodeAvailableVars and types selections', () {
      final scope = VarScope.of(beforeNodes: [start, code]);
      expect([for (final g in scope.vars) g.nodeId], ['code', 'start', 'global']);
      expect(scope.vars.first.vars.map((v) => v.variable), ['result', 'data']);
      expect(scope.typeOf!(const ['code', 'result']), 'string');
      expect(scope.lookup('start')?.title, 'User Input');
      expect(scope.start?.id, 'start');
    });

    test('filtered keeps accepted variables and drops empty groups; withoutFileVars drops files', () {
      final scope = VarScope.of(beforeNodes: [start, code]);
      final files = scope.filtered((v, _) => v.type == 'file' || v.type == 'array[file]');
      expect([for (final g in files.vars) g.nodeId], ['start']);
      expect(files.vars.single.vars.map((v) => v.variable), contains('doc'));
      expect(
        scope.withoutFileVars().vars.expand((g) => g.vars).where((v) => v.type == 'file' || v.type == 'array[file]'),
        isEmpty,
      );
    });
  });

  group('VarReferencePicker', () {
    testWidgets('lists the scope by node and shows the chosen variable with its node and type', (t) async {
      final changes = <List<String>>[];
      await render(
        t,
        VarReferencePicker(
          value: const [],
          scope: VarScope.of(beforeNodes: [start, code]),
          onChange: (s, _) => changes.add(s),
        ),
      );
      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await t.pumpAndSettle();

      expect(find.text('CODE'), findsOneWidget);
      expect(find.text('USER INPUT'), findsOneWidget);
      expect(find.text('SYSTEM'), findsOneWidget);
      await t.tap(find.text('question'));
      await t.pumpAndSettle();
      expect(changes.single, ['start', 'question']);
      expect(find.byType(VarReferenceVars), findsNothing);

      await render(
        t,
        VarReferencePicker(
          value: const ['code', 'result'],
          scope: VarScope.of(beforeNodes: [start, code]),
          onChange: (_, _) {},
        ),
      );
      expect(find.text('Code'), findsOneWidget);
      expect(find.text('result'), findsOneWidget);
      expect(find.text('String'), findsOneWidget);
    });

    testWidgets('search narrows the list and Enter picks the first match', (t) async {
      final changes = <List<String>>[];
      await render(
        t,
        VarReferencePicker(
          value: const [],
          scope: VarScope.of(beforeNodes: [start, code]),
          onChange: (s, _) => changes.add(s),
        ),
      );
      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await t.pumpAndSettle();
      await t.enterText(find.byType(TextField), 'resu');
      await t.pump();
      expect(find.text('question'), findsNothing);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pumpAndSettle();
      expect(changes.single, ['code', 'result']);
    });

    testWidgets('hovering an object opens its members and choosing one selects the nested path', (t) async {
      final changes = <List<String>>[];
      await render(
        t,
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 240,
            child: VarReferencePicker(
              value: const [],
              scope: scopeOf(const [
                VarGroup(
                  nodeId: 'llm',
                  title: 'LLM',
                  vars: [
                    PickerVar('usage', 'object', children: [PickerVar('tokens', 'number')]),
                  ],
                ),
              ]),
              onChange: (s, _) => changes.add(s),
            ),
          ),
        ),
        width: 800,
      );
      await t.tap(find.byKey(const Key('var-reference-picker-trigger')));
      await t.pumpAndSettle();
      await hover(t, find.text('usage'));

      expect(find.byType(PickerStructurePanel), findsOneWidget);
      await t.tap(find.text('tokens'));
      await t.pumpAndSettle();
      expect(changes.single, ['llm', 'usage', 'tokens']);
    });

    testWidgets('the chevron opens the members on touch', (t) async {
      await render(
        t,
        Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: 240,
            child: VarReferenceVars(
              vars: const [
                VarGroup(
                  nodeId: 'llm',
                  title: 'LLM',
                  vars: [
                    PickerVar('usage', 'object', children: [PickerVar('tokens', 'number')]),
                  ],
                ),
              ],
              onChange: (_, _) {},
            ),
          ),
        ),
        width: 800,
      );
      await t.tap(find.byType(DifyIcon).last);
      await t.pumpAndSettle();
      expect(find.text('tokens'), findsOneWidget);
    });
  });

  group('VarList', () {
    testWidgets('names an unnamed row after the variable picked for it, avoiding duplicates', (t) async {
      final changes = <List<VarListItem>>[];
      await render(
        t,
        VarList(
          scope: VarScope.of(beforeNodes: [start, code]),
          list: const [
            VarListItem(variable: 'result'),
            VarListItem(variable: ''),
          ],
          onChange: changes.add,
        ),
        width: 420,
      );
      await t.tap(find.byKey(const Key('var-reference-picker-trigger')).at(1));
      await t.pumpAndSettle();
      await t.tap(find.descendant(of: find.byType(VarReferenceVars), matching: find.text('result')));
      await t.pumpAndSettle();

      final row = changes.single[1];
      expect(row.variable, 'result_1');
      expect(row.valueSelector, ['code', 'result']);
      expect(row.valueType, 'string');
    });
  });

  group('controls', () {
    testWidgets('DifySwitch toggles and reports, unless disabled', (t) async {
      final changes = <bool>[];
      await render(t, DifySwitch(checked: false, onCheckedChange: changes.add, semanticLabel: 's'));
      await t.tap(find.byType(DifySwitch));
      expect(changes, [true]);

      await render(t, DifySwitch(checked: false, disabled: true, onCheckedChange: changes.add));
      await t.tap(find.byType(DifySwitch));
      expect(changes, [true]);
    });

    testWidgets('DifySlider steps with the keyboard and clamps', (t) async {
      final changes = <int>[];
      await render(
        t,
        Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: 100, child: DifySlider(value: 10, min: 1, max: 10, onChanged: changes.add)),
        ),
      );
      await t.tap(find.byType(DifySlider));
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.home);
      expect(changes, [6, 1]);
    });

    testWidgets('TypeSelector and VarTypePicker choose an option', (t) async {
      final chosen = <String>[];
      await render(
        t,
        TypeSelector<String>(
          value: 'python3',
          options: const [(value: 'python3', label: 'Python3'), (value: 'javascript', label: 'JavaScript')],
          onChanged: chosen.add,
        ),
      );
      await t.tap(find.text('Python3'));
      await t.pumpAndSettle();
      await t.tap(find.text('JavaScript'));
      await t.pumpAndSettle();
      expect(chosen, ['javascript']);

      await render(t, VarTypePicker(value: 'string', onChanged: chosen.add));
      await t.tap(find.text('String'));
      await t.pumpAndSettle();
      await t.tap(find.text('Array[Number]'));
      await t.pumpAndSettle();
      expect(chosen.last, 'array[number]');
    });

    testWidgets('OptionCard selects only when not selected', (t) async {
      var selected = 0;
      await render(t, OptionCard(title: 'High', selected: true, onSelect: () => selected++));
      await t.tap(find.text('High'));
      await render(t, OptionCard(title: 'Low', selected: false, onSelect: () => selected++));
      await t.tap(find.text('Low'));
      expect(selected, 1);
    });
  });

  group('layout pieces', () {
    testWidgets('OutputVars collapses its VarItems, InfoPanel shows title and content', (t) async {
      await render(
        t,
        const Column(
          children: [
            OutputVars(
              child: VarItem(name: 'output', type: 'string', description: 'Transformed content'),
            ),
            InfoPanel(title: 'Answer', content: Text('hello')),
          ],
        ),
      );
      expect(find.text('output'), findsNothing);
      await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
      await t.pump();
      expect(find.text('output'), findsOneWidget);
      expect(find.text('Transformed content'), findsOneWidget);
      expect(find.text('ANSWER'), findsOneWidget);
      expect(find.text('hello'), findsOneWidget);
    });

    test('InputVarTypeIcon maps the Start input types', () {
      expect(InputVarTypeIcon.iconOf('paragraph'), 'align-left');
      expect(InputVarTypeIcon.iconOf('file-list'), 'file-copy-2-line');
      expect(InputVarTypeIcon.iconOf('unknown'), 'text-snippet');
    });

    testWidgets('NextStepLine is as tall as Dify draws it', (t) async {
      await render(
        t,
        const Align(
          alignment: Alignment.topLeft,
          child: NextStepLine(counts: [2, 1]),
        ),
      );
      // (2*36 + 2 + 18) + (36 + 18) + 8
      expect(t.getSize(find.byType(NextStepLine)), const Size(24, 92 + 54 + 8));
    });

    test('nextStepBranches follows the default handle and skips missing nodes', () {
      final a = node('a', 'llm');
      final b = node('b', 'end', title: 'End');
      final branches = nextStepBranches(
        node: a,
        nodes: {'a': a, 'b': b},
        edges: const [
          Edge(id: '1', source: 'a', sourceHandle: 'out', target: 'b'),
          Edge(id: '2', source: 'a', sourceHandle: 'out', target: 'gone'),
        ],
        defaultHandle: 'out',
      );
      expect(branches.single.nextNodes.map((n) => n.title), ['End']);
    });
  });
}
