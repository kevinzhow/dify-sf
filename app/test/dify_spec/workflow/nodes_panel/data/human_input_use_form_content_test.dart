// dify-spec: web/app/components/workflow/nodes/human-input/hooks/__tests__/use-form-content.spec.ts
//
// useFormContent over a document; the downstream rename is real (a node referencing the input follows it).
// `editorKey` (the remount counter) is the form content editor's own state.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/human_input_config.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

Map<String, Object?> formInput([String name = 'old_name']) => {
  'type': 'paragraph',
  'output_variable_name': name,
  'default': {'selector': <Object?>[], 'type': 'constant', 'value': ''},
};

void main() {
  late Harness h;

  HumanInputConfig config() =>
      HumanInputConfig(NodePanelProps(node: h['hi']!, controller: h.controller, actions: h.actions()));

  Future<void> start(WidgetTester t, {List<Object?>? inputs}) async {
    final hi = hiNode({
      'form_content': 'Hello {{#\$output.old_name#}}',
      'inputs': inputs ?? [formInput()],
    });
    final answer = difyNode('answer', {'type': 'answer', 'answer': 'Got {{#hi.old_name#}}'}, others: [hi], x: 800);
    h = await Harness.start(t, [hi, answer], edges: [edge('hi', 'answer', sourceHandle: 'approve')]);
  }

  group('human-input/use-form-content', () {
    testWidgets('should update raw form content and replace the form input list', (t) async {
      await start(t);
      config().formContentChange('Updated body');
      await Harness.settle(t);
      config().formInputsChange([formInput('approval')]);
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['form_content'], 'Updated body');
      expect(dataOf(h, 'hi')['inputs'], [formInput('approval')]);
      await h.dispose(t);
    });

    testWidgets('should rename input placeholders inside markdown and notify downstream references', (t) async {
      await start(t);
      expect(config().formInputRename(formInput('new_name'), 'old_name'), isTrue);
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['form_content'], 'Hello {{#\$output.new_name#}}');
      expect(dataOf(h, 'hi')['inputs'], [formInput('new_name')]);
      expect(dataOf(h, 'answer')['answer'], 'Got {{#hi.new_name#}}');
      await h.dispose(t);
    });

    testWidgets('should not rename an input to an existing variable name', (t) async {
      await start(t, inputs: [formInput(), formInput('existing_name')]);
      expect(config().formInputRename(formInput('existing_name'), 'old_name'), isFalse);
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['inputs'], [formInput(), formInput('existing_name')]);
      expect(dataOf(h, 'answer')['answer'], 'Got {{#hi.old_name#}}');
      await h.dispose(t);
    });

    testWidgets('should remove an input placeholder and its form input metadata', (t) async {
      await start(t);
      config().formInputRemove('old_name');
      await Harness.settle(t);

      expect(dataOf(h, 'hi')['form_content'], 'Hello ');
      expect(dataOf(h, 'hi')['inputs'], isEmpty);
      await h.dispose(t);
    });
  });
}
