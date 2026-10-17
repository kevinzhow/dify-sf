// dify-spec: web/app/components/workflow/block-selector/marketplace-plugin/__tests__/item-list.spec.tsx
import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

const _url = 'https://marketplace.test';

Widget _list(List<MarketplacePlugin> list, String search, List<String> tags, {bool hide = false, double spacer = 0}) =>
    SizedBox(
      width: 400,
      height: 300,
      child: MarketplaceScrollArea(
        children: [
          SizedBox(height: spacer),
          MarketplacePluginList(list: list, searchText: search, tags: tags, category: 'tool', hideFindMoreFooter: hide),
        ],
      ),
    );

void main() {
  setUpBlockSelectorTests();

  group('Marketplace plugin selector components', () {
    testWidgets('should render marketplace plugin metadata and open install modal', (t) async {
      final installs = <MarketplacePlugin>[];
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: MarketplacePluginItem(
            plugin: plugin(
              org: 'LangGenius',
              latestPackageIdentifier: 'plugin-1@2.0.0',
              installCount: 1200,
              label: 'Search Plugin',
              brief: 'Searches documents',
            ),
          ),
        ),
        data: BlockSelectorData(
          canInstallPlugin: true,
          onInstallPlugin: (p) async {
            installs.add(p);
            return true;
          },
        ),
      );
      expect(find.text('Search Plugin'), findsOneWidget);
      expect(find.text('Searches documents'), findsOneWidget);
      expect(find.text('LangGenius'), findsOneWidget);

      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(hasFocusOn(t, find.text('plugin.installAction')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pump();
      expect(
        hasFocusOn(t, find.byWidgetPredicate((w) => w is DifyIconButton && w.label == 'common.operation.more')),
        isTrue,
      );

      await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(installs.single.latestPackageIdentifier, 'plugin-1@2.0.0');
    });

    testWidgets('should expose separate keyboard actions for scrolling to and searching marketplace results', (
      t,
    ) async {
      await pumpSelector(
        t,
        _list([plugin()], 'filtered', const [], spacer: 600),
        data: const BlockSelectorData(marketplaceUrlPrefix: _url),
      );
      await t.pump();
      final bar = find.byWidgetPredicate(
        (w) => w is MarketplaceStickyBar && w.position == StickyScrollPosition.belowTheWrap,
      );
      expect(bar, findsOneWidget);
      final scroll = t.state<ScrollableState>(find.byType(Scrollable).first);
      expect(scroll.position.pixels, 0);

      await t.tap(find.descendant(of: bar, matching: find.text('plugin.fromMarketplace')));
      await settle(t, 500);
      expect(scroll.position.pixels, greaterThan(0));
      expect(linkUrlOf(t, 'plugin.searchInMarketplace').toString(), contains('q=filtered'));
    });

    testWidgets('should expose marketplace navigation as links when the results are already visible', (t) async {
      await pumpSelector(
        t,
        _list([plugin()], 'filtered', const ['rag']),
        data: const BlockSelectorData(marketplaceUrlPrefix: _url),
      );
      await t.pump();
      final url = linkUrlOf(t, 'plugin.fromMarketplace').toString();
      expect(url, contains('q=filtered'));
      expect(url, contains('tags=rag'));
      expect(
        find.byWidgetPredicate((w) => w is MarketplaceStickyBar && w.position == StickyScrollPosition.belowTheWrap),
        findsNothing,
      );
    });

    testWidgets('should render find-more footer for empty filters and marketplace results for filtered searches', (
      t,
    ) async {
      const data = BlockSelectorData(marketplaceUrlPrefix: _url);
      await pumpSelector(t, _list(const [], '', const []), data: data);
      expect(find.byType(MarketplaceFooter), findsOneWidget);
      expect(linkUrlOf(t, 'plugin.findMoreInMarketplace'), Uri.parse('$_url/plugins/tool'));

      await pumpSelector(t, _list([plugin(label: 'Filtered Plugin')], 'filtered', const ['rag']), data: data);
      await t.pump();
      expect(find.text('plugin.fromMarketplace'), findsOneWidget);
      expect(find.text('Filtered Plugin'), findsOneWidget);
      expect(find.text('plugin.searchInMarketplace'), findsOneWidget);
      final url = linkUrlOf(t, 'plugin.searchInMarketplace').toString();
      expect(url, contains('q=filtered'));
      expect(url, contains('/plugins/tool'));
    });

    testWidgets('should hide the marketplace footer when requested and no filters are active', (t) async {
      await pumpSelector(
        t,
        MarketplacePluginList(list: const [], searchText: '', tags: const [], hideFindMoreFooter: true),
      );
      expect(find.byType(MarketplaceFooter), findsNothing);
      expect(find.text('plugin.findMoreInMarketplace'), findsNothing);
    });
  });
}
