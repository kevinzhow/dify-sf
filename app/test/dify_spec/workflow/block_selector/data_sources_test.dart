// dify-spec: web/app/components/workflow/block-selector/__tests__/data-sources.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

ToolProvider _source({
  String id = 'langgenius/file',
  String name = 'file',
  String label = 'File Source',
  List<Map<String, Object?>>? tools,
}) => ToolProvider.fromJson({
  'id': id,
  'name': name,
  'author': 'Dify',
  'icon': 'icon',
  'label': {'en_US': label},
  'type': 'local_file',
  'plugin_id': 'langgenius/file',
  'tools': tools ?? [toolJson('local-file', 'Local File', 'Load local files')],
});

Widget _sources(SelectRecorder rec, String search, List<ToolProvider> sources) => SizedBox(
  width: 400,
  child: DataSourcesPanel(searchText: search, onSelect: rec.call, dataSources: sources),
);

void main() {
  setUpBlockSelectorTests();

  group('DataSources', () {
    group('Selection', () {
      testWidgets('should add default file extensions for the built-in local file data source', (t) async {
        final rec = SelectRecorder();
        await pumpSelector(t, _sources(rec, '', [_source()]));
        await tapText(t, 'File Source');
        await tapText(t, 'Local File');
        final (type, value) = rec.calls.single;
        expect(type, 'datasource');
        expect(value, containsPair('provider_name', 'file'));
        expect(value, containsPair('datasource_name', 'local-file'));
        expect(value, containsPair('datasource_label', 'Local File'));
        expect(value!['fileExtensions'], containsAll(['txt', 'pdf', 'md']));
      });

      testWidgets('should filter providers by search text', (t) async {
        await pumpSelector(
          t,
          _sources(SelectRecorder(), 'searchable', [
            _source(
              id: 'searchable-provider',
              name: 'searchable-provider',
              label: 'Searchable Source',
              tools: [toolJson('searchable-tool', 'Searchable Tool')],
            ),
            _source(id: 'other-provider', name: 'other-provider', label: 'Other Source'),
          ]),
        );
        expect(find.text('Searchable Source'), findsOneWidget);
        expect(find.text('Other Source'), findsNothing);
      });
    });

    group('Marketplace Search', () {
      testWidgets('should debounce marketplace requests while keeping datasource filtering responsive', (t) async {
        final searches = <MarketplaceQuery>[];
        final data = BlockSelectorData(
          enableMarketplace: true,
          searchMarketplace: (q) async {
            searches.add(q);
            return const [];
          },
        );
        final sources = [_source()];
        await pumpSelector(t, _sources(SelectRecorder(), '', sources), data: data);
        await pumpSelector(t, _sources(SelectRecorder(), 'i', sources), data: data);
        expect(find.text('plugin.findMoreInMarketplace'), findsNothing);
        await pumpSelector(t, _sources(SelectRecorder(), 'in', sources), data: data);
        await pumpSelector(t, _sources(SelectRecorder(), 'invoice', sources), data: data);
        expect(searches.where((q) => q.query != 'invoice'), isEmpty);

        await settle(t, 700);
        expect(searches.single.query, 'invoice');
        expect(searches.single.category, PluginCategory.datasource);
      });
    });
  });
}
