// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-modal-trigger.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

Map<String, Object?> createVariable() => {
  'id': 'var-1',
  'name': 'conversation_var',
  'description': 'Conversation scoped variable',
  'value_type': ChatVarType.string,
  'value': '',
};

/// `TriggerHarness`: the trigger with its own open state, open at first.
class TriggerHarness extends StatefulWidget {
  const TriggerHarness({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  State<TriggerHarness> createState() => _TriggerHarnessState();
}

class _TriggerHarnessState extends State<TriggerHarness> {
  bool open = true;

  @override
  Widget build(BuildContext context) => ChatVariableModalTrigger(
    open: open,
    setOpen: (v) => setState(() => open = v),
    showTip: false,
    chatVar: createVariable(),
    onClose: widget.onClose,
    onSave: (_) {},
  );
}

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(WidgetTester t, Widget w) async {
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 420,
        child: Padding(
          padding: const EdgeInsets.only(top: 300),
          child: Align(alignment: Alignment.topLeft, child: w),
        ),
      ),
      store: store,
    );
    await settle(t);
  }

  const namePlaceholder = 'workflow.chatVariable.modal.namePlaceholder';

  group('VariableModalTrigger', () {
    testWidgets('opens from the trigger when initially closed', (t) async {
      final opens = <bool>[];
      var closed = 0;
      await render(
        t,
        ChatVariableModalTrigger(
          open: false,
          setOpen: opens.add,
          showTip: true,
          onClose: () => closed++,
          onSave: (_) {},
        ),
      );

      expect(byPlaceholder(namePlaceholder), findsNothing);

      await tap(t, buttonNamed('workflow.chatVariable.button'));

      expect(opens, isNotEmpty);
      expect(closed, 0);
    });

    testWidgets('saves through the real modal and closes the trigger', (t) async {
      final opens = <bool>[];
      final saved = <Map<String, Object?>>[];
      var closed = 0;
      await render(
        t,
        ChatVariableModalTrigger(
          open: true,
          setOpen: opens.add,
          showTip: false,
          chatVar: createVariable(),
          onClose: () => closed++,
          onSave: saved.add,
        ),
      );

      await type(t, byDisplayValue('conversation_var'), 'updated_var');
      await type(t, byPlaceholder('workflow.chatVariable.modal.valuePlaceholder'), 'hello');
      await tap(t, find.text('common.operation.save'));

      expect(saved.single, containsPair('id', 'var-1'));
      expect(saved.single, containsPair('name', 'updated_var'));
      expect(saved.single, containsPair('value', 'hello'));
      expect(saved.single, containsPair('value_type', ChatVarType.string));
      expect(closed, greaterThan(0));
      expect(opens, contains(false));
    });

    testWidgets('closes when the portal dismisses', (t) async {
      var closed = 0;
      await render(t, TriggerHarness(onClose: () => closed++));

      expect(byPlaceholder(namePlaceholder), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(t);

      expect(byPlaceholder(namePlaceholder), findsNothing);
      expect(closed, greaterThan(0));
    });
  });
}
