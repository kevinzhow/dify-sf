// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-item.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

Map<String, Object?> createVariable([Map<String, Object?> overrides = const {}]) => {
  'id': 'var-1',
  'name': 'conversation_var',
  'description': 'Conversation scoped variable',
  'value_type': ChatVarType.string,
  'value': '',
  ...overrides,
};

Color cardBorder(WidgetTester t) {
  final box = t.widget<Container>(
    find.descendant(of: find.byType(ChatVariableItem), matching: find.byType(Container)).first,
  );
  return ((box.decoration! as BoxDecoration).border! as Border).top.color;
}

void main() {
  setUp(useDifyTestTranslator);

  group('VariableItem', () {
    testWidgets('updates destructive state on hover and fires edit/delete actions', (t) async {
      final edited = <Object?>[], deleted = <Object?>[];
      final store = WorkflowStore();
      addTearDown(store.dispose);
      await pumpPanel(
        t,
        SizedBox(
          width: 388,
          child: Align(
            alignment: Alignment.topCenter,
            child: ChatVariableItem(item: createVariable(), onEdit: edited.add, onDelete: deleted.add),
          ),
        ),
        store: store,
      );

      final g = await t.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: t.getCenter(buttonNamed('common.operation.delete')));
      addTearDown(g.removePointer);
      await t.pump();
      expect(cardBorder(t), DifyColors.stateDestructiveBorder);
      await g.moveTo(Offset.zero);
      await t.pump();
      expect(cardBorder(t), isNot(DifyColors.stateDestructiveBorder));

      await t.tap(buttonNamed('common.operation.edit'));
      await t.tap(buttonNamed('common.operation.delete'));

      expect(edited, [createVariable()]);
      expect(deleted, [createVariable()]);
    });
  });
}
