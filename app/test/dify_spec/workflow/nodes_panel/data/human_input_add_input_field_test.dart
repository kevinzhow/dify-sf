// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/add-input-field.spec.tsx
//
// AddInputField is InputField in create mode; the real editor is used (the spec mocks it).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

void main() {
  group('human-input/components/add-input-field', () {
    testWidgets('should render InputField in create mode and forward callbacks', (t) async {
      final saves = <Map<String, Object?>>[];
      var cancels = 0;
      await pumpComponent(
        t,
        InputFieldEditor(
          scope: const VarScope(),
          unavailable: const ['comment'],
          onChange: saves.add,
          onCancel: () => cancels++,
        ),
      );
      final name = inputNamed(hiKey('insertInputField.saveResponseAs'));

      expect(find.text(hiKey('insertInputField.insert')), findsOneWidget);
      await t.enterText(name, 'comment');
      await t.pump();
      expect(find.text(hiKey('insertInputField.variableNameDuplicated')), findsOneWidget);
      await t.tap(find.text(hiKey('insertInputField.insert')));
      await t.pump();
      expect(saves, isEmpty);

      await t.enterText(name, 'comment_2');
      await t.pump();
      await t.tap(find.text(hiKey('insertInputField.insert')));
      await t.pump();
      expect(saves.single['type'], 'paragraph');
      expect(saves.single['output_variable_name'], 'comment_2');

      await t.tap(find.text('common.operation.cancel'));
      expect(cancels, 1);
    });
  });
}
