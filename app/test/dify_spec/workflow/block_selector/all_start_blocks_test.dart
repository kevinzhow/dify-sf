// dify-spec: web/app/components/workflow/block-selector/__tests__/all-start-blocks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/start_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

ToolProvider _trigger({String label = 'Provider One'}) => ToolProvider.fromJson({
  'id': 'provider-1',
  'name': 'provider-one',
  'author': 'Provider Author',
  'icon': 'icon',
  'label': {'en_US': label, 'zh_Hans': label},
  'type': 'trigger',
  'plugin_id': 'plugin-1',
  'plugin_unique_identifier': 'plugin-1@1.0.0',
  'meta': {'version': '1.0.0'},
  'events': [
    {
      'name': 'created',
      'author': 'Provider Author',
      'label': {'en_US': 'Created'},
      'description': {'en_US': 'Created event'},
      'parameters': <Object?>[],
      'output_schema': <String, Object?>{},
    },
  ],
});

typedef _Search = List<MarketplaceQuery>;

BlockSelectorData _data({
  bool marketplace = false,
  List<ToolProvider>? triggers,
  List<BlockSelectorNode> nodes = const [],
  _Search? searches,
  List<MarketplacePlugin> results = const [],
}) => BlockSelectorData(
  enableMarketplace: marketplace,
  marketplaceUrlPrefix: 'https://marketplace.test',
  triggerPlugins: triggers ?? [_trigger()],
  nodes: nodes,
  searchMarketplace: (q) async {
    searches?.add(q);
    return results;
  },
);

Widget _blocks(
  SelectRecorder rec, {
  String search = '',
  List<String> tags = const [],
  List<String> types = const ['start', 'trigger-plugin'],
  bool allowUserInput = false,
  bool hasUserInputNode = false,
  bool hasTriggerNode = false,
  bool panel = false,
}) => SizedBox(
  width: 420,
  height: 700,
  child: Align(
    alignment: Alignment.topLeft,
    child: AllStartBlocks(
      searchText: search,
      tags: tags,
      onSelect: rec.call,
      availableBlocksTypes: types,
      allowUserInputSelection: allowUserInput,
      hasUserInputNode: hasUserInputNode,
      hasTriggerNode: hasTriggerNode,
      panelVariant: panel,
    ),
  ),
);

void main() {
  setUpBlockSelectorTests();

  group('AllStartBlocks', () {
    group('Content Rendering', () {
      testWidgets('should render start blocks and trigger plugin actions', (t) async {
        final rec = SelectRecorder();
        await pumpSelector(t, _blocks(rec, allowUserInput: true), data: _data());
        expect(find.text('workflow.blocks.start'), findsOneWidget);
        expect(find.text('workflow.tabs.allTriggers'), findsNothing);
        expect(find.text('WORKFLOW.BLOCKS.MOSTCOMMON'), findsOneWidget);
        expect(find.text('Provider One'), findsOneWidget);

        await tapText(t, 'workflow.blocks.start');
        expect(rec.calls.last, ('start', null));

        await tapText(t, 'Provider One');
        await tapText(t, 'Created');
        expect(rec.calls.last.$1, 'trigger-plugin');
        expect(rec.calls.last.$2, containsPair('provider_id', 'provider-one'));
        expect(rec.calls.last.$2, containsPair('event_name', 'created'));
      });

      testWidgets('should link to the trigger marketplace when marketplace is enabled', (t) async {
        await pumpSelector(
          t,
          _blocks(SelectRecorder(), types: const ['trigger-plugin']),
          data: _data(marketplace: true),
        );
        expect(find.text('plugin.findMoreInMarketplace'), findsOneWidget);
        expect(linkUrlOf(t, 'plugin.findMoreInMarketplace'), Uri.parse('https://marketplace.test/plugins/trigger'));
      });

      testWidgets('should expose the panel marketplace destination', (t) async {
        await pumpSelector(
          t,
          _blocks(SelectRecorder(), types: const ['trigger-plugin'], panel: true),
          data: _data(marketplace: true),
        );
        const label = 'workflow.nodes.startPlaceholder.browseMoreOnMarketplace';
        expect(find.text(label), findsOneWidget);
        expect(linkUrlOf(t, label), Uri.parse('https://marketplace.test/plugins/trigger'));
      });

      testWidgets('should render searched marketplace results after built-in and installed trigger options', (t) async {
        await pumpSelector(
          t,
          _blocks(SelectRecorder(), search: 'start', allowUserInput: true),
          data: _data(
            marketplace: true,
            triggers: [_trigger(label: 'Start Provider')],
            results: [plugin(name: 'start-marketplace', label: 'Start Marketplace')],
          ),
        );
        await settle(t, 700);
        expect(find.text('Start Marketplace'), findsOneWidget);
        double y(String s) => t.getTopLeft(find.text(s)).dy;
        expect(y('workflow.blocks.start'), lessThan(y('Start Provider')));
        expect(y('Start Provider'), lessThan(y('Start Marketplace')));
        expect(find.text('plugin.searchInMarketplace'), findsOneWidget);
      });

      testWidgets('should show the user input conflict state without allowing another start selection', (t) async {
        final semantics = t.ensureSemantics();
        final rec = SelectRecorder();
        await pumpSelector(
          t,
          _blocks(rec, hasUserInputNode: true),
          data: _data(marketplace: true, nodes: const [(id: 'start', type: 'start')]),
        );
        expect(find.text('workflow.nodes.startPlaceholder.userInputConflictTip'), findsOneWidget);
        expect(find.text('workflow.tabs.allTriggers'), findsNothing);
        expect(find.text('common.operation.added'), findsOneWidget);
        // The list is inert (no pointer, no focus); the marketplace footer isn't part of it.
        final inert = find.ancestor(of: find.text('workflow.blocks.start'), matching: find.byType(ExcludeFocus));
        expect(inert, findsOneWidget);
        expect(find.descendant(of: inert, matching: find.text('plugin.findMoreInMarketplace')), findsNothing);

        await t.tap(find.text('workflow.blocks.start'), warnIfMissed: false);
        await t.tap(find.text('Provider One'), warnIfMissed: false);
        await settle(t);
        expect(rec.calls, isEmpty);
        semantics.dispose();
      });

      testWidgets('should keep user input visible but disabled when another trigger already exists', (t) async {
        final semantics = t.ensureSemantics();
        final rec = SelectRecorder();
        await pumpSelector(
          t,
          _blocks(rec, types: const ['start', 'trigger-schedule'], hasTriggerNode: true),
          data: _data(),
        );
        expect(find.text('workflow.tabs.allTriggers'), findsNothing);
        expect(
          find.bySemanticsLabel('workflow.blocks.start. workflow.nodes.startPlaceholder.userInputConflictTip'),
          findsOneWidget,
        );
        await hover(t, find.text('workflow.blocks.start'));
        expect(find.text('workflow.nodes.startPlaceholder.userInputConflictTip'), findsOneWidget);

        await tapText(t, 'workflow.blocks.start');
        expect(rec.calls, isEmpty);
        await tapText(t, 'workflow.blocks.trigger-schedule');
        expect(rec.calls, [('trigger-schedule', null)]);
        semantics.dispose();
      });
    });

    group('Filtered Empty State', () {
      testWidgets('should show the no-results state immediately when marketplace search is unavailable', (t) async {
        final searches = <MarketplaceQuery>[];
        await pumpSelector(
          t,
          _blocks(SelectRecorder(), search: 'missing', types: const ['trigger-plugin']),
          data: _data(triggers: const [], searches: searches),
        );
        expect(find.text('workflow.nodes.startPlaceholder.noTriggersFound'), findsOneWidget);
        await settle(t, 700);
        expect(searches, isEmpty);
      });

      testWidgets('should query marketplace and show the no-results state when filters have no matches', (t) async {
        final searches = <MarketplaceQuery>[];
        await pumpSelector(
          t,
          _blocks(SelectRecorder(), search: 'missing', tags: const ['webhook'], types: const ['trigger-plugin']),
          data: _data(marketplace: true, triggers: const [], searches: searches),
        );
        await settle(t, 700);
        expect(searches.single.query, 'missing');
        expect(searches.single.tags, ['webhook']);
        expect(searches.single.category, 'trigger');
        expect(find.text('workflow.nodes.startPlaceholder.noTriggersFound'), findsOneWidget);
        expect(linkUrlOf(t, 'workflow.tabs.requestToCommunity'), Uri.parse(pluginRequestUrl));
        expect(linkUrlOf(t, 'plugin.findMoreInMarketplace'), Uri.parse('https://marketplace.test/plugins/trigger'));
      });

      testWidgets('should debounce marketplace requests across search and tag changes', (t) async {
        final searches = <MarketplaceQuery>[];
        final data = _data(marketplace: true, triggers: const [], searches: searches);
        Future<void> render(String search, List<String> tags) => pumpSelector(
          t,
          _blocks(SelectRecorder(), search: search, tags: tags, types: const ['trigger-plugin']),
          data: data,
        );
        await render('', const []);
        await render('w', const []);
        await render('web', const ['api']);
        await render('webhook', const ['automation']);
        expect(searches, isEmpty);
        expect(find.text('workflow.nodes.startPlaceholder.noTriggersFound'), findsNothing);

        await settle(t, 700);
        expect(searches, hasLength(1));
        expect(searches.single.query, 'webhook');
        expect(searches.single.tags, ['automation']);
        expect(searches.single.category, 'trigger');
      });
    });
  });
}
