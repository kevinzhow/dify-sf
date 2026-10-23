// dify-spec: web/app/components/workflow/nodes/start-placeholder/__tests__/panel.spec.tsx
//
// The node replacement, deselection, store flags, draft sync and webhook URL generation of handleSelectStartNode are
// the host's (StartPlaceholderHost.onSelectStartBlock): the case checks what the panel hands it.
import 'package:dify_sf_app/src/workflow_editor/node_panel/bodies/entry/start_placeholder/start_placeholder_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import '../trigger_plugin/panel_harness.dart';

void main() {
  setUp(useDifyTestTranslator);

  group('StartPlaceholderPanel', () {
    group('Start node selection', () {
      testWidgets('should replace the placeholder with user input and auto-open the next node selector', (t) async {
        final h = await Harness.start(t, [
          difyNode('placeholder-1', 'start-placeholder', {'title': 'Pick a start node', 'desc': ''}),
          difyNode('other-node', 'llm', {'title': 'LLM', 'desc': ''}),
        ]);
        final selections = <List<Object?>>[];
        await pumpBody(
          t,
          h,
          'placeholder-1',
          startPlaceholderPanelBody,
          wrap: (child) => StartPlaceholderHost(
            nodeDefaults: const {
              'start': {'title': 'User Input', 'desc': '', 'variables': <Object?>[]},
            },
            onSelectStartBlock: (id, type, data) => selections.add([id, type, data]),
            child: child,
          ),
        );

        await t.tap(find.text('workflow.blocks.start'));
        await Harness.settle(t);

        expect(selections, [
          [
            'placeholder-1',
            'start',
            {'title': 'User Input', 'desc': '', 'variables': <Object?>[], 'type': 'start', 'selected': true},
          ],
        ]);
        await h.dispose(t);
      });
    });
  });
}
