// dify-spec: web/app/components/base/prompt-editor/__tests__/prompt-editor-content.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('PromptEditorContent', () {
    group('Rendering', () {
      testWidgets('should render with real dependencies and forward update/focus/blur events', (t) async {
        final changes = <String>[];
        var focus = 0, blur = 0;
        final controller = PromptEditorController();
        addTearDown(controller.dispose);
        await render(
          t,
          DifyPromptEditor(
            controller: controller,
            compact: true,
            placeholder: 'Type prompt',
            onChange: changes.add,
            onFocus: () => focus++,
            onBlur: () => blur++,
          ),
        );
        expect(find.text('Type prompt'), findsOneWidget);
        expect(t.widget<TextField>(find.byType(TextField)).style?.fontSize, 13);
        controller.prompt = 'updated prompt';
        await t.pump();
        expect(changes, ['updated prompt']);
        await focusAt(t);
        editorState(t).focusNode.unfocus();
        await t.pump();
        expect(focus, 1);
        expect(blur, 1);
        expect(find.byType(EditableText), findsOneWidget);
      });

      testWidgets('should keep the shell stable without optional anchor or placeholder overrides', (t) async {
        await render(t, const DifyPromptEditor());
        expect(find.text('common.promptEditor.placeholder'), findsOneWidget);
      });
    });
  });
}
