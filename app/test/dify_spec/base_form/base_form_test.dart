// dify-spec: web/app/components/base/form/components/base/__tests__/base-form.spec.tsx
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

const baseSchemas = [
  FormSchema(type: FormTypeEnum.textInput, name: 'kind', label: 'Kind', defaultValue: 'show'),
  FormSchema(
    type: FormTypeEnum.textInput,
    name: 'title',
    label: 'Title',
    required: true,
    defaultValue: 'Initial title',
    showOn: [(variable: 'kind', value: 'show')],
  ),
];

void main() {
  group('BaseForm', () {
    testWidgets('should render nothing when no schemas are provided', (t) async {
      await renderForm(t, const BaseForm());
      expect(find.byType(BaseField), findsNothing);
      expect(find.byType(EditableText), findsNothing);
    });

    testWidgets('should render fields with default values from schema', (t) async {
      await renderForm(t, const BaseForm(formSchemas: baseSchemas));
      expect(hasInputValue(t, 'show'), isTrue);
      expect(hasInputValue(t, 'Initial title'), isTrue);
    });

    testWidgets('should hide conditional fields when show_on conditions are not met', (t) async {
      await renderForm(
        t,
        const BaseForm(formSchemas: baseSchemas, defaultValues: {'kind': 'hide', 'title': 'Hidden title'}),
      );
      expect(hasInputValue(t, 'hide'), isTrue);
      expect(hasInputValue(t, 'Hidden title'), isFalse);
    });

    testWidgets('should expose ref API for updating values and field states', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(t, BaseForm(key: ref, formSchemas: baseSchemas));
      expect(ref.currentState, isNotNull);
      ref.currentState!.setFields(const [
        SetFieldsParam(name: 'title', value: 'Changed title', errors: ['Title is invalid']),
      ]);
      await t.pump();
      expect(hasInputValue(t, 'Changed title'), isTrue);
      expect(find.text('Title is invalid'), findsOneWidget);
      expect(ref.currentState!.getForm(), isNotNull);
      expect(ref.currentState!.getFormValues(), isNotNull);
    });

    testWidgets('should derive warning status when setFields receives warnings only', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(t, BaseForm(key: ref, formSchemas: baseSchemas));
      ref.currentState!.setFields(const [
        SetFieldsParam(name: 'title', warnings: ['Title warning']),
      ]);
      await t.pump();
      expect(find.text('Title warning'), findsOneWidget);
    });

    testWidgets('should use formFromProps if provided', (t) async {
      final form = FormController(defaultValues: const {'kind': 'show'});
      addTearDown(form.dispose);
      await renderForm(t, BaseForm(formSchemas: baseSchemas, form: form));
      expect(find.text('Kind'), findsOneWidget);
    });

    testWidgets('should handle setFields with explicit validateStatus', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(t, BaseForm(key: ref, formSchemas: baseSchemas));
      ref.currentState!.setFields(const [
        SetFieldsParam(name: 'kind', validateStatus: FormItemValidateStatusEnum.error, errors: ['Explicit error']),
      ]);
      await t.pump();
      expect(find.text('Explicit error'), findsOneWidget);
    });

    testWidgets('should handle setFields with no value change', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(t, BaseForm(key: ref, formSchemas: baseSchemas));
      ref.currentState!.setFields(const [
        SetFieldsParam(name: 'kind', errors: ['Error only']),
      ]);
      await t.pump();
      expect(find.text('Error only'), findsOneWidget);
      expect(hasInputValue(t, 'show'), isTrue);
    });

    testWidgets('should use default values from schema when defaultValues prop is missing', (t) async {
      await renderForm(t, const BaseForm(formSchemas: baseSchemas));
      expect(hasInputValue(t, 'show'), isTrue);
    });

    testWidgets('should handle submit without preventDefaultSubmit', (t) async {
      var submitted = 0;
      await renderForm(t, BaseForm(formSchemas: baseSchemas, onSubmit: () => submitted++));
      await t.showKeyboard(input('kind'));
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(submitted, 1);
    });

    testWidgets('should handle undefined formSchemas', (t) async {
      await renderForm(t, const BaseForm());
      expect(find.byType(BaseField), findsNothing);
    });

    testWidgets('should handle empty array formSchemas', (t) async {
      await renderForm(t, const BaseForm(formSchemas: []));
      expect(find.byType(BaseField), findsNothing);
    });

    testWidgets('should handle missing onSubmit prop', (t) async {
      await renderForm(t, const BaseForm(formSchemas: baseSchemas));
      await t.showKeyboard(input('kind'));
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(t.takeException(), isNull);
    });

    testWidgets('should call onChange when field value changes', (t) async {
      final changes = <(String, Object?)>[];
      await renderForm(t, BaseForm(formSchemas: baseSchemas, onChange: (f, v) => changes.add((f, v))));
      await t.enterText(input('kind'), 'new-value');
      await t.pump();
      expect(changes, contains(('kind', 'new-value')));
    });

    testWidgets('should handle setFields with no status, errors, or warnings', (t) async {
      final ref = GlobalKey<BaseFormState>();
      await renderForm(t, BaseForm(key: ref, formSchemas: baseSchemas));
      ref.currentState!.setFields(const [SetFieldsParam(name: 'kind', value: 'new-show')]);
      await t.pump();
      expect(hasInputValue(t, 'new-show'), isTrue);
    });

    testWidgets('should handle schema without show_on in showOnValues', (t) async {
      await renderForm(
        t,
        const BaseForm(
          formSchemas: [FormSchema(type: FormTypeEnum.textInput, name: 'test', label: 'Test')],
        ),
      );
      expect(find.text('Test'), findsOneWidget);
    });
  });
}
