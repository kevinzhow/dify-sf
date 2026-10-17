// dify-spec: web/app/components/workflow/block-selector/__tests__/tool-browser.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/selector_widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

Widget _browser({
  String search = '',
  List<String> tags = const [],
  List<ToolProvider> builtIn = const [],
  List<ToolProvider> custom = const [],
  List<ToolProvider> workflow = const [],
  List<ToolProvider> mcp = const [],
}) => SizedBox(
  width: 400,
  height: 600,
  child: Align(
    alignment: Alignment.topLeft,
    child: ToolBrowser(
      searchText: search,
      tags: tags,
      onSelect: (_, [_]) {},
      buildInTools: builtIn,
      customTools: custom,
      workflowTools: workflow,
      mcpTools: mcp,
    ),
  ),
);

BlockSelectorData _market(Future<List<MarketplacePlugin>> Function(MarketplaceQuery q) search) => BlockSelectorData(
  enableMarketplace: true,
  marketplaceUrlPrefix: 'https://marketplace.test',
  searchMarketplace: search,
);

void main() {
  setUpBlockSelectorTests();

  group('ToolBrowser', () {
    testWidgets('filters tools by the active tab', (t) async {
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(
          builtIn: [toolProvider(id: 'provider-built-in', label: 'Built In Provider')],
          custom: [toolProvider(id: 'provider-custom', type: CollectionType.custom, label: 'Custom Provider')],
        ),
      );
      expect(find.text('Built In Provider'), findsOneWidget);
      expect(find.text('Custom Provider'), findsOneWidget);

      await tapText(t, 'workflow.tabs.customTool');
      expect(find.text('Custom Provider'), findsOneWidget);
      expect(find.text('Built In Provider'), findsNothing);
    });

    testWidgets('shows the selected category empty state and keeps the marketplace footer available', (t) async {
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(
          builtIn: [toolProvider(id: 'provider-built-in', label: 'Built In Provider')],
        ),
        data: _market((_) async => const []),
      );
      for (var i = 0; i < 3; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab); // All, Tool Plugin, Swagger API
      }
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await settle(t);
      final custom = find.ancestor(
        of: find.text('workflow.tabs.customTool'),
        matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.toggled != null),
      );
      expect(t.widget<Semantics>(custom.first).properties.toggled, isTrue);
      expect(find.text('Built In Provider'), findsNothing);
      expect(find.text('tools.addToolModal.custom.title'), findsOneWidget);
      expect(linkUrlOf(t, 'tools.addToolModal.custom.tip'), Uri.parse('/integrations/tools/api'));

      await tapText(t, 'workflow.tabs.workflowTool');
      expect(find.text('tools.addToolModal.workflow.title'), findsOneWidget);
      expect(linkUrlOf(t, 'tools.addToolModal.workflow.tip'), Uri.parse('/integrations/tools/workflow'));

      final footer = find.byType(MarketplaceFooterLink);
      expect(footer, findsOneWidget);
      expect(find.text('plugin.findMoreInMarketplace'), findsOneWidget);
    });

    testWidgets('updates the tools list title by the active tab', (t) async {
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(
          builtIn: [toolProvider(id: 'provider-built-in', label: 'Built In Provider')],
          custom: [toolProvider(id: 'provider-custom', type: CollectionType.custom, label: 'Swagger Provider')],
          workflow: [toolProvider(id: 'provider-workflow', type: CollectionType.workflow, label: 'Workflow Provider')],
          mcp: [toolProvider(id: 'provider-mcp', type: CollectionType.mcp, label: 'MCP Provider')],
        ),
      );
      expect(find.text('tools.allTools'), findsOneWidget);
      await tapText(t, 'workflow.tabs.plugin');
      expect(find.text('tools.allToolPlugins'), findsOneWidget);
      await tapText(t, 'workflow.tabs.customTool');
      expect(find.text('tools.allSwaggerAPIAsTool'), findsOneWidget);
      await tapText(t, 'workflow.tabs.workflowTool');
      expect(find.text('tools.allWorkflowAsTool'), findsOneWidget);
      await tapText(t, 'MCP');
      expect(find.text('tools.allMCP'), findsOneWidget);
    });

    testWidgets('filters the rendered tools by the search text', (t) async {
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(
          search: 'report',
          builtIn: [
            toolProvider(id: 'provider-report', label: 'Report Toolkit'),
            toolProvider(id: 'provider-other', label: 'Other Toolkit'),
          ],
        ),
      );
      expect(find.text('Report Toolkit'), findsOneWidget);
      expect(find.text('Other Toolkit'), findsNothing);
    });

    testWidgets('shows the empty state and request action when local and marketplace tools do not match', (t) async {
      await pumpSelector(textScale: 0.45, t, _browser(search: 'missing'), data: _market((_) async => const []));
      await settle(t, 700);
      expect(find.text('workflow.tabs.noPluginsFound'), findsOneWidget);
      expect(linkUrlOf(t, 'workflow.tabs.requestToCommunity'), Uri.parse(pluginRequestUrl));
    });

    testWidgets('keeps matching local tools visible while marketplace results are loading', (t) async {
      final searches = <MarketplaceQuery>[];
      final pending = Completer<List<MarketplacePlugin>>();
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(
          search: 'local',
          builtIn: [toolProvider(id: 'provider-local', label: 'Local Toolkit')],
        ),
        data: _market((q) {
          searches.add(q);
          return pending.future;
        }),
      );
      await settle(t, 700);
      expect(searches.single.query, 'local');
      expect(searches.single.tags, isEmpty);
      expect(searches.single.category, PluginCategory.tool);
      expect(find.text('Local Toolkit'), findsOneWidget);
      expect(find.text('workflow.tabs.noPluginsFound'), findsNothing);
    });

    testWidgets('renders a marketplace result instead of the empty state', (t) async {
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(search: 'marketplace'),
        data: _market((_) async => [plugin(pluginId: 'marketplace-tool', label: 'Marketplace Tool')]),
      );
      await settle(t, 700);
      expect(find.text('Marketplace Tool'), findsOneWidget);
      expect(find.text('workflow.tabs.noPluginsFound'), findsNothing);
    });

    testWidgets('debounces marketplace requests across search and tag changes', (t) async {
      final searches = <MarketplaceQuery>[];
      final data = _market((q) async {
        searches.add(q);
        return const [];
      });
      await pumpSelector(textScale: 0.45, t, _browser(), data: data);
      await pumpSelector(textScale: 0.45, t, _browser(search: 'w'), data: data);
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(search: 'web', tags: const ['api']),
        data: data,
      );
      await pumpSelector(
        textScale: 0.45,
        t,
        _browser(search: 'webhook', tags: const ['automation']),
        data: data,
      );
      expect(searches, isEmpty);
      expect(find.text('workflow.tabs.noPluginsFound'), findsNothing);

      await settle(t, 700);
      expect(searches, hasLength(1));
      expect(searches.single.query, 'webhook');
      expect(searches.single.tags, ['automation']);
      expect(searches.single.category, PluginCategory.tool);
    });
  });
}
