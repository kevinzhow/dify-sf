// dify-spec: web/app/components/workflow/panel/chat-variable-panel/components/__tests__/use-variable-modal-state.spec.ts
import 'dart:convert';

import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:dify_sf_app/src/workflow_editor/variable_panels/chat_variable_state.dart';

/// Dify's `withSelectorKey((key) => key)`: the bare key.
class KeyTranslator implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;
}

void main() {
  setUp(() => DifyI18n.current = KeyTranslator());

  late List<String> notified;
  late List<Map<String, Object?>> saved;
  late int closed;

  ChatVariableModalState create([Map<String, Object?>? chatVar]) => ChatVariableModalState(
    chatVar: chatVar,
    conversationVariables: () => const [],
    notify: notified.add,
    onClose: () => closed++,
    onSave: saved.add,
  );

  setUp(() {
    notified = [];
    saved = [];
    closed = 0;
  });

  group('useVariableModalState', () {
    test('should build initial state from an existing array object variable', () {
      final s = create({
        'id': 'var-1',
        'name': 'payload',
        'description': 'desc',
        'value_type': ChatVarType.arrayObject,
        'value': [
          {'enabled': true},
        ],
      });

      expect(s.name, 'payload');
      expect(s.description, 'desc');
      expect(s.type, ChatVarType.arrayObject);
      expect(s.editInJSON, true);
      expect(
        s.editorContent,
        jsonEncode([
          {'enabled': true},
        ]),
      );
    });

    test('should update state when changing types and editing scalar values', () {
      final s = create()..handleTypeChange(ChatVarType.object);
      expect(s.type, ChatVarType.object);
      expect(s.objectValue, hasLength(1));

      s
        ..handleTypeChange(ChatVarType.number)
        ..handleStringOrNumberChange([12]);
      expect(s.value, 12);

      s
        ..description = 'note'
        ..value = true;
      expect(s.description, 'note');
      expect(s.value, true);
    });

    test('should toggle object values between form and json modes', () {
      final s = create({
        'id': 'var-2',
        'name': 'config',
        'description': '',
        'value_type': ChatVarType.object,
        'value': {'timeout': 30},
      })..handleEditorChange(true);
      expect(s.editInJSON, true);
      expect(s.editorContent, jsonEncode({'timeout': 30}));

      s
        ..handleEditorValueChange('{"timeout":45}')
        ..handleEditorChange(false);
      expect(s.editInJSON, false);
      expect(s.objectValue, [(key: 'timeout', type: ChatVarType.number, value: 45)]);
    });

    test('should keep valid object rows when switching to json mode from form mode', () {
      final s = create()
        ..handleTypeChange(ChatVarType.object)
        ..objectValue = [
          (key: '', type: ChatVarType.string, value: null),
          (key: 'timeout', type: ChatVarType.number, value: 30),
        ]
        ..handleEditorChange(true);

      expect(s.editInJSON, true);
      expect(s.value, {'timeout': 30});
      expect(s.editorContent, jsonEncode({'timeout': 30}));
    });

    test('should reset object form values when leaving empty json mode', () {
      final s =
          create({'id': 'var-3', 'name': 'config', 'description': '', 'value_type': ChatVarType.object, 'value': {}})
            ..handleEditorChange(true)
            ..handleEditorValueChange('')
            ..handleEditorChange(false);

      expect(s.objectValue, hasLength(1));
      expect(s.value, isNull);
    });

    test('should handle array editor toggles and invalid json safely', () {
      final s = create()
        ..handleTypeChange(ChatVarType.arrayString)
        ..value = ['a', '', 'b']
        ..handleEditorChange(true);
      expect(s.editInJSON, true);
      expect(s.value, ['a', 'b']);

      s.handleEditorValueChange('[invalid');
      expect(s.editorContent, '[invalid');
      expect(s.value, ['a', 'b']);

      s.handleEditorChange(false);
      expect(s.value, ['a', 'b']);

      s
        ..handleTypeChange(ChatVarType.arrayBoolean)
        ..value = [true, false]
        ..handleEditorChange(true);
      expect(s.editorContent, jsonEncode(['True', 'False']));
    });

    test('should preserve zero values when switching number arrays into json mode', () {
      final s = create()
        ..handleTypeChange(ChatVarType.arrayNumber)
        ..value = [0, 2, null]
        ..handleEditorChange(true);

      expect(s.editInJSON, true);
      expect(s.value, [0, 2]);
      expect(s.editorContent, jsonEncode([0, 2]));
    });

    test('should notify and stop saving when object keys are invalid', () {
      create()
        ..handleVarNameChange('config')
        ..handleTypeChange(ChatVarType.object)
        ..objectValue = [(key: '', type: ChatVarType.string, value: 'secret')]
        ..save();

      expect(notified, ['chatVariable.modal.objectKeyRequired']);
      expect(saved, isEmpty);
      expect(closed, 0);
    });

    test('should notify and stop saving when description exceeds the limit', () {
      create()
        ..handleVarNameChange('greeting')
        ..handleStringOrNumberChange(['hello'])
        ..description = 'a' * 256
        ..save();

      expect(notified, ['chatVariable.modal.descriptionTooLong']);
      expect(saved, isEmpty);
      expect(closed, 0);
    });

    test('should save a new variable and close when state is valid', () {
      create()
        ..handleVarNameChange('greeting')
        ..handleStringOrNumberChange(['hello'])
        ..save();

      expect(saved, hasLength(1));
      expect(saved.single['id'], isA<String>());
      expect({...saved.single}..remove('id'), {
        'description': '',
        'name': 'greeting',
        'value': 'hello',
        'value_type': ChatVarType.string,
      });
      expect(closed, 1);
    });
  });
}
