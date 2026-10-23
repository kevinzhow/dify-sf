// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-modal.sections.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_modal.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  Future<void> render(WidgetTester t, List<Widget> children) async {
    final store = WorkflowStore();
    addTearDown(store.dispose);
    await pumpPanel(
      t,
      SizedBox(
        width: 360,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
      ),
      store: store,
    );
  }

  group('variable-modal sections', () {
    testWidgets('renders name and description sections and forwards input changes', (t) async {
      final names = <String>[], blurs = <String>[], descriptions = <String>[];
      await render(t, [
        NameSection(
          name: 'query',
          onBlur: blurs.add,
          onChange: names.add,
          placeholder: 'name-placeholder',
          title: 'Name',
        ),
        DescriptionSection(
          description: 'original description',
          maxLength: 255,
          onChange: descriptions.add,
          placeholder: 'description-placeholder',
          title: 'Description',
        ),
      ]);

      await type(t, byDisplayValue('query'), 'updated-query');
      await type(t, byDisplayValue('original description'), 'updated-description');

      expect(names, isNotEmpty);
      expect(blurs, ['updated-query']);
      expect(descriptions, ['updated-description']);
    });

    testWidgets('should show description length against the configured limit', (t) async {
      await render(t, [
        DescriptionSection(
          description: 'abc',
          maxLength: 255,
          onChange: (_) {},
          placeholder: 'description-placeholder',
          title: 'Description',
        ),
      ]);

      expect(find.text('3/255'), findsOneWidget);
    });

    testWidgets('renders type and value sections and forwards toggle and value changes', (t) async {
      final selected = <String>[],
          arrays = <List<Object?>>[],
          editors = <bool>[],
          objects = <Object?>[],
          values = <bool>[];
      await render(t, [
        TypeSection(
          list: const [ChatVarType.string, ChatVarType.boolean],
          onSelect: selected.add,
          title: 'Type',
          type: ChatVarType.string,
        ),
        ValueSection(
          editInJSON: false,
          editorMinHeight: 240,
          objectValue: const [],
          onArrayBoolChange: (_) {},
          onArrayChange: arrays.add,
          onEditorChange: editors.add,
          onEditorValueChange: (_) {},
          onObjectChange: objects.add,
          onValueChange: values.add,
          placeholder: 'placeholder',
          toggleLabelKey: 'chatVariable.modal.editInJSON',
          type: ChatVarType.string,
          value: 'draft',
        ),
      ]);

      expect(find.text('Type'), findsOneWidget);
      expect(byDisplayValue('draft'), findsOneWidget);

      await type(t, byDisplayValue('draft'), 'published');
      await tap(t, find.text('workflow.chatVariable.modal.editInJSON'));

      expect(arrays, [
        ['published'],
      ]);
      expect(editors, [true]);
      expect(selected, isEmpty);
      expect(objects, isEmpty);
      expect(values, isEmpty);
    });
  });
}
