// dify-spec: web/app/components/workflow/block-selector/__tests__/tabs.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _tabs = [
  BlockSelectorTabConfig(BlockSelectorTab.start, 'Start'),
  BlockSelectorTabConfig(BlockSelectorTab.blocks, 'Blocks', disabled: true),
  BlockSelectorTabConfig(BlockSelectorTab.tools, 'Tools'),
];

Widget _panels({
  List<BlockSelectorTabConfig> tabs = _tabs,
  BlockSelectorTab defaultTab = BlockSelectorTab.start,
  BlockSelectorTab? standalonePanel,
  List<ToolProvider> dataSources = const [],
}) => SizedBox(
  width: 400,
  child: BlockSelectorPanels(
    tabs: tabs,
    defaultTab: defaultTab,
    standalonePanel: standalonePanel,
    onSelect: (_, [_]) {},
    dataSources: dataSources,
  ),
);

void main() {
  setUpBlockSelectorTests();

  group('Tabs', () {
    testWidgets('should render start content and disabled tab tooltip text', (t) async {
      await pumpSelector(t, _panels());
      expect(searchField('workflow.tabs.searchTrigger'), findsOneWidget);
      await hover(t, find.text('Blocks'));
      expect(find.text('workflow.tabs.startDisabledTip'), findsOneWidget);
    });

    testWidgets('should expose tab semantics and use manual keyboard activation', (t) async {
      await pumpSelector(t, _panels());
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'workflow.common.addBlock'),
        findsOneWidget,
      );
      expect(tabSelected(t, 'Start'), isTrue);
      expect(tabDisabled(t, 'Blocks'), isTrue);
      expect(
        find.byWidgetPredicate(
          (w) => w is Semantics && w.properties.role == SemanticsRole.tabPanel && w.properties.label == 'Start',
        ),
        findsOneWidget,
      );

      await tapText(t, 'Start');
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(hasFocusOn(t, find.text('Blocks')), isTrue);
      expect(tabSelected(t, 'Start'), isTrue);

      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(hasFocusOn(t, find.text('Tools')), isTrue);
      expect(tabSelected(t, 'Start'), isTrue);
    });

    testWidgets('should ignore clicks on disabled and already active tabs', (t) async {
      await pumpSelector(t, _panels());
      await tapText(t, 'Start');
      await tapText(t, 'Blocks');
      expect(tabSelected(t, 'Start'), isTrue);
    });

    testWidgets('should fall back to an available tab when the active tab is removed', (t) async {
      var tabs = _tabs;
      late StateSetter set;
      await pumpSelector(
        t,
        StatefulBuilder(
          builder: (context, setState) {
            set = setState;
            return _panels(tabs: tabs);
          },
        ),
      );
      await tapText(t, 'Tools');
      expect(tabSelected(t, 'Tools'), isTrue);

      set(
        () => tabs = [
          for (final x in _tabs)
            if (x.tab != BlockSelectorTab.tools) x,
        ],
      );
      await settle(t);
      expect(tabSelected(t, 'Start'), isTrue);
    });

    testWidgets('should render sources content when the sources tab is active and data sources are provided', (
      t,
    ) async {
      await pumpSelector(
        t,
        _panels(
          defaultTab: BlockSelectorTab.sources,
          tabs: [..._tabs, const BlockSelectorTabConfig(BlockSelectorTab.sources, 'Sources')],
          dataSources: [toolProvider(id: 'dataset', name: 'dataset', type: 'local_file')],
        ),
      );
      expect(searchField('workflow.tabs.searchDataSource'), findsOneWidget);
      expect(rowText('Provider One'), findsOneWidget);
    });

    testWidgets('keeps search state independent for each tab during the popup session', (t) async {
      await pumpSelector(
        t,
        _panels(
          defaultTab: BlockSelectorTab.blocks,
          tabs: const [
            BlockSelectorTabConfig(BlockSelectorTab.blocks, 'Blocks'),
            BlockSelectorTabConfig(BlockSelectorTab.tools, 'Tools'),
          ],
        ),
      );
      Finder input(String label) => find.descendant(of: searchField(label), matching: find.byType(EditableText));
      await t.enterText(input('workflow.tabs.searchBlock'), 'llm');
      await t.pump();
      await tapText(t, 'Tools');
      expect(searchValue(t, 'plugin.searchTools'), '');
      await t.enterText(input('plugin.searchTools'), 'slack');
      await t.pump();
      await tapText(t, 'Blocks');
      expect(searchValue(t, 'workflow.tabs.searchBlock'), 'llm');
      await tapText(t, 'Tools');
      expect(searchValue(t, 'plugin.searchTools'), 'slack');
    });

    testWidgets('should force start content to render and invalidate built-in tools after featured installs', (
      t,
    ) async {
      final installs = <String>[];
      await pumpSelector(
        t,
        _panels(defaultTab: BlockSelectorTab.tools),
        data: BlockSelectorData(
          enableMarketplace: true,
          canInstallPlugin: true,
          buildInTools: [toolProvider(pluginId: 'other')],
          featuredTools: [plugin(pluginId: 'featured', name: 'featured', label: 'Featured Tool')],
          onInstallPlugin: (p) async {
            installs.add(p.pluginId);
            return true;
          },
        ),
      );
      expect(rowText('Provider One'), findsOneWidget);
      await hover(t, rowText('Featured Tool'));
      await tapText(t, 'plugin.installAction');
      expect(installs, ['featured']);
    });

    testWidgets('should compose start content directly without tab semantics in standalone mode', (t) async {
      await pumpSelector(t, _panels(standalonePanel: BlockSelectorTab.start));
      expect(searchField('workflow.tabs.searchTrigger'), findsOneWidget);
      expect(tabNamed('Start'), findsNothing);
    });
  });
}
