// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/var-list.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/variable/__tests__/output-var-list.spec.tsx
//
// Dify mocks the value picker and type picker; the real ones are used here (an empty variable scope). Outputs are
// name -> VarType maps (Dify's `{type, children: null}` entries).
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _names = find.byType(TextField);
final _removes = find.bySemanticsLabel('common.operation.remove');
final _handles = find.bySemanticsLabel(RegExp('^common.sort.handle'));
final _values = find.byKey(const Key('var-reference-picker-trigger'));

const initialVariables = [
  VarListItem(variable: 'alpha', valueSelector: ['node-id', 'alpha'], valueType: 'string'),
  VarListItem(variable: 'beta', valueSelector: ['node-id', 'beta'], valueType: 'string'),
  VarListItem(variable: 'gamma', valueSelector: ['node-id', 'gamma'], valueType: 'string'),
];

/// SortableVariables: a VarList keeping its own list.
class SortableVariables extends StatefulWidget {
  const SortableVariables({super.key, required this.onChange, this.readonly = false});
  final ValueChanged<List<VarListItem>> onChange;
  final bool readonly;

  @override
  State<SortableVariables> createState() => _SortableVariablesState();
}

class _SortableVariablesState extends State<SortableVariables> {
  var _list = initialVariables;

  @override
  Widget build(BuildContext context) => VarList(
    list: _list,
    scope: const VarScope(),
    readonly: widget.readonly,
    onChange: (items) {
      widget.onChange(items);
      setState(() => _list = items);
    },
  );
}

/// Whether the primary focus is in the widget [f] finds (at [index]).
bool focusedIn(Finder f, [int index = 0]) {
  final focused = FocusManager.instance.primaryFocus?.context;
  if (focused == null) return false;
  final target = f.evaluate().elementAt(index);
  var inside = focused == target;
  focused.visitAncestorElements((e) {
    if (e == target) inside = true;
    return !inside;
  });
  return inside;
}

List<String> nameValues(WidgetTester t) => [for (final f in t.widgetList<TextField>(_names)) f.controller!.text];

Future<void> tab(WidgetTester t, {bool shift = false}) async {
  if (shift) await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.tab);
  if (shift) await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await t.pump();
}

Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
  await t.sendKeyEvent(k);
  await t.pump();
  await t.pump();
}

void main() {
  group('VarList', () {
    testWidgets('normalizes a variable name through its labeled input', (t) async {
      final changes = <List<VarListItem>>[];
      await render(
        t,
        VarList(
          scope: const VarScope(),
          list: const [
            VarListItem(variable: 'input', valueSelector: ['node-id', 'value'], valueType: 'string'),
          ],
          onChange: changes.add,
        ),
      );

      expect(find.bySemanticsLabel('workflow.common.variableNamePlaceholder'), findsWidgets);
      await t.enterText(_names, 'renamed input');

      expect(changes.last.single.variable, 'renamed_input');
    });
  });

  testWidgets('tabs through each variable from the reorder handle to its name, value and remove button', (t) async {
    await render(t, SortableVariables(onChange: (_) {}));

    for (var i = 0; i < initialVariables.length; i++) {
      for (final control in [_handles, _names, _values, _removes]) {
        await tab(t);
        expect(focusedIn(control, i), isTrue, reason: '$control $i');
      }
    }

    await tab(t, shift: true);
    expect(focusedIn(_values, 2), isTrue);
    await tab(t, shift: true);
    expect(focusedIn(_names, 2), isTrue);
    await tab(t, shift: true);
    expect(focusedIn(_handles, 2), isTrue);
  });

  testWidgets('previews variable ordering, commits only on confirmation, and keeps the moved handle focused', (
    t,
  ) async {
    final changes = <List<VarListItem>>[];
    await render(t, SortableVariables(onChange: changes.add));
    expect(changes, isEmpty);

    await tab(t);
    expect(focusedIn(_handles, 0), isTrue);
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(nameValues(t), ['beta', 'alpha', 'gamma']);
    expect(changes, isEmpty);
    expect(focusedIn(_handles, 1), isTrue);
    expect(t.getSemantics(_handles.at(1)), isSemantics(isToggled: true));

    await key(t, LogicalKeyboardKey.enter);
    expect(changes, [
      [initialVariables[1], initialVariables[0], initialVariables[2]],
    ]);
    expect(focusedIn(_handles, 1), isTrue);
  });

  testWidgets('cancels a variable reorder and leaves arrow keys inside name inputs available for editing', (t) async {
    final changes = <List<VarListItem>>[];
    await render(t, SortableVariables(onChange: changes.add));

    await tab(t);
    await tab(t);
    expect(focusedIn(_names, 0), isTrue);
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(changes, isEmpty);

    await tab(t, shift: true);
    expect(focusedIn(_handles, 0), isTrue);
    await key(t, LogicalKeyboardKey.space);
    await key(t, LogicalKeyboardKey.arrowDown);
    await key(t, LogicalKeyboardKey.escape);

    expect(nameValues(t), ['alpha', 'beta', 'gamma']);
    expect(changes, isEmpty);
    expect(focusedIn(_handles, 0), isTrue);
  });

  testWidgets('does not expose variable sorting in readonly mode', (t) async {
    await render(t, SortableVariables(onChange: (_) {}, readonly: true));

    expect(_handles, findsNothing);
  });

  testWidgets('cancels a preview before deleting the variable whose remove button was activated', (t) async {
    final changes = <List<VarListItem>>[];
    await render(t, SortableVariables(onChange: changes.add));

    await tab(t);
    expect(focusedIn(_handles, 0), isTrue);
    await key(t, LogicalKeyboardKey.enter);
    await key(t, LogicalKeyboardKey.arrowDown);
    await t.tap(_removes.at(1));
    await t.pump();

    expect(changes, [
      [initialVariables[1], initialVariables[2]],
    ]);
    expect(nameValues(t), ['beta', 'gamma']);
  });

  group('OutputVarList', () {
    Future<Map<String, String>> collectRenameResult(
      WidgetTester t,
      Map<String, String> outputs,
      List<String> outputKeyOrders,
      int renameIndex,
      String newName,
    ) async {
      Map<String, String>? captured;
      await render(
        t,
        OutputVarList(
          outputs: outputs,
          outputKeyOrders: outputKeyOrders,
          onChange: (o, [_, _]) => captured = o,
          onRemove: (_) {},
        ),
      );
      await t.enterText(_names.at(renameIndex), newName);
      await t.pump(const Duration(milliseconds: 600));
      return captured!;
    }

    group('duplicate name handling', () {
      testWidgets('should preserve outputs entry when renaming one of two duplicate-name variables', (t) async {
        final next = await collectRenameResult(t, {'var_1': 'string'}, ['var_1', 'var_1'], 1, '');

        expect(next[''], 'string');
        expect(next['var_1'], 'string');
      });

      testWidgets('should delete old key when renamed entry is the only one using it', (t) async {
        final next = await collectRenameResult(
          t,
          {'var_1': 'string', 'var_2': 'number'},
          ['var_1', 'var_2'],
          1,
          'renamed',
        );

        expect(next['renamed'], 'number');
        expect(next.containsKey('var_2'), isFalse);
        expect(next['var_1'], 'string');
      });

      testWidgets('should keep outputs key alive when duplicate is renamed back to unique name', (t) async {
        final afterFirst = await collectRenameResult(
          t,
          {'var_1': 'string', 'var_2': 'number'},
          [
            'var_1',
            'var_2',
          ],
          1,
          'var_1',
        );
        expect(afterFirst.containsKey('var_2'), isFalse);
        expect(afterFirst.containsKey('var_1'), isTrue);

        final afterSecond = await collectRenameResult(t, afterFirst, ['var_1', 'var_1'], 1, 'var_2');
        expect(afterSecond.containsKey('var_1'), isTrue);
        expect(afterSecond.containsKey('var_2'), isTrue);
      });
    });

    group('removal with duplicate names', () {
      testWidgets('should call onRemove with correct index when removing a duplicate', (t) async {
        final removed = <int>[];
        await render(
          t,
          OutputVarList(
            outputs: const {'var_1': 'string'},
            outputKeyOrders: const ['var_1', 'var_1'],
            onChange: (_, [_, _]) {},
            onRemove: removed.add,
          ),
        );

        await t.tap(_removes.at(1));
        expect(removed, [1]);
      });
    });

    group('normal operation', () {
      testWidgets('should render one row per outputKeyOrders entry', (t) async {
        await render(
          t,
          OutputVarList(
            outputs: const {'a': 'string', 'b': 'number'},
            outputKeyOrders: const ['a', 'b'],
            onChange: (_, [_, _]) {},
            onRemove: (_) {},
          ),
        );

        expect(_names, findsNWidgets(2));
        expect(nameValues(t), ['a', 'b']);
      });

      testWidgets('should call onChange with updated outputs when renaming', (t) async {
        final calls = <(Map<String, String>, int?, String?)>[];
        await render(
          t,
          OutputVarList(
            outputs: const {'var_1': 'string'},
            outputKeyOrders: const ['var_1'],
            onChange: (o, [i, k]) => calls.add((o, i, k)),
            onRemove: (_) {},
          ),
        );

        await t.enterText(_names, 'new_name');
        await t.pump(const Duration(milliseconds: 600));

        expect(calls.single.$1['new_name'], 'string');
        expect((calls.single.$2, calls.single.$3), (0, 'new_name'));
      });

      testWidgets('should call onRemove when remove button is clicked', (t) async {
        final removed = <int>[];
        await render(
          t,
          OutputVarList(
            outputs: const {'var_1': 'string'},
            outputKeyOrders: const ['var_1'],
            onChange: (_, [_, _]) {},
            onRemove: removed.add,
          ),
        );

        await t.tap(_removes);
        expect(removed, [0]);
      });

      testWidgets('should render inputs as readonly when readonly is true', (t) async {
        await render(
          t,
          OutputVarList(
            readonly: true,
            outputs: const {'var_1': 'string'},
            outputKeyOrders: const ['var_1'],
            onChange: (_, [_, _]) {},
            onRemove: (_) {},
          ),
        );

        expect(t.widget<TextField>(_names).readOnly, isTrue);
      });
    });
  });
}
