// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/bool-value.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/panel_fields/form_controls.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('BoolValue', () {
    testWidgets('switches between true and false values', (t) async {
      final changes = <bool>[];
      final store = WorkflowStore();
      addTearDown(store.dispose);
      Widget boolValue(bool value) => SizedBox(
        width: 328,
        child: Align(
          alignment: Alignment.topCenter,
          child: BoolValue(value: value, onChange: changes.add),
        ),
      );
      await pumpPanel(t, boolValue(true), store: store);

      await tap(t, find.text('False'));
      await pumpPanel(t, boolValue(false), store: store);
      await tap(t, find.text('True'));

      expect(changes, [false, true]);
    });
  });
}
