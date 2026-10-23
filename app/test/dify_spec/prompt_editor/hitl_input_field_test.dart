// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/input-field.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/pre-populate.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/tag-label.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/hitl-input-block/__tests__/type-switch.spec.tsx
//
// The HITL field editor (InputFieldEditor, Dify's InputField) and its parts. Dify's spec mocks the variable picker,
// ConfigSelect and FileUploadSetting with buttons that emit fixed values; here those controls are real and the
// same values go through their onChange.
import 'package:dify_sf_app/src/design/dify_icon.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/human_input/form_content.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../workflow/nodes_panel/data/human_input_test_kit.dart';

Map<String, Object?> _payload({Object? def = const {'type': 'constant', 'selector': <Object?>[], 'value': 'hello'}}) =>
    {
      'type': 'paragraph',
      'output_variable_name': 'valid_name',
      'default': ?def,
    };

String _t(String key) => hiKey('insertInputField.$key');

Finder _nameField() => inputNamed(_t('saveResponseAs'));
Finder _textarea() => find.descendant(of: find.byType(DifyTextarea), matching: find.byType(EditableText));
Finder _button(String label) => find.widgetWithText(DifyButton, label);
Finder _insert() => _button(_t('insert'));

Future<List<Map<String, Object?>>> _render(
  WidgetTester t, {
  Map<String, Object?>? payload,
  bool isEdit = false,
  List<String> unavailable = const [],
  VoidCallback? onCancel,
}) async {
  final changes = <Map<String, Object?>>[];
  await pumpComponent(
    t,
    InputFieldEditor(
      scope: const VarScope(),
      payload: payload,
      isEdit: isEdit,
      unavailable: unavailable,
      onChange: changes.add,
      onCancel: onCancel ?? () {},
    ),
  );
  await t.pump();
  return changes;
}

Future<void> _ctrlEnter(WidgetTester t) async {
  await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await t.sendKeyEvent(LogicalKeyboardKey.enter);
  await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await t.pump();
}

/// Chooses the field type [label] (`app-debug.variableConfig.*`) in the type select.
Future<void> _chooseType(WidgetTester t, String label) async {
  await tapAndSettle(t, find.byType(InputTypeSelect));
  await tapAndSettle(t, find.text('app-debug.variableConfig.$label').last);
}

Future<void> _tapText(WidgetTester t, String key) async {
  await t.tap(find.text(_t(key)));
  await t.pump();
}

VarReferencePicker _picker(WidgetTester t) => t.widget<VarReferencePicker>(find.byType(VarReferencePicker).last);

class _PlaceholderTranslator extends DifyTestTranslator {
  @override
  String t(String ns, String key, [Map<String, Object?> params = const {}]) =>
      key == 'nodes.humanInput.insertInputField.prePopulateFieldPlaceholder'
      ? '<staticContent/> <variable/>'
      : super.t(ns, key, params);
}

void main() {
  group('InputField', () {
    testWidgets('should keep the header and actions visible while the field content scrolls internally', (t) async {
      await _render(t, payload: _payload());
      // `max-h-(--shortcut-popup-max-height,80dvh)` outside the shortcut popup: 80 % of the window's height.
      t.view.physicalSize = const Size(1400, 400);
      await t.pump();
      final panel = t.getRect(find.byType(InputFieldEditor));
      expect(panel.height, lessThanOrEqualTo(320));
      // The title and the actions stay in the panel; the fields scroll between them.
      expect(panel.contains(t.getCenter(find.text(_t('title')))), isTrue);
      expect(panel.contains(t.getCenter(find.text('common.operation.cancel'))), isTrue);
      expect(
        find.descendant(of: find.byType(InputFieldEditor), matching: find.byType(SingleChildScrollView)),
        findsOneWidget,
      );
    });

    testWidgets('should focus the field type from its visible label and save the selected type', (t) async {
      final changes = await _render(t, payload: _payload(), isEdit: true);
      await t.tap(find.text(_t('fieldType')));
      await t.pump();
      expect(t.widget<InputTypeSelect>(find.byType(InputTypeSelect)).focusNode!.hasFocus, isTrue);
      await _chooseType(t, 'select');
      await t.tap(_button('common.operation.save'));
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single['type'], 'select');
      expect(changes.single['output_variable_name'], 'valid_name');
    });

    testWidgets('should disable save and show validation error when variable name is invalid', (t) async {
      final changes = await _render(t, payload: _payload(), isEdit: true);
      await t.enterText(_nameField(), 'invalid name');
      await t.pump();
      expect(find.text(_t('variableNameInvalid')), findsOneWidget);
      expect(t.widget<DifyButton>(_button('common.operation.save')).disabled, isTrue);
      await t.tap(_button('common.operation.save'));
      await _ctrlEnter(t);
      expect(changes, isEmpty);
    });

    testWidgets('should disable save and show validation error when variable name already exists', (t) async {
      final changes = await _render(t, payload: _payload(), unavailable: const ['existing_name']);
      await t.enterText(_nameField(), 'existing_name');
      await t.pump();
      expect(find.text(_t('variableNameDuplicated')), findsOneWidget);
      expect(t.widget<DifyButton>(_insert()).disabled, isTrue);
      await _ctrlEnter(t);
      expect(changes, isEmpty);
    });

    testWidgets('should call onChange when saving a valid payload in edit mode', (t) async {
      final changes = await _render(t, payload: _payload(), isEdit: true);
      await t.tap(_button('common.operation.save'));
      await t.pump();
      expect(changes, [_payload()]);
    });

    testWidgets('should call onCancel when cancel button is clicked', (t) async {
      var cancels = 0;
      await _render(t, payload: _payload(), onCancel: () => cancels++);
      await t.tap(_button('common.operation.cancel'));
      await t.pump();
      expect(cancels, 1);
    });

    testWidgets('should use default payload when payload is not provided', (t) async {
      final changes = await _render(t);
      await t.enterText(_nameField(), 'generated_name');
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {
          'type': 'paragraph',
          'output_variable_name': 'generated_name',
          'default': {'type': 'constant', 'selector': <Object?>[], 'value': ''},
        },
      ]);
    });

    testWidgets('should save in create mode on Ctrl+Enter and include updated default constant value', (t) async {
      final changes = await _render(
        t,
        payload: _payload(def: {'type': 'constant', 'selector': <Object?>[], 'value': ''}),
      );
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await t.enterText(_textarea(), 'constant-default');
      await t.pump();
      await _ctrlEnter(t);
      expect(changes, hasLength(1));
      expect(changes.single['default'], {'type': 'constant', 'selector': <Object?>[], 'value': 'constant-default'});
    });

    testWidgets('should switch to variable mode when type switch is clicked', (t) async {
      final changes = await _render(
        t,
        payload: _payload(def: {'type': 'constant', 'selector': <Object?>[], 'value': 'preset'}),
      );
      await _tapText(t, 'useVarInstead');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect((changes.single['default']! as Map)['type'], 'variable');
    });

    testWidgets('should switch to constant mode when variable mode type switch is clicked', (t) async {
      final changes = await _render(
        t,
        payload: _payload(
          def: {
            'type': 'variable',
            'selector': ['node-y', 'var-y'],
            'value': '',
          },
        ),
      );
      await _tapText(t, 'useConstantInstead');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect((changes.single['default']! as Map)['type'], 'constant');
    });

    testWidgets('should update default selector when variable picker is used', (t) async {
      final changes = await _render(
        t,
        payload: _payload(
          def: {
            'type': 'variable',
            'selector': ['node-x', 'old'],
            'value': '',
          },
        ),
      );
      _picker(t).onChange(['node-a', 'var-a'], null);
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single['default'], {
        'type': 'variable',
        'selector': ['node-a', 'var-a'],
        'value': '',
      });
    });

    testWidgets('should initialize default config when missing and selector is selected', (t) async {
      final changes = await _render(t, payload: _payload(def: null));
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      await _tapText(t, 'useVarInstead');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single['default'], {'type': 'variable', 'selector': <Object?>[], 'value': ''});
    });

    testWidgets('should switch to select payload when field type changes', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'select');
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {
          'type': 'select',
          'output_variable_name': 'valid_name',
          'option_source': {'type': 'constant', 'selector': <Object?>[], 'value': <Object?>[]},
        },
      ]);
      expect(find.text(_t('prePopulateField')), findsNothing);
    });

    testWidgets('should keep paragraph pre-populate editor available after switching back to paragraph', (t) async {
      await _render(t, payload: _payload());
      expect(find.text(_t('prePopulateField')), findsOneWidget);
      await _chooseType(t, 'single-file');
      expect(find.text(_t('prePopulateField')), findsNothing);
      await _chooseType(t, 'paragraph');
      expect(find.text(_t('prePopulateField')), findsOneWidget);
    });

    testWidgets('should save constant select options', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'select');
      t.widget<ConfigSelect>(find.byType(ConfigSelect)).onChange(['alpha', 'beta']);
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {
          'type': 'select',
          'output_variable_name': 'valid_name',
          'option_source': {
            'type': 'constant',
            'selector': <Object?>[],
            'value': ['alpha', 'beta'],
          },
        },
      ]);
    });

    testWidgets('should preserve constant and variable select sources when toggling', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'select');
      t.widget<ConfigSelect>(find.byType(ConfigSelect)).onChange(['alpha', 'beta']);
      await t.pump();
      await _tapText(t, 'useVarInstead');
      _picker(t).onChange(['node-a', 'var-a'], null);
      await t.pump();
      await _tapText(t, 'useConstantInstead');
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {
          'type': 'select',
          'output_variable_name': 'valid_name',
          'option_source': {
            'type': 'constant',
            'selector': ['node-a', 'var-a'],
            'value': ['alpha', 'beta'],
          },
        },
      ]);
    });

    testWidgets('should only allow array[string] variables for select option source', (t) async {
      await _render(t, payload: _payload());
      await _chooseType(t, 'select');
      await _tapText(t, 'useVarInstead');
      final filter = _picker(t).filterVar!;
      expect(filter(const PickerVar('a', 'array[string]'), const []), isTrue);
      expect(filter(const PickerVar('a', 'string'), const []), isFalse);
      expect(filter(const PickerVar('a', 'array[file]'), const []), isFalse);
    });

    testWidgets('should clear paragraph default state when switching to select', (t) async {
      final changes = await _render(
        t,
        payload: _payload(def: {'type': 'constant', 'selector': <Object?>[], 'value': 'paragraph-default'}),
      );
      await _chooseType(t, 'select');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single.containsKey('default'), isFalse);
    });

    const fileSetting = {
      'allowed_file_extensions': ['.pdf'],
      'allowed_file_types': ['document'],
      'allowed_file_upload_methods': ['local_file'],
    };

    testWidgets('should save single file upload settings', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'single-file');
      t.widget<FileUploadSetting>(find.byType(FileUploadSetting)).onChange({...fileSetting, 'max_length': 4});
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {'type': 'file', 'output_variable_name': 'valid_name', ...fileSetting},
      ]);
    });

    testWidgets('should clear paragraph default state when switching to single file', (t) async {
      final changes = await _render(
        t,
        payload: _payload(def: {'type': 'constant', 'selector': <Object?>[], 'value': 'paragraph-default'}),
      );
      await _chooseType(t, 'single-file');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single.containsKey('default'), isFalse);
    });

    testWidgets('should save file-list upload settings and max upload count', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'multi-files');
      t.widget<FileUploadSetting>(find.byType(FileUploadSetting)).onChange({...fileSetting, 'max_length': 4});
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, [
        {'type': 'file-list', 'output_variable_name': 'valid_name', ...fileSetting, 'number_limits': 4},
      ]);
    });

    testWidgets('should normalize empty file-list upload limit on save', (t) async {
      final changes = await _render(t, payload: _payload());
      await _chooseType(t, 'multi-files');
      t.widget<FileUploadSetting>(find.byType(FileUploadSetting)).onChange({...fileSetting, 'max_length': double.nan});
      await t.pump();
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single['type'], 'file-list');
      expect(changes.single['number_limits'], 1);
    });

    testWidgets('should clear paragraph default state when switching to file-list', (t) async {
      final changes = await _render(
        t,
        payload: _payload(def: {'type': 'constant', 'selector': <Object?>[], 'value': 'paragraph-default'}),
      );
      await _chooseType(t, 'multi-files');
      await t.tap(_insert());
      await t.pump();
      expect(changes, hasLength(1));
      expect(changes.single.containsKey('default'), isFalse);
    });
  });

  group('PrePopulate', () {
    // Dify's spec gives the placeholder its tags (`<staticContent/> <variable/>`).
    Future<void> pumpPre(WidgetTester t, Widget child) async {
      DifyI18n.current = _PlaceholderTranslator();
      await t.pumpWidget(
        MaterialApp(
          home: Material(
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 600, child: child),
            ),
          ),
        ),
      );
      await t.pump();
    }

    Widget prePopulate({
      bool isVariable = false,
      List<String> selector = const [],
      String value = '',
      ValueChanged<bool>? onIsVariableChange,
      ValueChanged<List<String>>? onSelectorChange,
      ValueChanged<String>? onValueChange,
    }) => PrePopulate(
      isVariable: isVariable,
      selector: selector,
      value: value,
      scope: const VarScope(),
      onIsVariableChange: onIsVariableChange ?? (_) {},
      onSelectorChange: onSelectorChange ?? (_) {},
      onValueChange: onValueChange ?? (_) {},
    );

    testWidgets('should show placeholder initially and switch out of placeholder on Tab key', (t) async {
      await pumpPre(t, prePopulate());
      expect(find.text(_t('staticContent')), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(find.text(_t('staticContent')), findsNothing);
      expect(_textarea(), findsOneWidget);
    });

    testWidgets('should update constant value and toggle to variable mode when type switch is clicked', (t) async {
      final values = <String>[];
      final isVariable = <bool>[];
      await pumpPre(
        t,
        StatefulBuilder(
          builder: (context, setState) {
            final value = values.isEmpty ? 'initial value' : values.last;
            return prePopulate(
              value: value,
              onValueChange: (v) => setState(() => values.add(v)),
              onIsVariableChange: isVariable.add,
            );
          },
        ),
      );
      await t.enterText(_textarea(), 'next');
      await t.pump();
      await _tapText(t, 'useVarInstead');
      expect(values.last, 'next');
      expect(isVariable, [true]);
    });

    testWidgets('should render variable picker mode and propagate selected value selector', (t) async {
      final selectors = <List<String>>[];
      final isVariable = <bool>[];
      await pumpPre(
        t,
        prePopulate(
          isVariable: true,
          selector: const ['node-2', 'existing'],
          onSelectorChange: selectors.add,
          onIsVariableChange: isVariable.add,
        ),
      );
      _picker(t).onChange(['node-1', 'var-1'], null);
      await t.pump();
      await _tapText(t, 'useConstantInstead');
      expect(selectors, [
        ['node-1', 'var-1'],
      ]);
      expect(isVariable, [false]);
    });

    testWidgets('should pass variable type filter to picker that allows string number and secret', (t) async {
      await pumpPre(t, prePopulate(isVariable: true, selector: const ['node-3', 'existing']));
      final filter = _picker(t).filterVar!;
      expect(filter(const PickerVar('a', 'string'), const []), isTrue);
      expect(filter(const PickerVar('a', 'number'), const []), isTrue);
      expect(filter(const PickerVar('a', 'secret'), const []), isTrue);
      expect(filter(const PickerVar('a', 'object'), const []), isFalse);
    });

    testWidgets('should trigger static-content placeholder action and switch to non-placeholder mode', (t) async {
      final isVariable = <bool>[];
      await pumpPre(t, prePopulate(onIsVariableChange: isVariable.add));
      await _tapText(t, 'staticContent');
      expect(isVariable, [false]);
      expect(find.text(_t('staticContent')), findsNothing);
    });
  });

  group('TagLabel', () {
    testWidgets('should render edit icon label and trigger click handler when type is edit', (t) async {
      var clicks = 0;
      await pumpComponent(t, TagLabel(text: 'Edit', isVariable: false, onTap: () => clicks++));
      await t.tap(find.text('Edit'));
      expect(clicks, 1);
      expect(find.byWidgetPredicate((w) => w is RemixIcon && w.name == 'edit-line'), findsOneWidget);
    });

    testWidgets('should render variable icon label when type is variable', (t) async {
      await pumpComponent(t, const TagLabel(text: 'Variable', isVariable: true));
      expect(find.text('Variable'), findsOneWidget);
      expect(
        find.byWidgetPredicate((w) => w is DifyIcon && w.name == 'vender/solid/development/variable-02'),
        findsOneWidget,
      );
    });
  });

  group('TypeSwitch', () {
    testWidgets('should render use variable text when isVariable is false and toggle to true on click', (t) async {
      final changes = <bool>[];
      await pumpComponent(t, TypeSwitch(isVariable: false, onIsVariableChange: changes.add));
      await t.tap(find.bySemanticsLabel(_t('useVarInstead')));
      expect(changes, [true]);
    });

    testWidgets('should render use constant text when isVariable is true and toggle to false on click', (t) async {
      final changes = <bool>[];
      await pumpComponent(t, TypeSwitch(isVariable: true, onIsVariableChange: changes.add));
      await t.tap(find.bySemanticsLabel(_t('useConstantInstead')));
      expect(changes, [false]);
    });
  });
}
