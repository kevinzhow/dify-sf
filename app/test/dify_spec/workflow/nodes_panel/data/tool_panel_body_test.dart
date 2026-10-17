// The tool panel body on a document: tools from the store, defaults filled once, edits written per field.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/data/tool/tool_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/panel_fields/panel_fields.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

JsonMap p(String name, String type, {String form = 'form', Object? def, List<Object?>? options}) => {
  'name': name,
  'label': {'en_US': 'L-$name'},
  'human_description': {'en_US': 'about $name'},
  'type': type,
  'form': form,
  'required': true,
  'default': def,
  'options': ?options,
};

final collection = {
  'id': 'google',
  'name': 'google',
  'plugin_id': 'langgenius/google',
  'allow_delete': true,
  'is_team_authorization': true,
  'tools': [
    {
      'name': 'search',
      'parameters': [
        p('query', 'string', form: 'llm', def: 'hello'),
        p('count', 'number', def: 3),
        p(
          'region',
          'select',
          def: 'us',
          options: [
            {
              'value': 'us',
              'label': {'en_US': 'United States'},
            },
            {
              'value': 'cn',
              'label': {'en_US': 'China'},
            },
          ],
        ),
        p('safe', 'boolean', def: true),
      ],
      'output_schema': {
        'properties': {
          'title': {'type': 'string', 'description': 'Page title'},
        },
      },
    },
  ],
};

JsonMap toolData([JsonMap extra = const {}]) => {
  'type': 'tool',
  'title': 'Search',
  'provider_id': 'google',
  'provider_type': 'builtin',
  'tool_name': 'search',
  'tool_parameters': <String, Object?>{},
  'tool_configurations': <String, Object?>{},
  ...extra,
};

void main() {
  Future<Harness> start(WidgetTester t, JsonMap data, {JsonMap? coll}) async {
    final h = await Harness.start(t, [difyNode('tool', data)]);
    h.store.buildInTools.value = [coll ?? collection];
    await renderBody(t, h, 'tool', toolPanelBody);
    return h;
  }

  testWidgets('fills empty parameters and settings with the schema defaults once', (t) async {
    final h = await start(t, toolData());
    final data = dataOf(h, 'tool');
    expect(data['tool_parameters'], {
      'query': {'type': 'mixed', 'value': 'hello'},
    });
    expect(data['tool_configurations'], {
      'count': {'type': 'constant', 'value': 3},
      'region': {'type': 'constant', 'value': 'us'},
      'safe': {'type': 'constant', 'value': true},
    });
    expect(find.text('WORKFLOW.NODES.TOOL.INPUTVARS'), findsOneWidget);
    expect(find.text('L-query'), findsOneWidget);
    expect(find.text('about query'), findsOneWidget);
    await h.dispose(t);
  });

  testWidgets('writes typed text, selects, booleans and the variable switch per field', (t) async {
    final h = await start(
      t,
      toolData({
        'tool_parameters': {
          'query': {'type': 'mixed', 'value': 'hello'},
        },
        'tool_configurations': {
          'count': {'type': 'constant', 'value': 3},
          'region': {'type': 'constant', 'value': 'us'},
          'safe': {'type': 'constant', 'value': true},
        },
      }),
    );
    await t.enterText(find.byType(TextField).first, 'weather');
    await blur(t);
    expect(dataOf(h, 'tool')['tool_parameters'], {
      'query': {'type': 'mixed', 'value': 'weather'},
    });

    await t.tap(find.text('United States'));
    await Harness.settle(t);
    await t.tap(find.text('China').last);
    await Harness.settle(t);
    expect((dataOf(h, 'tool')['tool_configurations']! as Map)['region'], {'type': 'constant', 'value': 'cn'});

    await t.tap(find.text('False'));
    await Harness.settle(t);
    expect((dataOf(h, 'tool')['tool_configurations']! as Map)['safe'], {'type': 'constant', 'value': false});

    // The number's variable / constant switch: "Use variable" clears the value.
    await t.tap(find.bySemanticsLabel('workflow.nodes.common.typeSwitch.variable').first);
    await Harness.settle(t);
    expect((dataOf(h, 'tool')['tool_configurations']! as Map)['count'], {'type': 'variable', 'value': ''});
    expect(find.byType(VarReferencePicker), findsOneWidget);
    await h.dispose(t);
  });

  testWidgets('hides the forms while the provider needs authorization', (t) async {
    final h = await start(t, toolData(), coll: {...collection, 'is_team_authorization': false});
    expect(find.text('WORKFLOW.NODES.TOOL.INPUTVARS'), findsNothing);
    expect(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'), findsOneWidget);
    await t.tap(find.text('WORKFLOW.NODES.COMMON.OUTPUTVARS'));
    await Harness.settle(t);
    expect(find.text('title'), findsOneWidget);
    expect(find.text('string'), findsWidgets);
    await h.dispose(t);
  });
}
