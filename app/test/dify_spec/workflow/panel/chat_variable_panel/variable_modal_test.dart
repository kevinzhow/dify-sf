// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-modal.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  late List<Map<String, Object?>> saved;
  late int closed;

  Future<WorkflowStore> renderVariableModal(WidgetTester t, {Map<String, Object?>? chatVar}) async {
    saved = [];
    closed = 0;
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 480,
        child: Align(
          alignment: Alignment.topCenter,
          child: ChatVariableModal(chatVar: chatVar, onClose: () => closed++, onSave: saved.add),
        ),
      ),
      store: store,
    );
    return store;
  }

  Map<String, Object?> withoutId(Map<String, Object?> v) => {...v}..remove('id');

  group('variable-modal', () {
    testWidgets('should create a new string variable and close after saving', (t) async {
      await renderVariableModal(t);

      await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'greeting');
      await type(t, byPlaceholder('workflow.chatVariable.modal.valuePlaceholder'), 'hello');
      await type(t, byPlaceholder('workflow.chatVariable.modal.descriptionPlaceholder'), 'demo variable');
      await tap(t, find.text('common.operation.save'));

      expect(saved.single['id'], isA<String>());
      expect(withoutId(saved.single), {
        'name': 'greeting',
        'value_type': ChatVarType.string,
        'value': 'hello',
        'description': 'demo variable',
      });
      expect(closed, greaterThan(0));
    });

    testWidgets('should reject duplicate variable names from the workflow store', (t) async {
      final store = await renderVariableModal(t);

      store.setConversationVariables([
        {'id': 'var-1', 'name': 'existing_name', 'description': '', 'value_type': ChatVarType.string, 'value': ''},
      ]);

      await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'existing_name');
      await tap(t, find.text('common.operation.save'));

      expect(toasts.last, 'app-debug.varKeyError.keyAlreadyExists:{"key":"workflow.chatVariable.modal.name"}');
      expect(saved, isEmpty);
    });

    testWidgets('should load an existing object variable and save object values edited in form mode', (t) async {
      await renderVariableModal(
        t,
        chatVar: {
          'id': 'var-2',
          'name': 'config',
          'description': 'settings',
          'value_type': ChatVarType.object,
          'value': {'apiKey': 'secret', 'timeout': 30},
        },
      );

      expect(byDisplayValue('config'), findsOneWidget);
      expect(byDisplayValue('secret'), findsOneWidget);
      expect(byDisplayValue('30'), findsOneWidget);

      await type(t, byDisplayValue('secret'), '');
      await tap(t, byDisplayValue('30')); // focusing the last row's value adds a row
      await type(t, byDisplayValue('30'), '');
      await type(t, byDisplayValue('0'), '5');
      await tap(t, find.text('common.operation.save'));

      expect(saved, [
        {
          'id': 'var-2',
          'name': 'config',
          'value_type': ChatVarType.object,
          'value': {'apiKey': null, 'timeout': 5},
          'description': 'settings',
        },
      ]);
    });

    testWidgets('should switch types and use default values for boolean arrays', (t) async {
      await renderVariableModal(t);

      await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'flags');
      await tap(t, find.text('string'));
      await tap(t, find.text('array[boolean]'));
      await tap(t, find.text('common.operation.save'));

      expect(withoutId(saved.single), {
        'name': 'flags',
        'value_type': ChatVarType.arrayBoolean,
        'value': [false],
        'description': '',
      });
    });

    testWidgets('should toggle object editing modes without changing behavior', (t) async {
      await renderVariableModal(
        t,
        chatVar: {
          'id': 'var-3',
          'name': 'payload',
          'description': '',
          'value_type': ChatVarType.object,
          'value': {'enabled': 1},
        },
      );

      await tap(t, find.text('workflow.chatVariable.modal.editInJSON'));
      expect(find.byType(DifyCodeEditor), findsOneWidget);
      await tap(t, find.text('workflow.chatVariable.modal.editInForm'));
      expect(byDisplayValue('enabled'), findsOneWidget);
    });

    testWidgets('should validate variable names on blur-sm and preserve underscore replacement', (t) async {
      await renderVariableModal(t);
      final input = byPlaceholder('workflow.chatVariable.modal.namePlaceholder');

      await type(t, input, 'bad name');
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();

      expect(t.widget<TextField>(input).controller!.text, 'bad_name');
      expect(toasts, isEmpty);
    });

    testWidgets('should stop invalid variable names before they are stored in local state', (t) async {
      await renderVariableModal(t);
      final input = byPlaceholder('workflow.chatVariable.modal.namePlaceholder');

      await type(t, input, '1bad');
      await tap(t, find.text('common.operation.save'));

      expect(t.widget<TextField>(input).controller!.text, '');
      expect(toasts, isNotEmpty);
      expect(saved, isEmpty);
    });

    testWidgets('should edit number variables through the value input', (t) async {
      await renderVariableModal(t);

      await type(t, byPlaceholder('workflow.chatVariable.modal.namePlaceholder'), 'timeout');
      await tap(t, find.text('string'));
      await tap(t, find.text('number'));
      await type(t, byPlaceholder('workflow.chatVariable.modal.valuePlaceholder'), '3');
      await tap(t, find.text('common.operation.save'));

      expect(withoutId(saved.single), {
        'name': 'timeout',
        'value_type': ChatVarType.number,
        'value': 3,
        'description': '',
      });
    });

    testWidgets('should keep the number input empty while editing after the user clears it', (t) async {
      await renderVariableModal(
        t,
        chatVar: {'id': 'var-4', 'name': 'timeout', 'description': '', 'value_type': ChatVarType.number, 'value': 3},
      );

      final input = byPlaceholder('workflow.chatVariable.modal.valuePlaceholder');
      await type(t, input, '');

      expect(t.widget<TextField>(input).controller!.text, '');
    });
  });
}
