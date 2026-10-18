// dify-spec: web/app/components/workflow/utils/__tests__/plugin-install-check.spec.ts
import 'package:dify_sf_app/src/workflow_editor/header/checklist/use_checklist.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> _tool([Map<String, Object?> overrides = const {}]) => {
  'id': 'langgenius/search/search',
  'name': 'search',
  'plugin_id': 'plugin-search',
  'provider': 'search-provider',
  'plugin_unique_identifier': 'plugin-search@1.0.0',
  ...overrides,
};

Map<String, Object?> _triggerProvider() => {
  'id': 'trigger-provider-id',
  'name': 'trigger-provider',
  'plugin_id': 'trigger-plugin',
};

void main() {
  group('plugin install check', () {
    group('matchToolInCollection', () {
      final collection = [_tool()];

      test('should match a tool by plugin id', () {
        expect(matchToolInCollection(collection, {'plugin_id': 'plugin-search'}), collection[0]);
      });

      test('should match a tool by legacy provider id', () {
        expect(matchToolInCollection(collection, {'provider_id': 'search'}), collection[0]);
      });

      test('should match a tool by provider name', () {
        expect(matchToolInCollection(collection, {'provider_name': 'search'}), collection[0]);
      });

      test('should return undefined when no tool matches', () {
        expect(matchToolInCollection(collection, {'plugin_id': 'missing-plugin'}), isNull);
      });
    });

    group('matchTriggerProvider', () {
      final providers = [_triggerProvider()];

      test('should match a trigger provider by name', () {
        expect(matchTriggerProvider(providers, {'provider_name': 'trigger-provider'}), providers[0]);
      });

      test('should match a trigger provider by id', () {
        expect(matchTriggerProvider(providers, {'provider_id': 'trigger-provider-id'}), providers[0]);
      });

      test('should match a trigger provider by plugin id', () {
        expect(matchTriggerProvider(providers, {'plugin_id': 'trigger-plugin'}), providers[0]);
      });
    });

    group('matchDataSource', () {
      final dataSources = [
        _tool({
          'provider': 'knowledge-provider',
          'plugin_id': 'knowledge-plugin',
          'plugin_unique_identifier': 'knowledge-plugin@1.0.0',
        }),
      ];

      test('should match a data source by unique identifier', () {
        expect(matchDataSource(dataSources, {'plugin_unique_identifier': 'knowledge-plugin@1.0.0'}), dataSources[0]);
      });

      test('should match a data source by plugin id', () {
        expect(matchDataSource(dataSources, {'plugin_id': 'knowledge-plugin'}), dataSources[0]);
      });

      test('should match a data source by provider name', () {
        expect(matchDataSource(dataSources, {'provider_name': 'knowledge-provider'}), dataSources[0]);
      });
    });

    group('isNodePluginMissing', () {
      const toolNode = {
        'type': 'tool',
        'title': 'Tool',
        'desc': '',
        'provider_type': 'builtin',
        'provider_id': 'missing-provider',
        'plugin_unique_identifier': 'missing-plugin@1.0.0',
      };
      const triggerNode = {
        'type': 'trigger-plugin',
        'title': 'Trigger',
        'desc': '',
        'provider_id': 'missing-trigger',
        'plugin_unique_identifier': 'trigger-plugin@1.0.0',
      };
      const dataSourceNode = {
        'type': 'datasource',
        'title': 'Data Source',
        'desc': '',
        'provider_name': 'missing-provider',
        'plugin_unique_identifier': 'missing-data-source@1.0.0',
      };

      test('should report missing tool plugins when the collection is loaded but unmatched', () {
        expect(isNodePluginMissing(toolNode, ChecklistEnv(builtInTools: [_tool()])), isTrue);
      });

      test('should keep tool nodes installable when the collection has not loaded yet', () {
        expect(isNodePluginMissing(toolNode, ChecklistEnv()), isFalse);
      });

      test('should ignore unmatched tool nodes without plugin identifiers', () {
        final node = {...toolNode}..remove('plugin_unique_identifier');
        expect(isNodePluginMissing(node, ChecklistEnv(builtInTools: [_tool()])), isFalse);
      });

      test('should report missing trigger plugins when no provider matches', () {
        expect(isNodePluginMissing(triggerNode, ChecklistEnv(triggerPlugins: [_triggerProvider()])), isTrue);
      });

      test('should keep trigger plugin nodes installable when the provider list has not loaded yet', () {
        expect(isNodePluginMissing(triggerNode, ChecklistEnv()), isFalse);
      });

      test('should report missing data source plugins when the list is loaded but unmatched', () {
        expect(isNodePluginMissing(dataSourceNode, ChecklistEnv(dataSourceList: [_tool()])), isTrue);
      });

      test('should keep data source nodes installable when the list has not loaded yet', () {
        expect(isNodePluginMissing(dataSourceNode, ChecklistEnv()), isFalse);
      });

      test('should return false for unsupported node types', () {
        expect(isNodePluginMissing({'type': 'llm', 'title': 'LLM', 'desc': ''}, ChecklistEnv()), isFalse);
      });
    });
  });
}
