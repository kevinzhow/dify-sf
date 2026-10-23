// dify-spec: web/app/components/workflow/nodes/_base/components/editor/code-editor/__tests__/utils.spec.ts
import 'package:dify_sf_app/src/workflow_editor/code_editor/utils.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('serializeCodeEditorValue', () {
    test('turns object values into JSON text so Monaco does not treat them as a buffer factory', () {
      const schema = {
        'type': 'object',
        'properties': {
          'id': {'type': 'string'},
        },
      };
      const json = '{\n  "type": "object",\n  "properties": {\n    "id": {\n      "type": "string"\n    }\n  }\n}';

      expect(serializeCodeEditorValue(schema), json);
      expect(serializeCodeEditorValue(schema, isJSONStringifyBeauty: true), json);
      expect(serializeCodeEditorValue('{"type":"object"}'), '{"type":"object"}');
      expect(serializeCodeEditorValue(null), '');
    });
  });
}
