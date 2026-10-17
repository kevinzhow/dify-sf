// dify-spec: web/app/components/base/prompt-editor/plugins/variable-value-block/__tests__/index.spec.tsx
// dify-spec: web/app/components/base/prompt-editor/plugins/variable-block/__tests__/index.spec.tsx
import 'package:dify_sf_app/src/design/dify_tokens.g.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The text spans of the editor.
List<TextSpan> _spans(WidgetTester t) {
  final s = editorState(t);
  final root = s.controller.buildTextSpan(
    context: t.element(find.byType(EditableText)),
    style: const TextStyle(fontSize: 13),
    withComposing: false,
  );
  return [for (final c in root.children!) c as TextSpan];
}

void main() {
  group('VariableValueBlock', () {
    testWidgets('should render null and register lexical text entity when node is registered', (t) async {
      await render(t, const DifyPromptEditor(isSupportFileVar: true, value: 'a {{name}} b'));
      final accent = _spans(t).where((s) => s.style?.color == DifyColors.textAccent).map((s) => s.text).join();
      expect(accent, '{{name}}');
    });

    test('should return match offsets when placeholder exists and null when not present', () {
      expect(variableValueRanges('prefix {{foo_1}} suffix'), [(start: 7, end: 16)]);
      expect(variableValueRanges('prefix without variable'), isEmpty);
    });

    testWidgets('should create variable node from text node content in create callback', (t) async {
      await render(t, const DifyPromptEditor(isSupportFileVar: true, value: '{{account_id}}'));
      expect(_spans(t).map((s) => s.text).join(), '{{account_id}}');
      expect(_spans(t).every((s) => s.style?.color == DifyColors.textAccent), isTrue);
    });
  });

  group('VariableBlock', () {
    group('Command handling', () {
      testWidgets('should insert an opening brace when INSERT_VARIABLE_BLOCK_COMMAND is dispatched', (t) async {
        final c = await renderWithController(t, (c) => DifyPromptEditor(controller: c));
        c.insertText('{');
        expect(c.prompt, '{');
      });

      testWidgets('should insert provided value when INSERT_VARIABLE_VALUE_BLOCK_COMMAND is dispatched', (t) async {
        final c = await renderWithController(t, (c) => DifyPromptEditor(controller: c));
        c.insertText('{{custom_value}}');
        expect(c.prompt, '{{custom_value}}');
      });
    });
  });
}
