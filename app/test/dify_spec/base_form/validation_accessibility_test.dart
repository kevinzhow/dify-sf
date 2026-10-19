// dify-spec: web/app/components/base/form/components/base/__tests__/validation-accessibility.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

FormSchema requiredSchema(String label, {String name = 'token', List<FormShowOn> showOn = const []}) => FormSchema(
  name: name,
  label: label,
  type: FormTypeEnum.secretInput,
  required: true,
  description: 'Paste your API token',
  tooltip: 'Find this token in the provider settings',
  showOn: showOn,
  validators: FieldValidators(
    onMount: (v) => v == null || v == '' ? 'Token is required' : null,
    onChange: (v) => v == null || v == '' ? 'Token is required' : null,
  ),
);

SemanticsData semanticsOf(WidgetTester t, String name, {int index = 0}) =>
    t.getSemantics(input(name).at(index)).getSemanticsData();

bool focused(WidgetTester t, String name, {int index = 0}) =>
    t.widget<EditableText>(input(name).at(index)).focusNode.hasFocus;

/// [text] in a form (the toasts are outside: Dify's tests mock them).
Finder inForm(String text) => find.descendant(of: find.byType(BaseForm), matching: find.text(text));

Widget saveButton(GlobalKey<BaseFormState> ref) => DifyButton(
  key: const ValueKey('save'),
  onPressed: () => ref.currentState!.getFormValues(),
  child: const Text('Save credentials'),
);

void main() {
  group('BaseForm validation accessibility', () {
    testWidgets('shows client validation again after editing clears a server error', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(
        t,
        Column(
          children: [
            BaseForm(
              key: ref,
              formSchemas: [requiredSchema('API token')],
              onChange: (name, _) => ref.currentState?.setFields([SetFieldsParam(name: name, errors: const [])]),
            ),
            saveButton(ref),
          ],
        ),
      );
      await t.enterText(input('token'), 'rejected-token');
      await t.pump();
      ref.currentState!.setFields(const [
        SetFieldsParam(name: 'token', errors: ['Token was rejected']),
      ]);
      await t.pump();
      expect(semanticsOf(t, 'token').validationResult, SemanticsValidationResult.invalid);
      expect(semanticsOf(t, 'token').hint, 'Paste your API token Token was rejected');

      await t.enterText(input('token'), '');
      await t.pump();
      await t.tap(find.byKey(const ValueKey('save')));
      await t.pump();
      expect(focused(t, 'token'), isTrue);
      expect(semanticsOf(t, 'token').validationResult, SemanticsValidationResult.invalid);
      expect(semanticsOf(t, 'token').hint, 'Paste your API token Token is required');
      expect(inForm('Token was rejected'), findsNothing);

      await t.enterText(input('token'), 'valid-token');
      await t.pump();
      expect(semanticsOf(t, 'token').validationResult, isNot(SemanticsValidationResult.invalid));
      expect(semanticsOf(t, 'token').hint, 'Paste your API token');
      expect(inForm('Token is required'), findsNothing);
    });

    testWidgets('focuses the invalid field in the submitting form and associates the error until corrected', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(
        t,
        Column(
          children: [
            BaseForm(formSchemas: [requiredSchema('Other token')]),
            BaseForm(key: ref, formSchemas: [requiredSchema('API token')]),
            saveButton(ref),
          ],
        ),
      );
      expect(semanticsOf(t, 'token', index: 1).validationResult, isNot(SemanticsValidationResult.invalid));
      await t.tap(find.byKey(const ValueKey('save')));
      await t.pump();
      expect(focused(t, 'token', index: 1), isTrue);
      expect(semanticsOf(t, 'token', index: 1).validationResult, SemanticsValidationResult.invalid);
      expect(semanticsOf(t, 'token', index: 1).hint, 'Paste your API token Token is required');
      expect(semanticsOf(t, 'token').validationResult, isNot(SemanticsValidationResult.invalid));

      await t.enterText(input('token').at(1), 'valid-token');
      await t.pump();
      expect(semanticsOf(t, 'token', index: 1).validationResult, isNot(SemanticsValidationResult.invalid));
      expect(semanticsOf(t, 'token', index: 1).hint, 'Paste your API token');
      expect(inForm('Token is required'), findsNothing);
    });

    testWidgets('skips hidden field errors and focuses the first visible invalid field in schema order', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(
        t,
        Column(
          children: [
            BaseForm(
              key: ref,
              defaultValues: const {'enabled': 'no'},
              formSchemas: [
                requiredSchema('Hidden token', name: 'hidden', showOn: const [(variable: 'enabled', value: 'yes')]),
                requiredSchema('Visible token'),
                requiredSchema('Later token', name: 'later'),
              ],
            ),
            saveButton(ref),
          ],
        ),
      );
      await t.tap(find.byKey(const ValueKey('save')));
      await t.pump();
      expect(focused(t, 'token'), isTrue);
      expect(input('hidden'), findsNothing);
    });
  });
}
