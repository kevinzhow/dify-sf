// dify-spec: web/app/components/workflow/block-selector/tool/tool-list-tree-view/__tests__/item.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/block_selector.dart';
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('ToolListTreeView Item', () {
    testWidgets('renders the group heading and its provider list', (t) async {
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: ToolTreeGroup(
            groupName: 'My Group',
            children: [
              ToolProviderRow(
                provider: toolProvider(label: 'Provider Alpha'),
                viewType: ViewType.tree,
                hasSearchText: false,
                onSelect: (_, [_]) {},
              ),
            ],
          ),
        ),
      );
      expect(find.text('My Group'), findsOneWidget);
      expect(find.text('Provider Alpha'), findsOneWidget);
    });
  });
}
