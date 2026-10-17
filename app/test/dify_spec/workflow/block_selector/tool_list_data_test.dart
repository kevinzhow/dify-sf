// dify-spec: web/app/components/workflow/block-selector/__tests__/tool-list-data.spec.ts
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

String _group(ToolGroup g) => g.author ?? g.category!;

void main() {
  group('createToolListData', () {
    test('normalizes letters and keeps non-alphabetic tools at the end', () {
      final r = createToolListData([
        toolProvider(id: 'custom', label: '1Custom', zhLabel: '1自定义'),
        toolProvider(id: 'chinese', label: 'Chinese', zhLabel: '中文'),
        toolProvider(id: 'alpha', label: 'Alpha'),
      ], (t) => t.label['zh_Hans']!.substring(0, 1));
      expect(r.letters, ['A', 'Z', '#']);
      expect([for (final f in r.flatTools) (f.tool.id, f.letter)], [('alpha', 'A'), ('chinese', 'Z'), ('custom', '#')]);
    });

    test('sorts the flat view by letter without changing the tree view provider order', () {
      final r = createToolListData([
        toolProvider(id: 'zeta', author: 'Zeta', label: 'Zeta'),
        toolProvider(id: 'alpha', author: 'Alpha', label: 'Alpha'),
      ], (t) => t.label['en_US']!.substring(0, 1));
      expect([for (final f in r.flatTools) f.tool.id], ['alpha', 'zeta']);
      expect(r.treeGroups.map(_group), ['Zeta', 'Alpha']);
    });

    test('keeps author and category group identities separate without sentinel keys', () {
      final r = createToolListData([
        toolProvider(id: 'author', author: 'custom'),
        toolProvider(id: 'category', type: CollectionType.custom),
      ], (_) => 'A');
      expect(r.treeGroups, hasLength(2));
      expect(r.treeGroups[0].author, 'custom');
      expect(r.treeGroups[0].category, isNull);
      expect(r.treeGroups[0].tools.single.id, 'author');
      expect(r.treeGroups[1].category, 'custom');
      expect(r.treeGroups[1].author, isNull);
      expect(r.treeGroups[1].tools.single.id, 'category');
    });

    test('maps workflow and data source providers to distinct categories', () {
      final r = createToolListData([
        toolProvider(id: 'workflow', type: CollectionType.workflow),
        toolProvider(id: 'data-source', type: 'local_file'),
      ], (_) => 'A');
      expect(
        [for (final g in r.treeGroups) (g.category, g.tools.single.id)],
        [
          ('workflow', 'workflow'),
          ('data-source', 'data-source'),
        ],
      );
    });

    test('merges providers across letters and keeps MCP and plugin provider identities explicit', () {
      const letters = {'author-a': 'A', 'author-b': 'B', 'mcp': 'C', 'plugin': 'D'};
      final r = createToolListData([
        toolProvider(id: 'author-a', author: 'Dify'),
        toolProvider(id: 'author-b', author: 'Dify'),
        toolProvider(id: 'mcp', type: CollectionType.mcp),
        toolProvider(id: 'plugin', author: 'Plugin Author', type: 'plugin'),
      ], (t) => letters[t.id] ?? '#');
      expect(
        [
          for (final g in r.treeGroups) (g.author, g.category, [for (final t in g.tools) t.id].join(',')),
        ],
        [
          ('Dify', null, 'author-a,author-b'),
          (null, 'mcp', 'mcp'),
          ('Plugin Author', null, 'plugin'),
        ],
      );
    });
  });
}
