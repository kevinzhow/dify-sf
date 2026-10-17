// The Start node's input field dialog (config-modal) beyond Dify's specs: its validation and each field type's form.
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/core/start_var_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

String t(String ns, String key, [Map<String, Object?> params = const {}]) => key;

class _LastSegment implements Translator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      key == 'variableConfig.localUpload' ? 'Local' : key.split('.').last;
}

void main() {
  group('validateConfigModalPayload', () {
    Map<String, Object?> v(Map<String, Object?> o) => {...newVarInWorkflow(), 'variable': 'a', 'label': 'A', ...o};

    test('checks the name, label, options, file types and JSON schema in order', () {
      expect(validateConfigModalPayload(tempPayload: v({'variable': '1a'}), t: t).errorField, 'variable');
      expect(
        validateConfigModalPayload(tempPayload: v({'label': ''}), t: t).errorMessage,
        'variableConfig.errorMsg.labelNameRequired',
      );
      expect(
        validateConfigModalPayload(tempPayload: v({'type': 'select', 'options': []}), t: t).errorMessage,
        'variableConfig.errorMsg.atLeastOneOption',
      );
      expect(
        validateConfigModalPayload(
          tempPayload: v({
            'type': 'select',
            'options': ['x', 'x'],
          }),
          t: t,
        ).errorMessage,
        'variableConfig.errorMsg.optionRepeat',
      );
      final file = createPayloadForType(v({}), 'file-list');
      expect(
        validateConfigModalPayload(tempPayload: {...file, 'allowed_file_types': []}, t: t).errorField,
        'allowed_file_types',
      );
      expect(
        validateConfigModalPayload(
          tempPayload: {
            ...file,
            'allowed_file_types': ['custom'],
          },
          t: t,
        ).errorField,
        'allowed_file_extensions',
      );
      expect(
        validateConfigModalPayload(tempPayload: v({'type': 'json_object', 'json_schema': '{'}), t: t).errorMessage,
        'variableConfig.errorMsg.jsonSchemaInvalid',
      );
      expect(
        validateConfigModalPayload(
          tempPayload: v({'type': 'json_object', 'json_schema': '{"type":"array"}'}),
          t: t,
        ).errorMessage,
        'variableConfig.errorMsg.jsonSchemaMustBeObject',
      );
    });

    test('saves file lists clamped to the upload limit and reports renames', () {
      final r = validateConfigModalPayload(
        tempPayload: {...createPayloadForType(v({}), 'file-list'), 'max_length': 50},
        payload: v({'variable': 'old'}),
        maxFileUploadLimit: 10,
        t: t,
      );
      expect(r.payloadToSave!['max_length'], 10);
      expect(r.payloadToSave!['hide'], false);
      expect(r.payloadToSave!['allowed_file_types'], ['image']);
      expect(r.moreInfo, const VarChange.rename('old', 'a'));
      expect(validateConfigModalPayload(tempPayload: v({}), payload: v({}), t: t).moreInfo, isNull);
    });

    test('changing the options drops a default that is gone', () {
      final p = {
        'type': 'select',
        'options': ['a', 'b'],
        'default': 'b',
      };
      expect(updatePayloadField(p, 'options', ['a']).containsKey('default'), isFalse);
      expect(updatePayloadField(p, 'options', ['b'])['default'], 'b');
    });
  });

  testWidgets('each field type shows its form, and a valid field is saved', (t) async {
    // Keys as their last segment: the test font makes the full keys wider than the option cards.
    DifyI18n.current = _LastSegment();
    t.view.physicalSize = const Size(1600, 2400);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final saved = <Map<String, Object?>>[];
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showConfigVarModal(
                context,
                isCreate: true,
                supportFile: true,
                onConfirm: (p, _) {
                  saved.add(p);
                  return true;
                },
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await settle(t);
    expect(find.text('addModalTitle'), findsOneWidget);
    for (final type in [
      'paragraph',
      'select',
      'number',
      'checkbox',
      'single-file',
      'multi-files',
      'json',
      'text-input',
    ]) {
      await t.tap(find.byType(InputTypeSelect));
      await settle(t);
      await t.tap(find.text(type).last);
      await settle(t);
      final e = t.takeException();
      expect(e, isNull, reason: '$type: $e');
    }
    await t.enterText(
      find.descendant(
        of: find.ancestor(of: find.text('varName'), matching: find.byType(ModalField)),
        matching: find.byType(TextField),
      ),
      'my var',
    );
    // A blurred name fills the empty label.
    FocusManager.instance.primaryFocus?.unfocus();
    await settle(t);
    await t.tap(find.text('save'));
    await settle(t);
    expect(saved.single, containsPair('variable', 'my_var'));
    expect(saved.single, containsPair('label', 'my_var'));
    expect(saved.single, containsPair('type', 'text-input'));
    expect(find.text('addModalTitle'), findsNothing);
  });
}
