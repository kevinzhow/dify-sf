// dify-spec: web/app/components/workflow/nodes/loop/components/loop-variables/__tests__/item.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/loop/loop_variables.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../panel_fields/harness.dart';

const _item = {'id': 'loop-variable', 'label': 'item', 'var_type': 'string', 'value_type': 'constant', 'value': ''};

void main() {
  group('Loop variable item', () {
    testWidgets('normalizes the variable name through its labeled input', (t) async {
      final updates = <(String, Json)>[];
      await render(t, LoopVariableItem(item: _item, onRemove: (_) {}, onUpdate: (id, u) => updates.add((id, u))));

      final name = find.descendant(
        of: find.byWidgetPredicate((w) => w is DifyInput && w.semanticLabel == 'workflow.nodes.loop.variableName'),
        matching: find.byType(TextField),
      );
      await t.enterText(name, 'new name');

      expect(updates.last.$1, 'loop-variable');
      expect(updates.last.$2, {'label': 'new_name'});
    });

    testWidgets('removes the current variable from its named icon command', (t) async {
      final removed = <String>[];
      await render(t, LoopVariableItem(item: _item, onRemove: removed.add, onUpdate: (_, _) {}));

      await t.tap(find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'common.operation.remove'));

      expect(removed, ['loop-variable']);
    });
  });
}
