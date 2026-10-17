// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/object-value-list.spec.tsx
import 'package:dify_sf_app/src/cards/card_kit.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_values.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

/// The DifyText showing [text] (CSS `uppercase` only changes how it is drawn).
Finder difyText(String text) => find.byWidgetPredicate((w) => w is DifyText && w.text == text);

void main() {
  setUp(useDifyTestTranslator);

  group('ObjectValueList', () {
    testWidgets('renders headers and forwards child item changes', (t) async {
      final changes = <List<ObjectValueItem>>[];
      final store = WorkflowStore();
      addTearDown(store.dispose);
      await pumpPanel(
        t,
        SizedBox(
          width: 448,
          child: Align(
            alignment: Alignment.topCenter,
            child: ObjectValueList(
              list: const [(key: 'reason', type: ChatVarType.string, value: 'draft')],
              onChange: changes.add,
            ),
          ),
        ),
        store: store,
      );

      expect(difyText('workflow.chatVariable.modal.objectKey'), findsOneWidget);
      expect(difyText('workflow.chatVariable.modal.objectType'), findsOneWidget);
      expect(difyText('workflow.chatVariable.modal.objectValue'), findsOneWidget);

      await type(t, byDisplayValue('reason'), 'status');

      expect(changes, [
        [(key: 'status', type: ChatVarType.string, value: 'draft')],
      ]);
    });
  });
}
