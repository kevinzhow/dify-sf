// dify-spec: web/app/components/workflow/block-selector/__tests__/featured-triggers.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/start_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

ToolProvider _provider({
  String id = 'provider-1',
  String name = 'provider-one',
  String label = 'Provider One',
  String pluginId = 'plugin-1',
}) => ToolProvider.fromJson({
  'id': id,
  'name': name,
  'author': 'Provider Author',
  'label': {'en_US': label},
  'type': 'trigger',
  'plugin_id': pluginId,
  'plugin_unique_identifier': '$pluginId@1.0.0',
  'events': [
    {
      'name': 'created',
      'label': {'en_US': 'Created'},
      'description': {'en_US': 'Created event'},
    },
  ],
});

const _data = BlockSelectorData(marketplaceUrlPrefix: 'https://marketplace.test', canInstallPlugin: true);

Widget _featured(List<MarketplacePlugin> plugins, Map<String, ToolProvider> map, [SelectRecorder? rec]) => SizedBox(
  width: 400,
  child: FeaturedTriggers(plugins: plugins, providerMap: map, onSelect: (rec ?? SelectRecorder()).call),
);

void main() {
  setUpBlockSelectorTests();

  group('FeaturedTriggers', () {
    group('Visibility Controls', () {
      testWidgets('should persist collapse state in localStorage', (t) async {
        final semantics = t.ensureSemantics();
        await pumpSelector(t, _featured(const [], const {}), data: _data);
        final trigger = find.bySemanticsLabel('workflow.tabs.featuredTools');
        expect(t.getSemantics(trigger).getSemanticsData().flagsCollection.isExpanded.toString(), contains('isTrue'));

        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.sendKeyEvent(LogicalKeyboardKey.space);
        await t.pump();
        expect(t.getSemantics(trigger).getSemanticsData().flagsCollection.isExpanded.toString(), contains('isFalse'));
        expect(find.text('workflow.tabs.noFeaturedTriggers'), findsNothing);
        await t.runAsync(() async {
          final prefs = await SharedPreferences.getInstance();
          expect(prefs.getString('workflow_triggers_featured_collapsed'), 'true');
        });
        semantics.dispose();
      });

      testWidgets('should reveal installed providers in batches and then return to the initial list', (t) async {
        final providers = [
          for (var i = 0; i < 11; i++)
            _provider(id: 'provider-$i', name: 'provider-$i', label: 'Provider $i', pluginId: 'plugin-$i'),
        ];
        await pumpSelector(
          t,
          _featured(
            [
              for (final p in providers)
                plugin(pluginId: p.pluginId!, latestPackageIdentifier: p.pluginUniqueIdentifier!),
            ],
            {for (final p in providers) p.pluginId!: p},
          ),
          data: _data,
        );
        expect(find.text('Provider 4'), findsOneWidget);
        expect(find.text('Provider 5'), findsNothing);

        await tapText(t, 'workflow.tabs.showMoreFeatured');
        expect(find.text('Provider 9'), findsOneWidget);
        expect(find.text('Provider 10'), findsNothing);

        await tapText(t, 'workflow.tabs.showMoreFeatured');
        expect(find.text('Provider 10'), findsOneWidget);
        expect(find.text('workflow.tabs.showLessFeatured'), findsOneWidget);

        await tapText(t, 'workflow.tabs.showLessFeatured');
        expect(find.text('Provider 5'), findsNothing);
        expect(find.text('workflow.tabs.showMoreFeatured'), findsOneWidget);
      });
    });

    group('Rendering and Selection', () {
      testWidgets('should render the empty state link when there are no featured plugins', (t) async {
        await pumpSelector(t, _featured(const [], const {}), data: _data);
        expect(linkUrlOf(t, 'workflow.tabs.noFeaturedTriggers'), Uri.parse('https://marketplace.test/plugins/trigger'));
      });

      testWidgets('should select an installed trigger event from the featured list', (t) async {
        final rec = SelectRecorder();
        final provider = _provider();
        await pumpSelector(
          t,
          _featured([plugin()], {'plugin-1': provider, 'plugin-1@1.0.0': provider}, rec),
          data: _data,
        );
        await tapText(t, 'Provider One');
        await tapText(t, 'Created');
        expect(rec.calls.single.$1, 'trigger-plugin');
        expect(rec.calls.single.$2, containsPair('provider_id', 'provider-one'));
        expect(rec.calls.single.$2, containsPair('event_name', 'created'));
        expect(rec.calls.single.$2, containsPair('event_label', 'Created'));
      });

      testWidgets('should keep the marketplace link and row actions keyboard reachable', (t) async {
        await pumpSelector(t, _featured([plugin(name: 'trigger-plugin')], const {}), data: _data);
        expect(linkUrlOf(t, 'Plugin One'), Uri.parse('https://marketplace.test/plugins/org/trigger-plugin'));
        final link = find.ancestor(
          of: find.text('Plugin One'),
          matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.link == true),
        );
        expect(find.descendant(of: link, matching: find.text('plugin.installAction')), findsNothing);

        await t.sendKeyEvent(LogicalKeyboardKey.tab); // Featured
        await t.sendKeyEvent(LogicalKeyboardKey.tab); // the plugin's page
        await t.pump();
        expect(hasFocusOn(t, find.text('Plugin One')), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(hasFocusOn(t, find.text('plugin.installAction')), isTrue);
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(
          hasFocusOn(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'common.operation.more')),
          isTrue,
        );
      });
    });
  });
}
