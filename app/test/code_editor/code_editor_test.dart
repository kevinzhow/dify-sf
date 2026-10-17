import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/monarch/vs_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import '../dify_spec/dify_test_i18n.dart';

Widget _host(Widget child, {double width = 420}) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Overlay.wrap(
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(width: width, child: child),
      ),
    ),
  ),
);

EditableText _editable(WidgetTester t) => t.widget<EditableText>(find.byType(EditableText));

/// (text, colour) of each leaf span the editor shows.
List<(String, Color?)> _spans(WidgetTester t) {
  final e = _editable(t);
  final span = e.controller.buildTextSpan(
    context: t.element(find.byType(EditableText)),
    style: e.style,
    withComposing: false,
  );
  final out = <(String, Color?)>[];
  void walk(InlineSpan s, Color? inherited) {
    if (s is! TextSpan) return;
    final color = s.style?.color ?? inherited;
    if (s.text != null && s.text!.isNotEmpty) out.add((s.text!, color));
    for (final c in s.children ?? const <InlineSpan>[]) {
      walk(c, color);
    }
  }

  walk(span, null);
  return out;
}

Future<void> _type(WidgetTester t, String text) async {
  final value = _editable(t).controller.value;
  final s = value.selection;
  t.testTextInput.updateEditingValue(
    TextEditingValue(
      text: value.text.replaceRange(s.start, s.end, text),
      selection: TextSelection.collapsed(offset: s.start + text.length),
    ),
  );
  await t.pump();
}

Future<void> _focusAt(WidgetTester t, int offset) async {
  await t.tap(find.byType(EditableText), warnIfMissed: false);
  await t.pump();
  _editable(t).controller.selection = TextSelection.collapsed(offset: offset);
  await t.pump();
}

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('colours tokens with the vs theme and brackets by nesting level', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'def f(a):\n    return "x"')));
    final spans = _spans(t);
    expect(spans, contains(('def', VsTheme.match('keyword.python').foreground)));
    expect(spans, contains(('(', VsTheme.bracketColors[0])));
    expect(spans, contains(('"x"', const Color(0xFFA31515))));
    expect(spans.map((s) => s.$1).join(), 'def f(a):\n    return "x"');
  });

  testWidgets('typing goes through Monaco\'s enter and auto-closing rules and reports changes', (t) async {
    final changes = <String>[];
    await t.pumpWidget(
      _host(DifyCodeEditor(language: CodeLanguage.python3, value: 'def main():', onChange: changes.add)),
    );
    await _focusAt(t, 11);
    await _type(t, '\n');
    expect(_editable(t).controller.text, 'def main():\n    ');
    await _type(t, '(');
    expect(_editable(t).controller.text, 'def main():\n    ()');
    await _type(t, ')');
    expect(_editable(t).controller.text, 'def main():\n    ()');
    expect(_editable(t).controller.selection, const TextSelection.collapsed(offset: 18));
    expect(changes.last, 'def main():\n    ()');
  });

  testWidgets('Tab indents, Shift+Tab outdents and Ctrl+/ toggles a comment', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'x = 1')));
    await _focusAt(t, 0);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    expect(_editable(t).controller.text, '    x = 1');
    await t.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(_editable(t).controller.text, 'x = 1');
    await t.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await t.sendKeyEvent(LogicalKeyboardKey.slash);
    await t.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(_editable(t).controller.text, '# x = 1');
  });

  testWidgets('a new value from outside replaces the text', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.javascript, value: 'a')));
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.javascript, value: 'b\nc')));
    expect(_editable(t).controller.text, 'b\nc');
  });

  testWidgets('read-only editors take no input', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.json, value: '{}', readOnly: true)));
    expect(_editable(t).readOnly, isTrue);
  });

  testWidgets('shows the placeholder while empty and unfocused', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, placeholder: 'Write code')));
    expect(find.text('Write code'), findsOneWidget);
    await _focusAt(t, 0);
    expect(find.text('Write code'), findsNothing);
  });

  testWidgets('expand lifts the editor over its area and keeps its text', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'x = 1', title: 'Code')));
    Finder labelled(String label) => find.byWidgetPredicate((w) => w is Semantics && w.properties.label == label);
    await t.tap(labelled('share.chat.expand'));
    await t.pump();
    expect(labelled('share.chat.collapse'), findsOneWidget);
    expect(_editable(t).controller.text, 'x = 1');
    // Fills the area (800 x 600) less the bottom padding, without the resize handle.
    expect(t.getSize(find.byType(CodeEditorView)).height, greaterThan(500));
    expect(labelled('common.resize.editor'), findsNothing);
    await t.tap(labelled('share.chat.collapse'));
    await t.pump();
    expect(labelled('share.chat.expand'), findsOneWidget);
  });

  testWidgets('the resize handle drags the body taller and a click resets it', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'x', height: 100)));
    double body() => t.getSize(find.byType(CodeEditorView)).height;
    expect(body(), 100 - 28 - 8);
    final handle = find.byWidgetPredicate((w) => w is Semantics && w.properties.label == 'common.resize.editor');
    await t.drag(handle, const Offset(0, 60));
    await t.pump();
    expect(body(), greaterThan(100));
    await t.tap(handle);
    await t.pump();
    expect(body(), 100 - 28 - 8);
  });

  testWidgets('without the wrapper the height follows Monaco\'s content height like Dify', (t) async {
    await t.pumpWidget(
      _host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'a\nb\nc', noWrapper: true)),
    );
    await t.pump();
    final lh = CodeEditorMetrics.of(TargetPlatform.android).lineHeight;
    // Mounted at 56 / 2 + 18 px; content = 3 lines + (46 - lineHeight) to scroll the last line to the top.
    expect(t.getSize(find.byType(CodeEditorView)).height, (3 * lh + 46 - lh) / 2 + 18);
  });

  testWidgets('a click in the margin selects the line', (t) async {
    await t.pumpWidget(_host(const DifyCodeEditor(language: CodeLanguage.python3, value: 'a = 1\nb = 2')));
    final view = t.getTopLeft(find.byType(CodeEditorView));
    final lh = CodeEditorMetrics.of(TargetPlatform.android).lineHeight;
    await t.tapAt(view + Offset(10, lh * 1.5));
    await t.pump();
    expect(_editable(t).controller.selection, const TextSelection(baseOffset: 6, extentOffset: 11));
  });
}
