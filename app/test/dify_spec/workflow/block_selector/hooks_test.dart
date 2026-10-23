// dify-spec: web/app/components/workflow/block-selector/__tests__/hooks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('block-selector hooks', () {
    test('keeps the start tab enabled when a configured user input start node exists', () {
      final r = blockSelectorTabs(noStart: false, defaultActiveTab: BlockSelectorTab.start);
      expect(r.tabs.firstWhere((t) => t.tab == BlockSelectorTab.start).disabled, isFalse);
      expect(r.initialTab, BlockSelectorTab.start);
    });

    test('disables the start tab when an unconfigured start placeholder exists', () {
      final r = blockSelectorTabs(
        noStart: false,
        hasStartPlaceholderNode: true,
        defaultActiveTab: BlockSelectorTab.start,
      );
      final start = r.tabs.firstWhere((t) => t.tab == BlockSelectorTab.start);
      expect(start.disabled, isTrue);
      expect(start.disabledTip, 'workflow.tabs.unconfiguredStartDisabledTip');
      expect(r.initialTab, BlockSelectorTab.blocks);
    });

    test('chooses the enabled start panel when blocks, sources, and tools are unavailable', () {
      final r = blockSelectorTabs(
        noBlocks: true,
        noSources: true,
        noTools: true,
        noStart: false,
        forceEnableStartTab: true,
      );
      expect(r.tabs.firstWhere((t) => t.tab == BlockSelectorTab.start).disabled, isFalse);
      expect(r.initialTab, BlockSelectorTab.start);
    });

    test('returns the MCP tab only when it is not hidden', () {
      expect(toolTabs().any((t) => t.type == ToolType.mcp), isTrue);
      expect(toolTabs(hideMcp: true).any((t) => t.type == ToolType.mcp), isFalse);
    });

    test('includes the snippets tab by default', () {
      expect(blockSelectorTabs().tabs.map((t) => t.tab), [
        BlockSelectorTab.blocks,
        BlockSelectorTab.tools,
        BlockSelectorTab.sources,
        BlockSelectorTab.snippets,
      ]);
    });

    test('uses the same category order for tabs and the default fallback', () {
      final r = blockSelectorTabs(noStart: false, noSources: false);
      expect(r.tabs.map((t) => t.tab), [
        BlockSelectorTab.blocks,
        BlockSelectorTab.tools,
        BlockSelectorTab.sources,
        BlockSelectorTab.start,
        BlockSelectorTab.snippets,
      ]);
      expect(r.initialTab, BlockSelectorTab.blocks);
    });

    test('hides the snippets tab and falls back when snippets are disabled', () {
      final r = blockSelectorTabs(defaultActiveTab: BlockSelectorTab.snippets, noSnippets: true);
      expect(r.tabs.any((t) => t.tab == BlockSelectorTab.snippets), isFalse);
      expect(r.initialTab, BlockSelectorTab.blocks);
    });
  });
}
