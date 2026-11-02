// dify-sf (no Dify spec), PR #89 review of the phone polish: the prompt field's semantics value is exactly the text it
// edits (a block is its one character there), so the offsets and texts the platform sends act on the real text; the
// sentence with each variable's name in place is the field's hint (read with it), and the chips are out of the tree.
// A plain prompt is the field's own text. On a phone the Jinja switch's whole touch box toggles it. Cases from
// Winnie's reviews (pr89_semantics_touch_review5_test.dart: the selection after a variable, a plain prompt, Jinja;
// pr89_prompt_replacement_review13_test.dart: a deleted variable next to an identical literal, a changed suffix,
// character moves), with the offsets of the edited text.
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

/// [action] on the prompt field's node, as the platform sends it.
void _act(WidgetTester t, ui.SemanticsAction action, [Object? args]) {
  final n = t.getSemantics(find.byType(EditableText));
  t.binding.renderViews.first.owner!.semanticsOwner!.performAction(n.id, action, args);
}

/// The prompt field's node data, as the platform gets it.
SemanticsData _field(WidgetTester t) => t.getSemantics(find.byType(EditableText)).getSemanticsData();

void main() {
  setUp(useDifyTestTranslator);

  testWidgets('a screen reader\'s selection after a named variable puts the caret after the variable; an insert goes '
      'there; the field reads the sentence with the name as its hint', (t) async {
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
      // The value is the edited text (the variable is its one character); the sentence is the hint.
      final spoken = n.getSemanticsData().value;
      expect(spoken, c.text);
      expect(n.getSemanticsData().hint, 'A Start query abcdefghijklmnopqrst');
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
      expect(n.getSemanticsData().hint, isEmpty, reason: 'no variable: the value says it all');
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

  testWidgets('deleting a selected variable and its space keeps the identical literal after it (review13): the '
      'platform selects them in the edited text and sets the text without them', (t) async {
    final semantics = t.ensureSemantics();
    try {
      await render(
        t,
        DifyPromptEditor(
          value: '{{#start1.query#}} Start query',
          onChange: (_) {},
          workflowVariableBlock: testVarBlock,
        ),
      );
      await focusAt(t, 0);
      final c = editorState(t).controller;
      expect(_field(t).value, c.text, reason: 'the variable is one character, then " Start query"');
      expect(_field(t).hint, 'Start query Start query');
      _act(t, ui.SemanticsAction.setSelection, {'base': 0, 'extent': 2});
      await t.pump();
      expect(c.selection, const TextSelection(baseOffset: 0, extentOffset: 2), reason: 'the variable and the space');
      _act(t, ui.SemanticsAction.setText, _field(t).value.substring(2));
      await t.pump();
      expect(c.prompt, 'Start query', reason: 'the selected variable is deleted; the literal stays');
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  testWidgets('a text the platform sets with a changed suffix keeps an unselected variable (review13)', (t) async {
    final semantics = t.ensureSemantics();
    try {
      await render(
        t,
        DifyPromptEditor(value: '{{#start1.query#}} suffix', onChange: (_) {}, workflowVariableBlock: testVarBlock),
      );
      await focusAt(t);
      final c = editorState(t).controller;
      _act(t, ui.SemanticsAction.setText, _field(t).value.replaceFirst('suffix', 'changed'));
      await t.pump();
      expect(c.prompt, '{{#start1.query#}} changed');
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  testWidgets('character moves pass a variable whole, both ways; the selection told is the editor\'s (review13)', (
    t,
  ) async {
    final semantics = t.ensureSemantics();
    try {
      await render(
        t,
        DifyPromptEditor(value: 'A {{#start1.query#}} b', onChange: (_) {}, workflowVariableBlock: testVarBlock),
      );
      await focusAt(t, 0);
      final c = editorState(t).controller;
      for (final expected in [1, 2, 3, 4, 5]) {
        _act(t, ui.SemanticsAction.moveCursorForwardByCharacter, false);
        await t.pump();
        expect(c.selection, TextSelection.collapsed(offset: expected));
        expect(_field(t).textSelection!.extentOffset, expected);
      }
      for (final expected in [4, 3, 2, 1, 0]) {
        _act(t, ui.SemanticsAction.moveCursorBackwardByCharacter, false);
        await t.pump();
        expect(c.selection, TextSelection.collapsed(offset: expected));
        expect(_field(t).textSelection!.extentOffset, expected);
      }
    } finally {
      await t.pumpWidget(const SizedBox());
      semantics.dispose();
    }
  });

  test('the sentence read with the field: each name in its place, apart from a word or another name next to it', () {
    PromptEditorController controller(String prompt) =>
        PromptEditorController(prompt: prompt, blocks: const PromptBlockSet({PromptBlockKind.workflowVariable}))
          ..blockLabel = (b) => 'Start query';
    expect(controller('A {{#start1.query#}} b').readableText, 'A Start query b');
    // Recheck 4 ("textSlow"): names next to a word or another name are read apart.
    expect(
      controller('A{{#start1.query#}}{{#start1.query#}}b {{#start1.query#}}.').readableText,
      'A Start query Start query b Start query.',
    );
    // No named block: no sentence (the value says it all).
    expect(controller('plain').readableText, isNull);
    // The value is the edited text: one character per block.
    final c = controller('A {{#start1.query#}} b');
    expect(c.text.length, 5);
    c.dispose();
  });
}
