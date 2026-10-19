// dify-spec: web/app/components/workflow/nodes/data-source/__tests__/panel.spec.tsx
//
// The panel over a document node with the host's data source list (Dify's mocked store); the real tool form and tag
// input instead of their mocks.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/data_source/data_source_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_plugin/plugin_form.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../trigger_plugin/panel_harness.dart';

import 'package:dify_sf_app/src/design/widgets/widgets.dart';

Map<String, Object?> createData([Map<String, Object?> overrides = const {}]) => {
  'title': 'Datasource',
  'desc': '',
  'plugin_id': 'plugin-1',
  'provider_type': 'online_document',
  'provider_name': 'provider',
  'datasource_name': 'source-a',
  'datasource_label': 'Source A',
  'datasource_parameters': <String, Object?>{},
  'datasource_configurations': <String, Object?>{},
  'fileExtensions': ['pdf'],
  ...overrides,
};

final dataSourceList = <Map<String, Object?>>[
  {
    'plugin_id': 'plugin-1',
    'is_authorized': true,
    'tools': [
      {
        'name': 'source-a',
        'parameters': [
          {
            'name': 'dataset',
            'type': 'string',
            'label': {'en_US': 'Dataset'},
          },
        ],
        'output_schema': {
          'properties': {
            'metadata': {'type': 'object'},
          },
        },
      },
    ],
  },
];

void main() {
  setUp(useDifyTestTranslator);

  group('data-source/panel', () {
    testWidgets('renders the authorized tool form path and forwards parameter changes', (t) async {
      final h = await Harness.start(t, [difyNode('data-source-node', 'datasource', createData())]);
      var inputFieldPanels = 0;
      await pumpBody(
        t,
        h,
        'data-source-node',
        dataSourcePanelBody,
        wrap: (child) => DataSourceHost(
          dataSourceList: dataSourceList,
          pipelineId: 'pipeline-1',
          onShowInputFieldPanel: () => inputFieldPanels++,
          child: child,
        ),
      );

      final form = t.widget<PluginForm>(find.byType(PluginForm));
      expect(form.showManageInputField, isTrue);
      expect(form.value, isEmpty);
      form.onManageInputField!();
      expect(inputFieldPanels, 1);

      await t.enterText(
        find.descendant(of: find.byType(DifyPromptEditor), matching: find.byType(EditableText)),
        'docs',
      );
      await Harness.settle(t);
      expect(plainOf(h['data-source-node']!.config['datasource_parameters']), {
        'dataset': {'type': 'mixed', 'value': 'docs'},
      });
      await t.tap(find.text('workflow.nodes.common.outputVars'.toUpperCase()));
      await Harness.settle(t);
      expect(find.text('metadata'), findsOneWidget);
      await h.dispose(t);
    });

    testWidgets('renders the local-file path and updates supported file extensions', (t) async {
      final h = await Harness.start(t, [
        difyNode('data-source-node', 'datasource', createData({'provider_type': 'local_file'})),
      ]);
      await pumpBody(
        t,
        h,
        'data-source-node',
        dataSourcePanelBody,
        wrap: (child) => DataSourceHost(dataSourceList: dataSourceList, child: child),
      );

      final field = find.descendant(of: find.byType(DifyTagInput), matching: find.byType(EditableText));
      expect(
        find.descendant(
          of: find.byType(DifyTagInput),
          matching: find.text('workflow.nodes.dataSource.supportedFileFormatsPlaceholder'),
        ),
        findsOneWidget,
      );
      await t.enterText(field, 'txt');
      await t.testTextInput.receiveAction(TextInputAction.done);
      await Harness.settle(t);

      expect(plainOf(h['data-source-node']!.config['fileExtensions']), ['pdf', 'txt']);
      expect(find.byType(PluginForm), findsNothing);
      await t.tap(find.text('workflow.nodes.common.outputVars'.toUpperCase()));
      await Harness.settle(t);
      final vars = {for (final v in t.widgetList<VarItem>(find.byType(VarItem))) v.name: v.type};
      expect(vars['datasource_type'], 'string');
      expect(vars['file'], 'file');
      await h.dispose(t);
    });
  });
}
