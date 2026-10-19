// dify-spec: web/app/components/base/form/components/base/__tests__/base-field.spec.tsx
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:dify_sf_app/src/settings/settings_kit.dart' show SettingsRadioDot;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '_harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

/// `renderBaseField`: one field over a form with [defaultValues] (the field's name with '' by default).
Future<FormController> renderBaseField(
  WidgetTester t, {
  required FormSchema formSchema,
  Map<String, Object?>? defaultValues,
  FieldState? fieldState,
  void Function(String field, Object? value)? onChange,
}) async {
  final form = FormController(defaultValues: defaultValues ?? {formSchema.name: ''});
  addTearDown(form.dispose);
  await renderForm(
    t,
    ListenableBuilder(
      listenable: form,
      builder: (context, _) => BaseField(
        form: form,
        formSchema: formSchema,
        fieldState: fieldState,
        onChange: onChange,
        focusNode: _focus,
      ),
    ),
  );
  return form;
}

final _focus = FocusNode();

/// The semantics around the field's control (label, hint: the description and the message).
SemanticsData fieldSemantics(WidgetTester t, Finder control) => t.getSemantics(control).getSemanticsData();

void main() {
  group('BaseField', () {
    for (final type in [FormTypeEnum.textInput, FormTypeEnum.secretInput, FormTypeEnum.textNumber]) {
      testWidgets('associates the visible label, description and required state for %s', (t) async {
        await renderBaseField(
          t,
          formSchema: FormSchema(
            type: type,
            name: 'credential',
            label: 'Credential',
            description: 'Use the workspace credential',
            required: true,
            options: const [FormOption(label: 'Primary', value: 'primary')],
          ),
        );
        final s = fieldSemantics(t, input('credential'));
        expect(s.label, contains('Credential'));
        expect(s.hint, contains('Use the workspace credential'));
        expect(find.text('*'), findsOneWidget);
        await t.tap(find.text('Credential'));
        await t.pump();
        expect(_focus.hasFocus, isTrue);
        _focus.unfocus();
      });
    }

    testWidgets('focuses the \$type trigger from its label and supports keyboard selection (multiple: \$multiple)', (
      t,
    ) async {
      // The select (single); Dify's multiple and dynamic selects are not offered by dify-sf's credential forms.
      const options = [FormOption(label: 'Primary', value: 'primary')];
      final form = await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.select,
          name: 'credential',
          label: 'Credential',
          description: 'Use the workspace credential',
          tooltip: 'Credential help',
          required: true,
          options: options,
        ),
        fieldState: const FieldState(validateStatus: FormItemValidateStatusEnum.error, errors: ['Choose a credential']),
      );
      final s = fieldSemantics(t, find.byKey(const ValueKey('form-select-credential')));
      expect(s.hint, 'Use the workspace credential Choose a credential');
      expect(find.bySemanticsLabel('Credential help'), findsOneWidget);
      await t.tap(find.text('Credential'));
      await t.pump();
      expect(_focus.hasFocus, isTrue);
      await t.tap(find.byKey(const ValueKey('form-select-credential')));
      await t.pumpAndSettle();
      await t.tap(find.text('Primary').last);
      await t.pumpAndSettle();
      expect(form.value('credential'), 'primary');
      _focus.unfocus();
    });

    testWidgets('should render text input and propagate changes', (t) async {
      final changes = <(String, Object?)>[];
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textInput, name: 'title', label: 'Title', required: true),
        defaultValues: const {'title': 'Hello'},
        onChange: (f, v) => changes.add((f, v)),
      );
      expect(inputText(t, 'title'), 'Hello');
      await t.enterText(input('title'), 'Updated');
      await t.pump();
      expect(changes, contains(('title', 'Updated')));
      expect(find.text('Title'), findsOneWidget);
      expect(find.text('*'), findsOneWidget);
    });

    testWidgets('should render only options that satisfy show_on conditions', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.select,
          name: 'mode',
          label: 'Mode',
          options: [
            FormOption(label: 'Alpha', value: 'alpha'),
            FormOption(label: 'Beta', value: 'beta', showOn: [(variable: 'enabled', value: 'yes')]),
          ],
        ),
        defaultValues: const {'mode': 'alpha', 'enabled': 'no'},
      );
      await t.tap(find.text('Alpha'));
      await t.pumpAndSettle();
      expect(find.text('Beta'), findsNothing);
    });

    testWidgets('should not render current select value when it is filtered out by show_on conditions', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.select,
          name: 'mode',
          label: 'Mode',
          options: [
            FormOption(label: 'Alpha', value: 'alpha'),
            FormOption(label: 'Beta', value: 'beta', showOn: [(variable: 'enabled', value: 'yes')]),
          ],
        ),
        defaultValues: const {'mode': 'beta', 'enabled': 'no'},
      );
      expect(t.widget<DifySelect<String>>(find.byType(DifySelect<String>)).value, isNull);
      expect(find.text('beta'), findsNothing);
      expect(find.text('common.placeholder.input'), findsOneWidget);
    });

    testWidgets('should update value when users click a radio option', (t) async {
      final changes = <(String, Object?)>[];
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.radio,
          name: 'visibility',
          label: 'Visibility',
          options: [
            FormOption(label: 'Public', value: 'public'),
            FormOption(label: 'Private', value: 'private'),
          ],
        ),
        defaultValues: const {'visibility': 'public'},
        onChange: (f, v) => changes.add((f, v)),
      );
      // A row (`flex items-center`), not a column.
      expect(t.getTopLeft(find.text('Public')).dy, t.getTopLeft(find.text('Private')).dy);
      await t.tap(find.text('Private'));
      await t.pump();
      expect(changes, contains(('visibility', 'private')));
    });

    for (final type in [FormTypeEnum.select, FormTypeEnum.radio, FormTypeEnum.checkbox]) {
      testWidgets('associates \$type validation and description with the named control', (t) async {
        await renderBaseField(
          t,
          formSchema: FormSchema(
            type: type,
            name: 'access',
            label: 'Access level',
            description: 'Choose an access level',
            required: true,
            options: const [FormOption(label: 'Public', value: 'public')],
          ),
          defaultValues: {'access': type == FormTypeEnum.checkbox ? <String>[] : ''},
          fieldState: const FieldState(validateStatus: FormItemValidateStatusEnum.error, errors: ['Choose an option']),
        );
        final node = find.semantics.byPredicate(
          (n) => n.label == 'Access level' && n.getSemanticsData().hint == 'Choose an access level Choose an option',
        );
        expect(node, findsOneWidget);
        expect(
          node.evaluate().single.getSemanticsData().validationResult,
          type == FormTypeEnum.select ? isNot(SemanticsValidationResult.valid) : SemanticsValidationResult.invalid,
        );
      });
    }

    testWidgets('should show validation message when field state has an error', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textInput, name: 'name', label: 'Name'),
        fieldState: const FieldState(validateStatus: FormItemValidateStatusEnum.error, errors: ['Name is required']),
      );
      final s = fieldSemantics(t, input('name'));
      expect(s.validationResult, SemanticsValidationResult.invalid);
      expect(s.hint, 'Name is required');
    });

    testWidgets('should render description and help link when provided', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.textInput,
          name: 'doc',
          label: 'Documentation',
          description: 'Read the description',
          url: 'https://example.com/help',
          help: 'Open help docs',
        ),
        defaultValues: const {'doc': ''},
      );
      expect(find.text('Read the description'), findsOneWidget);
      final link = find.semantics.byPredicate(
        (n) => n.label == 'Open help docs' && n.getSemanticsData().flagsCollection.isLink,
      );
      expect(link, findsOneWidget);
      expect(link.evaluate().single.getSemanticsData().linkUrl, Uri.parse('https://example.com/help'));
    });

    testWidgets('should render secret input with password type', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.secretInput, name: 'token', label: 'Token'),
        defaultValues: const {'token': 'abc'},
      );
      expect(inputText(t, 'token'), 'abc');
      expect(t.widget<EditableText>(input('token')).obscureText, isTrue);
    });

    testWidgets('should render number input with number type', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textNumber, name: 'count', label: 'Count'),
        defaultValues: const {'count': 7},
      );
      expect(inputText(t, 'count'), '7');
      expect(t.widget<EditableText>(input('count')).keyboardType, TextInputType.number);
    });

    testWidgets('should render translated object label content', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.textInput,
          name: 'title_i18n',
          label: {'en_US': 'Localized title', 'zh_Hans': '标题'},
        ),
        defaultValues: const {'title_i18n': ''},
      );
      expect(find.text('Localized title'), findsOneWidget);
    });

    testWidgets('should update boolean field when users choose false', (t) async {
      final form = await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.boolean, name: 'enabled', label: 'Enabled'),
        defaultValues: const {'enabled': true},
      );
      expect(form.value('enabled'), true);
      await t.tap(find.text('False'));
      await t.pump();
      expect(form.value('enabled'), false);
    });

    testWidgets('should render warning message when field state has a warning', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textInput, name: 'warning_field', label: 'Warning field'),
        fieldState: const FieldState(
          validateStatus: FormItemValidateStatusEnum.warning,
          warnings: ['This is a warning'],
        ),
      );
      expect(find.text('This is a warning'), findsOneWidget);
    });

    testWidgets('should render infotip when tooltip content is provided', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textInput, name: 'info', label: 'Info', tooltip: 'Extra info'),
      );
      expect(find.text('Info'), findsOneWidget);
      await t.tap(find.descendant(of: find.byType(Infotip), matching: find.byType(RemixIcon)));
      await t.pumpAndSettle();
      expect(find.text('Extra info'), findsOneWidget);
    });

    testWidgets('should render checkbox list and handle changes', (t) async {
      final form = await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.checkbox,
          name: 'features',
          label: 'Features',
          options: [
            FormOption(label: 'Feature A', value: 'a'),
            FormOption(label: 'Feature B', value: 'b'),
          ],
        ),
        defaultValues: const {
          'features': ['a'],
        },
      );
      expect(find.byType(CheckboxList), findsOneWidget);
      expect(find.text('Feature A'), findsOneWidget);
      expect(find.text('Feature B'), findsOneWidget);
      await t.tap(find.text('Feature B'));
      await t.pump();
      expect(form.value('features'), ['a', 'b']);
    });

    testWidgets('should render radio buttons in vertical layout when length >= 3', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.radio,
          name: 'vertical_radio',
          label: 'Vertical',
          options: [
            FormOption(label: 'O1', value: '1'),
            FormOption(label: 'O2', value: '2'),
            FormOption(label: 'O3', value: '3'),
          ],
        ),
      );
      expect(find.text('O1'), findsOneWidget);
      expect(find.text('O2'), findsOneWidget);
      expect(find.text('O3'), findsOneWidget);
      expect(t.getTopLeft(find.text('O2')).dy, greaterThan(t.getTopLeft(find.text('O1')).dy));
    });

    testWidgets('should render radio UI when showRadioUI is true', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(
          type: FormTypeEnum.radio,
          name: 'ui_radio',
          label: 'UI Radio',
          showRadioUI: true,
          options: [FormOption(label: 'Option 1', value: '1')],
        ),
      );
      expect(find.text('Option 1'), findsOneWidget);
      expect(find.byType(SettingsRadioDot), findsOneWidget);
      expect(find.bySemanticsLabel('UI Radio'), findsOneWidget);
    });

    testWidgets('should return empty string for null content in getTranslatedContent', (t) async {
      await renderBaseField(
        t,
        formSchema: const FormSchema(type: FormTypeEnum.textInput, name: 'null_label'),
      );
      expect(find.text('*'), findsNothing);
    });
  });
}
