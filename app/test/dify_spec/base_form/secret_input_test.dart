// dify-spec: web/app/components/base/form/utils/secret-input/__tests__/index.spec.ts
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fake_form.dart';

void main() {
  group('secret input utilities', () {
    test('should mask only selected truthy values in transformFormSchemasSecretInput', () {
      expect(
        transformFormSchemasSecretInput(['apiKey'], {'apiKey': 'secret', 'token': 'token-value', 'emptyValue': ''}),
        {
          'apiKey': '[__HIDDEN__]',
          'token': 'token-value',
          'emptyValue': '',
        },
      );
    });

    test('should mask pristine secret input fields from form state', () {
      const schemas = [
        FormSchema(name: 'apiKey', type: FormTypeEnum.secretInput, label: 'API Key', required: true),
        FormSchema(name: 'name', type: FormTypeEnum.textInput, label: 'Name', required: true),
      ];
      final form = FakeFormApi(
        values: {'apiKey': 'secret', 'name': 'Alice'},
        meta: (name) => FieldMeta(isPristine: name == 'apiKey'),
      );
      expect(getTransformedValuesWhenSecretInputPristine(schemas, form), {'apiKey': '[__HIDDEN__]', 'name': 'Alice'});
    });

    test('should keep value unchanged when secret input is not pristine', () {
      const schemas = [FormSchema(name: 'apiKey', type: FormTypeEnum.secretInput, label: 'API Key', required: true)];
      final form = FakeFormApi(values: {'apiKey': 'secret'}, meta: (_) => const FieldMeta(isPristine: false));
      expect(getTransformedValuesWhenSecretInputPristine(schemas, form), {'apiKey': 'secret'});
    });

    test('should not mask when secret name is not in the values object', () {
      expect(transformFormSchemasSecretInput(['missing'], {'apiKey': 'secret'}), {'apiKey': 'secret'});
    });

    test('should not mask falsy values like 0 or null', () {
      expect(transformFormSchemasSecretInput(['zeroVal', 'nullVal'], {'zeroVal': 0, 'nullVal': null}), {
        'zeroVal': 0,
        'nullVal': null,
      });
    });

    test('should return empty object when form values are undefined', () {
      const schemas = [FormSchema(name: 'apiKey', type: FormTypeEnum.secretInput, label: 'API Key', required: true)];
      final form = FakeFormApi(meta: (_) => const FieldMeta());
      expect(getTransformedValuesWhenSecretInputPristine(schemas, form), <String, Object?>{});
    });

    test('should handle fieldMeta being undefined', () {
      const schemas = [FormSchema(name: 'apiKey', type: FormTypeEnum.secretInput, label: 'API Key', required: true)];
      final form = FakeFormApi(values: {'apiKey': 'secret'}, meta: (_) => null);
      expect(getTransformedValuesWhenSecretInputPristine(schemas, form), {'apiKey': 'secret'});
    });

    test('should skip non-secretInput schema types entirely', () {
      const schemas = [
        FormSchema(name: 'name', type: FormTypeEnum.textInput, label: 'Name', required: true),
        FormSchema(name: 'desc', type: FormTypeEnum.textInput, label: 'Desc'),
      ];
      final form = FakeFormApi(values: {'name': 'Alice', 'desc': 'Test'}, meta: (_) => const FieldMeta());
      expect(getTransformedValuesWhenSecretInputPristine(schemas, form), {'name': 'Alice', 'desc': 'Test'});
    });
  });
}
