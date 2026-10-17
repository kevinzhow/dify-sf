// dify-spec: web/app/components/workflow/nodes/tool/components/tool-form/__tests__/index.spec.tsx
// dify-spec: web/app/components/workflow/nodes/tool/components/tool-form/__tests__/item.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/data_common.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_form.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_model.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_schema_view.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/store/store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

JsonMap createSchema([JsonMap overrides = const {}]) => {
  'name': 'api_key',
  'variable': 'api_key',
  'label': {'en_US': 'API Key', 'zh_Hans': 'API Key'},
  'type': FormType.textInput,
  'required': true,
  'show_on': const <Object?>[],
  ...overrides,
};

Future<void> render(WidgetTester t, Widget child, {ValueChanged<String>? openUrl}) {
  useDifyTestTranslator();
  return t.pumpWidget(
    MaterialApp(
      home: Material(
        child: WorkflowStoreScope(
          store: WorkflowStore(),
          child: DataPanelHost(
            openUrl: openUrl,
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 400, child: child),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> settle(WidgetTester t) async {
  for (var i = 0; i < 4; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('tool/tool-form', () {
    testWidgets('should render every schema item and forward tool-specific props', (t) async {
      void onChange(JsonMap v, [int? base]) {}
      void onManage() {}
      final value = {
        'api_key': {'type': 'constant', 'value': 'secret'},
      };
      const env = ToolFormEnv(extraParams: {'mode': 'panel'});
      await render(
        t,
        ToolForm(
          readOnly: true,
          schema: [
            createSchema(),
            createSchema({
              'name': 'region',
              'variable': 'region',
              'label': {'en_US': 'Region', 'zh_Hans': 'Region'},
            }),
          ],
          value: value,
          onChange: onChange,
          env: env,
          showManageInputField: true,
          onManageInputField: onManage,
        ),
      );
      final items = t.widgetList<ToolFormItem>(find.byType(ToolFormItem)).toList();
      expect(items, hasLength(2));
      expect(find.text('API Key'), findsOneWidget);
      expect(find.text('Region'), findsOneWidget);
      final first = items.first;
      expect(first.readOnly, isTrue);
      expect(first.schema['variable'], 'api_key');
      expect(first.value, value);
      expect(first.onChange, onChange);
      expect(first.showManageInputField, isTrue);
      expect(first.onManageInputField, onManage);
      expect(first.env.extraParams, {'mode': 'panel'});
    });

    testWidgets('should render an empty container when schema is empty', (t) async {
      await render(t, ToolForm(readOnly: false, schema: const [], value: const {}, onChange: (_, [_]) {}));
      expect(find.byType(ToolForm), findsOneWidget);
      expect(find.byType(ToolFormItem), findsNothing);
    });
  });

  group('tool/tool-form/item', () {
    testWidgets('should render URLs in descriptions as external links', (t) async {
      final opened = <String>[];
      await render(
        t,
        ToolFormItem(
          readOnly: false,
          schema: createSchema({
            'tooltip': {
              'en_US': 'Visit https://docs.dify.ai/tools for docs',
              'zh_Hans': 'Visit https://docs.dify.ai/tools for docs',
            },
          }),
          value: const {},
          onChange: (_, [_]) {},
        ),
        openUrl: opened.add,
      );
      expect(find.text('Visit https://docs.dify.ai/tools for docs', findRichText: true), findsOneWidget);
      await t.tapOnText(find.textRange.ofSubstring('https://docs.dify.ai/tools'));
      expect(opened, ['https://docs.dify.ai/tools']);
    });

    testWidgets('should show tooltip for non-description fields and open the schema modal', (t) async {
      await render(
        t,
        ToolFormItem(
          readOnly: false,
          schema: createSchema({
            'name': 'tool_config',
            'variable': 'tool_config',
            'label': {'en_US': 'Tool Config', 'zh_Hans': 'Tool Config'},
            'type': FormType.object,
            'tooltip': {'en_US': 'Select from tools', 'zh_Hans': 'Select from tools'},
            'input_schema': {
              'type': 'object',
              'properties': {
                'city': {'type': 'string'},
              },
              'additionalProperties': false,
            },
          }),
          value: const {},
          onChange: (_, [_]) {},
        ),
      );
      final tip = find.byWidgetPredicate((w) => w is Infotip && w.label == 'Select from tools');
      expect(tip, findsOneWidget);
      await t.tap(tip);
      await settle(t);
      expect(find.text('Select from tools'), findsOneWidget);

      await t.tap(find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'JSON Schema'));
      await settle(t);
      expect(find.byType(ToolSchemaModal), findsOneWidget);
      expect(find.descendant(of: find.byType(ToolSchemaModal), matching: find.text('tool_config')), findsOneWidget);
      expect(find.descendant(of: find.byType(ToolSchemaModal), matching: find.text('city')), findsOneWidget);
      await t.tap(find.byWidgetPredicate((w) => w is DifyPressable && w.semanticLabel == 'common.operation.close'));
      await settle(t);
      expect(find.byType(ToolSchemaModal), findsNothing);
    });
  });
}
