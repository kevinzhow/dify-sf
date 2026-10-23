// dify-spec: web/app/components/base/prompt-editor/plugins/__tests__/update-block.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('UpdateBlock', () {
    group('Update value event', () {
      testWidgets('should update editor state when update event matches instance id', (t) async {
        final controller = PromptEditorController();
        addTearDown(controller.dispose);
        await render(t, DifyPromptEditor(controller: controller));
        controller.prompt = 'updated text';
        await t.pump();
        expect(find.text('updated text', findRichText: true), findsOneWidget);
      });
    });

    group('Quick insert event', () {
      testWidgets('should insert slash when quick insert event matches instance id', (t) async {
        var value = '';
        await render(
          t,
          DifyPromptEditorPanel(title: 'Prompt', value: value, onChange: (v) => value = v),
        );
        await t.tap(find.bySemanticsLabel('workflow.common.insertVarTip'));
        await t.pump();
        expect(value, '/');
        expect(editorState(t).focusNode.hasFocus, isTrue);
      });
    });
  });
}
