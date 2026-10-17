// dify-spec: web/app/components/header/account-setting/model-provider-page/__tests__/utils.spec.ts
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
  });
}
