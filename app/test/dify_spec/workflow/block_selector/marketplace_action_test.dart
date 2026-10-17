// dify-spec: web/app/components/workflow/block-selector/marketplace-plugin/__tests__/action.spec.tsx
import 'dart:async';

import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

final _plugin = MarketplacePlugin(pluginId: 'p', org: 'langgenius', name: 'test-plugin', latestVersion: '1.0.0');

void main() {
  setUpBlockSelectorTests();

  group('MarketplaceOperationDropdown', () {
    testWidgets('should render download and view details actions when opened', (t) async {
      await pumpSelector(t, MarketplacePluginAction(plugin: _plugin, open: true));
      expect(find.text('common.operation.download'), findsOneWidget);
      expect(find.text('common.operation.viewDetails'), findsOneWidget);
    });

    testWidgets('should request a download when download is clicked', (t) async {
      final changes = <bool>[];
      final downloads = <MarketplacePlugin>[];
      await pumpSelector(
        t,
        MarketplacePluginAction(plugin: _plugin, open: true, onOpenChange: changes.add),
        data: BlockSelectorData(onDownloadPlugin: (p) async => downloads.add(p)),
      );
      await tapText(t, 'common.operation.download');
      expect(changes, contains(false));
      expect(downloads.single.org, 'langgenius');
      expect(downloads.single.name, 'test-plugin');
      expect(downloads.single.latestVersion, '1.0.0');
    });

    testWidgets('should skip duplicate downloads while pending', (t) async {
      var downloads = 0;
      final never = Completer<void>();
      await pumpSelector(
        t,
        MarketplacePluginAction(plugin: _plugin, open: true),
        data: BlockSelectorData(
          onDownloadPlugin: (_) {
            downloads++;
            return never.future;
          },
        ),
      );
      await tapText(t, 'common.operation.download');
      expect(downloads, 1);
      await tapText(t, 'common.operation.download');
      expect(downloads, 1);
    });

    testWidgets('should link to the marketplace detail page', (t) async {
      final opened = <String>[];
      await pumpSelector(
        t,
        MarketplacePluginAction(plugin: _plugin, open: true),
        data: BlockSelectorData(marketplaceUrlPrefix: 'https://marketplace.example', openUrl: opened.add),
      );
      expect(
        linkUrlOf(t, 'common.operation.viewDetails'),
        Uri.parse('https://marketplace.example/plugins/langgenius/test-plugin'),
      );
      await tapText(t, 'common.operation.viewDetails');
      expect(opened, ['https://marketplace.example/plugins/langgenius/test-plugin']);
    });
  });
}
