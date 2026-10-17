// dify-spec: web/app/components/base/prompt-editor/__tests__/hooks.spec.tsx
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_chips.dart';
import 'package:dify_sf_app/src/workflow_editor/prompt_editor/prompt_editor.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  group('prompt-editor/hooks', () {
    // A block is one character of the editor text; "selected" is the selection covering exactly it.
    bool selectedAt(WidgetTester t, int offset) {
      final s = editorState(t).controller.selection;
      return s.start == offset && s.end == offset + 1;
    }

    group('useSelectOrDelete', () {
      testWidgets('should register delete and backspace commands and select node on click', (t) async {
        await render(t, const DifyPromptEditor(value: 'a {{#query#}}', queryBlock: PromptBlockConfig(show: true)));
        await t.tap(find.byType(QueryChip));
        await t.pump();
        expect(selectedAt(t, 2), isTrue);
        expect(t.widget<QueryChip>(find.byType(QueryChip)).selected, isTrue);
      });

      Future<void> deleteFocusedBlock(WidgetTester t, String kind) async {
        var deleted = 0;
        void onDelete() => deleted++;
        final value = {'context': '{{#context#}}', 'history': '{{#histories#}}', 'query': '{{#query#}}'}[kind]!;
        await render(
          t,
          DifyPromptEditor(
            value: 'a$value',
            contextBlock: kind == 'context' ? ContextBlockConfig(show: true, onDelete: onDelete) : null,
            historyBlock: kind == 'history' ? HistoryBlockConfig(show: true, onDelete: onDelete) : null,
            queryBlock: kind == 'query' ? PromptBlockConfig(show: true, onDelete: onDelete) : null,
          ),
        );
        await focusAt(t, 1);
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await t.pump();
        expect(deleted, 1);
        expect(editorState(t).controller.prompt, 'a');
      }

      testWidgets('should dispatch delete command when unselected context block is focused', (t) async {
        await deleteFocusedBlock(t, 'context');
      });

      testWidgets('should dispatch delete command when unselected history block is focused', (t) async {
        await deleteFocusedBlock(t, 'history');
      });

      testWidgets('should dispatch delete command when unselected query block is focused', (t) async {
        await deleteFocusedBlock(t, 'query');
      });

      testWidgets('should prevent default and remove selected decorator node on delete', (t) async {
        var deleted = 0;
        await render(
          t,
          DifyPromptEditor(
            value: 'a {{#query#}} b',
            queryBlock: PromptBlockConfig(show: true, onDelete: () => deleted++),
          ),
        );
        await t.tap(find.byType(QueryChip));
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.backspace);
        await t.pump();
        expect(deleted, 1);
        expect(editorState(t).controller.prompt, 'a  b');
      });

      testWidgets('should remove selected decorator node without dispatching when command is undefined', (t) async {
        await render(
          t,
          const DifyPromptEditor(
            value: '{{#n.x#}}',
            workflowVariableBlock: WorkflowVariableBlockConfig(show: true),
          ),
        );
        await t.tap(find.byType(WorkflowVariableChip));
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.delete);
        await t.pump();
        expect(editorState(t).controller.prompt, '');
      });

      Future<void> clickWith(WidgetTester t, LogicalKeyboardKey key) async {
        await render(t, const DifyPromptEditor(value: 'a {{#query#}}', queryBlock: PromptBlockConfig(show: true)));
        await t.sendKeyDownEvent(key);
        await t.tap(find.byType(QueryChip));
        await t.sendKeyUpEvent(key);
        await t.pump();
        expect(selectedAt(t, 2), isFalse);
      }

      testWidgets('should not select when metaKey is pressed on click', (t) async {
        await clickWith(t, LogicalKeyboardKey.metaLeft);
      });

      testWidgets('should not select when ctrlKey is pressed on click', (t) async {
        await clickWith(t, LogicalKeyboardKey.controlLeft);
      });
    });

    group('useTrigger', () {
      testWidgets('should toggle open state when trigger element is clicked', (t) async {
        await render(t, const DifyPromptEditor(value: '{{#context#}}', contextBlock: ContextBlockConfig(show: true)));
        final count = find.text('0');
        await t.tap(count);
        await t.pumpAndSettle();
        expect(find.text('common.promptEditor.context.modal.footer'), findsOneWidget);
        await t.tap(count);
        await t.pumpAndSettle();
        expect(find.text('common.promptEditor.context.modal.footer'), findsNothing);
      });
    });

    group('useBasicTypeaheadTriggerMatch', () {
      test('should return match details when input satisfies trigger and length rules', () {
        expect(basicTypeaheadTriggerMatch('@', 'prefix @ab', minLength: 2, maxLength: 5), (
          leadOffset: 7,
          matchingString: 'ab',
          replaceableString: '@ab',
        ));
      });

      test('should return null when matching text is shorter than minLength', () {
        expect(basicTypeaheadTriggerMatch('@', 'prefix @a', minLength: 2, maxLength: 5), isNull);
      });

      test('should return null when matching text exceeds maxLength', () {
        expect(basicTypeaheadTriggerMatch('@', 'prefix @abc', minLength: 1, maxLength: 2), isNull);
      });

      test('should return null when text has no trigger character', () {
        expect(basicTypeaheadTriggerMatch('@', 'no trigger here', minLength: 1, maxLength: 75), isNull);
      });

      test('should match a trigger at the start of the text', () {
        expect(basicTypeaheadTriggerMatch('/', '/query', minLength: 0, requireTriggerBoundary: true), (
          leadOffset: 0,
          matchingString: 'query',
          replaceableString: '/query',
        ));
      });

      test('should match a trigger preceded by whitespace', () {
        expect(basicTypeaheadTriggerMatch('/', 'prefix /query', minLength: 0, requireTriggerBoundary: true), (
          leadOffset: 7,
          matchingString: 'query',
          replaceableString: '/query',
        ));
      });

      for (final text in ['https://dict.youdao.com/dictvoice', 'path/to/file']) {
        test('should not match a trigger preceded by a non-whitespace character in %s', () {
          expect(basicTypeaheadTriggerMatch('/', text, minLength: 0, requireTriggerBoundary: true), isNull);
        });
      }

      test('should preserve triggers without a required boundary', () {
        expect(basicTypeaheadTriggerMatch('{', 'prefix{query', minLength: 0), (
          leadOffset: 6,
          matchingString: 'query',
          replaceableString: '{query',
        ));
      });
    });
  });
}
