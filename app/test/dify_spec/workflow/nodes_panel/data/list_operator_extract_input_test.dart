// dify-spec: web/app/components/workflow/nodes/list-operator/components/__tests__/extract-input.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/list_operator/list_operator_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';
import 'list_operator_sub_variable_picker_test.dart' show pumpControl;

const scope = VarScope(
  vars: [
    VarGroup(nodeId: 'number-node', title: 'Numbers', vars: [PickerVar('count', 'number')]),
    VarGroup(nodeId: 'text-node', title: 'Texts', vars: [PickerVar('name', 'string')]),
  ],
);

/// Types [text] into the variable-capable input under [of] (replacing its content).
Future<void> typeInto(WidgetTester t, Finder of, String text) async {
  final field = find.descendant(of: of, matching: find.byType(TextField));
  await t.tap(field);
  await t.pump();
  await t.enterText(field, text);
  await t.pump();
}

/// Whether a VarInput box shows the focused look (`bg-components-input-bg-active shadow-xs`).
bool focusedLook(WidgetTester t) => find
    .byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).color == DifyColors.componentsInputBgActive &&
          (w.decoration! as BoxDecoration).boxShadow == DifyShadows.xs,
    )
    .evaluate()
    .isNotEmpty;

void main() {
  group('list-operator/extract-input', () {
    testWidgets('should filter variables to numeric values and toggle focus styles', (t) async {
      final changes = <String>[];
      await pumpControl(t, ExtractInput(value: '5', scope: scope, onChange: (v, _) => changes.add(v)));

      final input = t.widget<VarInput>(find.byType(VarInput));
      expect(input.readOnly, false);
      expect(input.value, '5');
      expect(input.placeholder, 'workflow.nodes.http.extractListPlaceholder');
      expect([for (final g in input.vars) g.nodeId], ['number-node']);
      expect(input.vars.single.vars.single.variable, 'count');

      await typeInto(t, find.byType(VarInput), '12');
      expect(focusedLook(t), true);
      await blur(t);
      expect(focusedLook(t), false);
      expect(changes, ['12']);
    });

    testWidgets('should clear the placeholder when the component is readonly', (t) async {
      await pumpControl(t, ExtractInput(value: '', readOnly: true, onChange: (_, _) {}));
      final input = t.widget<VarInput>(find.byType(VarInput));
      expect(input.placeholder, '');
      expect(input.readOnly, true);
    });
  });
}
