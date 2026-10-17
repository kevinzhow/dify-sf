// The entry group's panel bodies (trigger-schedule, trigger-webhook, trigger-plugin, start-placeholder, datasource,
// knowledge-index) as registered: each renders in the node panel shell from Dify's default data without errors, and
// setInputs writes Dify's next data as small ops.
import 'package:collab_client/collab_client.dart';
import 'package:dify_sf_app/src/i18n/dify_i18n.dart';
import 'package:dify_sf_app/src/workflow/dify_json.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/entry_bodies.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/knowledge_base/knowledge_base_logic.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/trigger_webhook/webhook_default.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:dify_sf_app/src/workflow_editor/node_panel/panel_edit.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/workflow/node_panel/harness.dart';
import 'dify_spec/workflow/nodes_panel/entry/trigger_plugin/panel_harness.dart' show difyNode;

/// Each node type's `defaultValue` (default.ts).
final _defaults = <String, Map<String, Object?>>{
  'trigger-schedule': triggerScheduleDefaultValue(),
  'trigger-webhook': triggerWebhookDefaultValue(),
  'trigger-plugin': triggerPluginDefaultValue,
  'start-placeholder': startPlaceholderDefaultValue,
  'datasource': {...dataSourceDefaultValue, 'provider_type': 'local_file', 'fileExtensions': <Object?>[]},
  'knowledge-index': knowledgeBaseDefaultValue,
};

void main() {
  // Dify's English, as on the device.
  setUpAll(() async => DifyI18n.current = await DifyI18n.load('en-US'));

  test('registers every entry node type with a panel', () {
    expect(entryPanelBodies.keys.toSet(), _defaults.keys.toSet());
    expect(entryCheckValid.keys.toSet(), {..._defaults.keys, 'datasource-empty'});
  });

  for (final MapEntry(key: type, value: data) in _defaults.entries) {
    testWidgets('renders the $type panel from its default data', (t) async {
      final h = await Harness.start(t, [difyNode('n', type, data)]);
      await t.pumpWidget(
        panelApp(
          h,
          WorkflowNodePanel(node: h['n']!, actions: panelActions(h), bodies: const NodePanelBodies(entryPanelBodies)),
        ),
      );
      await settle(t);
      expect(t.takeException(), isNull);
      await h.dispose(t);
    });
  }

  group('setInputs', () {
    Future<(Harness, NodePanelProps)> start(WidgetTester t, Map<String, Value> config) async {
      final h = await Harness.start(t, [
        node(
          'src',
          config: {
            'outputs': VItems([
              Item('o', Value.of({'name': 'result', 'type': 'string'})),
            ]),
          },
        ),
        node('n', type: 'trigger-webhook', config: config),
      ]);
      return (h, NodePanelProps(node: h['n']!, controller: h.controller, actions: panelActions(h)));
    }

    Map<String, Object?> data(Harness h) => difyDataOf(h['n']!);

    testWidgets('writes changed keys only, clears absent ones and keeps references', (t) async {
      final (h, p) = await start(t, {
        'a': const VInt(1),
        'b': const VString('x'),
        'sel': const VRef(OutputRef('src', 'result')),
      });
      setInputs(p, {
        ...p.data,
        'a': 2,
        'b': null,
        'new': ['src', 'result'],
      });
      await t.pump();
      expect(data(h)['a'], 2);
      expect(data(h)['b'], isNull);
      expect(h['n']!.config['sel'], const VRef(OutputRef('src', 'result')));
      expect(h['n']!.config['new'], const VRef(OutputRef('src', 'result')));
      await h.dispose(t);
    });

    testWidgets('edits keyed lists item by item, keeping the ids of the others', (t) async {
      final (h, p) = await start(t, {
        'rows': VItems([
          for (final id in ['r1', 'r2', 'r3']) Item(id, VString(id)),
        ]),
      });
      setInputs(p, {
        ...p.data,
        'rows': ['r1', 'r3', 'x', 'y'],
      });
      await t.pump();
      final items = (h['n']!.config['rows']! as VItems).items;
      expect([for (final i in items) plainOf(i.value)], ['r1', 'r3', 'x', 'y']);
      expect(items[0].id, 'r1');
      expect(items[1].id, 'r3');
      await h.dispose(t);
    });
  });
}
