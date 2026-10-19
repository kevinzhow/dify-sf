// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/settings/form/base_form.dart';
import 'package:dify_sf_app/src/settings/model_provider/provider_data.dart';
import 'package:dify_sf_app/src/workflow/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('utils', () {
    group('sizeFormat', () {
      test('should format size less than 1000', () {
        expect(sizeFormat(500), '500');
      });

      test('should format size greater than 1000', () {
        expect(sizeFormat(1500), '1K');
      });
    });

    group('modelTypeFormat', () {
      test('should format text embedding type', () {
        expect(modelTypeFormat(ModelTypeEnum.textEmbedding), 'TEXT EMBEDDING');
      });

      test('should format other types', () {
        expect(modelTypeFormat(ModelTypeEnum.textGeneration), 'LLM');
      });
    });

    group('genModelTypeFormSchema', () {
      test('should generate form schema', () {
        final schema = genModelTypeFormSchema([ModelTypeEnum.textGeneration]);
        expect(schema.type, FormTypeEnum.select);
        expect(schema.name, '__model_type');
        expect(schema.options![0].value, ModelTypeEnum.textGeneration);
      });
    });

    group('genModelNameFormSchema', () {
      test('should generate default form schema when no model provided', () {
        final schema = genModelNameFormSchema();
        expect(schema.type, FormTypeEnum.textInput);
        expect(schema.name, '__model_name');
        expect(schema.required, isTrue);
        expect((schema.label! as Map)['en_US'], 'Model Name');
        expect((schema.placeholder! as Map)['en_US'], 'Please enter model name');
      });

      test('should use provided label and placeholder when model is given', () {
        final schema = genModelNameFormSchema({
          'label': {'en_US': 'Custom', 'zh_Hans': 'Custom'},
          'placeholder': {'en_US': 'Enter custom', 'zh_Hans': 'Enter custom'},
        });
        expect((schema.label! as Map)['en_US'], 'Custom');
        expect((schema.placeholder! as Map)['en_US'], 'Enter custom');
      });
    });
  });
}
