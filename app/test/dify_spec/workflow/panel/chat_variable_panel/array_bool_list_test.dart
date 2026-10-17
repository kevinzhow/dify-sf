// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/array-bool-list.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('ArrayBoolList', () {
    testWidgets('toggles, appends, and removes boolean values', (t) async {
      final changes = <List<bool>>[];
      final store = WorkflowStore();
      addTearDown(store.dispose);
      await pumpPanel(
        t,
        SizedBox(
          width: 328,
          child: Align(
            alignment: Alignment.topCenter,
            child: ArrayBoolList(list: const [true], onChange: changes.add),
          ),
        ),
        store: store,
      );

      await tap(t, find.text('False'));
      await tap(t, find.text('workflow.chatVariable.modal.addArrayValue'));
      await tap(t, buttonNamed('common.operation.remove'));

      expect(changes, [
        [false],
        [true, false],
        <bool>[],
      ]);
    });
  });
}
