// dify-spec: web/app/components/workflow/nodes/human-input/components/__tests__/form-content-preview.spec.tsx
//
// The preview card itself; the panel places it `panelWidth + 8` from the right (human_input_panel_test.dart).
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_preview.dart';
import 'package:flutter_test/flutter_test.dart';

import 'human_input_test_kit.dart';

String nodeName(String id) => id == 'node-1' ? 'Classifier' : id;

void main() {
  group('FormContentPreview', () {
    testWidgets('should render preview content with resolved node names, note fallbacks, and action buttons', (
      t,
    ) async {
      await pumpComponent(
        t,
        FormContentPreview(
          content: 'Answer {{#node-1.answer#}}\n\n{{#\$output.field_1#}} {{#\$output.missing_field#}}',
          formInputs: const [
            {
              'type': 'text-input',
              'output_variable_name': 'field_1',
              'default': {
                'type': 'variable',
                'selector': ['node-1', 'answer'],
                'value': '',
              },
            },
          ],
          userActions: const [
            {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
          ],
          nodeName: nodeName,
          onClose: () {},
        ),
        width: 700,
      );

      expect(find.text(hiKey('formContent.preview').toUpperCase()), findsOneWidget);
      expect(find.textContaining('{{Classifier/answer}}'), findsWidgets);
      expect(find.text("Can't find note:missing_field"), findsOneWidget);
      expect(find.widgetWithText(DifyButton, 'Approve'), findsOneWidget);
      expect(find.text(hiKey('editor.previewTip')), findsOneWidget);
    });

    testWidgets('should close the preview when the close action is clicked', (t) async {
      var closes = 0;
      await pumpComponent(
        t,
        FormContentPreview(
          content: 'content',
          formInputs: const [],
          userActions: const [],
          nodeName: nodeName,
          onClose: () => closes++,
        ),
        width: 700,
      );
      await tapNamed(t, 'common.operation.close');
      expect(closes, 1);
    });

    testWidgets('should pass non-paragraph inputs through the preview note renderer', (t) async {
      await pumpComponent(
        t,
        FormContentPreview(
          content: '{{#\$output.field_1#}}',
          formInputs: const [
            {
              'type': 'select',
              'output_variable_name': 'field_1',
              'option_source': {
                'type': 'variable',
                'selector': ['node-1', 'items'],
                'value': <Object?>[],
              },
            },
          ],
          userActions: const [],
          nodeName: nodeName,
          onClose: () {},
        ),
        width: 700,
      );
      expect(find.byType(FormInputNote), findsOneWidget);
      expect(find.text('{{Classifier/items}}'), findsOneWidget);
    });
  });
}
