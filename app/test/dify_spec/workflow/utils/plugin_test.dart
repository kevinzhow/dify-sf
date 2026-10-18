// dify-spec: web/app/components/workflow/utils/__tests__/plugin.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/checklist/node_validators.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('extractPluginId', () {
    test('returns the provider prefix for nested plugin paths', () {
      expect(extractPluginId('langgenius/openai/tools/chat'), 'langgenius/openai');
    });

    test('returns the original provider when it has no nested path', () {
      expect(extractPluginId('langgenius'), 'langgenius');
    });
  });
}
