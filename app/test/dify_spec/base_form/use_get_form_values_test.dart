// dify-spec: web/app/components/base/form/hooks/__tests__/use-get-form-values.spec.ts
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:flutter_test/flutter_test.dart';

import '_fake_form.dart';

void main() {
  group('useGetFormValues', () {
    var checkResult = true;
    var checks = 0;
    final transformCalls = <(List<FormSchema>, FormApi)>[];
    Map<String, Object?> transformResult = const {};

    ({Map<String, Object?> values, bool isCheckValidated}) get(
      FormApi form,
      List<FormSchema> schemas, {
      bool needCheckValidatedValues = true,
      bool needTransformWhenSecretFieldIsPristine = false,
    }) => formValuesOf(
      form,
      schemas,
      needCheckValidatedValues: needCheckValidatedValues,
      needTransformWhenSecretFieldIsPristine: needTransformWhenSecretFieldIsPristine,
      check: () {
        checks++;
        return checkResult;
      },
      transform: (s, f) {
        transformCalls.add((s, f));
        return transformResult;
      },
    );

    setUp(() {
      checkResult = true;
      checks = 0;
      transformCalls.clear();
      transformResult = const {};
    });

    test('should return raw values when validation check is disabled', () {
      final r = get(FakeFormApi(values: const {'name': 'Alice'}), const [], needCheckValidatedValues: false);
      expect(r.values, {'name': 'Alice'});
      expect(r.isCheckValidated, isTrue);
    });

    test('should return transformed values when validation passes and transform is requested', () {
      const schemas = [FormSchema(name: 'password', label: 'Password', required: true, type: FormTypeEnum.secretInput)];
      transformResult = {'password': '[__HIDDEN__]'};
      final r = get(
        FakeFormApi(values: const {'password': 'abc123'}),
        schemas,
        needTransformWhenSecretFieldIsPristine: true,
      );
      expect(r.values, {'password': '[__HIDDEN__]'});
      expect(r.isCheckValidated, isTrue);
    });

    test('should return empty values when validation fails', () {
      checkResult = false;
      final r = get(FakeFormApi(values: const {'name': ''}), const []);
      expect(r.values, isEmpty);
      expect(r.isCheckValidated, isFalse);
    });

    test('should return raw values when validation passes but no transformation is requested', () {
      const schemas = [FormSchema(name: 'email', label: 'Email', required: true, type: FormTypeEnum.textInput)];
      final r = get(FakeFormApi(values: const {'email': 'test@example.com'}), schemas);
      expect(r.values, {'email': 'test@example.com'});
      expect(r.isCheckValidated, isTrue);
      expect(transformCalls, isEmpty);
    });

    test('should return raw values when validation passes and transformation is undefined', () {
      const schemas = [FormSchema(name: 'username', label: 'Username', required: true, type: FormTypeEnum.textInput)];
      final r = get(FakeFormApi(values: const {'username': 'john_doe'}), schemas);
      expect(r.values, {'username': 'john_doe'});
      expect(r.isCheckValidated, isTrue);
      expect(transformCalls, isEmpty);
    });

    test('should handle empty form values when validation check is disabled', () {
      final r = get(FakeFormApi(values: const {}), const [], needCheckValidatedValues: false);
      expect(r.values, isEmpty);
      expect(r.isCheckValidated, isTrue);
      expect(checks, 0);
    });

    test('should handle null form values gracefully', () {
      final r = get(FakeFormApi(), const [], needCheckValidatedValues: false);
      expect(r.values, isEmpty);
      expect(r.isCheckValidated, isTrue);
    });

    test('should call transform with correct arguments when transformation is requested', () {
      const schemas = [FormSchema(name: 'password', label: 'Password', required: true, type: FormTypeEnum.secretInput)];
      final form = FakeFormApi(values: const {'password': 'secret'});
      transformResult = {'password': 'encrypted'};
      get(form, schemas, needTransformWhenSecretFieldIsPristine: true);
      expect(transformCalls.single.$1, schemas);
      expect(transformCalls.single.$2, same(form));
    });

    test('should return validation failure before attempting transformation', () {
      const schemas = [FormSchema(name: 'password', label: 'Password', required: true, type: FormTypeEnum.secretInput)];
      checkResult = false;
      final r = get(
        FakeFormApi(values: const {'password': 'secret'}),
        schemas,
        needTransformWhenSecretFieldIsPristine: true,
      );
      expect(r.values, isEmpty);
      expect(r.isCheckValidated, isFalse);
      expect(transformCalls, isEmpty);
    });

    test('should handle complex nested values with validation check disabled', () {
      final values = {
        'user': {'name': 'Alice', 'age': 30},
        'settings': {'theme': 'dark'},
      };
      final r = get(FakeFormApi(values: values), const [], needCheckValidatedValues: false);
      expect(r.values, values);
      expect(r.isCheckValidated, isTrue);
    });
  });
}
