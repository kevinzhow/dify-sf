// dify-spec: web/app/components/workflow/nodes/tool/__tests__/default.spec.ts
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:flutter_test/flutter_test.dart';

/// `withSelectorKey((key) => key, 'workflow')`: the key, without namespace or parameters.
String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

const _defaultValue = {'tool_parameters': <String, Object?>{}, 'tool_configurations': <String, Object?>{}};

void main() {
  group('tool default node validation', () {
    test('should reject an empty required multi-select input', () {
      final error = checkValidTool(
        {
          ..._defaultValue,
          'title': 'Tool',
          'desc': '',
          'type': 'tool',
          'tool_parameters': {
            'formats': {'type': 'constant', 'value': <Object?>[]},
          },
        },
        t,
        {
          'toolInputsSchema': [
            {'variable': 'formats', 'required': true, 'label': 'Formats', 'type': 'select', 'multiple': true},
          ],
          'toolSettingSchema': <Object?>[],
          'language': 'en_US',
          'notAuthed': false,
        },
      );
      expect(error, 'errorMsg.fieldRequired');
    });

    test('should accept an explicit empty array for a required array input', () {
      final error = checkValidTool(
        {
          ..._defaultValue,
          'title': 'Tool',
          'desc': '',
          'type': 'tool',
          'tool_parameters': {
            'items': {'type': 'constant', 'value': <Object?>[]},
          },
        },
        t,
        {
          'toolInputsSchema': [
            {'variable': 'items', 'required': true, 'label': 'Items', 'type': 'array'},
          ],
          'toolSettingSchema': <Object?>[],
          'language': 'en_US',
          'notAuthed': false,
        },
      );
      expect(error, '');
    });
  });
}
