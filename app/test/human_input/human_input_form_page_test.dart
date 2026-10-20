// The mailed form page (protocol 1.16, Dify's `(humanInputLayout)/form/[token]`): a recipient with no account opens the
// link, the page reads the form without signing in, answers it and thanks them; an expired or already answered form and
// an unknown token get Dify's own states; a failure keeps the form and can be retried.
import 'package:collab_client/collab_client.dart';
import 'package:collab_client/testing.dart';
import 'package:dify_sf_app/src/human_input/human_input_form_page.dart';
import 'package:dify_sf_app/src/launch_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/workflow/run/run_harness.dart' show renderRun;
import '../support/app_fonts.dart';

const _token = 'recipient-token';
const _form = {
  'form_id': 'form-1',
  'node_id': 'human',
  'node_title': 'Review',
  'form_content': r'Please review: {{#$output.review#}}',
  'inputs': [
    {'type': 'paragraph', 'output_variable_name': 'review'},
  ],
  'actions': [
    {'id': 'approve', 'title': 'Approve', 'button_style': 'primary'},
  ],
  'rendered_content': r'Please review: {{#$output.review#}}',
  'default_values': <String, Object?>{},
  'display_in_ui': false,
  'expiration_time': 0,
};

void main() {
  test('a /form/<token> link carries the form token', () {
    expect(LaunchOptions.fromQuery(const {}, path: '/form/abc-123').formToken, 'abc-123');
    expect(LaunchOptions.fromQuery(const {}, path: '/form/abc-123/').formToken, 'abc-123');
    expect(LaunchOptions.fromQuery(const {}, fragment: '#/form/xyz').formToken, 'xyz');
    expect(LaunchOptions.fromQuery(const {}, path: '/app/x/workflow').formToken, isNull);
    expect(LaunchOptions.fromQuery(const {}, path: '/form/').formToken, isNull);
  });

  testWidgets('the page reads and answers the form with no account', (t) async {
    await useAppFonts();
    final api = FakeWorkflowRunApi()..humanInputForms[_token] = _form;
    await renderRun(
      t,
      HumanInputFormPage(token: _token, server: Uri.parse('https://dify.example'), apiFor: (_) => api),
      size: const Size(800, 900),
    );
    await t.pumpAndSettle();
    expect(find.text('Approve'), findsOneWidget, reason: 'the form is shown');

    await t.enterText(find.byType(EditableText), 'looks good');
    await t.pump();
    await t.tap(find.text('Approve'));
    await t.pumpAndSettle();
    expect(api.humanInputAnswers[_token], {
      'inputs': {'review': 'looks good'},
      'action': 'approve',
    });
    // Dify's thanks card (the harness translates to keys: `share.humanInput.thanks` is Thanks!).
    expect(find.text('share.humanInput.thanks'), findsOneWidget);
  });

  testWidgets('an expired form gets its own state', (t) async {
    await useAppFonts();
    final api = FakeWorkflowRunApi()
      ..humanInputFormError = const TransportException('this form has expired', statusCode: 412, code: 'human_input_form_expired');
    await renderRun(
      t,
      HumanInputFormPage(token: _token, server: Uri.parse('https://dify.example'), apiFor: (_) => api),
      size: const Size(800, 900),
    );
    await t.pumpAndSettle();
    expect(find.text('Approve'), findsNothing);
    expect(find.text('share.humanInput.expired'), findsOneWidget);
  });

  testWidgets('an unknown token says the form was not found', (t) async {
    await useAppFonts();
    final api = FakeWorkflowRunApi()
      ..humanInputFormError = const TransportException('Form not found', statusCode: 404, code: 'not_found');
    await renderRun(
      t,
      HumanInputFormPage(token: _token, server: Uri.parse('https://dify.example'), apiFor: (_) => api),
      size: const Size(800, 900),
    );
    await t.pumpAndSettle();
    expect(find.text('share.humanInput.formNotFound'), findsOneWidget);
  });
}
