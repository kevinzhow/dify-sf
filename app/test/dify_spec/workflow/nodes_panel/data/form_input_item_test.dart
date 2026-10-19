// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/form-input-item.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/form-input-item.branches.spec.tsx
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/form-input-item.helpers.spec.ts
// dify-spec: web/app/components/workflow/nodes/_base/components/__tests__/form-input-item.sections.spec.tsx
//
// FormInputItem (tool_form.dart) and its helpers (tool_model.dart). Dify's mocked controls (the mixed text input,
// the JSON editor, the variable picker, the app and model selectors, the dynamic option queries) are the real
// controls and ToolPanelHost's services; the values Dify's mocks emit go through them.
import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_form.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_host.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

JsonMap _schema([JsonMap overrides = const {}]) => {
  'label': {'en_US': 'Field', 'zh_Hans': '字段'},
  'name': 'field',
  'required': false,
  'show_on': const <Object?>[],
  'type': FormType.textInput,
  'variable': 'field',
  ...overrides,
};

JsonMap _option(String value, [JsonMap overrides = const {}]) => {
  'label': {'en_US': value, 'zh_Hans': value},
  'show_on': const <Object?>[],
  'value': value,
  ...overrides,
};

JsonMap _entry(String type, Object? value) => {'type': type, 'value': value};

const _constant = ToolVarKind.constant, _variable = ToolVarKind.variable, _mixed = ToolVarKind.mixed;

Future<List<JsonMap>> _render(
  WidgetTester t, {
  JsonMap? schema,
  JsonMap? value,
  ToolFormEnv env = const ToolFormEnv(),
  ToolDynamicOptionsFetch? fetch,
  ToolSelectorBuilder? appSelector,
  ToolSelectorBuilder? modelSelector,
}) async {
  useDifyTestTranslator();
  final changes = <JsonMap>[];
  await t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: WorkflowStore(),
          child: DataPanelHost(
            child: ToolPanelHost(
              fetchDynamicOptions: fetch,
              appSelector: appSelector,
              modelSelector: modelSelector,
              child: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 800,
                  child: FormInputItem(
                    readOnly: false,
                    schema: schema ?? _schema(),
                    value: value ?? {'field': _entry(_constant, '')},
                    onChange: (v, [_]) => changes.add(v),
                    env: env,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return changes;
}

Future<void> _settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Widget _sections(Widget child) => MaterialApp(
  home: Material(
    child: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(width: 420, child: child),
    ),
  ),
);

const _dynamicEnv = ToolFormEnv(
  currentProvider: {'plugin_id': 'provider-1', 'name': 'provider-1'},
  currentTool: {'name': 'tool-1'},
);

void main() {
  group('FormInputItem', () {
    testWidgets('should parse number inputs as numbers', (t) async {
      final changes = await _render(
        t,
        schema: _schema({'type': FormType.textNumber}),
        value: {'field': _entry(_constant, 1)},
      );
      // dify-sf's number field commits on Enter or blur (a typed draft).
      await t.enterText(find.byType(EditableText), '3.5');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await t.pump();
      expect(changes.last, {'field': _entry(_constant, 3.5)});
    });

    testWidgets('should toggle boolean fields using the shared boolean input', (t) async {
      final changes = await _render(
        t,
        schema: _schema({'_type': FormType.boolean, 'type': FormType.textInput}),
        value: {'field': _entry(_constant, true)},
      );
      await t.tap(find.text('False'));
      expect(changes.last, {'field': _entry(_constant, false)});
    });

    testWidgets('should filter checkbox options by show_on and update selected values', (t) async {
      final changes = await _render(
        t,
        schema: _schema({
          '_type': FormType.checkbox,
          'type': FormType.textInput,
          'options': [
            _option('basic'),
            _option('pro', {
              'show_on': [
                {'variable': 'mode', 'value': 'pro'},
              ],
            }),
          ],
        }),
        value: {
          'field': _entry(_constant, ['basic']),
          'mode': _entry(_constant, 'pro'),
        },
      );
      await t.tap(find.text('pro'));
      expect(changes.last, {
        'field': _entry(_constant, ['basic', 'pro']),
        'mode': _entry(_constant, 'pro'),
      });
    });
  });

  group('FormInputItem branches', () {
    testWidgets('should update mixed string inputs via the shared text input', (t) async {
      final changes = await _render(t);
      final editor = find.descendant(of: find.byType(DifyPromptEditor), matching: find.byType(EditableText));
      await t.enterText(editor, 'hello world');
      // The mixed input commits its draft on blur.
      FocusManager.instance.primaryFocus?.unfocus();
      await t.pump();
      expect(changes.last, {'field': _entry(_mixed, 'hello world')});
    });

    testWidgets('should switch from variable mode back to constant mode with the schema default value', (t) async {
      final changes = await _render(
        t,
        schema: _schema({'default': 7, 'type': FormType.textNumber}),
        value: {
          'field': _entry(_variable, ['node-1', 'count']),
        },
      );
      await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.input'));
      expect(changes.last, {'field': _entry(_constant, 7)});
    });

    testWidgets('should render static select options with icons and update the selected item', (t) async {
      final changes = await _render(
        t,
        schema: _schema({
          'type': FormType.select,
          'options': [
            _option('basic', {'icon': '/basic.png'}),
            _option('pro'),
          ],
        }),
      );
      await t.tap(find.byType(DifySelect<String>));
      await _settle(t);
      expect(find.byWidgetPredicate((w) => w is ToolOptionIcon && w.url == '/basic.png'), findsOneWidget);
      await t.tap(find.text('basic'));
      expect(changes.last, {'field': _entry(_constant, 'basic')});
    });

    testWidgets('should render static multi-select values and update selected labels', (t) async {
      final changes = await _render(
        t,
        schema: _schema({
          'multiple': true,
          'type': FormType.select,
          'options': [_option('alpha'), _option('beta')],
        }),
        value: {
          'field': _entry(_constant, ['alpha']),
        },
      );
      expect(find.text('alpha'), findsOneWidget);
      await t.tap(find.bySemanticsLabel('alpha').first);
      await _settle(t);
      await t.tap(find.text('beta'));
      expect(changes.last, {
        'field': _entry(_constant, ['alpha', 'beta']),
      });
    });

    testWidgets('should fetch tool dynamic options, render them, and update the value', (t) async {
      var fetches = 0;
      final changes = await _render(
        t,
        schema: _schema({'type': FormType.dynamicSelect}),
        env: _dynamicEnv,
        fetch: ({required pluginId, required provider, required tool, required parameter, extraParams}) async {
          fetches++;
          return [
            _option('remote', {'icon': '/remote.png'}),
          ];
        },
      );
      await _settle(t);
      expect(fetches, 1);
      expect(t.widget<DifySelect<String>>(find.byType(DifySelect<String>)).disabled, isFalse);
      await t.tap(find.byType(DifySelect<String>));
      await _settle(t);
      expect(find.byWidgetPredicate((w) => w is ToolOptionIcon && w.url == '/remote.png'), findsOneWidget);
      await t.tap(find.text('remote'));
      expect(changes.last, {'field': _entry(_constant, 'remote')});
    });

    testWidgets('should recover when fetching dynamic tool options fails', (t) async {
      await _render(
        t,
        schema: _schema({'type': FormType.dynamicSelect}),
        env: _dynamicEnv,
        fetch: ({required pluginId, required provider, required tool, required parameter, extraParams}) async =>
            throw StateError('network'),
      );
      await _settle(t);
      // The failure leaves no options and ends the loading state.
      final select = t.widget<DifySelect<String>>(find.byType(DifySelect<String>));
      expect(select.disabled, isFalse);
      expect(select.options, isEmpty);
    });

    testWidgets('should use trigger dynamic options for multi-select values', (t) async {
      final changes = await _render(
        t,
        schema: _schema({'multiple': true, 'type': FormType.dynamicSelect}),
        value: {'field': _entry(_constant, <Object?>[])},
        env: const ToolFormEnv(
          currentProvider: {'plugin_id': 'provider-2', 'name': 'provider-2', 'credential_id': 'credential-1'},
          currentTool: {'name': 'trigger-tool'},
        ),
        fetch: ({required pluginId, required provider, required tool, required parameter, extraParams}) async => [
          _option('trigger-option'),
        ],
      );
      await _settle(t);
      await t.tap(find.text('Select options'));
      await _settle(t);
      await t.tap(find.text('trigger-option'));
      expect(changes.last, {
        'field': _entry(_constant, ['trigger-option']),
      });
    });

    testWidgets('should delegate app and model selection to their dedicated controls', (t) async {
      Widget selector(String label, JsonMap picked, ValueChanged<JsonMap> onSelect) =>
          TextButton(onPressed: () => onSelect(picked), child: Text(label));
      final app = await _render(
        t,
        schema: _schema({'type': FormType.appSelector}),
        appSelector: (context, {required value, required onSelect, required readOnly, scope}) =>
            selector('app-selector', {'app_id': 'app-1', 'inputs': {}, 'files': []}, onSelect),
      );
      await t.tap(find.text('app-selector'));
      expect(app.last, {
        'field': _entry(_constant, {'app_id': 'app-1', 'inputs': {}, 'files': []}),
      });
      final model = await _render(
        t,
        schema: _schema({'type': FormType.modelSelector}),
        modelSelector: (context, {required value, required onSelect, required readOnly, scope}) =>
            selector('model-selector', {'model': 'model-1'}, onSelect),
      );
      await t.tap(find.text('model-selector'));
      expect(model.last, {
        'field': _entry(_constant, {'model': 'model-1'}),
      });
    });

    testWidgets('should render the JSON editor and variable picker specialized branches', (t) async {
      final json = await _render(
        t,
        schema: _schema({'type': FormType.object}),
        value: {'field': _entry(_constant, '{"enabled":false}')},
      );
      t.widget<DifyCodeEditor>(find.byType(DifyCodeEditor)).onChange!('{"enabled":true}');
      expect(json.last, {'field': _entry(_constant, '{"enabled":true}')});
      final picker = await _render(t, schema: _schema({'type': FormType.file}));
      t.widget<VarReferencePicker>(find.byType(VarReferencePicker)).onChange(['node-2', 'asset'], null);
      expect(picker.last, {
        'field': _entry(_variable, ['node-2', 'asset']),
      });
    });

    testWidgets('should render variable selectors for boolean variable inputs', (t) async {
      final changes = await _render(
        t,
        schema: _schema({'_type': FormType.boolean, 'type': FormType.textInput}),
        value: {
          'field': _entry(_variable, ['node-3', 'flag']),
        },
      );
      t.widget<VarReferencePicker>(find.byType(VarReferencePicker)).onChange(['node-2', 'asset'], null);
      expect(changes.last, {
        'field': _entry(_variable, ['node-2', 'asset']),
      });
    });
  });

  group('form-input-item helpers', () {
    test('should derive field state and target var type', () {
      final number = FormInputState(_schema({'type': FormType.textNumber}), _entry(_constant, 1));
      final files = FormInputState(_schema({'type': FormType.files}), _entry(_variable, ['node', 'files']));
      expect(number.isNumber, isTrue);
      expect(number.showTypeSwitch, isTrue);
      expect(getTargetVarType(number), 'number');
      expect(files.isFile, isTrue);
      expect(files.showVariableSelector, isTrue);
      expect(getTargetVarType(files), 'array[file]');
      final multiple = FormInputState(
        _schema({'multiple': true, 'type': FormType.select}),
        _entry(_variable, ['node', 'formats']),
      );
      expect(getTargetVarType(multiple), 'array[string]');
      final filter = getFilterVar(multiple)!;
      expect(filter(const PickerVar('v', 'array[string]'), const []), isTrue);
      expect(filter(const PickerVar('v', 'array'), const []), isTrue);
      expect(filter(const PickerVar('v', 'array[number]'), const []), isFalse);
      expect(filter(const PickerVar('v', 'array[object]'), const []), isFalse);
      expect(filter(const PickerVar('v', 'string'), const []), isFalse);
    });

    test('should return filter functions and var kind types by schema mode', () {
      final stringFilter = getFilterVar(FormInputState(_schema(), _entry(_mixed, '')))!;
      final boolean = FormInputState(
        _schema({'_type': FormType.boolean, 'type': FormType.textInput}),
        _entry(_constant, true),
      );
      expect(stringFilter(const PickerVar('v', 'secret'), const []), isTrue);
      expect(stringFilter(const PickerVar('v', 'file'), const []), isFalse);
      expect(getVarKindType(boolean), _constant);
      // A boolean shown as a text input is a string field first (Dify's order of checks).
      expect(getFilterVar(boolean)!(const PickerVar('v', 'boolean'), const []), isFalse);
      final file = FormInputState(_schema({'type': FormType.file}), _entry(_variable, ['node', 'file']));
      final object = FormInputState(_schema({'type': FormType.object}), _entry(_constant, '{}'));
      final array = FormInputState(_schema({'type': FormType.array}), _entry(_constant, '[]'));
      final dynamic = FormInputState(_schema({'type': FormType.dynamicSelect}), _entry(_constant, 'selected'));
      expect(getFilterVar(file)!(const PickerVar('v', 'file'), const []), isTrue);
      expect(getFilterVar(object)!(const PickerVar('v', 'object'), const []), isTrue);
      expect(getFilterVar(array)!(const PickerVar('v', 'array[string]'), const []), isTrue);
      expect(getVarKindType(file), _variable);
      expect(getVarKindType(dynamic), _constant);
      expect(getVarKindType(FormInputState(_schema({'type': FormType.appSelector}), null)), isNull);
    });

    test('should expose date field state', () {
      final date = FormInputState(_schema({'type': FormType.date}), _entry(_constant, '2024-01-01'));
      expect(date.isDate, isTrue);
      expect(date.isDateRange, isFalse);
      expect(getTargetVarType(date), 'string');
      expect(getVarKindType(date), _constant);
      expect(getFilterVar(date)!(const PickerVar('v', 'string'), const []), isTrue);
      final range = FormInputState(_schema({'type': FormType.dateRange}), _entry(_constant, '{}'));
      expect(range.isDateRange, isTrue);
      expect(range.isDate, isFalse);
      expect(getVarKindType(range), _constant);
    });

    test('should filter and map visible options using show_on rules', () {
      final options = [
        _option('always'),
        _option('premium', {
          'show_on': [
            {'variable': 'mode', 'value': 'pro'},
          ],
        }),
      ];
      final visible = filterVisibleOptions(options, {'mode': _entry(_constant, 'pro')});
      expect(visible, hasLength(2));
      expect(mapSelectItems(visible, 'en_US'), [
        (icon: null, name: 'always', value: 'always'),
        (icon: null, name: 'premium', value: 'premium'),
      ]);
    });

    test('should compute selected labels and checkbox state from visible options', () {
      final options = [_option('alpha'), _option('beta'), _option('gamma')];
      expect(getSelectedLabels(['alpha', 'beta'], options, 'en_US'), 'alpha, beta');
      expect(getSelectedLabels(['alpha', 'beta', 'gamma'], options, 'en_US'), '3 selected');
      expect(getCheckboxListOptions(options, 'en_US'), [
        (label: 'alpha', value: 'alpha'),
        (label: 'beta', value: 'beta'),
        (label: 'gamma', value: 'gamma'),
      ]);
      expect(getCheckboxListValue(['alpha', 'missing'], ['beta'], options), ['alpha']);
    });

    test('should normalize number and variable selector values', () {
      // The number input's text: '' for NaN and nothing.
      expect(getNumberInputValue(double.nan), '');
      expect(getNumberInputValue(2), '2');
      expect(getNumberInputValue('3'), '3');
      expect(getNumberInputValue(null), '');
      expect(normalizeVariableSelectorValue(const <String>[]), const <String>[]);
      expect(normalizeVariableSelectorValue(const ['node', 'answer']), ['node', 'answer']);
      expect(normalizeVariableSelectorValue(''), '');
    });

    test('should derive remaining target variable types and label states', () {
      expect(getTargetVarType(FormInputState(_schema({'type': FormType.object}), null)), 'object');
      expect(getTargetVarType(FormInputState(_schema({'type': FormType.array}), null)), 'array[object]');
      expect(getSelectedLabels(null, const [], 'en_US'), '');
      expect(getCheckboxListValue('alpha', const [], [_option('alpha')]), ['alpha']);
    });
  });

  group('form-input-item sections', () {
    testWidgets('should render a loading multi-select label', (t) async {
      await t.pumpWidget(
        _sections(
          MultiSelectField(
            disabled: false,
            isLoading: true,
            items: const [(icon: null, name: 'Alpha', value: 'alpha')],
            onChange: (_) {},
            selectedLabel: '',
            value: const [],
          ),
        ),
      );
      expect(find.bySemanticsLabel('Options'), findsWidgets);
      expect(find.text('Loading…'), findsOneWidget);
    });

    testWidgets('should render the shared json editor section', (t) async {
      await _render(
        t,
        schema: _schema({'type': FormType.object}),
        value: {'field': _entry(_constant, '{"enabled":true}')},
      );
      expect(find.text('JSON'), findsOneWidget);
    });

    testWidgets('should render placeholder, icons, and select multi-select options', (t) async {
      final changes = <List<String>>[];
      await t.pumpWidget(
        _sections(
          MultiSelectField(
            disabled: false,
            items: const [
              (icon: '/alpha.png', name: 'Alpha', value: 'alpha'),
              (icon: null, name: 'Beta', value: 'beta'),
            ],
            onChange: changes.add,
            placeholder: 'Choose options',
            selectedLabel: '',
            value: const [],
          ),
        ),
      );
      expect(find.text('Choose options'), findsOneWidget);
      await t.tap(find.text('Choose options'));
      await _settle(t);
      await t.tap(find.text('Alpha'));
      expect(find.byWidgetPredicate((w) => w is ToolOptionIcon && w.url == '/alpha.png'), findsOneWidget);
      expect(changes, isNotEmpty);
    });
  });
}
