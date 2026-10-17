// dify-spec: web/app/components/workflow/block-selector/tool/tool-list-flat-view/__tests__/list.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/block_selector/tools_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  setUpBlockSelectorTests();

  group('ToolListFlatView', () {
    testWidgets('assigns the first tool of each letter to the shared refs and renders the index bar', (t) async {
      await pumpSelector(
        t,
        SizedBox(
          width: 400,
          child: ToolsList(
            onSelect: (_, [_]) {},
            tools: [
              for (var i = 0; i < 11; i++)
                toolProvider(id: 'provider-$i', label: '${String.fromCharCode(65 + i)} Provider'),
            ],
          ),
        ),
      );
      expect(find.text('A Provider'), findsOneWidget);
      expect(find.text('B Provider'), findsOneWidget);
      final bar = t.widget<IndexBar>(find.byType(IndexBar));
      expect(bar.itemKeys['A']?.currentContext, isNotNull);
      expect(bar.itemKeys['B']?.currentContext, isNotNull);
    });
  });
}
