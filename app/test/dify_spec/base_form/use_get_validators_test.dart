// dify-spec: web/app/components/base/form/hooks/__tests__/use-get-validators.spec.ts
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('useGetValidators', () {
    test('should create required validators when field is required without custom validators', () {
      final v = getValidators(
        const FormSchema(name: 'username', label: 'Username', required: true, type: FormTypeEnum.textInput),
      );
      final mount = v?.onMount?.call('');
      final blur = v?.onBlur?.call('');
      expect(mount, contains('common.errorMsg.fieldRequired'));
      expect(mount, contains('"field":"Username"'));
      expect(blur, contains('common.errorMsg.fieldRequired'));
    });

    test('should keep existing validators when custom validators are provided', () {
      final custom = FieldValidators(onChange: (_) => 'custom error');
      final v = getValidators(
        FormSchema(
          name: 'username',
          label: 'Username',
          required: true,
          type: FormTypeEnum.textInput,
          validators: custom,
        ),
      );
      expect(v, same(custom));
    });

    test('should fallback to field name when label is a react element', () {
      final v = getValidators(
        const FormSchema(name: 'apiKey', label: Text('API Key'), required: true, type: FormTypeEnum.textInput),
      );
      expect(v?.onMount?.call(''), contains('"field":"apiKey"'));
    });

    test('should translate object labels and skip validators for non-required fields', () {
      final required = getValidators(
        const FormSchema(
          name: 'workspace',
          label: {'en_US': 'Workspace', 'zh_Hans': '工作区'},
          required: true,
          type: FormTypeEnum.textInput,
        ),
      );
      final optional = getValidators(
        const FormSchema(name: 'optionalField', label: 'Optional', type: FormTypeEnum.textInput),
      );
      expect(required?.onChange?.call(''), contains('"field":"Workspace"'));
      expect(optional, isNull);
    });

    test('should return undefined when value is truthy (onMount, onChange, onBlur)', () {
      final v = getValidators(
        const FormSchema(name: 'username', label: 'Username', required: true, type: FormTypeEnum.textInput),
      );
      expect(v?.onMount?.call('some value'), isNull);
      expect(v?.onChange?.call('some value'), isNull);
      expect(v?.onBlur?.call('some value'), isNull);
    });

    test('should handle null/missing labels correctly', () {
      final v = getValidators(const FormSchema(name: 'id_field', required: true, type: FormTypeEnum.textInput));
      expect(v?.onMount?.call(''), contains('"field":"id_field"'));
    });

    test('should handle onChange message with fallback to name', () {
      final v = getValidators(
        const FormSchema(name: 'desc', label: SizedBox(), required: true, type: FormTypeEnum.textInput),
      );
      expect(v?.onChange?.call(''), contains('"field":"desc"'));
    });

    test('should handle onBlur message specifically', () {
      final v = getValidators(
        const FormSchema(name: 'email', label: 'Email Address', required: true, type: FormTypeEnum.textInput),
      );
      expect(v?.onBlur?.call(''), contains('"field":"Email Address"'));
    });
  });
}
