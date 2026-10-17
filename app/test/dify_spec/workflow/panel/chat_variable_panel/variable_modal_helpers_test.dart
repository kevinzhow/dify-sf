// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/variable-modal.helpers.spec.ts
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('variable-modal helpers', () {
    test('should build object items from a conversation variable value', () {
      expect(buildObjectValueItems(), hasLength(1));

      expect(
        buildObjectValueItems({
          'id': 'var-1',
          'name': 'config',
          'description': '',
          'value_type': ChatVarType.object,
          'value': {'apiKey': 'secret', 'timeout': 30},
        }),
        [
          (key: 'apiKey', type: ChatVarType.string, value: 'secret'),
          (key: 'timeout', type: ChatVarType.number, value: 30),
        ],
      );
    });

    test('should format object and array values for saving', () {
      expect(
        formatObjectValueFromList([
          (key: 'apiKey', type: ChatVarType.string, value: 'secret'),
          (key: '', type: ChatVarType.number, value: 1),
        ]),
        {'apiKey': 'secret'},
      );

      expect(
        formatObjectValueFromList([
          (key: 'count', type: ChatVarType.number, value: 0),
          (key: 'label', type: ChatVarType.string, value: ''),
        ]),
        {'count': 0, 'label': null},
      );
      expect(
        formatChatVariableValue(
          editInJSON: false,
          objectValue: [(key: 'enabled', type: ChatVarType.string, value: 'true')],
          type: ChatVarType.object,
          value: null,
        ),
        {'enabled': 'true'},
      );

      expect(
        formatChatVariableValue(editInJSON: true, objectValue: const [], type: ChatVarType.object, value: {'count': 1}),
        {'count': 1},
      );

      expect(
        formatChatVariableValue(
          editInJSON: false,
          objectValue: const [],
          type: ChatVarType.arrayString,
          value: ['a', '', 'b'],
        ),
        ['a', 'b'],
      );

      expect(
        formatChatVariableValue(
          editInJSON: false,
          objectValue: const [],
          type: ChatVarType.arrayNumber,
          value: [0, 1, null, null, ''],
        ),
        [0, 1],
      );

      expect(
        formatChatVariableValue(editInJSON: false, objectValue: const [], type: ChatVarType.number, value: null),
        0,
      );

      expect(
        formatChatVariableValue(editInJSON: false, objectValue: const [], type: ChatVarType.boolean, value: null),
        true,
      );

      expect(
        formatChatVariableValue(editInJSON: false, objectValue: const [], type: ChatVarType.arrayBoolean, value: null),
        <Object?>[],
      );
    });

    test('should derive placeholders, editor defaults, and editor toggle labels', () {
      expect(getEditorMinHeight(ChatVarType.arrayObject), 240);
      expect(getEditorMinHeight(ChatVarType.object), 120);
      expect(getPlaceholderByType(ChatVarType.arrayBoolean), isNotEmpty);
      expect(getTypeChangeState(ChatVarType.boolean).value, false);
      expect(getTypeChangeState(ChatVarType.arrayBoolean).value, [false]);
      expect(getTypeChangeState(ChatVarType.object).objectValue, hasLength(1));
      expect(getTypeChangeState(ChatVarType.arrayObject).editInJSON, true);
      expect(getEditorToggleLabelKey(ChatVarType.object, true), 'chatVariable.modal.editInForm');
      expect(getEditorToggleLabelKey(ChatVarType.arrayString, false), 'chatVariable.modal.editInJSON');
    });

    test('should parse boolean arrays from JSON editor content', () {
      expect(parseEditorContent('["True","false",true,false,"invalid"]', ChatVarType.arrayBoolean), [
        true,
        false,
        true,
        false,
      ]);

      expect(
        () => parseEditorContent('{"enabled":true}', ChatVarType.arrayBoolean),
        throwsA(isA<FormatException>().having((e) => e.message, 'message', contains('JSON array'))),
      );
      expect(parseEditorContent('{"enabled":true}', ChatVarType.object), {'enabled': true});
    });

    test('should validate variable names and notify when invalid', () {
      final notified = <String>[];

      expect(validateVariableName('valid_name', notified.add), true);
      expect(validateVariableName('1invalid', notified.add), false);
      expect(notified, hasLength(1));
    });
  });
}
