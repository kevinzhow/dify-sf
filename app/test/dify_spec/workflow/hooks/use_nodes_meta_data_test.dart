// dify-spec: web/app/components/workflow/hooks/__tests__/use-nodes-meta-data.spec.tsx
//
// useNodeMetaData's author and description are nodeMetaDataOf (hooks/use_nodes_meta_data.dart), shown in the node
// menu's About.
import 'package:dify_sf_app/src/workflow_editor/hooks/use_nodes_meta_data.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('useNodesMetaData', () {
    test('resolves built-in tool metadata from tool providers', () {
      final meta = nodeMetaDataOf(
        {'type': 'tool', 'title': 'Tool Node', 'desc': '', 'provider_type': 'builtin', 'provider_id': 'provider-1'},
        buildInTools: [
          {
            'id': 'provider-1',
            'author': 'Provider Author',
            'description': {'en-US': 'Built-in provider description'},
          },
        ],
        language: 'en-US',
      );
      expect(meta.author, 'Provider Author');
      expect(meta.description, 'Built-in provider description');
    });

    test('prefers workflow store data for datasource nodes and keeps generic metadata for normal blocks', () {
      final datasource = nodeMetaDataOf(
        {'type': 'datasource', 'title': 'Dataset', 'desc': '', 'plugin_id': 'datasource-1'},
        dataSourceList: [
          {
            'plugin_id': 'datasource-1',
            'author': 'Datasource Author',
            'description': {'en-US': 'Datasource description'},
          },
        ],
        language: 'en-US',
      );
      expect(datasource.author, 'Datasource Author');
      expect(datasource.description, 'Datasource description');
      final normal = nodeMetaDataOf({'type': 'llm', 'title': 'Writer', 'desc': ''}, language: 'en-US');
      expect(normal.author, 'Dify');
      expect(normal.description, 'workflow.blocksAbout.llm');
    });
  });
}
