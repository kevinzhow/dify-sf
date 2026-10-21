import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/human_input/human_input_form_page.dart';
import 'package:dify_sf_app/src/workflow_editor/run/ui/human_input_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/run/run_harness.dart';

void main() {
  testWidgets('a refused run-panel answer preserves input and allows another attempt', (t) async {
    var attempts = 0;
    await renderRun(
      t,
      HumanInputForm(
        formData: const {
          'form_token': 'token',
          'form_content': r'Review {{#$output.reply#}}',
          'inputs': [
            {'type': 'paragraph', 'output_variable_name': 'reply'},
          ],
          'actions': [
            {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
          ],
          'resolved_default_values': <String, Object?>{},
        },
        onSubmit: (token, data) async {
          attempts++;
          if (attempts == 1) throw StateError('temporarily unavailable');
        },
      ),
    );
    final input = find.byType(EditableText);
    await t.enterText(input, 'keep this answer');
    await t.tap(find.text('Approve'));
    await t.pump();
    final uncaught = t.takeException();
    expect(t.widget<EditableText>(input).controller.text, 'keep this answer');
    final button = find.widgetWithText(DifyButton, 'Approve');
    final disabled = t.widget<DifyButton>(button).disabled;
    await t.tap(button);
    await t.pump();
    expect(
      [uncaught == null, disabled, attempts],
      [true, false, 2],
      reason: 'no unhandled future, a usable button, and a second submission are required after refusal',
    );
  });

  testWidgets('the emailed page renders the server definition action and resolved text', (t) async {
    final api = FakeWorkflowRunApi()
      ..humanInputForms['recipient'] = const {
        'node_title': 'Review',
        'form_content': r'Hello {{#start.name#}} {{#$output.reply#}}',
        'rendered_content': r'Hello Alice {{#$output.reply#}}',
        'inputs': [
          {'type': 'paragraph', 'output_variable_name': 'reply'},
        ],
        // These are the actual formDefinitionJSON keys, rather than the SSE keys used by the existing page fake.
        'user_actions': [
          {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
        ],
        'default_values': {'reply': 'prefilled'},
        'display_in_ui': false,
        'expiration_time': 0,
      };
    await renderRun(
      t,
      HumanInputFormPage(token: 'recipient', server: Uri.parse('https://local.test'), apiFor: (_) => api),
    );
    await t.pumpAndSettle();
    expect(find.text('Approve'), findsOneWidget, reason: 'a real mailed definition must have its submit action');
  });
}
