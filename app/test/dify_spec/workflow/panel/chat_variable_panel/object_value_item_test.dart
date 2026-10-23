// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/object-value-item.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(WidgetTester t, List<ObjectValueItem> list, ValueChanged<List<ObjectValueItem>> onChange) async {
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 448,
        child: Align(
          alignment: Alignment.topCenter,
          child: ObjectValueItemRow(index: 0, list: list, onChange: onChange),
        ),
      ),
      store: store,
    );
  }

  group('ObjectValueItem', () {
    testWidgets('updates key and value and appends a new row when the last value input is focused', (t) async {
      final changes = <List<ObjectValueItem>>[];
      await render(t, const [(key: 'reason', type: ChatVarType.string, value: 'draft')], changes.add);

      await type(t, byDisplayValue('reason'), 'status');
      // A change without focusing (fireEvent.change), then the focus.
      t.widget<TextField>(byDisplayValue('draft')).onChanged!('published');
      await t.tap(byDisplayValue('draft'));
      await t.pump();

      expect(changes, [
        [(key: 'status', type: ChatVarType.string, value: 'draft')],
        [(key: 'reason', type: ChatVarType.string, value: 'published')],
        [(key: 'reason', type: ChatVarType.string, value: 'draft'), defaultObjectValue],
      ]);
    });

    testWidgets('rejects invalid object keys', (t) async {
      final changes = <List<ObjectValueItem>>[];
      await render(t, const [(key: 'reason', type: ChatVarType.string, value: 'draft')], changes.add);

      await type(t, byDisplayValue('reason'), 'invalid key');

      expect(toasts, ['workflow.chatVariable.modal.objectKeyPatternError']);
      expect(changes, isEmpty);
    });
  });
}
