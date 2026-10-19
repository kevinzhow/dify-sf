import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dify_spec/prompt_editor/harness.dart';
import 'support/app_fonts.dart';

void main() {
  setUp(useAppFonts);

  Future<void> mount(WidgetTester t, String value, {bool compact = false, double width = 300}) async {
    await t.pumpWidget(
      MaterialApp(
        home: Material(
          child: DefaultTextStyle(
            style: const TextStyle(fontFamily: 'Noto Sans', letterSpacing: 0),
            child: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width,
                child: DifyPromptEditor(
                  value: value,
                  compact: compact,
                  lineHeight: compact ? 20 : 18,
                  minHeight: 0,
                  workflowVariableBlock: testVarBlock,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
  }

  double height(WidgetTester t) => t.getSize(find.byType(CssInlineExtent)).height;

  testWidgets('HTTP URL occupies Chromium two chip lines of 19.25px', (t) async {
    await mount(t, '{{#llm1.text#}}\n{{#llm1.text#}}');
    expect(height(t), 38.5);
    expect(editorState(t).controller.prompt, '{{#llm1.text#}}\n{{#llm1.text#}}');
  });

  testWidgets('HTTP JSON grows only the line containing an inline chip', (t) async {
    await mount(t, '{\n  "kind": "daily",\n  "time": "{{#llm1.text#}}"\n}', compact: true);
    expect(height(t), closeTo(80.515625, 1e-6));
  });

  testWidgets('wrapping a chip uses the new line rather than growing the previous line', (t) async {
    await mount(t, 'abcdefghij {{#llm1.text#}}', width: 110);
    expect(height(t), closeTo(18 + 19.25, 1e-6));
    await mount(t, 'abcdefghij {{#llm1.text#}}', width: 300);
    expect(height(t), 19.25);
  });

  testWidgets('a chip starting exactly at a soft wrap belongs to the following line', (t) async {
    await mount(t, '{{#llm1.text#}}{{#llm1.text#}}', width: 110);
    expect(height(t), 38.5);
  });

  testWidgets('deleting a chip updates the occupied height and preserves the editable text', (t) async {
    await mount(t, 'a\n{{#llm1.text#}}');
    expect(height(t), 18 + 19.25);
    await focusAt(t);
    await deleteBlockAt(t, 2);
    expect(editorState(t).controller.prompt, 'a\n');
    expect(height(t), 36);
    await typeText(t, 'b');
    expect(editorState(t).controller.prompt, 'a\nb');
    expect(height(t), 36);
  });
}
