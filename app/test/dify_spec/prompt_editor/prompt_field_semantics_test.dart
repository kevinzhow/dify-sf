// dify-sf (no Dify spec), PR #89 review of the phone polish: the prompt field tells a screen reader its text with each
// variable's name in place, and maps every offset between that text and the editor's (a block is one character there):
// a selection the platform sets after a variable puts the caret after it, so an insert goes there. A plain prompt is
// the field's own text. On a phone the Jinja switch's whole touch box toggles it. Cases from Winnie's review
// (pr89_semantics_touch_review5_test.dart), plus the offset map itself.
import 'dart:ui' as ui;

import 'package:dify_sf_app/src/design/widgets/widgets.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// The node control [f] forms, or the one it is merged into, as the platform gets it.
SemanticsNode _platformNode(WidgetTester t, Finder f) {
  final pending = <RenderObject>[t.renderObject(f)];
  while (pending.isNotEmpty) {
    final r = pending.removeAt(0);
    if (r.debugSemantics case final n?) {
      var m = n;
      while (m.isMergedIntoParent && m.parent != null) {
        m = m.parent!;
      }
      return m;
    }
    r.visitChildren(pending.add);
  }
  return t.getSemantics(f);
}

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('a screen reader\'s selection after a named variable puts the caret after the variable; an insert goes '
      'there', (t) async {
    final semantics = t.ensureSemantics();
    try {
      await render(
        t,
        DifyPromptEditor(
          value: 'A {{#start1.query#}} abcdefghijklmnopqrst',
          onChange: (_) {},
          workflowVariableBlock: testVarBlock,
        ),
      );
      await focusAt(t);
      final c = editorState(t).controller;
      final n = t.getSemantics(find.byType(EditableText));
      final spoken = n.getSemanticsData().value;
      expect(spoken, 'A Start query abcdefghijklmnopqrst');
      final semanticOffset = spoken.indexOf(' abcdefghijklmnopqrst');
      t.binding.renderViews.first.owner!.semanticsOwner!.performAction(n.id, ui.SemanticsAction.setSelection, {
        'base': semanticOffset,
        'extent': semanticOffset,
      });
      await t.pump();
      final actualOffset = c.text.indexOf(' abcdefghijklmnopqrst');
      final receivedOffset = c.selection.baseOffset;
      await typeText(t, 'X');
      expect(
        c.text.substring(actualOffset),
        startsWith('X abcdefghijklmnopqrst'),
        reason: 'platform requested $semanticOffset, editing received $receivedOffset, variable ends at $actualOffset',
      );
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  testWidgets('a plain prompt takes a screen reader\'s selection at the same offset', (t) async {
    final semantics = t.ensureSemantics();
    try {
      await render(t, DifyPromptEditor(value: 'A Start query abcdefghijklmnopqrst', onChange: (_) {}));
      await focusAt(t);
      final c = editorState(t).controller;
      final n = t.getSemantics(find.byType(EditableText));
      expect(n.getSemanticsData().value, 'A Start query abcdefghijklmnopqrst');
      const offset = 13;
      t.binding.renderViews.first.owner!.semanticsOwner!.performAction(n.id, ui.SemanticsAction.setSelection, {
        'base': offset,
        'extent': offset,
      });
      await t.pump();
      expect(c.selection.baseOffset, offset);
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  testWidgets('a phone: the Jinja switch toggles at the centre and 2 dp inside each edge of its accessible target', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    try {
      t.view.physicalSize = const Size(411, 914);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var toggles = 0;
      await render(
        t,
        DifyPromptEditorPanel(
          title: 'Prompt',
          value: 'Hello',
          onChange: (_) {},
          isSupportJinja: true,
          onEditionTypeChange: (_) => toggles++,
        ),
        width: 390,
      );
      final f = find.byType(DifySwitch);
      expect(f, findsOneWidget);
      final n = _platformNode(t, f);
      var r = n.rect;
      for (SemanticsNode? a = n; a != null; a = a.parent) {
        if (a.transform case final m?) r = MatrixUtils.transformRect(m, r);
      }
      expect(r.height, greaterThanOrEqualTo(44));
      await t.tap(f);
      await t.pump();
      expect(toggles, 1, reason: 'the visible switch');
      for (final p in [
        r.center,
        Offset(r.center.dx, r.top + 2),
        Offset(r.center.dx, r.bottom - 2),
        Offset(r.left + 2, r.center.dy),
        Offset(r.right - 2, r.center.dy),
      ]) {
        final old = toggles;
        await t.tapAt(p);
        await t.pump();
        expect(toggles, old + 1, reason: 'point $p inside target=$r');
      }
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  test('the offset map: exact at each character; inside a name, the nearer edge of its block (or the asked one); a '
      'replaced value keeps the blocks outside the change', () {
    final c = PromptEditorController(
      prompt: 'A {{#start1.query#}} b',
      blocks: const PromptBlockSet({PromptBlockKind.workflowVariable}),
    )..blockLabel = (b) => 'Start query';
    final m = c.semanticsText!;
    expect(m.value, 'A Start query b');
    // Text: "A " + block + " b" (5 long); value: "A " + "Start query" + " b".
    expect([for (var i = 0; i <= 5; i++) m.toValue(i)], [0, 1, 2, 13, 14, 15]);
    expect(m.toText(2), 2);
    expect(m.toText(13), 3);
    expect(m.toText(5), 2, reason: '"Sta|rt": nearer the start');
    expect(m.toText(10), 3, reason: '"Start qu|ery": nearer the end');
    expect(m.toText(10, floor: true), 2);
    expect(m.toText(5, ceil: true), 3);
    expect(
      m.toValueSelection(const TextSelection(baseOffset: 2, extentOffset: 3)),
      const TextSelection(baseOffset: 2, extentOffset: 13),
    );
    expect(
      m.toTextSelection(const TextSelection(baseOffset: 2, extentOffset: 13)),
      const TextSelection(baseOffset: 2, extentOffset: 3),
    );
    // "b" replaced by "c": the block stays.
    c.text = m.textFor('A Start query c');
    expect(c.prompt, 'A {{#start1.query#}} c');
    // A name changed in part: the block goes, the typed text stays.
    final m2 = c.semanticsText!;
    c.text = m2.textFor('A Stat query c');
    expect(c.prompt, 'A Stat query c');
    // Names next to a word or another name are read apart (recheck 4: "textSlow"); the spaces belong to the blocks.
    final adjacent = PromptEditorController(
      prompt: 'A{{#start1.query#}}{{#start1.query#}}b {{#start1.query#}}.',
      blocks: const PromptBlockSet({PromptBlockKind.workflowVariable}),
    )..blockLabel = (b) => 'Start query';
    final a = adjacent.semanticsText!;
    expect(a.value, 'A Start query Start query b Start query.');
    // Text: "A" b b "b " b "." (7 long).
    expect([for (var i = 0; i <= 7; i++) a.toValue(i)], [0, 1, 13, 26, 27, 28, 39, 40]);
    expect(a.toText(13), 2);
    adjacent.dispose();
    // No named block: no map (the field's own text).
    expect((PromptEditorController(prompt: 'plain')..blockLabel = (b) => 'x').semanticsText, isNull);
    c.dispose();
  });
}
