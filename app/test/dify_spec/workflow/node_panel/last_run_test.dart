// dify-spec: web/app/components/workflow/nodes/_base/components/workflow-panel/last-run/__tests__/index.spec.tsx
//
// dify-sf has no last-run fetch yet: the tab is always the no-data state (the 404 case).
import 'package:dify_sf_app/src/workflow_editor/node_panel/node_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../dify_test_i18n.dart';

void main() {
  group('LastRun', () {
    testWidgets('should render the no-data state for 404 last-run responses and forward single-run clicks', (t) async {
      useDifyTestTranslator();
      var clicks = 0;
      Future<void> render({required bool canSingleRun}) => t.pumpWidget(
        MaterialApp(
          home: LastRun(canSingleRun: canSingleRun, onSingleRun: () => clicks++),
        ),
      );

      await render(canSingleRun: true);
      expect(find.text('workflow.debug.noData.description'), findsOneWidget);
      await t.tap(find.text('workflow.debug.noData.runThisNode'));
      await t.pump();
      expect(clicks, 1);

      await render(canSingleRun: false);
      expect(find.text('workflow.debug.noData.runThisNode'), findsNothing);
    });
  });
}
