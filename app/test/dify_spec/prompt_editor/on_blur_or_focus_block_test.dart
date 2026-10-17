// dify-spec: web/app/components/base/prompt-editor/plugins/__tests__/on-blur-or-focus-block.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('OnBlurBlock', () {
    group('Focus and blur-sm handling', () {
      testWidgets('should call onFocus when focus command is dispatched', (t) async {
        var focus = 0;
        await render(t, DifyPromptEditor(onFocus: () => focus++));
        await focusAt(t);
        expect(focus, 1);
      });

      testWidgets('should call onBlur when blur-sm target is not var-search-input', (t) async {
        var blur = 0;
        final other = FocusNode();
        addTearDown(other.dispose);
        await render(
          t,
          Column(
            children: [
              DifyPromptEditor(onBlur: () => blur++),
              Focus(focusNode: other, child: const SizedBox(height: 10)),
            ],
          ),
        );
        await focusAt(t);
        other.requestFocus();
        await t.pump();
        expect(blur, 1);
      });

      testWidgets('should handle blur-sm when onBlur callback is not provided', (t) async {
        await render(t, const DifyPromptEditor());
        await focusAt(t);
        editorState(t).focusNode.unfocus();
        await t.pump();
        expect(t.takeException(), isNull);
      });

      testWidgets('should skip onBlur when blur-sm target is var-search-input', (t) async {
        var blur = 0;
        await render(t, DifyPromptEditor(onBlur: () => blur++, workflowVariableBlock: testVarBlock));
        await focusAt(t);
        await typeText(t, '{');
        expect(menuOpen(), isTrue);
        await t.tap(find.byType(EditableText).last);
        await t.pump();
        expect(editorState(t).focusNode.hasFocus, isFalse);
        expect(blur, 0);
        expect(menuOpen(), isTrue);
      });

      testWidgets('should handle focus command when onFocus callback is not provided', (t) async {
        await render(t, const DifyPromptEditor());
        await focusAt(t);
        expect(t.takeException(), isNull);
      });
    });

    group('Lifecycle cleanup', () {
      testWidgets('should unregister commands when component unmounts', (t) async {
        var calls = 0;
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await render(t, DifyPromptEditor(focusNode: focus, onFocus: () => calls++, onBlur: () => calls++));
        await t.pumpWidget(Focus(focusNode: focus, child: const SizedBox()));
        focus.requestFocus();
        await t.pump();
        focus.unfocus();
        await t.pump();
        expect(calls, 0);
      });
    });
  });
}
