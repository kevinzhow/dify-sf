import 'package:dify_sf_app/src/workflow_editor/code_editor/code_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/editor_view.dart';
import 'package:dify_sf_app/src/workflow_editor/code_editor/paragraph.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart' as re;

Widget host({bool readOnly = false}) => MaterialApp(
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: SizedBox(
        width: 230,
        height: 220,
        child: CodeEditorView(
          value: '\t    alpha beta gamma delta epsilon 😀 中文 zeta',
          language: CodeLanguage.javascript,
          readOnly: readOnly,
        ),
      ),
    ),
  ),
);
void main() {
  String? copied;
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
        return null;
      },
    );
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  test('visual rows preserve UTF16 source, affinity and selection geometry', () {
    const source = '    hello 世界 😀 abcdefghijklmnopqrstuvwxyz\tend';
    final p = WrappedParagraph(
      const TextSpan(text: source),
      const TextStyle(fontSize: 14, fontFamily: 'monospace'),
      130,
    );
    addTearDown(p.dispose);
    expect(p.lineCount, greaterThan(2));
    expect(p.length, source.length);
    for (var at = 0; at <= source.length; at++) {
      if (at > 0 && at < source.length && source.codeUnitAt(at) >= 0xdc00 && source.codeUnitAt(at) <= 0xdfff) continue;
      for (final affinity in TextAffinity.values) {
        final pos = TextPosition(offset: at, affinity: affinity);
        final xy = p.getOffset(pos);
        expect(p.getPosition(xy + Offset(0, p.preferredLineHeight / 2)).offset, at, reason: '$pos => $xy');
      }
    }
    expect(p.getRangeRects(const TextRange(start: 0, end: source.length)).length, greaterThan(2));
    expect(p.span.toPlainText(), source);
  });
  testWidgets('real text input composition, undo and continuation hit tests keep original tabs', (t) async {
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    final view = t.state<CodeEditorViewState>(find.byType(CodeEditorView));
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    view.controller.selection = const TextSelection.collapsed(offset: 5);
    await t.pump();
    final before = view.text;
    final remote = TextEditingValue.fromJSON(t.testTextInput.editingState!);
    final at = remote.selection.start;
    final composingValue = remote.copyWith(
      text: remote.text.replaceRange(at, at, '中'),
      selection: TextSelection.collapsed(offset: at + 1),
      composing: TextRange(start: at, end: at + 1),
    );
    t.testTextInput.updateEditingValue(composingValue);
    await t.pump();
    expect(view.text, before.replaceRange(5, 5, '中'));
    expect(view.controller.value.composing, const TextRange(start: 5, end: 6));
    final next = composingValue;
    t.testTextInput.updateEditingValue(
      next.copyWith(
        text: next.text.replaceRange(at, at + 1, '中文'),
        selection: TextSelection.collapsed(offset: at + 2),
        composing: TextRange.empty,
      ),
    );
    await t.pump();
    expect(view.text, before.replaceRange(5, 5, '中文'));
    expect(view.text.contains('\u200b'), isFalse);
    native.controller!.undo();
    await t.pump();
    expect(view.text, before);
    final metrics = CodeEditorMetrics.of(Theme.of(t.element(find.byType(re.CodeEditor))).platform);
    final span = native.controller!.buildTextSpan(
      context: t.element(find.byType(re.CodeEditor)),
      index: 0,
      textSpan: const TextSpan(),
      style: metrics.style,
    );
    final paragraph = native.controller!.paragraphBuilder!(span, metrics.style, 230, null) as WrappedParagraph;
    expect(paragraph.lineCount, greaterThan(1));
    final boundary = paragraph.projection.startOf(1);
    final local = paragraph.getOffset(TextPosition(offset: boundary));
    await t.tapAt(
      t.getTopLeft(find.byType(re.CodeEditor)) +
          Offset(metrics.contentLeft(1) + local.dx, local.dy + paragraph.preferredLineHeight / 2),
    );
    await t.pump();
    expect(view.controller.selection.extentOffset, boundary);
    native.controller!.selectAll();
    native.controller!.copy();
    await t.pump();
    expect(copied, before);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('read-only mobile editor refuses destructive keys', (t) async {
    await t.pumpWidget(host(readOnly: true));
    await t.pumpAndSettle();
    final view = t.state<CodeEditorViewState>(find.byType(CodeEditorView));
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    view.controller.selection = const TextSelection.collapsed(offset: 5);
    await t.pump();
    final before = view.text;
    await t.sendKeyEvent(LogicalKeyboardKey.backspace);
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(view.text, before);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets('font arrival rebuilds paragraphs without losing composition or focused input', (t) async {
    await t.pumpWidget(host());
    await t.pumpAndSettle();
    final view = t.state<CodeEditorViewState>(find.byType(CodeEditorView));
    final native = t.widget<re.CodeEditor>(find.byType(re.CodeEditor));
    native.focusNode!.requestFocus();
    view.controller.value = view.controller.value.copyWith(
      selection: const TextSelection.collapsed(offset: 6),
      composing: const TextRange(start: 5, end: 6),
    );
    await t.pump();
    final before = view.controller.value;
    await t.binding.handleSystemMessage({'type': 'fontsChange'});
    await t.pump();
    await t.pump();
    expect(view.controller.value, before);
    expect(native.focusNode!.hasFocus, isTrue);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
