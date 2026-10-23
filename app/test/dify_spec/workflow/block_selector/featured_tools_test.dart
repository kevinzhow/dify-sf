// dify-spec: web/app/components/workflow/block-selector/__tests__/featured-tools.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'harness.dart';

const _data = BlockSelectorData(marketplaceUrlPrefix: 'https://marketplace.test', canInstallPlugin: true);

Widget _featured(List<MarketplacePlugin> plugins, Map<String, ToolProvider> map) => SizedBox(
  width: 400,
  child: FeaturedTools(plugins: plugins, providerMap: map, onSelect: (_, [_]) {}),
);

void main() {
  setUpBlockSelectorTests();

  group('FeaturedTools', () {
    testWidgets('reveals featured tools in batches and then returns to the initial list', (t) async {
      final plugins = [
        for (var i = 1; i <= 11; i++)
          plugin(pluginId: 'plugin-$i', latestPackageIdentifier: 'plugin-$i@1.0.0', label: 'Plugin $i'),
      ];
      final providers = [
        for (var i = 1; i <= 11; i++) toolProvider(id: 'provider-$i', pluginId: 'plugin-$i', label: 'Provider $i'),
      ];
      await pumpSelector(t, _featured(plugins, {for (final p in providers) p.pluginId!: p}), data: _data);
      expect(find.text('Provider 1'), findsOneWidget);
      expect(find.text('Provider 6'), findsNothing);

      await tapText(t, 'workflow.tabs.showMoreFeatured');
      expect(find.text('Provider 10'), findsOneWidget);
      expect(find.text('Provider 11'), findsNothing);

      await tapText(t, 'workflow.tabs.showMoreFeatured');
      expect(find.text('Provider 11'), findsOneWidget);
      expect(find.text('workflow.tabs.showLessFeatured'), findsOneWidget);

      await tapText(t, 'workflow.tabs.showLessFeatured');
      expect(find.text('Provider 6'), findsNothing);
      expect(find.text('workflow.tabs.showMoreFeatured'), findsOneWidget);
    });

    testWidgets('restores the collapsed state and expands from the keyboard', (t) async {
      SharedPreferences.setMockInitialValues({'workflow_tools_featured_collapsed': 'true'});
      final semantics = t.ensureSemantics();
      await pumpSelector(t, _featured([plugin()], {'plugin-1': toolProvider()}), data: _data);
      final trigger = find.bySemanticsLabel('workflow.tabs.featuredTools');
      expect(t.getSemantics(trigger).getSemanticsData().flagsCollection.isExpanded.toString(), contains('isFalse'));
      expect(find.text('Provider One'), findsNothing);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text('workflow.tabs.featuredTools')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(t.getSemantics(trigger).getSemanticsData().flagsCollection.isExpanded.toString(), contains('isTrue'));
      expect(find.text('Provider One'), findsOneWidget);
      await t.runAsync(() async {
        expect((await SharedPreferences.getInstance()).getString('workflow_tools_featured_collapsed'), 'false');
      });
      semantics.dispose();
    });

    testWidgets('keeps the marketplace link and row actions keyboard reachable', (t) async {
      await pumpSelector(t, _featured([plugin(name: 'plugin-one')], const {}), data: _data);
      expect(linkUrlOf(t, 'Plugin One'), Uri.parse('https://marketplace.test/plugins/org/plugin-one'));
      final link = find.ancestor(
        of: find.text('Plugin One'),
        matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.link == true),
      );
      expect(find.descendant(of: link, matching: find.text('plugin.installAction')), findsNothing);

      await t.sendKeyEvent(LogicalKeyboardKey.tab); // Featured
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
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

    testWidgets('shows the marketplace empty state when no featured tools are available', (t) async {
      await pumpSelector(t, _featured(const [], const {}), data: _data);
      expect(find.text('workflow.tabs.noFeaturedPlugins'), findsOneWidget);
    });
  });
}
