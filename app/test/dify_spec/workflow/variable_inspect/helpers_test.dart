// dify-spec: web/app/components/workflow/variable-inspect/__tests__/utils.spec.ts
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/value-content.helpers.spec.ts
// dify-spec: web/app/components/workflow/variable-inspect/__tests__/value-content.helpers.branches.spec.ts
import 'dart:convert';

import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/inspect_vars.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_inspect/value_content_helpers.dart';
import 'package:flutter_test/flutter_test.dart';

DifyJson createVar(DifyJson overrides) => {
  'id': 'var-1',
  'name': 'query',
  'type': VarInInspectType.node,
  'value_type': 'string',
  'value': '',
  ...overrides,
};

void main() {
  group('validateJSONSchema', () {
    test('accepts supported schema payloads for each structured type', () {
      expect(validateJSONSchema(['a', 'b'], 'array[string]').success, isTrue);
      expect(validateJSONSchema([1, 2], 'array[number]').success, isTrue);
      expect(
        validateJSONSchema({
          'answer': ['a', 1, false],
        }, 'object').success,
        isTrue,
      );
      expect(
        validateJSONSchema([
          {'answer': 'ok'},
        ], 'array[object]').success,
        isTrue,
      );
    });

    test('rejects invalid structured payloads and skips unknown types', () {
      expect(validateJSONSchema(['a', 1], 'array[string]').success, isFalse);
      expect(
        validateJSONSchema([
          {'answer': 'ok'},
        ], 'array[number]').success,
        isFalse,
      );
      expect(validateJSONSchema('plain-text', 'custom').success, isTrue);
    });
  });

  group('value-content helpers', () {
    test('should derive editor modes from the variable shape', () {
      final env = getValueEditorState(
        createVar({'type': VarInInspectType.environment, 'name': 'api_key', 'value_type': 'string', 'value': 'secret'}),
      );
      expect((env.showTextEditor, env.textEditorDisabled, env.showJSONEditor), (true, true, false));

      final chunks = getValueEditorState(
        createVar({
          'name': 'payload',
          'value_type': 'object',
          'value': {'foo': 1},
          'schemaType': 'general_structure',
        }),
      );
      expect((chunks.showJSONEditor, chunks.hasChunks), (true, true));

      final files = getValueEditorState(
        createVar({'type': VarInInspectType.system, 'name': 'files', 'value_type': 'array[file]', 'value': []}),
      );
      expect((files.isSysFiles, files.showFileEditor, files.showJSONEditor), (true, true, false));
    });

    test('should format file values and detect upload completion', () {
      expect(
        formatInspectFileValue(
          createVar({
            'name': 'file',
            'value_type': 'file',
            'value': {'id': 'file-1'},
          }),
        ),
        hasLength(1),
      );

      expect(
        isFileValueUploaded([
          {'upload_file_id': 'file-1'},
        ]),
        isTrue,
      );
      expect(
        isFileValueUploaded([
          {'upload_file_id': ''},
        ]),
        isFalse,
      );
      expect(
        formatInspectFileValue(
          createVar({
            'type': VarInInspectType.system,
            'name': 'files',
            'value_type': 'array[file]',
            'value': [
              {'id': 'file-2'},
            ],
          }),
        ),
        hasLength(1),
      );
    });

    test('should validate json input and surface parse errors', () {
      expect(validateInspectJsonValue('{"foo":1}', 'object').success, isTrue);
      expect(validateInspectJsonValue('[]', 'array[any]').success, isTrue);
      final broken = validateInspectJsonValue('{', 'object');
      expect(broken.success, isFalse);
      expect(broken.parseError, isA<FormatException>());
    });
  });

  group('value-content helpers branch coverage', () {
    // Dify mocks the schema checks; the real ones are fed values that fail each of them.
    test('should return validation errors for invalid schemas, over-deep schemas, and draft7 violations', () {
      final invalid = validateInspectJsonValue('["a", 1]', 'array[string]');
      expect((invalid.success, invalid.parseError), (false, null));
      expect(invalid.validationError, contains('invalid_type'));

      Object deep(int depth) => depth == 0
          ? {'type': 'string'}
          : {
              'type': 'object',
              'properties': {'child': deep(depth - 1)},
            };
      final tooDeep = validateInspectJsonValue(jsonEncode(deep(11)), 'object');
      expect((tooDeep.success, tooDeep.parseError), (false, null));
      expect(tooDeep.validationError, contains('Schema exceeds maximum depth'));

      final draft7 = validateInspectJsonValue('{"type": 1}', 'object');
      expect((draft7.success, draft7.parseError), (false, null));
      expect(draft7.validationError, startsWith('Error: '));
    });
  });
}
