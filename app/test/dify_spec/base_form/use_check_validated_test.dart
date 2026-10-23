// dify-spec: web/app/components/base/form/hooks/__tests__/use-check-validated.spec.ts
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fake_form.dart';

void main() {
  group('useCheckValidated', () {
    final notified = <String>[];
    bool check(FakeFormApi form, List<FormSchema> schemas) => checkValidated(form, schemas, toastError: notified.add);

    setUp(notified.clear);

    test('should return true when form has no errors', () {
      expect(check(FakeFormApi(values: const {}), const []), isTrue);
      expect(notified, isEmpty);
    });

    for (final (fieldName, label, message) in const [
      ('name', 'Name', 'Name is required'),
      ('field1', 'Field 1', 'Field is required'),
    ]) {
      test('should notify and return false when visible field has errors (show_on: []) for \$fieldName', () {
        final form = FakeFormApi(
          values: const {},
          errors: {
            fieldName: [message],
          },
        );
        final schemas = [FormSchema(name: fieldName, label: label, required: true, type: FormTypeEnum.textInput)];
        expect(check(form, schemas), isFalse);
        expect(notified, [message]);
        notified.clear();
      });
    }

    test('should ignore hidden field errors and return true', () {
      final form = FakeFormApi(
        values: const {'enabled': 'false'},
        errors: const {
          'secret': ['Secret is required'],
        },
      );
      const schemas = [
        FormSchema(
          name: 'secret',
          label: 'Secret',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'enabled', value: 'true')],
        ),
      ];
      expect(check(form, schemas), isTrue);
      expect(notified, isEmpty);
    });

    test('should notify when field is shown and has errors', () {
      final form = FakeFormApi(
        values: const {'enabled': 'true'},
        errors: const {
          'secret': ['Secret is required'],
        },
      );
      const schemas = [
        FormSchema(
          name: 'secret',
          label: 'Secret',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'enabled', value: 'true')],
        ),
      ];
      expect(check(form, schemas), isFalse);
      expect(notified, ['Secret is required']);
    });

    test('should notify with first error when multiple fields have errors', () {
      final form = FakeFormApi(
        values: const {},
        errors: const {
          'name': ['Name error'],
          'email': ['Email error'],
        },
      );
      const schemas = [
        FormSchema(name: 'name', label: 'Name', required: true, type: FormTypeEnum.textInput),
        FormSchema(name: 'email', label: 'Email', required: true, type: FormTypeEnum.textInput),
      ];
      expect(check(form, schemas), isFalse);
      expect(notified, ['Name error']);
    });

    test('should notify when multiple conditions all match', () {
      final form = FakeFormApi(
        values: const {'enabled': 'true', 'level': 'advanced'},
        errors: const {
          'advancedOption': ['Advanced is required'],
        },
      );
      const schemas = [
        FormSchema(
          name: 'advancedOption',
          label: 'Advanced Option',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'enabled', value: 'true'), (variable: 'level', value: 'advanced')],
        ),
      ];
      expect(check(form, schemas), isFalse);
      expect(notified, ['Advanced is required']);
    });

    test('should ignore error when one of multiple conditions does not match', () {
      final form = FakeFormApi(
        values: const {'enabled': 'true', 'level': 'basic'},
        errors: const {
          'advancedOption': ['Advanced is required'],
        },
      );
      const schemas = [
        FormSchema(
          name: 'advancedOption',
          label: 'Advanced Option',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'enabled', value: 'true'), (variable: 'level', value: 'advanced')],
        ),
      ];
      expect(check(form, schemas), isTrue);
      expect(notified, isEmpty);
    });

    test('should handle field with error when schema is not found', () {
      final form = FakeFormApi(
        values: const {},
        errors: const {
          'unknownField': ['Unknown error'],
        },
      );
      const schemas = [
        FormSchema(name: 'knownField', label: 'Known Field', required: true, type: FormTypeEnum.textInput),
      ];
      expect(check(form, schemas), isFalse);
      expect(notified, ['Unknown error']);
    });

    test('should handle field with multiple errors and notify only first one', () {
      final form = FakeFormApi(
        values: const {},
        errors: const {
          'field1': ['First error', 'Second error'],
        },
      );
      const schemas = [FormSchema(name: 'field1', label: 'Field 1', required: true, type: FormTypeEnum.textInput)];
      expect(check(form, schemas), isFalse);
      expect(notified, ['First error']);
    });

    test('should return true when all visible fields have no errors', () {
      final form = FakeFormApi(
        values: const {'showHidden': 'false'},
        errors: const {'visibleField': [], 'hiddenField': []},
      );
      const schemas = [
        FormSchema(name: 'visibleField', label: 'Visible Field', required: true, type: FormTypeEnum.textInput),
        FormSchema(
          name: 'hiddenField',
          label: 'Hidden Field',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'showHidden', value: 'true')],
        ),
      ];
      expect(check(form, schemas), isTrue);
      expect(notified, isEmpty);
    });

    test('should properly evaluate show_on conditions with different values', () {
      final form = FakeFormApi(
        values: const {'threshold': '100'},
        errors: const {
          'numericField': ['Numeric error'],
        },
      );
      const schemas = [
        FormSchema(
          name: 'numericField',
          label: 'Numeric Field',
          required: true,
          type: FormTypeEnum.textInput,
          showOn: [(variable: 'threshold', value: '100')],
        ),
      ];
      expect(check(form, schemas), isFalse);
      expect(notified, ['Numeric error']);
    });
  });
}
